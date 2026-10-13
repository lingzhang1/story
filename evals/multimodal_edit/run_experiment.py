"""Multimodal Creative Editing experiment — A0/A1/B/C controlled arms (owner-approved, $20 gate).

Answers: does giving the Edit Planner richer AU TEXT (A1) and/or VISUAL frames (B/C) improve editorial
quality over today's 600-char-folded-text baseline (A0)?  Separates information-loss from image-specific value.

EXPERIMENT-ONLY. Does NOT touch production code, prompts, or contracts:
  - Edit Planner SYSTEM body is the frozen prompts/edit_plan/5.2/system.md VERBATIM across every arm.
  - EditPlan/2 tool schema + the deterministic validator are imported from packages/edit_planner (same gate).
  - Model config identical across arms (Opus 4.6, temperature 0, same max_tokens). Only the EVIDENCE in the
    user message / image blocks differs — the exact per-arm delta is recorded in the result JSON.
  - Multimodal is the gateway's EXISTING StructuredRequest.images surface (BedrockModelGateway already attaches
    image blocks before the text). No new wrapper, no model swap.

Fresh AU is REAL model output (prompts/asset_understanding/v1 + moment_understanding/1 schema), labeled as
such and cost-tracked. Frames are bounded derived JPEGs (au_frames/1: 24 @ <=768px, q0.6 for AU; Tier-1
contact-sheet frames for the planner). Nothing is persisted to a frame store; scratch is session-reclaimed.
No image payloads are logged (only counts + bytes).

Usage:
  TMPDIR=/tmp .venv/bin/python evals/multimodal_edit/run_experiment.py --dry                 # cost estimate, no model
  TMPDIR=/tmp .venv/bin/python evals/multimodal_edit/run_experiment.py --au    --only guitar  # fresh AU only (cheap)
  TMPDIR=/tmp .venv/bin/python evals/multimodal_edit/run_experiment.py --run   --arms A0 A1    # planner arms
  TMPDIR=/tmp .venv/bin/python evals/multimodal_edit/run_experiment.py --run                   # all arms, all datasets
"""
from __future__ import annotations
import argparse, json, os, pathlib, subprocess, sys, time
from dataclasses import dataclass, field

REPO = pathlib.Path(__file__).resolve().parents[2]
for rel in (".", "packages", "apps/api"):
    p = str((REPO / rel).resolve())
    if p not in sys.path:
        sys.path.insert(0, p)

SCRATCH = pathlib.Path(os.environ.get("KIROCREW_SCRATCH", "/tmp")) / "mm_exp"
SAMPLER = pathlib.Path(os.environ.get("MM_SAMPLER", str(pathlib.Path(os.environ.get("KIROCREW_SCRATCH", "/tmp")) / "sample_frames")))
RESULTS = REPO / "evals/results"
AU_CACHE = SCRATCH / "au_cache"          # fresh-AU outputs cached here so planner arms reuse ONE AU run
FRAMES = SCRATCH / "frames"

# Models — identical across every planner arm (control). Opus 4.6 is the production edit-planner primary.
EDIT_MODEL = os.environ.get("MM_EDIT_MODEL", "us.anthropic.claude-opus-4-6-v1")
AU_MODEL = os.environ.get("MM_AU_MODEL", "us.anthropic.claude-sonnet-4-6")   # image-capable; AU is a judgment, not the thing under test

# Opus 4.6 approx pricing (same figures the repo's other runners use): $5/M in, $25/M out.
PRICE_IN, PRICE_OUT = 5.0 / 1e6, 25.0 / 1e6

# au_frames/1 production policy for the AU call.
AU_N_FRAMES = 24
AU_LONGEST = 768
# Tier-1 contact-sheet frames handed to the PLANNER (bounded; fewer than AU's 24, duration-scaled).
def tier1_budget(dur: float) -> int:
    return max(4, min(9, round(dur / 8.0)))

DATASETS = {
    "girl_with_dress": REPO / "evals/scenarios/girl_with_dress",
    "hiking": REPO / "evals/scenarios/hiking",
    "guitar": REPO / "evals/scenarios/guitar_practice_001",
    # solitude: synthetic 3-clip payload built from hiking calm clips if no dedicated dir (regression only).
}
VIDEO_EXT = {".mov", ".MOV", ".mp4", ".MP4", ".m4v"}

