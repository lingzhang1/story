"""Experiment 1 of the Creative-Objective series — SHORT-FORM SOCIAL EDITING INTELLIGENCE.

Objective: an engaging, visually coherent short-form edit that captures attention fast and holds it with
MEANINGFUL variation — NOT "maximize cuts" and NOT "always cut on the beat".

Question this run answers: of three levers — richer AU TEXT, VISUAL frames, explicit CREATIVE DIRECTION, and a
CRITIQUE/REVISION pass — which produces the largest measurable short-form quality gain over the richer-text
baseline?

Arms (evidence/direction is the ONLY delta; model + frozen v5.2 body + schema + validator held constant):
  A1   — rich AU text (structured subjects/events-with-timestamps/temporal), v5.2 verbatim.          [baseline]
  A1c  — A1 text + the explicit short-form CREATIVE BRIEF (text-only + brief; isolates visual contribution).
  B    — A1 text + timestamped Tier-1 contact sheets (one tiled JPEG/Moment), v5.2 verbatim.
  C    — B + the explicit short-form CREATIVE BRIEF.
  D    — C, then ONE bounded critique→revision pass (self-critique against the brief, then a single revise call).

EXPERIMENT-ONLY. Reuses exp-1 machinery; touches NO production code, prompt, or contract:
  - Edit Planner SYSTEM body = frozen prompts/edit_plan/5.2 VERBATIM (pin STORY_EDIT_PLAN_VERSION=5.2). The
    creative brief is injected into the USER message as experimental direction, never into the frozen body.
  - EditPlan/2 schema + deterministic validator imported from packages/edit_planner (same production gate).
  - Model config identical across arms. Multimodal via the gateway's existing StructuredRequest.images surface.
  - AU is REAL asset_understanding/v1 output, reloaded from the committed exp-1 exports (au_cache rebuilt from
    outbox/*_au_and_editplans.json) — NO fresh AU run, $0 AU cost. Same source evidence across every arm.

Datasets: girl_with_dress (primary visual diversity), hiking (scenery/action/progression).
Durations: 30s primary, 60s secondary.

Usage (always pin the frozen body):
  TMPDIR=/tmp STORY_EDIT_PLAN_VERSION=5.2 .venv/bin/python evals/multimodal_edit/run_shortform_experiment.py --dry
  TMPDIR=/tmp STORY_EDIT_PLAN_VERSION=5.2 .venv/bin/python evals/multimodal_edit/run_shortform_experiment.py --run \
      --arms A1 A1c B C D --durations 30 60 --only girl_with_dress
"""
from __future__ import annotations
import argparse, json, os, pathlib, subprocess, sys, time, statistics, hashlib, random
from dataclasses import dataclass

REPO = pathlib.Path(__file__).resolve().parents[2]
for rel in (".", "packages", "apps/api"):
    p = str((REPO / rel).resolve())
    if p not in sys.path:
        sys.path.insert(0, p)

SCRATCH = pathlib.Path(os.environ.get("KIROCREW_SCRATCH", "/tmp")) / "mm_exp"
SAMPLER = pathlib.Path(os.environ.get("MM_SAMPLER", str(pathlib.Path(os.environ.get("KIROCREW_SCRATCH", "/tmp")) / "sample_frames")))
RESULTS = REPO / "evals/results"
AU_CACHE = SCRATCH / "au_cache"
FRAMES = SCRATCH / "frames_sf"

EDIT_MODEL = os.environ.get("MM_EDIT_MODEL", "us.anthropic.claude-opus-4-6-v1")
AU_MODEL_LABEL = "us.anthropic.claude-sonnet-4-6 (reused from exp-1, no re-run)"
PRICE_IN, PRICE_OUT = 5.0 / 1e6, 25.0 / 1e6

DATASETS = {
    "girl_with_dress": REPO / "evals/scenarios/girl_with_dress",
    "hiking": REPO / "evals/scenarios/hiking",
}
VIDEO_EXT = {".mov", ".MOV", ".mp4", ".MP4", ".m4v"}

