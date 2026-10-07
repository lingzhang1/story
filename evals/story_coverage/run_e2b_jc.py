"""E2-b J-C experiment: frozen Mapper + factual material-scope evidence -> Judge v2.

Changes ONLY the Judge input abstraction vs J-A: adds neutral FACTUAL material-scope evidence
(understood_moment_count, useful_moment_count, total_useful_segment_duration_seconds,
target_output_duration_seconds) derived DETERMINISTICALLY from the fixtures' MomentUnderstanding
useful_segments. NO Guide, NO dimension states, NO candidates, NO completion signals (preserves the
J-A/J-B ablation result). Judge prompt = story_judgment/v2 (refined sufficiency + material adequacy +
novel-contribution idea rule). Opus 4.6. Mapper reused from the two-call run (verification-only).

Usage: TMPDIR=/tmp .venv/bin/python evals/story_coverage/run_e2b_jc.py --run
Writes evals/results/story_coverage_e2b_jc.json
"""
from __future__ import annotations
import argparse, json, pathlib, re, sys, time, uuid
from statistics import median

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO), str(REPO / "packages")]
from model_gateway import BedrockModelGateway, StructuredRequest, StructuredOutputError, ProviderError

MODEL = "us.anthropic.claude-opus-4-6-v1"
JUDGE_PROMPT = (REPO / "prompts/story_judgment/v2/system.md").read_text()
MAPPER_PROMPT = (REPO / "prompts/story_coverage/mapper-v1/system.md").read_text()
E_FIX = json.loads((REPO / "evals/story_coverage/fixtures.json").read_text())["fixtures"]
E2B_FIX = json.loads((REPO / "evals/story_coverage/fixtures_e2b.json").read_text())["fixtures"]
GUIDES = json.loads((REPO / "evals/story_guide/fixture_guides.json").read_text())
STATES = ["strong", "looking_good", "could_use_more", "unknown"]
SUFF = ["insufficient", "workable", "sufficient"]

JUDGE_SCHEMA = {"type": "object", "additionalProperties": False, "properties": {
    "sufficiency": {"type": "object", "additionalProperties": False,
        "properties": {"status": {"type": "string", "enum": SUFF}, "reason": {"type": "string"}}, "required": ["status"]},
    "story_idea": {"type": ["object", "null"], "additionalProperties": False, "properties": {
        "title": {"type": "string"}, "description": {"type": "string"}, "rationale": {"type": "string"},
        "target_story_guide_dimension_id": {"type": ["string", "null"]}}, "required": ["title", "description"]}},
    "required": ["sufficiency", "story_idea"]}


def seg_dur(s):
    a = s.get("t_start_s", s.get("start_time", s.get("start_seconds")))
    b = s.get("t_end_s", s.get("end_time", s.get("end_seconds")))
    try:
        return float(b) - float(a) if a is not None and b is not None else None
    except Exception:
        return None


def material_scope(fx):
    target = fx["scope"].get("target_duration_seconds")
    umom = 0; total = 0.0; comp = 0
    for m in fx["moments"]:
        if m.get("pending"):
            continue
        comp += 1
        us = m.get("observed", {}).get("useful_segments", [])
        any_useful = False
        for s in us:
            d = seg_dur(s)
            if d and d > 0:
                total += d; any_useful = True
        if any_useful or us:
            umom += 1
    return {"target_output_duration_seconds": target, "understood_moment_count": comp,
            "useful_moment_count": umom, "total_useful_segment_duration_seconds": round(total, 1)}


# --- Mapper (frozen; verification + strengths/redundancies source) ---
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


def gc(guide):
    return {"framing_summary": guide["framing_summary"], "dimensions": [
        {"id": d["id"], "label": d["label"], "purpose": d["purpose"],
         "capture_possibilities": [{"id": p["id"], "label": p["label"]} for p in d.get("capture_possibilities", [])]}
        for d in guide["dimensions"]]}


def cmu(m, idm):
    if m.get("pending"):
        return None
    r = idm.setdefault(m["id"], str(uuid.uuid4())); o = m["observed"]
    return {"moment_id": r, "summary": o.get("summary", ""), "subjects": o.get("subjects", []),
            "events": [e.get("description", "") for e in o.get("events", [])],
            "useful_segments": [s.get("why_useful", "") for s in o.get("useful_segments", [])],
            "story_utility": m.get("story_context", {}).get("story_utility")}


