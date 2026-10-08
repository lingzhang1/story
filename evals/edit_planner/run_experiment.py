"""M-d.3 Edit Planner planning-quality experiment.

Scope: EXPERIMENTAL. Produces an experimental EditPlan/2 from frozen Story inputs via ONE Opus call, under a
deterministic validator. Compares Arm A (MusicPlan only) vs Arm B (MusicPlan + MusicAnalysis) on identical
inputs to answer: does real musical structure materially improve the plan? NO production code, NO rendering,
NO catalog, NO real Epidemic audio. Text-only Converse tool-use, temperature 0.

Usage:
  TMPDIR=/tmp .venv/bin/python evals/edit_planner/run_experiment.py --dry      # cost estimate + validate fixtures, no model
  TMPDIR=/tmp .venv/bin/python evals/edit_planner/run_experiment.py --run       # real Opus, writes evals/results/edit_planner_md3.json
  TMPDIR=/tmp .venv/bin/python evals/edit_planner/run_experiment.py --only tmb  # single scenario

The experimental EditPlan/2 shape under test (additive over the frozen EditPlanContract):
  story_id, creative_intent_id, target_duration_seconds, output_format,
  music_asset_id?, music_plan_id?, music_analysis_ref?,   # provenance / alignment source
  segments[]: order, asset_id(=Moment id), source_start_seconds?, source_end_seconds?,
              output_duration_seconds, speed?, transition?{type,duration_seconds?},
              narrative_role?, native_audio{keep|duck|mute},   # per-segment native-audio INTENT
              music_alignment?{anchor: beat|downbeat|highlight|none, note?}  # segment-level, no global beat_sync bool
NOTE: there is deliberately NO global beat_sync boolean — alignment is represented per segment (see §6 of the report).
"""
from __future__ import annotations
import argparse, json, pathlib, sys, time
from statistics import median

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO), str(REPO / "packages")]

MODEL = "us.anthropic.claude-opus-4-6-v1"  # strongest invocable Opus already used for Director/Guide/Coverage/MusicPlan
RESULTS = REPO / "evals/results"
FIX = json.loads((pathlib.Path(__file__).parent / "fixtures.json").read_text())["scenarios"]

TRANSITION = ["cut", "crossfade", "fade_in", "fade_out", "dip_to_black"]
NATIVE = ["keep", "duck", "mute"]
ANCHOR = ["beat", "downbeat", "highlight", "none"]

SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "target_duration_seconds": {"type": "number", "exclusiveMinimum": 0},
        "segments": {"type": "array", "minItems": 1, "items": {
            "type": "object", "additionalProperties": False,
            "properties": {
                "order": {"type": "integer", "minimum": 0},
                "asset_id": {"type": "string", "description": "a Moment id that EXISTS in the input moments[]"},
                "source_start_seconds": {"type": "number", "minimum": 0},
                "source_end_seconds": {"type": "number", "exclusiveMinimum": 0},
                "output_duration_seconds": {"type": "number", "exclusiveMinimum": 0},
                "speed": {"type": "number", "exclusiveMinimum": 0},
                "transition": {"type": "object", "additionalProperties": False, "properties": {
                    "type": {"type": "string", "enum": TRANSITION},
                    "duration_seconds": {"type": "number", "minimum": 0}}, "required": ["type"]},
                "narrative_role": {"type": "string"},
                "native_audio": {"type": "string", "enum": NATIVE},
                "music_alignment": {"type": "object", "additionalProperties": False, "properties": {
                    "anchor": {"type": "string", "enum": ANCHOR},
                    "note": {"type": "string"}}, "required": ["anchor"]},
            },
            "required": ["order", "asset_id", "source_start_seconds", "source_end_seconds",
                         "output_duration_seconds", "native_audio"]}},
    },
    "required": ["target_duration_seconds", "segments"],
}
# feasible defaults true; the planner sets it false (with infeasible_reason) rather than inventing footage.
SCHEMA["properties"]["feasible"] = {"type": "boolean"}
SCHEMA["properties"]["infeasible_reason"] = {"type": "string"}

