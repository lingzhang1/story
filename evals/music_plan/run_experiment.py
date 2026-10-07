"""M-b MusicPlan experiment — Sonnet 4.6 vs Opus 4.6, Arm A (Guide only) vs Arm B (+Coverage/2).

Candidate MusicPlan schema (minimize via experiment): character + energy_arc[] (fractions, categorical
intensity) + key_moments[]? (ablated) + track_selection_criteria? + audio_strategy (experimental native-
audio). Text-only Converse tool-use, temperature 0. NO audio inference, NO catalog, NO provider.

Usage: TMPDIR=/tmp .venv/bin/python evals/music_plan/run_experiment.py --run
Writes evals/results/music_plan_mb.json
"""
from __future__ import annotations
import argparse, json, pathlib, re, sys, time
from statistics import median

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO), str(REPO / "packages")]
from model_gateway import BedrockModelGateway, StructuredRequest, StructuredOutputError, ProviderError

MODELS = {"sonnet": "us.anthropic.claude-sonnet-4-6", "opus": "us.anthropic.claude-opus-4-6-v1"}
FIX = json.loads((REPO / "evals/music_plan/fixtures.json").read_text())["fixtures"]
RESULTS = REPO / "evals/results"

INTENSITY = ["low", "rising", "high", "falling"]
ENERGY = ["low", "medium", "high", "dynamic"]
KM_KIND = ["build", "payoff", "breath", "ending"]
ROLE = ["continuous", "supportive", "sparse"]
NAP = ["low", "selective", "important"]

SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "character": {"type": "object", "additionalProperties": False, "properties": {
            "mood_tags": {"type": "array", "items": {"type": "string"}},
            "energy": {"type": "string", "enum": ENERGY}}, "required": ["mood_tags", "energy"]},
        "energy_arc": {"type": "array", "description": "SMALL, scope-sensitive. Fractions 0..1, NOT cut times.",
            "items": {"type": "object", "additionalProperties": False, "properties": {
                "label": {"type": "string"},
                "start_fraction": {"type": "number", "minimum": 0, "maximum": 1},
                "end_fraction": {"type": "number", "minimum": 0, "maximum": 1},
                "intensity": {"type": "string", "enum": INTENSITY},
                "note": {"type": "string"}},
                "required": ["label", "start_fraction", "end_fraction", "intensity"]}},
        "key_moments": {"type": "array", "description": "ONLY if it adds info beyond energy_arc.",
            "items": {"type": "object", "additionalProperties": False, "properties": {
                "kind": {"type": "string", "enum": KM_KIND},
                "at_fraction": {"type": "number", "minimum": 0, "maximum": 1},
                "note": {"type": "string"}}, "required": ["kind", "at_fraction"]}},
        "track_selection_criteria": {"type": "object", "additionalProperties": False, "properties": {
            "mood_tags": {"type": "array", "items": {"type": "string"}},
            "energy": {"type": "string", "enum": ENERGY},
            "structure_hint": {"type": "string"}}},
        "audio_strategy": {"type": "object", "additionalProperties": False, "properties": {
            "soundtrack_role": {"type": "string", "enum": ROLE},
            "native_audio_priority": {"type": "string", "enum": NAP},
            "guidance": {"type": "string"}}, "required": ["soundtrack_role", "native_audio_priority"]},
    },
    "required": ["character", "energy_arc", "audio_strategy"],
}

SYSTEM = """You plan the SOUNDTRACK SHAPE for a personal Story video — the Story-level MusicPlan a future
Edit Planner will use for pacing. You do NOT pick a song, cut clips, choose Moments, or set exact times.

Produce a MusicPlan: the music's character + a SMALL energy arc + how the soundtrack should relate to the
Story's own (native) audio.

INPUTS: CreativeIntent (what the user wants), MusicDirection (the intended feel), StoryGuide (intended
narrative shape), optionally StoryCoverage (what the Story ACTUALLY became from captured material), and the
target duration.

RULES:
- SMALLEST USEFUL. A more elaborate / more dramatic / more-sectioned plan is NOT better. The best plan is
  the smallest one that gives the Edit Planner useful creative timing context.
- SCALE THE ARC TO SCOPE. An 8-second Story gets ONE energy region. A short/minimal Story gets 1-2. A rich
  60-120s Story may justify 3-4 — only if each earns its place. Do NOT mechanically produce four sections.
- energy_arc fractions are APPROXIMATE Story-level regions (0..1 of duration), NEVER cut points. intensity
  is categorical (low|rising|high|falling) — NO numeric energy scores.
- Do NOT invent a quiet->build->climax arc for every Story. A still/minimal Story may be STABLE low energy
  with no build. A steady city groove may just lift, not climax. An 8s burst is one stable hit.
- NATIVE AUDIO: the Story's own captured sound (a guitar performance, singing, laughter, dialogue, wind,
  waves, crowd) may be emotionally central. When it is, the soundtrack must recede/leave room — set
  audio_strategy.soundtrack_role (continuous|supportive|sparse) and native_audio_priority
  (low|selective|important) accordingly, with one concise guidance line. Do NOT drown important native
  audio under continuous music.
- Use StoryGuide as narrative CONTEXT — do NOT produce one music section per Guide dimension; there is no
  1:1 mapping. Use StoryCoverage (when given) as evidence of what the Story ACTUALLY became (e.g. an
  intended-scenic trek that became a storm/struggle story may want grit, not a glossy swell). Do NOT treat
  a weak Coverage dimension as a missing musical section; music does not compensate for missing capture.
- NO Moment/clip ids, NO transitions, NO camera/edit instructions, NO exact seconds.
- character echoes the intended feel; keep track_selection_criteria (if given) a brief handle for a future
  track selector, and key_moments ONLY if they add something the energy_arc cannot express.

Return ONLY the MusicPlan via the tool."""


