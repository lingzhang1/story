"""Asset Understanding — frame-density scaling + Opus comparison + COST accounting.

Runs a fixed representative 8-clip subset at frame densities {12,24,48,96} on Nova Pro,
and Opus 4.5 at {24,48} on IDENTICAL frames, capturing EXACT per-call usage so the
quality/latency/COST frontier is explicit. Pricing constants are ESTIMATES (recorded
date + source below); unknowns are marked, not fabricated.

PRICING (per 1k tokens, USD) — ESTIMATE, us-east-1 on-demand, recorded 2026-10-05 from
AWS Bedrock public pricing for the tested model families. Treat as approximate.
"""
from __future__ import annotations
import json, pathlib, subprocess, sys, time
from statistics import median

REPO = pathlib.Path(__file__).resolve().parents[1]
for rel in (".", "packages", "apps/api"):
    sys.path.insert(0, str((REPO / rel).resolve()))

MEDIA_MAP = json.loads((REPO / "evals/shot_validation/media-map.json").read_text())
MEDIA_ROOT = REPO / MEDIA_MAP["media_root"]
FIXTURES = REPO / "evals/shot_validation/scenarios"
SAMPLER = pathlib.Path("/tmp/sample_frames")
FRAMES = REPO / "evals/assets/private_local/frames/au_density"

PRICE_PER_1K = {   # (input, output) USD/1k tok — ESTIMATE 2026-10-05
    "amazon.nova-pro-v1:0": (0.0008, 0.0032),
    "us.anthropic.claude-opus-4-5-20251101-v1:0": (0.015, 0.075),
}
PRICING_NOTE = "ESTIMATE; AWS Bedrock on-demand us-east-1 public pricing, recorded 2026-10-05."

# Fixed representative subset: multi-event long clips (recall), temporal, semantic, short.
SUBSET = [
    "S08_end_of_day__D_cooking_dinner",            # 154s multi-event (recall ceiling)
    "S07_companionship__A_natural_conversation",   # 95s multi-event
    "S06_difficulty__E_cross_river",               # 38s multi-event temporal
    "A01_semantic_adversarial__A03_backpack_but_arrival_not_departure",  # temporal contradiction
    "S03_scenic_reveal__D_reverse_reveal__take1",  # reveal direction
    "S05_trail_progression__A_follow_behind",      # progression
    "S01_backpack_static__A_exact_good",           # short semantic
    "S08_end_of_day__F_nice_dinner_window_view",   # beautiful-wrong-purpose
]
AU_PROMPT = (
 "Analyze this ONE captured video Moment for a Story app. Return ONLY JSON: "
 "{summary, events:[{t_start_s,t_end_s,description}], temporal_order_note, "
 "useful_segments:[{t_start_s,t_end_s,why_useful}], story_utility}. Observe the whole clip in "
 "order; note departures/arrivals/reveal-direction/progression/contradiction; timestamps within "
 "the clip duration.")


def dur_of(p):
    r = subprocess.run([str(SAMPLER), str(p), "/tmp/_dd", "1"], capture_output=True, text=True)
    return json.loads(next(l for l in r.stdout.splitlines() if l.strip().startswith("{")))["duration_s"]


def sample(p, n, out):
    out.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([str(SAMPLER), str(p), str(out), str(n)], capture_output=True, text=True)
    return json.loads(next(l for l in r.stdout.splitlines() if l.strip().startswith("{")))["frames"]


def parse(txt):
    s, e = txt.find("{"), txt.rfind("}")
    try: return json.loads(txt[s:e+1])
    except Exception: return {"_parse_error": txt[:120]}


def cost(model, intok, outtok):
    pin, pout = PRICE_PER_1K[model]
    return round(intok / 1000 * pin + outtok / 1000 * pout, 5)


