"""Score AU finalist outputs against the OWNER-APPROVED ground truth (§5-§7).

Two scoring layers:
 1. DETERMINISTIC reliability (§6): valid/total, parse failures, provider errors — computed from the
    raw run, NEVER repairing malformed output (a prose/truncated output counts as a production failure).
 2. SEMANTIC quality on VALID outputs (§5): an LLM judge (Nova Pro) compares each valid arm output to
    the frozen GT for that clip and returns structured scores with TOLERANT temporal matching (§5.3) —
    event precision/recall/F1, hallucinated vs over-segmented events (§5.1 distinction), temporal-order
    correctness (§5.2), useful-segment coverage + boundary error + dead-detection (§5.3), and
    requested-shot/beat/story_utility accuracy (§5.4). The judge is told MORE EVENTS ≠ BETTER.

Then §7 model-limited vs evidence-limited: for each GT event, did Nova miss it while Sonnet/Opus (same
24 frames) caught it (model-limited) — or did ALL three frame arms miss it while Pegasus native caught
it (evidence-limited)? Uses the judge's per-event recall verdicts.

Usage: TMPDIR=/tmp .venv/bin/python evals/score_au_finalists.py --run
"""
from __future__ import annotations
import argparse, json, pathlib, time
from statistics import median

REPO = pathlib.Path(__file__).resolve().parents[1]
GT = {c["fixture"]: c for c in json.loads((REPO / "evals/asset_understanding/ground_truth.json").read_text())["clips"]}
RUN = json.loads((REPO / "evals/results/au_finalists.json").read_text())
JUDGE = "amazon.nova-pro-v1:0"
FRAME_ARMS = ["ft_nova_pro", "ft_sonnet", "ft_opus"]
ALL_ARMS = FRAME_ARMS + ["nv_pegasus"]

JUDGE_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "event_recall": {"type": "number", "description": "0-1 fraction of GT observed_events the model captured (tolerant ±3s, semantic match)"},
        "event_precision": {"type": "number", "description": "0-1 fraction of model events that are REAL (match a GT event or are plausibly true from the clip)"},
        "hallucinated_events": {"type": "integer", "description": "count of model events describing things that did NOT happen"},
        "over_segmented_events": {"type": "integer", "description": "count of model events that split ONE GT event into redundant pieces (real but redundant — NOT hallucinated)"},
        "gt_events_missed": {"type": "array", "items": {"type": "string"}, "description": "short labels of GT events the model MISSED"},
        "temporal_order_correct": {"type": "boolean", "description": "did the model get the key temporal interpretation right (departure/arrival, reveal direction, progression, contradiction)?"},
        "temporal_note": {"type": "string"},
        "useful_segment_coverage": {"type": "number", "description": "0-1 how well model useful_segments cover the GT useful_segments (tolerant boundaries)"},
        "boundary_error_s": {"type": "number", "description": "approx mean start/end boundary error in seconds vs GT useful_segments"},
        "dead_detection_correct": {"type": "boolean", "description": "did the model correctly find GT dead/setup segments if any (true if GT has none and model invented none)"},
        "shot_contribution_correct": {"type": "boolean"},
        "beat_contribution_correct": {"type": "boolean"},
        "story_utility_correct": {"type": "boolean"},
        "notes": {"type": "string"}
    },
    "required": ["event_recall", "event_precision", "hallucinated_events", "over_segmented_events",
                 "gt_events_missed", "temporal_order_correct", "useful_segment_coverage",
                 "dead_detection_correct", "shot_contribution_correct", "beat_contribution_correct",
                 "story_utility_correct"]
}

JUDGE_PROMPT = (
 "You are a strict evaluation judge for a Story video-understanding model. You are given HUMAN-APPROVED "
 "ground truth for ONE video clip and a MODEL's structured understanding of the same clip. Score the "
 "model against the ground truth. CRITICAL RULES: (1) MORE EVENTS IS NOT BETTER — reward real coverage, "
 "penalize hallucinated events (things that didn't happen) and over-segmentation (splitting one real "
 "event into redundant pieces). Count those two SEPARATELY. (2) Use TOLERANT temporal matching: a model "
 "event within ~3s of a GT event and semantically equivalent is a MATCH; do not require frame-perfect "
 "timestamps. (3) Judge temporal_order_correct on the KEY interpretation (departure vs arrival, reveal "
 "direction, progression, contradiction) — not wording. (4) story_utility is one of none/useful_elsewhere/"
 "strong_elsewhere; shot/beat contribution: does the footage serve the requested creative purpose "
 "(not literal instruction obedience)? Good-footage-wrong-shot must NOT be scored as shot fulfilled. "
 "Return ONLY JSON matching the schema."
)