from edit_planner import SCHEMA as EDIT_SCHEMA, validate_plan, EditPlanInputs, _load_system  # type: ignore
EDIT_SYSTEM = _load_system()
EDIT_SYSTEM_SHA = hashlib.sha256(EDIT_SYSTEM.encode()).hexdigest()[:12]

# ---- Phase 1 creative brief (owner-supplied, verbatim) — injected into the USER message for C/D/A1c only ----
CREATIVE_BRIEF = (
    "Create a compelling short-form social video from the supplied footage. Capture attention immediately with "
    "a striking visual, meaningful action, or emotional hook. Maintain interest through deliberate variation in "
    "framing, movement, setting, and pacing. Select the most expressive source ranges, not merely the most "
    "descriptively important clips.\n\n"
    "Use quick cuts where they improve rhythm, but allow a shot to breathe when an action, expression, or reveal "
    "requires it.\n\n"
    "Build momentum and a memorable ending. Avoid repetitive footage, filler, artificial excitement, and "
    "unsupported narrative claims.\n\n"
    "Let the actual footage determine the edit. Do not impose a fixed shot length or minimum clip count."
)

# Tier-1 contact-sheet frame budget (bounded, duration-scaled) — same policy as exp-1.
def tier1_budget(dur: float) -> int:
    return max(4, min(9, round(dur / 8.0)))


@dataclass
class Cost:
    in_tok: int = 0
    out_tok: int = 0
    calls: int = 0
    def add(self, u):
        if u:
            self.in_tok += (u.input_tokens or 0); self.out_tok += (u.output_tokens or 0)
        self.calls += 1
    @property
    def usd(self) -> float:
        return round(self.in_tok * PRICE_IN + self.out_tok * PRICE_OUT, 4)


def clips_for(ds: str) -> list[pathlib.Path]:
    return sorted([p for p in DATASETS[ds].iterdir() if p.suffix in VIDEO_EXT])


def load_au(stem: str) -> dict | None:
    f = AU_CACHE / f"{stem}.json"
    return json.loads(f.read_text()) if f.exists() else None


def sample(path: pathlib.Path, n: int, out: pathlib.Path) -> list[dict]:
    out.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([str(SAMPLER), str(path), str(out), str(n)], capture_output=True, text=True)
    try:
        return json.loads(next(l for l in r.stdout.splitlines() if l.strip().startswith("{")))["frames"]
    except Exception:
        return []


# ---- evidence builders (reused from exp-1, verbatim semantics) --------------------------------------------
def _useful_pairs(u: dict, dur: float) -> list[list[float]]:
    segs = (((u or {}).get("observed") or {}).get("useful_segments")) or []
    out = []
    for s in segs:
        a, b = s.get("start_time"), s.get("end_time")
        if isinstance(a, (int, float)) and isinstance(b, (int, float)) and b > a:
            out.append([float(a), float(b)])
    return out or [[0.0, max(1.0, dur)]]


def richtext(u: dict) -> dict:
    obs = (u or {}).get("observed") or {}
    ev = []
    for e in (obs.get("events") or [])[:10]:
        if e.get("description"):
            ev.append({"t": round(float(e.get("start_time", 0)), 1),
                       "t_end": (round(float(e["end_time"]), 1) if isinstance(e.get("end_time"), (int, float)) else None),
                       "what": e["description"]})
    return {
        "summary": obs.get("summary", ""),
        "subjects": [x for x in (obs.get("subjects") or []) if isinstance(x, str)][:10],
        "events": ev,
        "temporal_order_note": obs.get("temporal_order_note", ""),
        "story_utility": ((u or {}).get("story_context") or {}).get("story_utility"),
    }


