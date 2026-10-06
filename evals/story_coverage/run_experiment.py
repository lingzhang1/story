"""Story Coverage experiment (reconciliation §11-12; task §4-12). Report-only.

Phase 1 (--phase dims): dimension-strategy sweep (fixed / derived / hybrid) on ONE model (Sonnet)
across all fixtures — answers the representation question.
Phase 2 (--phase models): model comparison (Nova Pro / Sonnet 4.6 / Opus) on the CHOSEN strategy.

Text-only reasoning (no images). Converse tool-use for schema-enforced structured output (same
reliable path AU/C-series use). temperature 0. Captures StoryCoverage output + usage/latency per call.

Usage: TMPDIR=/tmp .venv/bin/python evals/story_coverage/run_experiment.py --phase dims --run
       TMPDIR=/tmp .venv/bin/python evals/story_coverage/run_experiment.py --phase models --strategy hybrid --run
"""
from __future__ import annotations
import argparse, json, pathlib, time

REPO = pathlib.Path(__file__).resolve().parents[2]
FIX = json.loads((REPO / "evals/story_coverage/fixtures.json").read_text())["fixtures"]

MODELS = {"nova_pro": "amazon.nova-pro-v1:0",
          "sonnet": "us.anthropic.claude-sonnet-4-6",
          "opus": "us.anthropic.claude-opus-4-6-v1"}

COVERAGE = {"unknown", "could_use_more", "looking_good", "strong"}
SUFF = {"insufficient", "workable", "sufficient"}


def dim_schema(strategy):
    """The dimensions[] item shape differs by strategy."""
    if strategy == "fixed":
        # fixed small vocabulary: model only scores coverage of preset labels
        return {"type": "array", "items": {"type": "object", "additionalProperties": False, "properties": {
            "label": {"type": "string", "enum": ["environment/place", "human/relationship",
                      "progression/action", "detail", "challenge/tension", "resolution/ending"]},
            "coverage": {"type": "string", "enum": sorted(COVERAGE)},
            "note": {"type": "string"}}, "required": ["label", "coverage"]}}
    if strategy == "derived":
        # fully intent-derived: model invents the labels per Story
        return {"type": "array", "items": {"type": "object", "additionalProperties": False, "properties": {
            "label": {"type": "string"}, "coverage": {"type": "string", "enum": sorted(COVERAGE)},
            "note": {"type": "string"}}, "required": ["label", "coverage"]}}
    # hybrid: stable structure (id+label+purpose) with intent-derived label/purpose
    return {"type": "array", "items": {"type": "object", "additionalProperties": False, "properties": {
        "id": {"type": "string"}, "label": {"type": "string"}, "purpose": {"type": "string"},
        "coverage": {"type": "string", "enum": sorted(COVERAGE)}, "note": {"type": "string"}},
        "required": ["id", "label", "coverage"]}}


def coverage_schema(strategy):
    return {"type": "object", "additionalProperties": False, "properties": {
        "dimensions": dim_schema(strategy),
        "strengths": {"type": "array", "items": {"type": "string"}},
        "redundancies": {"type": "array", "items": {"type": "string"}},
        "sufficiency": {"type": "string", "enum": sorted(SUFF)},
        "sufficiency_reason": {"type": "string"},
        "story_idea": {"type": ["object", "null"], "additionalProperties": False, "properties": {
            "title": {"type": "string"}, "description": {"type": "string"}, "rationale": {"type": "string"}},
            "required": ["title", "description"]},
    }, "required": ["dimensions", "strengths", "redundancies", "sufficiency", "story_idea"]}


STRATEGY_NOTE = {
 "fixed": "Use the FIXED dimension vocabulary provided in the schema enum. Score each dimension's coverage. A dimension existing does NOT mean the user owes footage for it.",
 "derived": "DERIVE a small set (3-6) of narrative dimensions SPECIFIC to THIS Story from the CreativeIntent + the Moments. Do NOT use a generic travel template. Labels should fit this Story's domain (e.g. a guitar story has 'concentration/progress', not 'landscape').",
 "hybrid": "DERIVE a small set (3-6) of Story-specific dimensions, each with a stable short id (snake_case, reusable across recomputes for the SAME dimension), an intent-fit label, and a purpose. Keep ids stable when the same dimension recurs. Do NOT use a generic travel template.",
}

SYSTEM = (
 "You are Story Coverage for a personal Story video app. Given the user's CreativeIntent, the intended "
 "scope (target duration), and the collection of per-Moment understandings already captured, decide what "
 "the COLLECTION means for the Story. You answer: what does the Story already have (strengths); what "
 "narrative dimensions are strong vs weak/absent; what is redundant (quantity is NOT coverage); whether "
 "the Story is already SUFFICIENT for its intended scope; and whether ONE high-level Story Idea is worth "
 "surfacing — or whether the right answer is NO idea (story_idea = null is a first-class, often-correct "
 "result). HARD RULES: (1) Coverage is NOT a checklist — a dimension may be weak without the user owing "
 "footage for it; never invent generic requirements a travel template would want if THIS CreativeIntent "
 "doesn't ask for them. (2) Sufficiency is relative to the CreativeIntent + target duration/scope, NOT a "
 "Moment count — the same Moments can be sufficient for a short story and insufficient for a rich one. "
 "(3) A Moment that failed its requested Shot but is marked story_utility=strong_elsewhere still "
 "contributes its observed content — never zero it out. (4) Reason from observed content even when a "
 "Moment has no requested Shot/Beat. (5) Pending/unanalyzed Moments are UNKNOWN, not absent; do not "
 "invent their content, and let high uncertainty temper confidence. (6) A Story Idea must be high-level "
 "(NOT camera/framing direction), grounded in the CreativeIntent, complementary (never ask for material "
 "already strongly represented). Call the tool once."
)

