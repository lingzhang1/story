"""E2-b two-call architecture experiment: Mapper (Call 1) + Judge (Call 2), variants J-A / J-B.

CALL 1 StoryCoverageMapper (prompts/story_coverage/mapper-v1): StoryGuide + completed MU[] + pending
  -> dimension_coverage[] + strengths[] + redundancies[]. NO sufficiency, NO idea.
DETERMINISTIC evidence build (NO extra LLM): Mapper strengths -> positive story evidence; redundancies;
  pending_count; + (J-B only) optional opportunity candidates = {dimension_id,label,purpose} for
  dimensions the Mapper did NOT rate strong/looking_good, with NO state/possibility/completion words.
CALL 2 StoryJudgmentEngine (prompts/story_judgment/v1): -> {sufficiency, story_idea|null}.
  J-A = no candidates; J-B = with optional candidates. Opus 4.6 both.

Public StoryCoverage/2 = Mapper output + Judge output (composed; not changed).

Usage: TMPDIR=/tmp .venv/bin/python evals/story_coverage/run_e2b_twocall.py --run
Writes evals/results/story_coverage_e2b_twocall.json
"""
from __future__ import annotations
import argparse, json, pathlib, re, sys, time, uuid
from statistics import median

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO), str(REPO / "packages")]
from model_gateway import BedrockModelGateway, StructuredRequest, StructuredOutputError, ProviderError

MODEL = "us.anthropic.claude-opus-4-6-v1"
MAPPER_PROMPT = (REPO / "prompts/story_coverage/mapper-v1/system.md").read_text()
JUDGE_PROMPT = (REPO / "prompts/story_judgment/v1/system.md").read_text()
E_FIX = json.loads((REPO / "evals/story_coverage/fixtures.json").read_text())["fixtures"]
E2B_FIX = json.loads((REPO / "evals/story_coverage/fixtures_e2b.json").read_text())["fixtures"]
GUIDES = json.loads((REPO / "evals/story_guide/fixture_guides.json").read_text())
STATES = ["strong", "looking_good", "could_use_more", "unknown"]
SUFF = ["insufficient", "workable", "sufficient"]
STRONG_ENOUGH = {"strong", "looking_good"}


def mapper_schema(gids, pids):
    return {"type": "object", "additionalProperties": False, "properties": {
        "dimension_coverage": {"type": "array", "items": {"type": "object", "additionalProperties": False,
            "properties": {"story_guide_dimension_id": {"type": "string", "enum": gids},
                "state": {"type": "string", "enum": STATES}, "note": {"type": "string"},
                "evidence_moment_ids": {"type": "array", "items": {"type": "string"}},
                "represented_possibility_ids": {"type": "array",
                    "items": ({"type": "string", "enum": pids} if pids else {"type": "string"})}},
            "required": ["story_guide_dimension_id", "state"]}},
        "strengths": {"type": "array", "items": {"type": "string"}},
        "redundancies": {"type": "array", "items": {"type": "string"}}},
        "required": ["dimension_coverage", "strengths", "redundancies"]}


JUDGE_SCHEMA = {"type": "object", "additionalProperties": False, "properties": {
    "sufficiency": {"type": "object", "additionalProperties": False,
        "properties": {"status": {"type": "string", "enum": SUFF}, "reason": {"type": "string"}},
        "required": ["status"]},
    "story_idea": {"type": ["object", "null"], "additionalProperties": False, "properties": {
        "title": {"type": "string"}, "description": {"type": "string"}, "rationale": {"type": "string"},
        "target_story_guide_dimension_id": {"type": ["string", "null"]}},
        "required": ["title", "description"]}},
    "required": ["sufficiency", "story_idea"]}


def guide_compact(guide):
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


def run_mapper(gw, ci, scope, guide, moments, pending):
    gids = [d["id"] for d in guide["dimensions"]]
    pids = [p["id"] for d in guide["dimensions"] for p in d.get("capture_possibilities", [])]
    id_map = {}
    mus = [x for x in (compact_mu(m, id_map) for m in moments) if x]
    payload = {"story_guide": guide_compact(guide), "pending_count": pending, "moments": mus}
    user = ("Map the understood material onto this StoryGuide. One dimension_coverage entry per Guide "
            "dimension (by id). Purpose fulfillment > literal possibility. Return ONLY the CoverageMapping.\n\n"
            + json.dumps(payload, indent=2))
    req = StructuredRequest(task="story_coverage.map", schema=mapper_schema(gids, pids),
                            prompt_version="story_coverage/mapper-v1", system=MAPPER_PROMPT,
                            user_content=user, max_repair_attempts=2, max_tokens=1800, temperature=0.0)
    return gw.generate_structured(req), {d["id"]: d for d in guide["dimensions"]}