# ---- the production edit-planner validator + schema + prompt (imported, never re-authored) ----------------
from edit_planner import SCHEMA as EDIT_SCHEMA, validate_plan, EditPlanInputs, _load_system  # type: ignore

EDIT_SYSTEM = _load_system()   # the frozen 5.2 body (version resolved by STORY_EDIT_PLAN_VERSION, default 5.1)

# ---- AU prompt + schema (production asset_understanding/v1 + moment_understanding/1) -----------------------
AU_SYSTEM = (REPO / "prompts/asset_understanding/v1/system.md").read_text().strip()
AU_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "observed": {"type": "object", "additionalProperties": False, "properties": {
            "summary": {"type": "string"},
            "subjects": {"type": "array", "items": {"type": "string"}},
            "events": {"type": "array", "items": {"type": "object", "additionalProperties": False, "properties": {
                "start_time": {"type": "number", "minimum": 0}, "end_time": {"type": "number"},
                "description": {"type": "string"}}, "required": ["start_time", "description"]}},
            "temporal_order_note": {"type": "string"},
            "useful_segments": {"type": "array", "items": {"type": "object", "additionalProperties": False, "properties": {
                "start_time": {"type": "number", "minimum": 0}, "end_time": {"type": "number", "exclusiveMinimum": 0},
                "why_useful": {"type": "string"}}, "required": ["start_time", "end_time", "why_useful"]}},
        }, "required": ["summary"]},
        "story_context": {"type": "object", "additionalProperties": False, "properties": {
            "story_utility": {"type": "string", "enum": ["none", "useful_elsewhere", "strong_elsewhere"]},
            "requested_shot_contribution": {"type": ["string", "null"]},
            "requested_beat_contribution": {"type": ["string", "null"]},
        }, "required": ["story_utility"]},
    },
    "required": ["observed", "story_context"],
}


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
    d = DATASETS[ds]
    return sorted([p for p in d.iterdir() if p.suffix in VIDEO_EXT])


def duration(path: pathlib.Path) -> float:
    r = subprocess.run([str(SAMPLER), str(path), str(SCRATCH / "_d"), "1"], capture_output=True, text=True)
    try:
        return json.loads(next(l for l in r.stdout.splitlines() if l.strip().startswith("{")))["duration_s"]
    except Exception:
        return 0.0


def sample(path: pathlib.Path, n: int, out: pathlib.Path, longest: int | None = None) -> list[dict]:
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    r = subprocess.run([str(SAMPLER), str(path), str(out), str(n)], capture_output=True, text=True, env=env)
    try:
        man = json.loads(next(l for l in r.stdout.splitlines() if l.strip().startswith("{")))
        return man["frames"]
    except Exception:
        return []


# ---- fresh AU (real model) --------------------------------------------------------------------------------
def run_au(path: pathlib.Path, cost: Cost) -> dict:
    """Run REAL Asset Understanding on one clip (24 frames, au_frames/1). Cached to AU_CACHE by clip stem."""
    from model_gateway import BedrockModelGateway, StructuredRequest, ImageInput
    AU_CACHE.mkdir(parents=True, exist_ok=True)
    cache = AU_CACHE / f"{path.stem}.json"
    if cache.exists():
        rec = json.loads(cache.read_text())
        return rec
    dur = duration(path)
    frames = sample(path, AU_N_FRAMES, FRAMES / "au" / path.stem)
    imgs = [ImageInput(data=pathlib.Path(f["path"]).read_bytes(), media_type="image/jpeg") for f in frames]
    stamps = ", ".join(f"frame{f['index']}@{f['t_ms']}ms" for f in frames)
    user = (f"Analyze this ONE Moment. clip_duration_s={dur:.1f}. Ordered frames (timestamps in ms from clip "
            f"start): {stamps}. Call the tool exactly once with the structured understanding.")
    gw = BedrockModelGateway(model_id=AU_MODEL)
    req = StructuredRequest(task="asset_understanding", schema=AU_SCHEMA, prompt_version="asset_understanding/v1",
                            system=AU_SYSTEM, user_content=user, images=imgs, max_repair_attempts=2,
                            max_tokens=1500, temperature=0.0)
    t0 = time.time()
    out = gw.generate_structured(req)
    cost.add(out.usage)
    rec = {"clip": path.name, "stem": path.stem, "duration_s": round(dur, 2), "n_frames": len(frames),
           "au_model": AU_MODEL, "au_real": True, "latency_s": round(time.time() - t0, 2),
           "in_tok": out.usage.input_tokens if out.usage else None,
           "out_tok": out.usage.output_tokens if out.usage else None,
           "understanding": out.data}
    cache.write_text(json.dumps(rec, indent=2))
    return rec