# Phase-0 restraint rule (approved 2026-10-05). GENERAL, not fixture-tuned. Appended when --restraint.
RESTRAINT = (
 " (7) RESTRAINT ON STORY IDEA — a weak or missing dimension is NOT by itself a reason to emit a Story "
 "Idea. `sufficiency` answers 'can a Story meeting the intent be made from current material?'; "
 "`story_idea` answers 'is there ONE additional opportunity valuable enough to interrupt the user RIGHT "
 "NOW?' — they are DISTINCT. `workable` does NOT imply an idea; `insufficient` does NOT automatically "
 "imply an idea; and for MVP a `sufficient` Story should emit story_idea = null (ENOUGH). Before "
 "emitting a non-null story_idea you must be able to affirm ALL of: (a) it materially serves THIS "
 "CreativeIntent; (b) it would materially IMPROVE the Story, not merely make it more complete; (c) it is "
 "complementary to existing material; (d) it is non-redundant; (e) it is important enough to justify "
 "interrupting the user. If those are not CLEARLY met, output story_idea = null. story_idea = null is a "
 "first-class SUCCESSFUL result, not a failure. Do not use numeric scores or fixed thresholds — judge it."
)


def compact_moment(m):
    if m.get("pending"):
        return {"id": m["id"], "status": "PENDING_AU_NOT_YET_ANALYZED"}
    o = m["observed"]; sc = m["story_context"]
    return {"id": m["id"], "summary": o["summary"],
            "subjects": o.get("subjects", []),
            "events": [e.get("description", "") for e in o.get("events", [])],
            "temporal_order_note": o.get("temporal_order_note", ""),
            "useful_segments": [s.get("why_useful", "") for s in o.get("useful_segments", [])],
            "story_utility": sc.get("story_utility"),
            "requested_shot_contribution": sc.get("requested_shot_contribution"),
            "requested_beat_contribution": sc.get("requested_beat_contribution")}


def call(model_id, strategy, fx, restraint=False):
    import boto3
    br = boto3.client("bedrock-runtime", region_name="us-east-1")
    schema = coverage_schema(strategy)
    payload = {"creative_intent": fx["creative_intent"], "scope": fx["scope"],
               "pending_count": fx.get("pending_count", 0),
               "moments": [compact_moment(m) for m in fx["moments"]]}
    user = (STRATEGY_NOTE[strategy] + "\n\nSTORY INPUT:\n" + json.dumps(payload)
            + "\n\nReturn ONLY the StoryCoverage via the tool.")
    system = SYSTEM + (RESTRAINT if restraint else "")
    tool = {"toolSpec": {"name": "emit_coverage", "description": "Emit the StoryCoverage.",
                         "inputSchema": {"json": schema}}}
    t = time.time()
    r = br.converse(modelId=model_id, system=[{"text": system}],
                    messages=[{"role": "user", "content": [{"text": user}]}],
                    toolConfig={"tools": [tool], "toolChoice": {"tool": {"name": "emit_coverage"}}},
                    inferenceConfig={"maxTokens": 1500, "temperature": 0})
    dt = time.time() - t
    data = None
    for b in r["output"]["message"]["content"]:
        if "toolUse" in b and isinstance(b["toolUse"].get("input"), dict):
            data = b["toolUse"]["input"]
    u = r.get("usage", {})
    return data, dt, u.get("inputTokens"), u.get("outputTokens")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", choices=["dims", "models"], required=True)
    ap.add_argument("--strategy", default="hybrid")
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--restraint", action="store_true", help="append the Phase-0 restraint rule to SYSTEM")
    ap.add_argument("--only", default="", help="restrict to one model key (e.g. opus)")
    args = ap.parse_args()

    rows = []
    if args.phase == "dims":
        combos = [("sonnet", s) for s in ("fixed", "derived", "hybrid")]
    else:
        combos = [(m, args.strategy) for m in ("nova_pro", "sonnet", "opus")]
    if args.only:
        combos = [(m, s) for (m, s) in combos if m == args.only]

    for fid, fx in FIX.items():
        rec = {"fixture": fid, "runs": {}}
        print(f"\n== {fid} ==")
        for model_key, strat in combos:
            key = f"{model_key}:{strat}"
            if not args.run:
                print(f"   (dry) {key}"); continue
            try:
                data, dt, itok, otok = call(MODELS[model_key], strat, fx, restraint=args.restraint)
                ok = isinstance(data, dict) and "sufficiency" in data
                rec["runs"][key] = {"ok": ok, "latency_s": round(dt, 1), "in_tok": itok, "out_tok": otok,
                                    "data": data}
                if ok:
                    nidea = data.get("story_idea") is not None
                    print(f"   {key:22s} {dt:4.1f}s suff={data['sufficiency']:12s} "
                          f"dims={len(data['dimensions'])} idea={'YES' if nidea else 'null'}")
                else:
                    print(f"   {key:22s} INVALID")
            except Exception as e:
                rec["runs"][key] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:150]}"}
                print(f"   {key:22s} EXC {str(e)[:100]}")
        rows.append(rec)

    suffix = "_restraint" if args.restraint else ""
    out = REPO / f"evals/results/story_coverage_{args.phase}{suffix}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"phase": args.phase, "strategy": args.strategy, "rows": rows}, indent=2))
    print("\nwrote", out)


if __name__ == "__main__":
    main()