def _contact_sheet(mid: str, dur: float, frames: list[dict], cols: int = 3, cell: int = 320) -> bytes:
    from PIL import Image, ImageDraw, ImageFont
    import io
    imgs = []
    for f in frames:
        try:
            imgs.append((Image.open(f["path"]).convert("RGB"), f["t_ms"]))
        except Exception:
            continue
    if not imgs:
        return b""
    scaled = []
    for im, tms in imgs:
        w, h = im.size
        nh = max(1, int(h * cell / w))
        scaled.append((im.resize((cell, nh)), tms))
    maxh = max(im.size[1] for im, _ in scaled)
    rows = (len(scaled) + cols - 1) // cols
    label_h, head_h = 20, 26
    sheet = Image.new("RGB", (cols * cell, head_h + rows * (maxh + label_h)), (16, 16, 18))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 13)
        hfont = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 15)
    except Exception:
        font = hfont = ImageFont.load_default()
    draw.text((6, 5), f"Moment {mid}  dur={dur:.1f}s  ({len(scaled)} frames)", fill=(235, 235, 235), font=hfont)
    for i, (im, tms) in enumerate(scaled):
        r, c = divmod(i, cols)
        x, y = c * cell, head_h + r * (maxh + label_h)
        sheet.paste(im, (x, y))
        draw.text((x + 4, y + im.size[1] + 2), f"t={tms/1000:.1f}s", fill=(120, 220, 255), font=font)
    buf = io.BytesIO()
    sheet.save(buf, format="JPEG", quality=70)
    return buf.getvalue()


def build_moments(aus: list[dict], want_images: bool) -> tuple[list[dict], list, dict]:
    from model_gateway import ImageInput
    moments, images, meta = [], [], {"img_frames_per_moment": {}, "sheet_bytes_per_moment": {}}
    for rec in aus:
        u = rec["understanding"]
        dur = rec["duration_s"]
        mid = rec["stem"]
        m = {"id": mid, "duration_seconds": dur, "useful_segments": _useful_pairs(u, dur),
             "evidence": richtext(u)}
        moments.append(m)
        if want_images:
            n = tier1_budget(dur)
            frames = sample(pathlib.Path(rec["_path"]), n, FRAMES / mid)
            sheet = _contact_sheet(mid, dur, frames)
            meta["img_frames_per_moment"][mid] = len(frames)
            meta["sheet_bytes_per_moment"][mid] = len(sheet)
            if sheet:
                images.append((mid, ImageInput(data=sheet, media_type="image/jpeg")))
    return moments, images, meta


ARMS = {
    #  arm   images  brief
    "A1":  (False, False),
    "A1c": (False, True),
    "B":   (True,  False),
    "C":   (True,  True),
    "D":   (True,  True),   # D = C + critique/revision (handled specially)
}


def _plan_stats(plan: dict) -> dict:
    segs = plan.get("segments", [])
    outs = [s.get("output_duration_seconds", 0) for s in segs]
    return {
        "n_segments": len(segs),
        "distinct_moments": len({s.get("asset_id") for s in segs}),
        "total_out_s": round(sum(outs), 1),
        "median_shot_s": round(statistics.median(outs), 2) if outs else 0,
        "min_shot_s": round(min(outs), 2) if outs else 0,
        "max_shot_s": round(max(outs), 2) if outs else 0,
        "shot_durations": [round(o, 2) for o in outs],
        "native_audio": [s.get("native_audio") for s in segs],
        "roles": [s.get("narrative_role") for s in segs],
        "first_segment": (segs[0] if segs else None),
        "last_segment": (segs[-1] if segs else None),
    }


def _user_message(payload: dict, with_brief: bool, with_images: bool, image_order: str) -> str:
    header = ("Plan the EditPlan for THIS short-form social Story from the material below. Use only the given "
              "Moment ids and their real/useful ranges. Plan to the Story target duration. Respect native audio.\n")
    if with_brief:
        header += ("\n=== CREATIVE DIRECTION (short-form social) ===\n" + CREATIVE_BRIEF +
                   "\n=== END CREATIVE DIRECTION ===\n")
    if with_images:
        header += ("\nVISUAL EVIDENCE: you also receive timestamped contact-sheet frames for each Moment, one tiled "
                   "image per Moment, labeled with Moment id and source timestamp. Use them to judge visual "
                   "distinctness, composition, expressiveness and precise source ranges. Frames are evidence for "
                   "the SAME Moments in the JSON — never invent footage not present.\n")
        header = f"(Contact-sheet images, one per Moment, in this order: {image_order})\n\n" + header
    return header + "\nINPUT:\n" + json.dumps(payload, indent=2) + "\n\nReturn ONLY the EditPlan via the tool."


