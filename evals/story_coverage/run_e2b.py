"""E2-b: StoryCoverage/2 migration experiment (Opus 4.6, story_coverage/v2).

Coverage/2 consumes a FROZEN StoryGuide + completed MomentUnderstanding[] + pending_count and
emits dimension_coverage keyed by Guide dimension id (it does NOT invent dimensions). This runner:
 - migrates the 15 frozen E fixtures (reusing evals/story_guide/fixture_guides.json), and
 - runs the 4 new E2-b fixtures (inline Guides w/ known possibility ids),
 - scores strict/envelope dangerous errors, H1/H2/H3 identity, Idea concision/restatement,
   purpose>possibility (P1/P2/P3), represented_possibility semantics, unexpected retention (U).

Model/prompt frozen: Opus 4.6, story_coverage/v2. temperature 0. text-only Converse tool-use.
Usage: TMPDIR=/tmp .venv/bin/python evals/story_coverage/run_e2b.py --run
Writes evals/results/story_coverage_e2b.json
"""
from __future__ import annotations
import argparse, json, pathlib, re, sys, time, uuid
from statistics import median

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO), str(REPO / "packages")]
from model_gateway import BedrockModelGateway, StructuredRequest, StructuredOutputError, ProviderError

MODEL = "us.anthropic.claude-opus-4-6-v1"
PROMPT = (REPO / "prompts/story_coverage/v2/system.md").read_text()
E_FIX = json.loads((REPO / "evals/story_coverage/fixtures.json").read_text())["fixtures"]
E2B_FIX = json.loads((REPO / "evals/story_coverage/fixtures_e2b.json").read_text())["fixtures"]
GUIDES = json.loads((REPO / "evals/story_guide/fixture_guides.json").read_text())
STATES = ["strong", "looking_good", "could_use_more", "unknown"]
SUFF = ["insufficient", "workable", "sufficient"]


def cov2_schema(guide_dim_ids: list[str], possibility_ids: list[str]) -> dict:
    return {
        "type": "object", "additionalProperties": False,
        "properties": {
            "dimension_coverage": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "properties": {
                    "story_guide_dimension_id": {"type": "string", "enum": guide_dim_ids},
                    "state": {"type": "string", "enum": STATES},
                    "note": {"type": "string"},
                    "evidence_moment_ids": {"type": "array", "items": {"type": "string"}},
                    "represented_possibility_ids": {"type": "array",
                        "items": ({"type": "string", "enum": possibility_ids} if possibility_ids else {"type": "string"})},
                },
                "required": ["story_guide_dimension_id", "state"]}},
            "strengths": {"type": "array", "items": {"type": "string"}},
            "redundancies": {"type": "array", "items": {"type": "string"}},
            "sufficiency": {"type": "object", "additionalProperties": False, "properties": {
                "status": {"type": "string", "enum": SUFF}, "reason": {"type": "string"}},
                "required": ["status"]},
            "story_idea": {"type": ["object", "null"], "additionalProperties": False, "properties": {
                "title": {"type": "string"}, "description": {"type": "string"},
                "rationale": {"type": "string"},
                "target_story_guide_dimension_id": {"type": ["string", "null"]}},
                "required": ["title", "description"]},
        },
        "required": ["dimension_coverage", "strengths", "redundancies", "sufficiency", "story_idea"],
    }


def guide_compact(guide: dict) -> dict:
    return {"framing_summary": guide["framing_summary"], "dimensions": [
        {"id": d["id"], "label": d["label"], "purpose": d["purpose"],
         "capture_possibilities": [{"id": p["id"], "label": p["label"]} for p in d.get("capture_possibilities", [])]}
        for d in guide["dimensions"]]}


def compact_mu(m, id_map):
    if m.get("pending"):
        return None
    real = id_map.setdefault(m["id"], str(uuid.uuid4()))
    o = m["observed"]
    return {"moment_id": real, "summary": o.get("summary", ""), "subjects": o.get("subjects", []),
            "events": [e.get("description", "") for e in o.get("events", [])],
            "useful_segments": [s.get("why_useful", "") for s in o.get("useful_segments", [])],
            "story_utility": m.get("story_context", {}).get("story_utility")}