def run_call(model, clip_path, n):
    import boto3
    br = boto3.client("bedrock-runtime", region_name="us-east-1")
    out = FRAMES / f"{model.split('.')[-1][:8]}_{n}" / clip_path.stem
    frames = sample(clip_path, n, out)
    payload = sum(len(pathlib.Path(f["path"]).read_bytes()) for f in frames)
    content = [{"image": {"format": "jpeg", "source": {"bytes": pathlib.Path(f["path"]).read_bytes()}}}
               for f in frames]
    content.append({"text": AU_PROMPT})
    t = time.time()
    r = br.converse(modelId=model, messages=[{"role": "user", "content": content}],
                    inferenceConfig={"maxTokens": 1400, "temperature": 0})
    dt = time.time() - t
    u = r["usage"]; txt = r["output"]["message"]["content"][0]["text"]
    data = parse(txt)
    ok = "_parse_error" not in data
    return {"n_frames": len(frames), "payload_bytes": payload, "latency_s": round(dt, 1),
            "in_tok": u["inputTokens"], "out_tok": u["outputTokens"],
            "cost_usd": cost(model, u["inputTokens"], u["outputTokens"]),
            "ok": ok, "n_events": len(data.get("events", [])) if ok else None,
            "n_useful": len(data.get("useful_segments", [])) if ok else None,
            "out_bytes": len(txt)}


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true")
    args = ap.parse_args()
    plan = [("amazon.nova-pro-v1:0", d) for d in (12, 24, 48, 96)] \
         + [("us.anthropic.claude-opus-4-5-20251101-v1:0", d) for d in (24, 48)]
    clips = [(f, MEDIA_ROOT / MEDIA_MAP["fixtures"][f]) for f in SUBSET]
    durs = {f: dur_of(p) for f, p in clips}
    print("subset durations:", {f.split('__')[-1][:16]: round(durs[f]) for f in SUBSET})
    results = []
    for model, n in plan:
        if not args.run:
            print(f"[plan] {model.split('.')[-1][:10]} @ {n}fr x {len(clips)} clips"); continue
        cells = []
        for f, p in clips:
            try:
                c = run_call(model, p, n); c["fixture"] = f; cells.append(c)
                print(f"  {model.split('.')[-1][:8]:8} {n:2}fr {f.split('__')[-1][:18]:18} "
                      f"{c['latency_s']:5}s in={c['in_tok']:6} ev={c['n_events']} ${c['cost_usd']:.4f}")
            except Exception as e:
                print(f"  {model.split('.')[-1][:8]} {n}fr {f[:20]} EXC {str(e)[:80]}")
                cells.append({"fixture": f, "ok": False, "error": str(e)[:120]})
        ok = [c for c in cells if c.get("ok")]
        agg = {"model": model, "n_frames": n, "clips": len(cells), "valid": len(ok),
               "lat_p50": round(median([c["latency_s"] for c in ok]), 1) if ok else None,
               "in_tok_med": int(median([c["in_tok"] for c in ok])) if ok else None,
               "events_med": round(median([c["n_events"] for c in ok]), 1) if ok else None,
               "useful_med": round(median([c["n_useful"] for c in ok]), 1) if ok else None,
               "cost_per_moment_med": round(median([c["cost_usd"] for c in ok]), 5) if ok else None,
               "cells": cells}
        results.append(agg)
    if args.run:
        (REPO / "evals/results/au_density_cost.json").write_text(
            json.dumps({"pricing_note": PRICING_NOTE, "price_per_1k": PRICE_PER_1K, "results": results}, indent=2))
        print("\n=== density/cost summary ===")
        for a in results:
            print(f"  {a['model'].split('.')[-1][:10]:10} {a['n_frames']:2}fr valid={a['valid']}/{a['clips']} "
                  f"p50={a['lat_p50']}s in={a['in_tok_med']} ev={a['events_med']} useful={a['useful_med']} "
                  f"${a['cost_per_moment_med']}/Moment")
        print("wrote evals/results/au_density_cost.json")


if __name__ == "__main__":
    main()