# ---- evidence builders (the ONLY per-arm delta) -----------------------------------------------------------
def _useful_pairs(u: dict, dur: float) -> list[list[float]]:
    segs = (((u or {}).get("observed") or {}).get("useful_segments")) or []
    out = []
    for s in segs:
        a, b = s.get("start_time"), s.get("end_time")
        if isinstance(a, (int, float)) and isinstance(b, (int, float)) and b > a:
            out.append([float(a), float(b)])
    return out or [[0.0, max(1.0, dur)]]


def summary_A0(u: dict) -> str:
    """Production understandingSummary(): summary · subjects · events(desc only) · temporal, de-duped, CAP 600."""
    obs = (u or {}).get("observed") or {}
    parts, seen = [], set()
    def add(s):
        t = (s or "").strip()
        if t and t.lower() not in seen:
            seen.add(t.lower()); parts.append(t)
    add(obs.get("summary", ""))
    subs = [x for x in (obs.get("subjects") or []) if isinstance(x, str)][:6]
    if subs: add("subjects: " + ", ".join(subs))
    descs = [e.get("description", "") for e in (obs.get("events") or []) if e.get("description")][:4]
    if descs: add("events: " + "; ".join(descs))
    add(obs.get("temporal_order_note", ""))
    out = " · ".join(parts)
    return (out[:600] + "…") if len(out) > 600 else out


def summary_A1(u: dict) -> dict:
    """Arm A1 richer text: fuller subjects + events WITH timestamps + temporal note, bounded but not 600-capped.
    No fabrication — only fields AU actually produced. Returned as a small structured object (still text to the
    model) so event timings are explicit."""
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
    }


# ---- planner arms -----------------------------------------------------------------------------------------
def _contact_sheet(mid: str, dur: float, frames: list[dict], cols: int = 3, cell: int = 320) -> bytes:
    """Tile a Moment's frames into ONE labelled JPEG (timestamp burned under each cell + Moment id header).
    One image per Moment keeps the Converse request within model input limits at 36+ moments (the per-frame
    approach overflowed 'Input is too long'). This IS the Tier-1 contact-sheet representation."""
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


def build_moments(aus: list[dict], arm: str) -> tuple[list[dict], list, dict]:
    """Return (moments[], image_inputs[], evidence_meta). moments carry id/duration/useful_segments and the
    arm-appropriate text; images only for B/C — ONE tiled contact-sheet per Moment. Moment id is the clip stem."""
    from model_gateway import ImageInput
    moments, images, meta = [], [], {"text_mode": arm, "img_frames_per_moment": {}, "sheet_bytes_per_moment": {}}
    for rec in aus:
        u = rec["understanding"]
        dur = rec["duration_s"]
        mid = rec["stem"]
        m = {"id": mid, "duration_seconds": dur, "useful_segments": _useful_pairs(u, dur)}
        if arm == "A0":
            m["summary"] = summary_A0(u)
        else:
            m["evidence"] = summary_A1(u)          # A1/B/C share the richer text
        moments.append(m)
        if arm in ("B", "C"):
            n = tier1_budget(dur) if arm == "B" else max(tier1_budget(dur), min(14, round(dur / 4.0)))
            frames = sample(pathlib.Path(rec["_path"]), n, FRAMES / arm / mid)
            sheet = _contact_sheet(mid, dur, frames)
            meta["img_frames_per_moment"][mid] = len(frames)
            meta["sheet_bytes_per_moment"][mid] = len(sheet)
            if sheet:
                images.append((mid, 0, ImageInput(data=sheet, media_type="image/jpeg")))
    return moments, images, meta


