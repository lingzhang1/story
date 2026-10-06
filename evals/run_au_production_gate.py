"""§12 PRODUCTION-PATH AU regression gate.

Runs the ACTUAL production engine (asset_engine.RealAssetUnderstandingEngine via the
real BedrockModelGateway tool-use path — Sonnet 4.6, au_prompt/1, moment_understanding/1,
24 frames) over the owner-approved 18-clip ground truth, with the FROZEN one-retry policy.
This is the real production code, NOT the experiment harness — so the measured baseline is
what ships. Captures validity/latency/usage + the structured output per clip for scoring by
score_au_finalists.py's judge.

Usage: TMPDIR=/tmp .venv/bin/python evals/run_au_production_gate.py --run [--limit N]
"""
from __future__ import annotations
import argparse, json, pathlib, subprocess, sys, time
from statistics import median
from uuid import uuid4

REPO = pathlib.Path(__file__).resolve().parents[1]
for rel in (".", "packages", "apps/api"):
    p = str((REPO / rel).resolve())
    if p not in sys.path:
        sys.path.insert(0, p)

MEDIA_MAP = json.loads((REPO / "evals/shot_validation/media-map.json").read_text())
MEDIA_ROOT = REPO / MEDIA_MAP["media_root"]
GT = json.loads((REPO / "evals/asset_understanding/ground_truth.json").read_text())["clips"]
FIXTURES = REPO / "evals/shot_validation/scenarios"
SAMPLER = pathlib.Path("/tmp/sample_frames")
FRAMES = REPO / "evals/assets/private_local/frames/au_prod_gate"


def dur_of(path):
    r = subprocess.run([str(SAMPLER), str(path), "/tmp/_aupg", "1"], capture_output=True, text=True)
    return json.loads(next(l for l in r.stdout.splitlines() if l.strip().startswith("{")))["duration_s"]


def sample24(path, out):
    out.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([str(SAMPLER), str(path), str(out), "24"], capture_output=True, text=True)
    return json.loads(next(l for l in r.stdout.splitlines() if l.strip().startswith("{")))["frames"]


def context_for(fx):
    fid = fx["fixture"]; sset = fid.split("__", 1)[0]
    reqp = FIXTURES / sset / fid / "request.json"
    if reqp.exists():
        req = json.loads(reqp.read_text())
        return {"shot": req.get("shot"), "beat": req.get("beat")}
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    from asset_engine import AUFrame, AURequestMeta, CaptureContext, AURetryableError, RealAssetUnderstandingEngine, DEFAULT_AU_MODEL
    from model_gateway import BedrockModelGateway

    engine = RealAssetUnderstandingEngine(BedrockModelGateway(model_id=DEFAULT_AU_MODEL), model_id=DEFAULT_AU_MODEL)
    clips = GT[: args.limit] if args.limit else GT
    rows = []
    for c in clips:
        fid = c["fixture"]; rel = MEDIA_MAP["fixtures"][fid]; path = MEDIA_ROOT / rel
        dur = dur_of(path); ctx = context_for(c)
        print(f"\n== {fid[:46]} {c['band']} {dur:.1f}s ==")
        if not args.run:
            rows.append({"fixture": fid, "band": c["band"], "dur_s": round(dur, 1)}); continue
        fr = sample24(path, FRAMES / path.stem)
        frames = [AUFrame(data=pathlib.Path(f["path"]).read_bytes(), t_ms=f["t_ms"]) for f in fr]
        meta = AURequestMeta(
            moment_id=uuid4(),
            capture_context=CaptureContext(shot=ctx.get("shot"), beat=ctx.get("beat")) if ctx else None,
        )
        t = time.time()
        rec = {"fixture": fid, "band": c["band"], "dur_s": round(dur, 1), "arms": {}}
        try:
            r = engine.analyze(frames, meta)
            dt = time.time() - t
            u = r.understanding
            # flatten to the same shape score_au_finalists.py expects (observed.* at top level + story_utility)
            data = {
                "summary": u.observed.summary,
                "subjects": u.observed.subjects,
                "events": [{"t_start_s": e.start_time, "t_end_s": e.end_time, "description": e.description} for e in u.observed.events],
                "temporal_order_note": u.observed.temporal_order_note,
                "useful_segments": [{"t_start_s": s.start_time, "t_end_s": s.end_time, "why_useful": s.why_useful} for s in u.observed.useful_segments],
                "dead_or_setup_segments": [],
                "story_utility": u.story_context.story_utility.value,
                "requested_shot_contribution": u.story_context.requested_shot_contribution,
                "requested_beat_contribution": u.story_context.requested_beat_contribution,
            }
            rec["arms"]["prod_sonnet"] = {
                "ok": True, "latency_s": round(dt, 1),
                "in_tok": r.usage_input_tokens, "out_tok": r.usage_output_tokens,
                "retried": r.retried, "attempts": r.attempts, "data": data,
            }
            print(f"   OK {dt:.1f}s retried={r.retried} events={len(u.observed.events)} util={data['story_utility']}")
        except AURetryableError as e:
            dt = time.time() - t
            rec["arms"]["prod_sonnet"] = {"ok": False, "latency_s": round(dt, 1), "error": str(e)[:200]}
            print(f"   RETRYABLE-FAIL {dt:.1f}s {str(e)[:120]}")
        rows.append(rec)

    out = REPO / "evals/results/au_production_gate.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"model": "us.anthropic.claude-sonnet-4-6", "path": "RealAssetUnderstandingEngine+BedrockModelGateway(tool-use)", "rows": rows}, indent=2))
    if args.run:
        oks = [r for r in rows if r["arms"].get("prod_sonnet", {}).get("ok")]
        lat = [r["arms"]["prod_sonnet"]["latency_s"] for r in oks]
        retried = sum(1 for r in oks if r["arms"]["prod_sonnet"].get("retried"))
        print(f"\nvalid {len(oks)}/{len(rows)}  p50={median(lat):.1f}s  retried={retried}")
    print("wrote", out)


if __name__ == "__main__":
    main()