def build_judge_evidence(ci, scope, mapping, guide_dims, pending, with_candidates):
    """DETERMINISTIC. positive evidence = mapper strengths; redundancy = mapper redundancies;
    candidates (J-B only) = {id,label,purpose} for dims NOT strong/looking_good, NO state words."""
    ev = {"creative_intent": ci, "scope": scope,
          "positive_actual_story_evidence": mapping["strengths"],
          "redundancy": mapping["redundancies"], "pending_count": pending}
    if with_candidates:
        weak = [c["story_guide_dimension_id"] for c in mapping["dimension_coverage"]
                if c["state"] not in STRONG_ENOUGH]
        ev["optional_opportunity_candidates"] = [
            {"story_guide_dimension_id": gid, "label": guide_dims[gid]["label"],
             "purpose": guide_dims[gid]["purpose"]}
            for gid in weak if gid in guide_dims]
    return ev


def run_judge(gw, evidence, with_candidates):
    note = ("\n\nOPTIONAL OPPORTUNITY CANDIDATES are creative possibilities the Story could explore — they "
            "are NOT missing requirements or gaps. Decide if ONE is valuable enough to surface; if none "
            "is, story_idea = null." if with_candidates else
            "\n\nDecide sufficiency and whether ONE Story Idea is worth surfacing; story_idea = null is "
            "a valid, successful answer.")
    user = ("Judge this Story.\n\n" + json.dumps(evidence, indent=2) + note
            + "\n\nReturn ONLY the StoryJudgment via the tool.")
    req = StructuredRequest(task="story_judgment.decide", schema=JUDGE_SCHEMA,
                            prompt_version="story_judgment/v1", system=JUDGE_PROMPT,
                            user_content=user, max_repair_attempts=2, max_tokens=1200, temperature=0.0)
    return gw.generate_structured(req)


def _wc(s): return len(re.findall(r"\S+", s or ""))


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--run", action="store_true"); a = ap.parse_args()
    if not a.run:
        print("dry run"); return
    gw = BedrockModelGateway(model_id=MODEL)
    out = {"model": MODEL, "fixtures": {}}
    lat = []
    allfix = {**{k: ("E", v) for k, v in E_FIX.items()}, **{k: ("E2b", v) for k, v in E2B_FIX.items()}}
    for fid, (kind, fx) in allfix.items():
        guide = (GUIDES[fid]["guide"] if kind == "E" else fx["guide"])
        try:
            t = time.time()
            mres, gdims = run_mapper(gw, fx["creative_intent"], fx["scope"], guide, fx["moments"], fx.get("pending_count", 0))
            mapping = mres.data
            gids = [d["id"] for d in guide["dimensions"]]
            covered = {c["story_guide_dimension_id"] for c in mapping["dimension_coverage"]}
            rec = {"kind": kind, "mapper": {"dim_states": {c["story_guide_dimension_id"]: c["state"] for c in mapping["dimension_coverage"]},
                   "all_covered": set(gids) == covered, "invented": sorted(covered - set(gids)),
                   "strengths": mapping["strengths"], "redundancies": mapping["redundancies"],
                   "rep_possibility": {c["story_guide_dimension_id"]: c.get("represented_possibility_ids", []) for c in mapping["dimension_coverage"]}}}
            for variant, cand in (("J_A", False), ("J_B", True)):
                ev = build_judge_evidence(fx["creative_intent"], fx["scope"], mapping, gdims, fx.get("pending_count", 0), cand)
                jr = run_judge(gw, ev, cand)
                j = jr.data; idea = j["story_idea"]
                rec[variant] = {"sufficiency": j["sufficiency"]["status"],
                                "idea": idea,
                                "idea_lengths": ({"title_w": _wc(idea["title"]), "desc_w": _wc(idea["description"]),
                                                  "rat_w": _wc(idea.get("rationale"))} if idea else None),
                                "n_candidates": len(ev.get("optional_opportunity_candidates", []))}
            lat.append(time.time() - t)
            out["fixtures"][fid] = rec
            ja, jb = rec["J_A"], rec["J_B"]
            print(f"{fid:30s} map_ok={rec['mapper']['all_covered']} | "
                  f"J-A {ja['sufficiency']:12s} idea={'Y' if ja['idea'] else '-'} | "
                  f"J-B {jb['sufficiency']:12s} idea={'Y' if jb['idea'] else '-'} (cand={jb['n_candidates']})")
        except (StructuredOutputError, ProviderError) as e:
            out["fixtures"][fid] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:140]}"}
            print(f"{fid}: FAIL {out['fixtures'][fid]['error']}")
    (REPO / "evals/results/story_coverage_e2b_twocall.json").write_text(json.dumps(out, indent=2))
    if lat:
        print(f"\n=== {len(lat)} fixtures x 3 calls, per-fixture p50 {median(lat):.1f}s ===")
    print("wrote evals/results/story_coverage_e2b_twocall.json")


if __name__ == "__main__":
    main()