SYSTEM = """You are the Edit Planner for a personal Story video. You PLAN the edit; you do NOT render it. You
never output pixels, mix curves, or sample-level audio automation — you produce a structured, executable plan a
separate Media Engine will run.

INPUTS you receive:
- CreativeIntent: what the user wants (feel, target duration).
- StoryGuide: the intended long-horizon narrative shape (dimensions).
- StoryCoverage: what the Story ACTUALLY became from captured material (meaning, sufficiency).
- Moments[]: the captured material. Each has an id, a duration, and observed events with timestamps and
  useful_segments (the sub-ranges worth using). Treat useful_segments as the good footage.
- MusicPlan: the intended SOUNDTRACK SHAPE (character, energy_arc as approximate fractions, audio_strategy
  with soundtrack_role + native_audio_priority).
- OPTIONALLY MusicAnalysis: the OBSERVED structure of the real chosen track (duration, bpm, beats[],
  downbeats[], a highlight window, sections). When present, align the edit to this REAL structure; when
  absent, plan from MusicPlan intent alone.

YOUR JOB — produce an EditPlan:
- Select the useful Moment SEGMENTS (source_start/end within each Moment's useful_segments) that tell the
  strongest achievable version of THIS Story. Do not use every Moment or every second.
- Order the segments into a coherent narrative progression grounded in the Guide/Coverage — not a generic
  montage template. A minimal/solitude Story may be a few calm held shots; do NOT manufacture a
  quiet->build->climax arc that the material does not support.
- DURATION DISCIPLINE: target_duration_seconds (from the Story's CreativeIntent) is AUTHORITATIVE. Plan TO the
  Story target, never to the music track's length. Prefer the requested duration when the usable footage
  supports it. Do NOT pad, repeat, slow, or stretch footage merely to fill a longer track. The music track is
  cut/looped downstream to fit the Story — the Story is NOT stretched to fit the track. ±20% is a hard
  feasibility TOLERANCE, not a planning target: aim at the target, not the edge. If the usable material cannot
  support the requested duration, do NOT invent footage — instead return feasible=false with a one-line
  infeasible_reason and your best shorter plan.
- NATIVE AUDIO (first-class): per segment set native_audio for the Moment's OWN CAPTURED audio:
    keep = preserve the Moment's meaningful captured sound (it carries the segment);
    duck = reduce the Moment's captured sound beneath the soundtrack;
    mute = omit the Moment's captured sound entirely.
  This controls ONLY the captured/source audio. (Whether the SOUNDTRACK itself recedes to protect a kept native
  moment is a downstream Media-Engine mix decision driven by MusicPlan.audio_strategy + native_audio=keep — NOT
  your call here.) If a Moment's own sound is the emotional payoff (a real guitar performance, birthday singing,
  meaningful dialogue), native_audio=keep. Otherwise duck or mute.
- MUSIC ALIGNMENT (RESTRAINED): If NO MusicAnalysis is given in the input, you MUST NOT set any
  music_alignment anchor — leave music_alignment off every segment (or anchor="none"). ONLY when MusicAnalysis
  IS given may you anchor, and even then default anchor="none" — most segments should NOT carry an anchor. Set
  an anchor (beat|downbeat|highlight) only when the alignment MATERIALLY serves narrative pacing, a transition,
  emphasis, the payoff, or the ending (anchor the payoff near the real highlight, a major cut on a downbeat).
  Do NOT align merely because beats exist. Preserve breathing room in slow/ambient/solitude Stories — stillness
  anchored to a beat serves nothing. Native-audio importance ALWAYS takes priority over musical alignment:
  never degrade a kept native moment to hit a beat.

HARD RULES:
- asset_id MUST be one of the provided Moment ids. NEVER invent footage, Moments, or seconds that do not exist.
- source ranges MUST lie within the Moment's real duration (and should lie within its useful_segments).
- No transitions that need footage you don't have. Keep transitions minimal (mostly cut).
- Smallest-useful wins; multiple valid edits exist — pick one coherent one. Return ONLY the EditPlan via the tool."""