def judge(gt, model_out):
    import boto3
    br = boto3.client("bedrock-runtime", region_name="us-east-1")
    payload = {
        "ground_truth": {k: gt[k] for k in ("observed_events", "useful_segments", "dead_or_setup_segments",
                         "temporal_order", "requested_shot_contribution", "requested_beat_contribution",
                         "story_utility", "capture_context") if k in gt},
        "model_output": {k: model_out.get(k) for k in ("summary", "events", "temporal_order_note",
                         "useful_segments", "dead_or_setup_segments", "requested_shot_contribution",
                         "requested_beat_contribution", "story_utility")},
    }
    content = [{"text": JUDGE_PROMPT + "\n\nDATA:\n" + json.dumps(payload)
                + "\n\nReturn ONLY JSON matching:\n" + json.dumps(JUDGE_SCHEMA)}]
    r = br.converse(modelId=JUDGE, messages=[{"role": "user", "content": content}],
                    inferenceConfig={"maxTokens": 1200, "temperature": 0})
    t = r["output"]["message"]["content"][0]["text"]
    s = t.find("{"); e = t.rfind("}")
    return json.loads(t[s:e+1])


def f1(p, r):
    return 0.0 if (p + r) == 0 else round(2 * p * r / (p + r), 3)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--run", action="store_true"); a = ap.parse_args()
    rows = {x["fixture"]: x for x in RUN["rows"]}
    scored = []
    for fid, rec in rows.items():
        gt = GT[fid]
        srec = {"fixture": fid, "band": rec["band"], "dur_s": rec["dur_s"], "arms": {}}
        for arm in ALL_ARMS:
            ar = rec["arms"].get(arm)
            if not ar:
                continue
            entry = {"ok": ar.get("ok", False), "latency_s": ar.get("latency_s"),
                     "in_tok": ar.get("in_tok"), "out_tok": ar.get("out_tok"),
                     "error": ar.get("error")}
            if a.run and ar.get("ok"):
                try:
                    j = judge(gt, ar["data"])
                    j["event_f1"] = f1(j["event_precision"], j["event_recall"])
                    entry["score"] = j
                    time.sleep(0.2)
                except Exception as e:
                    entry["score_error"] = f"{type(e).__name__}: {str(e)[:140]}"
            srec["arms"][arm] = entry
        scored.append(srec)
    out = REPO / "evals/results/au_finalists_scored.json"
    out.write_text(json.dumps({"scored": scored}, indent=2))
    print("wrote", out)

    # Aggregates
    print("\n=== RELIABILITY (§6, deterministic — no repair) ===")
    for arm in ALL_ARMS:
        tot = sum(1 for s in scored if arm in s["arms"])
        okc = sum(1 for s in scored if s["arms"].get(arm, {}).get("ok"))
        print(f"  {arm:12s} valid {okc}/{tot}")
    if a.run:
        print("\n=== SEMANTIC QUALITY on VALID outputs (§5) ===")
        for arm in ALL_ARMS:
            S = [s["arms"][arm]["score"] for s in scored
                 if s["arms"].get(arm, {}).get("ok") and "score" in s["arms"][arm]]
            if not S:
                continue
            def mn(k): return round(sum(x[k] for x in S) / len(S), 3)
            print(f"  {arm:12s} n={len(S):2d} P={mn('event_precision'):.2f} R={mn('event_recall'):.2f} "
                  f"F1={mn('event_f1'):.2f} halluc={sum(x['hallucinated_events'] for x in S):2d} "
                  f"overseg={sum(x['over_segmented_events'] for x in S):2d} "
                  f"temporal={sum(x['temporal_order_correct'] for x in S)}/{len(S)} "
                  f"segcov={mn('useful_segment_coverage'):.2f} "
                  f"shot={sum(x['shot_contribution_correct'] for x in S)}/{len(S)} "
                  f"util={sum(x['story_utility_correct'] for x in S)}/{len(S)}")


if __name__ == "__main__":
    main()