def run_one(gw, ci, scope, guide, moments, pending):
    gids = [d["id"] for d in guide["dimensions"]]
    pids = [p["id"] for d in guide["dimensions"] for p in d.get("capture_possibilities", [])]
    id_map = {}
    mus = [x for x in (compact_mu(m, id_map) for m in moments) if x]
    payload = {"creative_intent": ci, "scope": scope, "pending_count": pending,
               "story_guide": guide_compact(guide), "moments": mus}
    user = ("Evaluate StoryCoverage for THIS Story against its StoryGuide.\n\nINPUT:\n"
            + json.dumps(payload, indent=2)
            + "\n\nEmit one dimension_coverage entry per Guide dimension (by id). Remember: purpose "
              "fulfillment > literal possibility; represented_possibility_ids is UI-only; sufficiency "
              "is relative to intent+scope, not Guide completion; ONE concise Story Idea or null. "
              "Return ONLY the StoryCoverage via the tool.")
    req = StructuredRequest(task="story_coverage.compute", schema=cov2_schema(gids, pids),
                            prompt_version="story_coverage/v2", system=PROMPT, user_content=user,
                            max_repair_attempts=2, max_tokens=2000, temperature=0.0)
    r = gw.generate_structured(req)
    return r, id_map, gids


def idea_words(idea):
    if not idea:
        return 0
    return len(re.findall(r"\S+", (idea.get("description", "") + " " + idea.get("rationale", "")).strip()))


def _wc(s):
    return len(re.findall(r"\S+", s or ""))


def idea_lengths(idea):
    """Separate title / description / rationale word counts (Fix-3 reporting)."""
    if not idea:
        return {"title_w": 0, "desc_w": 0, "rat_w": 0}
    return {"title_w": _wc(idea.get("title")), "desc_w": _wc(idea.get("description")),
            "rat_w": _wc(idea.get("rationale"))}


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--run", action="store_true"); a = ap.parse_args()
    if not a.run:
        print("dry run"); return
    gw = BedrockModelGateway(model_id=MODEL)
    out = {"model": MODEL, "prompt": "story_coverage/v2", "e_fixtures": {}, "e2b_fixtures": {}}
    lat = []

    # --- migrated E fixtures ---
    for fid, fx in E_FIX.items():
        guide = GUIDES[fid]["guide"]
        t = time.time()
        try:
            r, id_map, gids = run_one(gw, fx["creative_intent"], fx["scope"], guide, fx["moments"], fx.get("pending_count", 0))
            dt = time.time() - t; lat.append(dt)
            d = r.data
            dc = d["dimension_coverage"]
            covered_ids = {x["story_guide_dimension_id"] for x in dc}
            rec = {"ok": True, "latency_s": round(dt, 1), "group": GUIDES[fid]["group"],
                   "guide_dim_ids": gids, "dim_states": {x["story_guide_dimension_id"]: x["state"] for x in dc},
                   "all_dims_covered": set(gids) == covered_ids, "invented_dims": sorted(covered_ids - set(gids)),
                   "sufficiency": d["sufficiency"]["status"], "idea": d["story_idea"],
                   "idea_words": idea_words(d["story_idea"]), "idea_lengths": idea_lengths(d["story_idea"]),
                   "strengths": d["strengths"],
                   "redundancies": d["redundancies"]}
            out["e_fixtures"][fid] = rec
            print(f"[E] {fid:28s} suff={rec['sufficiency']:12s} idea={'Y' if d['story_idea'] else '-'}"
                  f"({rec['idea_words']}w) dims_ok={rec['all_dims_covered']} {dt:.1f}s")
        except (StructuredOutputError, ProviderError) as e:
            out["e_fixtures"][fid] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:140]}"}
            print(f"[E] {fid}: FAIL {out['e_fixtures'][fid]['error']}")

    # --- new E2-b fixtures (inline guides) ---
    for fid, fx in E2B_FIX.items():
        guide = fx["guide"]
        t = time.time()
        try:
            r, id_map, gids = run_one(gw, fx["creative_intent"], fx["scope"], guide, fx["moments"], fx.get("pending_count", 0))
            dt = time.time() - t; lat.append(dt)
            d = r.data
            dc = {x["story_guide_dimension_id"]: x for x in d["dimension_coverage"]}
            rec = {"ok": True, "latency_s": round(dt, 1), "expected": fx["expected"],
                   "dim_coverage": {k: {"state": v["state"], "rep": v.get("represented_possibility_ids", [])} for k, v in dc.items()},
                   "sufficiency": d["sufficiency"]["status"], "idea": d["story_idea"],
                   "strengths": d["strengths"]}
            out["e2b_fixtures"][fid] = rec
            print(f"[E2b] {fid:28s} {json.dumps(rec['dim_coverage'])} suff={rec['sufficiency']}")
        except (StructuredOutputError, ProviderError) as e:
            out["e2b_fixtures"][fid] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:140]}"}
            print(f"[E2b] {fid}: FAIL {out['e2b_fixtures'][fid]['error']}")

    (REPO / "evals/results/story_coverage_e2b_v2fix.json").write_text(json.dumps(out, indent=2))
    if lat:
        print(f"\n=== {len(lat)} calls, p50 {median(lat):.1f}s, p95 {sorted(lat)[int(len(lat)*0.95)-1]:.1f}s ===")
    print("wrote evals/results/story_coverage_e2b_v2fix.json")


if __name__ == "__main__":
    main()