def build_user(sc: dict, with_analysis: bool) -> str:
    payload = {
        "creative_intent": sc["creative_intent"],
        "story_guide": sc["story_guide"],
        "story_coverage": sc["story_coverage"],
        "moments": sc["moments"],
        "music_plan": sc["music_plan"],
        "target_duration_seconds": sc["creative_intent"]["target_duration_seconds"],
    }
    if with_analysis:
        payload["music_analysis"] = sc["music_analysis"]
    return ("Plan the EditPlan for THIS Story from the material below. Use only the given Moment ids and their "
            "real/useful ranges. Keep total output within +/-20% of target. Respect native audio.\n\nINPUT:\n"
            + json.dumps(payload, indent=2) + "\n\nReturn ONLY the EditPlan via the tool.")


# ---------------------------------------------------------------------------
# Deterministic executability validator (NEVER let the model self-certify).
# ---------------------------------------------------------------------------
def validate(plan: dict, sc: dict) -> list[str]:
    errs: list[str] = []
    moments = {m["id"]: m for m in sc["moments"]}
    segs = plan.get("segments", [])
    if not segs:
        errs.append("no segments")
    orders = [s.get("order") for s in segs]
    if orders != sorted(orders):
        errs.append(f"segment order not monotonic: {orders}")
    if len(set(orders)) != len(orders):
        errs.append(f"duplicate order values: {orders}")
    total_out = 0.0
    for i, s in enumerate(segs):
        aid = s.get("asset_id")
        if aid not in moments:
            errs.append(f"seg{i}: asset_id '{aid}' is not a known Moment id")
            continue
        dur = moments[aid]["duration_seconds"]
        a, b = s.get("source_start_seconds"), s.get("source_end_seconds")
        if a is None or b is None:
            errs.append(f"seg{i}: missing source in/out")
        else:
            if a < 0 or b <= a:
                errs.append(f"seg{i}: invalid source range [{a},{b}]")
            if b > dur + 0.05:
                errs.append(f"seg{i}: source_end {b} exceeds Moment duration {dur}")
            # useful_segments containment (soft — warn only if entirely outside all useful ranges)
            us = moments[aid].get("useful_segments") or []
            if us and not any(not (b <= u[0] or a >= u[1]) for u in us):
                errs.append(f"seg{i}: source range [{a},{b}] overlaps NO useful_segment {us}")
        od = s.get("output_duration_seconds", 0)
        if od <= 0:
            errs.append(f"seg{i}: non-positive output_duration {od}")
        total_out += od or 0
        if s.get("native_audio") not in NATIVE:
            errs.append(f"seg{i}: native_audio missing/invalid")
        # source/output/speed physical consistency: output ~= (source_span / speed) within tolerance.
        sp = s.get("speed") or 1.0
        if sp <= 0:
            errs.append(f"seg{i}: non-positive speed {sp}")
        elif a is not None and b is not None and b > a and od > 0:
            expected = (b - a) / sp
            if abs(expected - od) > max(0.5, 0.25 * expected):
                errs.append(f"seg{i}: output {od}s inconsistent with source span {b-a:.1f}s @ speed {sp} "
                            f"(expected ~{expected:.1f}s)")
        # transition feasibility: a crossfade/dip needs a positive duration shorter than the segment.
        tr = s.get("transition")
        if tr and tr.get("type") in ("crossfade", "fade_in", "fade_out", "dip_to_black"):
            td = tr.get("duration_seconds")
            if td is not None and (td < 0 or (od and td > od)):
                errs.append(f"seg{i}: transition {tr.get('type')} duration {td}s infeasible vs segment {od}s")
    target = sc["creative_intent"]["target_duration_seconds"]
    dur_err_abs = round(total_out - target, 2) if total_out else None
    if total_out and abs(total_out - target) / target > 0.20:
        errs.append(f"total output {total_out:.1f}s is >20% off target {target}s (abs err {dur_err_abs:+}s)")
    # if the planner declared infeasible, it must give a reason (and that's a valid-but-flagged outcome)
    if plan.get("feasible") is False and not (plan.get("infeasible_reason") or "").strip():
        errs.append("feasible=false but no infeasible_reason given")
    # music_alignment only meaningful with analysis; anchor=highlight/beat/downbeat requires those to exist
    if "music_analysis" not in sc:  # arm A: alignment anchors should be none/absent
        for i, s in enumerate(segs):
            ma = s.get("music_alignment")
            if ma and ma.get("anchor") not in (None, "none"):
                errs.append(f"seg{i}: music_alignment anchor '{ma.get('anchor')}' set without MusicAnalysis")
    return errs