def run_planner_arm(ds: str, aus: list[dict], arm: str, intent: dict, music: dict | None, cost: Cost) -> dict:
    from model_gateway import BedrockModelGateway, StructuredRequest
    moments, images, meta = build_moments(aus, arm)
    payload = {"creative_intent": intent, "story_guide": {}, "story_coverage": {},
               "moments": moments, "music_plan": (music or {}),
               "target_duration_seconds": intent["target_duration_seconds"]}
    header = ("Plan the EditPlan for THIS Story from the material below. Use only the given Moment ids and "
              "their real/useful ranges. Plan to the Story target duration. Respect native audio.\n")
    if arm in ("B", "C"):
        header += ("\nVISUAL EVIDENCE: in addition to the text, you are given timestamped contact-sheet frames "
                   "for each Moment, grouped by Moment id. Each image is labeled with its Moment id and source "
                   "timestamp. Use them to judge visual distinctness, composition and precise source ranges. "
                   "Frames are evidence for the SAME Moments in the JSON — never invent footage not present.\n")
    user = header + "\nINPUT:\n" + json.dumps(payload, indent=2) + "\n\nReturn ONLY the EditPlan via the tool."

    # Image blocks: prefix each Moment's frames with a text label so the model can map image->Moment/timestamp.
    from model_gateway import StructuredRequest as SR
    img_inputs = [im for (_mid, _t, im) in images]
    # One contact-sheet per Moment; tell the model the sheet order so it can map image->Moment.
    if images:
        order = "; ".join(mid for (mid, _t, _im) in images)
        user = f"(Contact-sheet images, one per Moment, in this order: {order})\n\n" + user

    gw = BedrockModelGateway(model_id=EDIT_MODEL)
    req = SR(task="edit_plan.generate", schema=EDIT_SCHEMA, prompt_version="edit_plan/5.2-EXPERIMENT",
             system=EDIT_SYSTEM, user_content=user, images=img_inputs,
             max_repair_attempts=2, max_tokens=8192, temperature=0.0)
    t0 = time.time()
    out = gw.generate_structured(req)
    cost.add(out.usage)
    plan = out.data

    # deterministic validator (production gate), built against the SAME moments
    ei = EditPlanInputs(story_id="00000000-0000-0000-0000-000000000000",
                        creative_intent_id="00000000-0000-0000-0000-000000000000",
                        creative_intent=intent, story_guide={}, story_coverage={},
                        moments=moments, music_plan=(music or {}), music_analysis=None)
    errs = validate_plan(plan, ei)
    segs = plan.get("segments", [])
    outs = [s.get("output_duration_seconds", 0) for s in segs]
    import statistics
    return {
        "arm": arm, "evidence": meta,
        "image_count": len(img_inputs),
        "image_bytes": sum(len(im.data) for im in img_inputs),
        "latency_s": round(time.time() - t0, 2),
        "in_tok": out.usage.input_tokens if out.usage else None,
        "out_tok": out.usage.output_tokens if out.usage else None,
        "valid": not errs, "errors": errs,
        "n_segments": len(segs),
        "distinct_moments": len({s.get("asset_id") for s in segs}),
        "total_out_s": round(sum(outs), 1),
        "target_s": intent["target_duration_seconds"],
        "median_shot_s": round(statistics.median(outs), 2) if outs else 0,
        "min_shot_s": round(min(outs), 2) if outs else 0,
        "max_shot_s": round(max(outs), 2) if outs else 0,
        "native_audio": [s.get("native_audio") for s in segs],
        "anchors": [(s.get("music_alignment") or {}).get("anchor") for s in segs],
        "plan": plan,
    }