def run_mapper(gw, guide, moments, pending):
    gids = [d["id"] for d in guide["dimensions"]]
    pids = [p["id"] for d in guide["dimensions"] for p in d.get("capture_possibilities", [])]
    idm = {}
    mus = [x for x in (cmu(m, idm) for m in moments) if x]
    payload = {"story_guide": gc(guide), "pending_count": pending, "moments": mus}
    user = ("Map the understood material onto this StoryGuide. One dimension_coverage entry per Guide "
            "dimension (by id). Purpose > literal possibility. Return ONLY the CoverageMapping.\n\n" + json.dumps(payload, indent=2))
    req = StructuredRequest(task="story_coverage.map", schema=mapper_schema(gids, pids),
                            prompt_version="story_coverage/mapper-v1", system=MAPPER_PROMPT,
                            user_content=user, max_repair_attempts=2, max_tokens=1800, temperature=0.0)
    return gw.generate_structured(req), gids


def run_judge(gw, ci, scope, strengths, redundancies, ms, pending):
    ev = {"creative_intent": ci, "scope": scope,
          "positive_actual_story_evidence": strengths,
          "material_scope_evidence": ms, "redundancy": redundancies, "pending_count": pending}
    user = ("Judge this Story from the semantic evidence AND the factual material-scope evidence.\n\n"
            + json.dumps(ev, indent=2)
            + "\n\nmaterial_scope_evidence is neutral FACT, not a quota. Decide sufficiency (is there "
              "enough suitable material for THIS scope?) independently, then whether ONE genuinely NEW "
              "opportunity is worth surfacing (else null). Return ONLY the StoryJudgment.")
    req = StructuredRequest(task="story_judgment.decide", schema=JUDGE_SCHEMA,
                            prompt_version="story_judgment/v2", system=JUDGE_PROMPT,
                            user_content=user, max_repair_attempts=2, max_tokens=1200, temperature=0.0)
    return gw.generate_structured(req)


def _wc(s): return len(re.findall(r"\S+", s or ""))


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--run", action="store_true"); a = ap.parse_args()
    if not a.run:
        print("dry run"); return
    gw = BedrockModelGateway(model_id=MODEL)
    out = {"model": MODEL, "judge_prompt": "story_judgment/v2", "fixtures": {}}
    lat = []
    allfix = {**{k: ("E", v) for k, v in E_FIX.items()}, **{k: ("E2b", v) for k, v in E2B_FIX.items()}}
    for fid, (kind, fx) in allfix.items():
        guide = GUIDES[fid]["guide"] if kind == "E" else fx["guide"]
        try:
            t = time.time()
            mres, gids = run_mapper(gw, guide, fx["moments"], fx.get("pending_count", 0))
            mp = mres.data
            ms = material_scope(fx)
            jr = run_judge(gw, fx["creative_intent"], fx["scope"], mp["strengths"], mp["redundancies"], ms, fx.get("pending_count", 0))
            j = jr.data; idea = j["story_idea"]
            covered = {c["story_guide_dimension_id"] for c in mp["dimension_coverage"]}
            out["fixtures"][fid] = {"kind": kind, "material_scope": ms,
                "mapper": {"dim_states": {c["story_guide_dimension_id"]: c["state"] for c in mp["dimension_coverage"]},
                           "invented": sorted(covered - set(gids)), "strengths": mp["strengths"], "redundancies": mp["redundancies"]},
                "sufficiency": j["sufficiency"]["status"], "idea": idea,
                "idea_lengths": ({"title_w": _wc(idea["title"]), "desc_w": _wc(idea["description"]), "rat_w": _wc(idea.get("rationale"))} if idea else None)}
            lat.append(time.time() - t)
            ratio = (ms["total_useful_segment_duration_seconds"] / ms["target_output_duration_seconds"]) if ms["target_output_duration_seconds"] else 0
            print(f"{fid:30s} ratio={ratio:4.2f}x useful={ms['total_useful_segment_duration_seconds']:6.1f}s/"
                  f"{ms['target_output_duration_seconds']}s | suff={j['sufficiency']['status']:12s} idea={'Y' if idea else '-'}")
        except (StructuredOutputError, ProviderError) as e:
            out["fixtures"][fid] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:140]}"}
            print(f"{fid}: FAIL {out['fixtures'][fid]['error']}")
    (REPO / "evals/results/story_coverage_e2b_jc.json").write_text(json.dumps(out, indent=2))
    if lat:
        print(f"\n=== {len(lat)} fixtures x 2 calls, per-fixture p50 {median(lat):.1f}s ===")
    print("wrote evals/results/story_coverage_e2b_jc.json")


if __name__ == "__main__":
    main()