def build_user(fx: dict, with_coverage: bool) -> str:
    payload = {
        "creative_intent": fx["creative_intent"],
        "music_direction": fx["music_direction"],
        "story_guide": fx["story_guide"],
        "target_duration_seconds": fx["target_duration_seconds"],
    }
    if with_coverage:
        payload["story_coverage"] = fx["story_coverage"]
    return ("Plan the MusicPlan for THIS Story. Scale the arc to the target duration, respect native audio, "
            "keep it the smallest useful plan.\n\nINPUT:\n" + json.dumps(payload, indent=2)
            + "\n\nReturn ONLY the MusicPlan via the tool.")


def run(model_id, fx, with_coverage):
    gw = BedrockModelGateway(model_id=model_id)
    req = StructuredRequest(task="music_plan.generate", schema=SCHEMA, prompt_version="music_plan/exp-v1",
                            system=SYSTEM, user_content=build_user(fx, with_coverage),
                            max_repair_attempts=2, max_tokens=1600, temperature=0.0)
    return gw.generate_structured(req)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--run", action="store_true")
    ap.add_argument("--only", default=None); a = ap.parse_args()
    if not a.run:
        print("dry run"); return
    RESULTS.mkdir(parents=True, exist_ok=True)
    out = {"models": MODELS, "fixtures": {}}
    lat = []
    tok = {"sonnet": 0, "opus": 0}
    for fid, fx in FIX.items():
        if a.only and fid != a.only:
            continue
        out["fixtures"][fid] = {}
        for mname, mid in MODELS.items():
            for arm, cov in (("A", False), ("B", True)):
                try:
                    t = time.time()
                    r = run(mid, fx, cov)
                    dt = time.time() - t; lat.append(dt)
                    if r.usage and r.usage.total_tokens: tok[mname] += r.usage.total_tokens
                    d = r.data
                    out["fixtures"][fid][f"{mname}_{arm}"] = {
                        "latency_s": round(dt, 1), "tokens": r.usage.total_tokens if r.usage else None,
                        "n_arc": len(d.get("energy_arc", [])), "n_km": len(d.get("key_moments", []) or []),
                        "role": d.get("audio_strategy", {}).get("soundtrack_role"),
                        "nap": d.get("audio_strategy", {}).get("native_audio_priority"),
                        "plan": d}
                    km = len(d.get("key_moments", []) or [])
                    print(f"{fid:22s} {mname}/{arm}: arc={len(d.get('energy_arc',[]))} km={km} "
                          f"role={d.get('audio_strategy',{}).get('soundtrack_role')}/"
                          f"{d.get('audio_strategy',{}).get('native_audio_priority')} {dt:.1f}s")
                except (StructuredOutputError, ProviderError) as e:
                    out["fixtures"][fid][f"{mname}_{arm}"] = {"error": f"{type(e).__name__}: {str(e)[:120]}"}
                    print(f"{fid} {mname}/{arm}: FAIL {str(e)[:100]}")
    (RESULTS / "music_plan_mb.json").write_text(json.dumps(out, indent=2))
    if lat:
        sl = sorted(lat)
        print(f"\n=== {len(lat)} calls, p50 {median(lat):.1f}s p95 {sl[int(len(sl)*0.95)-1]:.1f}s | "
              f"tokens sonnet={tok['sonnet']} opus={tok['opus']} ===")
    print("wrote evals/results/music_plan_mb.json")


if __name__ == "__main__":
    main()