# ---- intents (held constant across arms within a dataset) -------------------------------------------------
INTENTS = {
    "girl_with_dress": {"raw_text": "A travel + fashion story of a trip, lots of different outfits and places",
                        "theme": "travel & style", "tone": "joyful, vivid",
                        "desired_feeling": ["joyful", "vivid"], "style_tags": ["fashion", "travel"],
                        "pace": "lively", "target_duration_seconds": 100.0},
    "hiking": {"raw_text": "A hiking trip — scenery, the climb, reaching the top",
               "theme": "adventure", "tone": "epic, earned",
               "desired_feeling": ["awe", "accomplishment"], "style_tags": ["outdoors", "journey"],
               "pace": "building", "target_duration_seconds": 100.0},
    "guitar": {"raw_text": "Practicing guitar, ending on the full song",
               "theme": "practice to performance", "tone": "intimate",
               "desired_feeling": ["focused", "satisfying"], "style_tags": ["music", "performance"],
               "pace": "patient", "target_duration_seconds": 60.0},
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--au", action="store_true", help="run fresh AU only (populate cache)")
    ap.add_argument("--run", action="store_true", help="run planner arms (needs AU cache)")
    ap.add_argument("--arms", nargs="*", default=["A0", "A1", "B"])
    ap.add_argument("--only", default=None)
    ap.add_argument("--limit", type=int, default=0, help="limit clips per dataset (smoke)")
    a = ap.parse_args()
    SCRATCH.mkdir(parents=True, exist_ok=True)
    datasets = [d for d in INTENTS if (not a.only or a.only in d)]

    if a.dry or not (a.au or a.run):
        print("=== DRY RUN — cost estimate, no model calls ===")
        total = 0.0
        for ds in datasets:
            clips = clips_for(ds)[: a.limit or None]
            n = len(clips)
            au_cost = n * (AU_N_FRAMES * 1600/1e6 * PRICE_IN * 1e6 / 1e6 + 1000/1e6 * PRICE_OUT * 1e6 / 1e6)  # rough
            # rough: AU ~ 24 frames ~ 1.6k tok/frame image + 1k out; planner ~ moments text + (B/C images)
            au_in = n * (AU_N_FRAMES * 1500 + 800); au_out = n * 900
            au_usd = au_in * PRICE_IN + au_out * PRICE_OUT
            # planner per arm: ~ (n*300 text) in + 4k out ; B/C add ~ n*tier1*1200 image tokens
            per_arm = {}
            for arm in a.arms:
                p_in = n * 350 + 2000
                if arm in ("B", "C"):
                    p_in += sum((tier1_budget(duration(c)) if arm == "B" else min(14, round(duration(c)/4))) * 1200 for c in clips)
                p_out = 5000
                per_arm[arm] = p_in * PRICE_IN + p_out * PRICE_OUT
            ds_usd = au_usd + sum(per_arm.values())
            total += ds_usd
            print(f"  {ds:16s} clips={n:3d}  AU~${au_usd:5.2f}  arms={ {k:round(v,2) for k,v in per_arm.items()} }  subtotal~${ds_usd:5.2f}")
        print(f"\n  ESTIMATED TOTAL ~= ${total:.2f}   (gate: $20)")
        if total > 20:
            print("  WARNING: estimate exceeds $20 gate — reduce --arms or --limit, or split datasets.")
        return

    RESULTS.mkdir(parents=True, exist_ok=True)
    cost = Cost()
    report = {"edit_model": EDIT_MODEL, "au_model": AU_MODEL, "prompt_version": "edit_plan/5.2 (verbatim body)",
              "arms_run": a.arms, "datasets": {}}

    for ds in datasets:
        clips = clips_for(ds)[: a.limit or None]
        print(f"\n==== {ds} ({len(clips)} clips) ====")
        # fresh AU for all clips (cached)
        aus = []
        for c in clips:
            rec = run_au(c, cost)
            rec["_path"] = str(c)
            aus.append(rec)
            print(f"  AU {c.name:34s} dur={rec['duration_s']:6.1f}s useful={len(_useful_pairs(rec['understanding'], rec['duration_s']))} "
                  f"subj={len((rec['understanding'].get('observed') or {}).get('subjects') or [])} "
                  f"ev={len((rec['understanding'].get('observed') or {}).get('events') or [])}")
        report["datasets"][ds] = {"n_clips": len(clips), "au_total_cost_usd": cost.usd, "arms": {}}
        if a.au:
            continue
        intent = INTENTS[ds]
        for arm in a.arms:
            try:
                r = run_planner_arm(ds, aus, arm, intent, None, cost)
                report["datasets"][ds]["arms"][arm] = r
                print(f"  ARM {arm:3s} valid={r['valid']} segs={r['n_segments']} distinct={r['distinct_moments']} "
                      f"out={r['total_out_s']}s med={r['median_shot_s']}s imgs={r['image_count']} "
                      f"({round(r['image_bytes']/1e6,2)}MB) {r['latency_s']}s"
                      + (f"  ERRS={r['errors']}" if r['errors'] else ""))
            except Exception as e:
                report["datasets"][ds]["arms"][arm] = {"error": repr(e)}
                print(f"  ARM {arm:3s} ERROR {e!r}")
            print(f"      running spend: ${cost.usd}  (gate $20)")
            if cost.usd > 20:
                print("  !! $20 GATE HIT — stopping."); report["gate_hit"] = True
                _write(report, cost); return
    _write(report, cost)


def _write(report, cost):
    report["total_cost_usd"] = cost.usd
    report["total_calls"] = cost.calls
    out = RESULTS / "multimodal_edit_experiment.json"
    out.write_text(json.dumps(report, indent=2))
    print(f"\nTOTAL SPEND ${cost.usd} over {cost.calls} calls -> wrote {out}")


if __name__ == "__main__":
    main()