def run_arm(ds: str, aus: list[dict], arm: str, intent: dict, cost: Cost) -> dict:
    from model_gateway import BedrockModelGateway, StructuredRequest
    want_images, with_brief = ARMS[arm]
    moments, images, meta = build_moments(aus, want_images)
    img_inputs = [im for (_mid, im) in images]
    order = "; ".join(mid for (mid, _im) in images)
    payload = {"creative_intent": intent, "story_guide": {}, "story_coverage": {},
               "moments": moments, "music_plan": {},
               "target_duration_seconds": intent["target_duration_seconds"]}
    gw = BedrockModelGateway(model_id=EDIT_MODEL)

    user = _user_message(payload, with_brief, want_images, order)
    t0 = time.time()
    out = gw.generate_structured(StructuredRequest(
        task="edit_plan.generate", schema=EDIT_SCHEMA, prompt_version="edit_plan/5.2-SHORTFORM-EXPERIMENT",
        system=EDIT_SYSTEM, user_content=user, images=img_inputs,
        max_repair_attempts=2, max_tokens=8192, temperature=0.0))
    cost.add(out.usage)
    plan = out.data
    revision = None

    if arm == "D":
        # ONE bounded critique → revision pass. Critique is a plain-text self-review against the brief; the
        # revise call re-emits the EditPlan via the SAME schema/validator. Still v5.2 body verbatim.
        crit_user = (
            "You produced the EditPlan below for a SHORT-FORM SOCIAL video. Critique it against the creative "
            "direction, in <=180 words, then STOP (no tool call). Judge ONLY: (1) does the first shot hook in the "
            "first 3s? (2) is there genuine visual variation or does footage repeat? (3) does any shot run long "
            "without an action/expression/reveal justifying the hold? (4) is the ending memorable? (5) is anything "
            "expressive left on the table? Be specific and cite Moment ids + source times. Do not rewrite the plan.\n\n"
            "=== CREATIVE DIRECTION ===\n" + CREATIVE_BRIEF + "\n=== END ===\n\nEDITPLAN:\n" + json.dumps(plan, indent=2))
        crit = gw.generate_text(StructuredRequest(
            task="edit_plan.critique", schema={}, prompt_version="edit_plan/5.2-SHORTFORM-EXPERIMENT",
            system=EDIT_SYSTEM, user_content=crit_user, images=img_inputs,
            max_repair_attempts=0, max_tokens=600, temperature=0.0)) if hasattr(gw, "generate_text") else None
        crit_text = (crit.text if crit else None)
        if not crit_text:
            # gateway has no plain-text path — ask for critique via a tiny schema instead
            cs = {"type": "object", "additionalProperties": False,
                  "properties": {"critique": {"type": "string"}}, "required": ["critique"]}
            co = gw.generate_structured(StructuredRequest(
                task="edit_plan.critique", schema=cs, prompt_version="edit_plan/5.2-SHORTFORM-EXPERIMENT",
                system=EDIT_SYSTEM, user_content=crit_user, images=img_inputs,
                max_repair_attempts=1, max_tokens=600, temperature=0.0))
            cost.add(co.usage)
            crit_text = (co.data or {}).get("critique", "")
        else:
            cost.add(crit.usage)
        rev_user = (
            "Revise the EditPlan to address your critique below, honoring the SAME creative direction and the "
            "SAME Moment ids/ranges and native-audio rules. Make only improvements the critique supports; do not "
            "pad clip count. Return ONLY the revised EditPlan via the tool.\n\n"
            "=== CREATIVE DIRECTION ===\n" + CREATIVE_BRIEF + "\n=== END ===\n\nCRITIQUE:\n" + (crit_text or "") +
            "\n\nCURRENT EDITPLAN:\n" + json.dumps(plan, indent=2) +
            "\n\nMoment inventory (ids + useful ranges):\n" +
            json.dumps([{"id": m["id"], "duration_seconds": m["duration_seconds"],
                         "useful_segments": m["useful_segments"]} for m in moments], indent=2))
        ro = gw.generate_structured(StructuredRequest(
            task="edit_plan.generate", schema=EDIT_SCHEMA, prompt_version="edit_plan/5.2-SHORTFORM-EXPERIMENT",
            system=EDIT_SYSTEM, user_content=rev_user, images=img_inputs,
            max_repair_attempts=2, max_tokens=8192, temperature=0.0))
        cost.add(ro.usage)
        revision = {"critique": crit_text, "pre_revision_plan_stats": _plan_stats(plan)}
        plan = ro.data  # D's final plan is the revised one

    ei = EditPlanInputs(story_id="00000000-0000-0000-0000-000000000000",
                        creative_intent_id="00000000-0000-0000-0000-000000000000",
                        creative_intent=intent, story_guide={}, story_coverage={},
                        moments=moments, music_plan={}, music_analysis=None)
    errs = validate_plan(plan, ei)
    stats = _plan_stats(plan)
    return {
        "arm": arm, "images": want_images, "brief": with_brief,
        "image_count": len(img_inputs), "image_bytes": sum(len(im.data) for im in img_inputs),
        "image_frames_per_moment": meta["img_frames_per_moment"],
        "latency_s": round(time.time() - t0, 2),
        "in_tok": out.usage.input_tokens if out.usage else None,
        "out_tok": out.usage.output_tokens if out.usage else None,
        "valid": not errs, "errors": errs,
        "target_s": intent["target_duration_seconds"],
        **stats,
        "revision": revision,
        "plan": plan,
    }