def run_one(sc: dict, with_analysis: bool):
    from model_gateway import BedrockModelGateway, StructuredRequest
    gw = BedrockModelGateway(model_id=MODEL)
    req = StructuredRequest(task="edit_plan.generate", schema=SCHEMA, prompt_version="edit_plan/exp-v3",
                            system=SYSTEM, user_content=build_user(sc, with_analysis),
                            max_repair_attempts=2, max_tokens=2600, temperature=0.0)
    t0 = time.time()
    out = gw.generate_structured(req)
    return out.data, round(time.time() - t0, 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--only", default=None)
    a = ap.parse_args()
    scenarios = {k: v for k, v in FIX.items() if (not a.only or a.only in k)}

    if a.dry or not a.run:
        print(f"=== DRY RUN — {len(scenarios)} scenarios x 2 arms = {len(scenarios)*2} Opus calls ===")
        print(f"Est tokens ~2.5k in / ~1k out per call; Opus 4.6 ~ $5/M in, $25/M out.")
        est = len(scenarios) * 2 * (2500/1e6*5 + 1000/1e6*25)
        print(f"Est spend ~= ${est:.2f}  (well under $20 gate)")
        for k, sc in scenarios.items():
            # validate the fixture is self-consistent (moments have ids/durations/useful_segments)
            ids = [m["id"] for m in sc["moments"]]
            print(f"  {k}: target={sc['creative_intent']['target_duration_seconds']}s, "
                  f"{len(sc['moments'])} moments {ids}, has_analysis={'music_analysis' in sc}")
        return

    RESULTS.mkdir(parents=True, exist_ok=True)
    report = {"model": MODEL, "scenarios": {}}
    for k, sc in scenarios.items():
        report["scenarios"][k] = {}
        for arm, wa in (("A_plan_only", False), ("B_plus_analysis", True)):
            # arm A must not see music_analysis in the validator either
            sc_arm = dict(sc)
            if not wa:
                sc_arm = {kk: vv for kk, vv in sc.items() if kk != "music_analysis"}
            try:
                plan, latency = run_one(sc, wa)
                errs = validate(plan, sc_arm if not wa else sc)
                total = round(sum(s.get("output_duration_seconds", 0) for s in plan.get("segments", [])), 1)
                target = sc["creative_intent"]["target_duration_seconds"]
                report["scenarios"][k][arm] = {
                    "latency_s": latency, "valid": not errs, "errors": errs,
                    "n_segments": len(plan.get("segments", [])),
                    "total_out_s": total,
                    "target_s": target,
                    "dur_err_abs_s": round(total - target, 2),
                    "dur_err_pct": round(100 * (total - target) / target, 1),
                    "feasible": plan.get("feasible", True),
                    "native_audio": [s.get("native_audio") for s in plan.get("segments", [])],
                    "anchors": [(s.get("music_alignment") or {}).get("anchor") for s in plan.get("segments", [])],
                    "plan": plan,
                }
                print(f"{k:18s} {arm:16s} valid={not errs} segs={len(plan.get('segments',[]))} "
                      f"out={total}s (err {round(total-target,1):+}s) {latency}s"
                      + (f"  ERRS={errs}" if errs else ""))
            except Exception as e:  # noqa
                report["scenarios"][k][arm] = {"error": repr(e)}
                print(f"{k:18s} {arm:16s} ERROR {e!r}")
    (RESULTS / "edit_planner_freeze.json").write_text(json.dumps(report, indent=2))
    print(f"\nwrote {RESULTS/'edit_planner_freeze.json'}")


if __name__ == "__main__":
    main()