INTENTS_BASE = {
    "girl_with_dress": {"raw_text": "A travel + fashion story of a trip, lots of different outfits and places",
                        "theme": "travel & style", "tone": "joyful, vivid",
                        "desired_feeling": ["joyful", "vivid"], "style_tags": ["fashion", "travel"],
                        "pace": "lively"},
    "hiking": {"raw_text": "A hiking trip — scenery, the climb, reaching the top",
               "theme": "adventure", "tone": "epic, earned",
               "desired_feeling": ["awe", "accomplishment"], "style_tags": ["outdoors", "journey"],
               "pace": "building"},
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--arms", nargs="*", default=["A1", "A1c", "B", "C", "D"])
    ap.add_argument("--durations", nargs="*", type=int, default=[30, 60])
    ap.add_argument("--only", default=None)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--seed", type=int, default=20261013)
    ap.add_argument("--out", default="shortform_social_experiment.json")
    a = ap.parse_args()
    random.seed(a.seed)
    SCRATCH.mkdir(parents=True, exist_ok=True)
    datasets = [d for d in DATASETS if (not a.only or a.only in d)]

    # load AU from cache (reused from exp-1); build per-dataset AU list
    ds_aus = {}
    for ds in datasets:
        clips = clips_for(ds)[: a.limit or None]
        aus = []
        for c in clips:
            rec = load_au(c.stem)
            if not rec:
                print(f"  !! no cached AU for {c.stem} — run exp-1 AU first"); continue
            rec["_path"] = str(c)
            aus.append(rec)
        ds_aus[ds] = aus

    if a.dry or not a.run:
        print("=== DRY RUN — planner-only cost estimate (AU reused, $0) ===")
        total = 0.0
        for ds in datasets:
            aus = ds_aus[ds]; n = len(aus)
            for dur_s in a.durations:
                for arm in a.arms:
                    want_images, _ = ARMS[arm]
                    p_in = n * 420 + 2500
                    if want_images:
                        p_in += sum(tier1_budget(r["duration_s"]) * 1200 for r in aus)
                    p_out = 4500
                    calls = 1
                    if arm == "D":
                        calls = 3; p_in = int(p_in * 2.1); p_out += 600 + 4500
                    usd = p_in * PRICE_IN + p_out * PRICE_OUT
                    total += usd
                    print(f"  {ds:16s} {dur_s}s  {arm:4s} ~${usd:5.3f}  ({calls} call/s)")
        print(f"\n  ESTIMATED TOTAL ~= ${total:.2f}   (gate: $20)")
        if total > 20:
            print("  WARNING: exceeds $20 — drop arms/durations or run one dataset at a time.")
        return

    RESULTS.mkdir(parents=True, exist_ok=True)
    cost = Cost()
    manifest = {
        "experiment": "shortform_social_editing_intelligence (creative-objective series #1)",
        "objective": "short-form social video optimized for immediate engagement",
        "edit_model": EDIT_MODEL, "au_source": AU_MODEL_LABEL,
        "frozen_body": "prompts/edit_plan/5.2", "frozen_body_sha12": EDIT_SYSTEM_SHA,
        "frozen_body_len": len(EDIT_SYSTEM),
        "creative_brief": CREATIVE_BRIEF, "arms": a.arms, "durations_s": a.durations,
        "seed": a.seed, "temperature": 0.0, "max_tokens": 8192,
        "controls": "same AU evidence, same intent, same empty music/guide/coverage, same validator, "
                    "same model/temp/max_tokens; only {text vs +images} x {brief vs no-brief} x {critique} differ",
        "datasets": {},
    }
    if EDIT_SYSTEM_SHA != "d1116552f2ff":
        print(f"  !! WARNING frozen body sha {EDIT_SYSTEM_SHA} != expected d1116552f2ff "
              f"(set STORY_EDIT_PLAN_VERSION=5.2). Aborting to protect the control.")
        return

    for ds in datasets:
        aus = ds_aus[ds]
        print(f"\n==== {ds} ({len(aus)} clips) ====")
        manifest["datasets"][ds] = {"n_clips": len(aus), "by_duration": {}}
        for dur_s in a.durations:
            intent = dict(INTENTS_BASE[ds]); intent["target_duration_seconds"] = float(dur_s)
            manifest["datasets"][ds]["by_duration"][str(dur_s)] = {}
            for arm in a.arms:
                try:
                    r = run_arm(ds, aus, arm, intent, cost)
                    manifest["datasets"][ds]["by_duration"][str(dur_s)][arm] = r
                    print(f"  {dur_s}s {arm:4s} valid={r['valid']} segs={r['n_segments']} "
                          f"distinct={r['distinct_moments']} out={r['total_out_s']}s "
                          f"med={r['median_shot_s']}s min={r['min_shot_s']} max={r['max_shot_s']} "
                          f"imgs={r['image_count']}({round(r['image_bytes']/1e6,2)}MB) {r['latency_s']}s"
                          + (f"  ERRS={r['errors']}" if r['errors'] else ""))
                except Exception as e:
                    manifest["datasets"][ds]["by_duration"][str(dur_s)][arm] = {"error": repr(e)}
                    print(f"  {dur_s}s {arm:4s} ERROR {e!r}")
                print(f"      spend ${cost.usd} (gate $20)")
                if cost.usd > 20:
                    print("  !! $20 GATE HIT — stopping."); manifest["gate_hit"] = True
                    _write(manifest, cost, a.out); return
    _write(manifest, cost, a.out)


def _write(manifest, cost, out_name):
    manifest["total_cost_usd"] = cost.usd
    manifest["total_calls"] = cost.calls
    out = RESULTS / out_name
    out.write_text(json.dumps(manifest, indent=2))
    print(f"\nTOTAL SPEND ${cost.usd} over {cost.calls} calls -> wrote {out}")


if __name__ == "__main__":
    main()
