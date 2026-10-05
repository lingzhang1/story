"""DIRECT UX enhancements eval (null-scene Skip-Scan + 3 ephemeral alternatives).

Uses the PRODUCTION Director model + prompt + frozen contracts + guards. Changes
ONLY: (A) run with scene_understanding=null; (B) ask for ~3 ranked ALTERNATIVE
decisions in ONE call, verifying they do NOT inflate plan.beats/plan.shots
(no over-planning) and are genuinely different (no paraphrase).

No new model bake-off: one model, the production one.
"""
from __future__ import annotations
import glob, json, sys, time
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
for rel in (".", "packages", "apps/api"):
    p = str((_ROOT / rel).resolve())
    if p not in sys.path: sys.path.insert(0, p)

from story_director import RealStoryDirectorEngine, DirectorOutput  # noqa: E402
from model_gateway import BedrockModelGateway, StructuredOutputError, ProviderError  # noqa: E402

MODEL = "us.anthropic.claude-opus-4-5-20251101-v1:0"  # production Director model

# Representative subset: relevant-ordinary, irrelevant-ordinary (rescan), rich scene,
# min-cap low-value. Enough to exercise actionability + grounding + over-planning.
SUBSET = [
    "dir_tmb_pretrip_home", "dir_ng_A_tmb_home_relevant",
    "dir_ng_B_tmb_musicroom_irrelevant", "dir_mincap_rich_scene",
    "dir_tmb_trail",
]

# Fabrication tripwires for the NULL-scene case: words implying specific unseen
# environment/objects a scene-less Director must not assert.
FAB_WORDS = ["window", "backpack", "trail", "mountain", "summit", "door", "bookshelf",
             "road", "street", "desk", "guitar", "chair", "the room", "the kitchen",
             "to your left", "to your right", "behind you", "in front of you"]


def _candidates_schema() -> dict:
    """Envelope + an ephemeral `candidates` array (alternative decisions). This is an
    ENGINE-RESPONSE shape only — NOT a canonical contract and NOT persisted into
    StoryPlan. plan.beats/plan.shots stay minimal; candidates are extra DECISIONS."""
    from contracts.schemas.ai_contracts import DirectorDecision
    base = DirectorOutput.model_json_schema()
    # Add candidates[] (each a DirectorDecision) at the top level, additive + optional.
    dd = DirectorDecision.model_json_schema()
    # inline $defs so the schema is self-contained for the tool
    defs = base.setdefault("$defs", {})
    for k, v in (dd.get("$defs") or {}).items():
        defs.setdefault(k, v)
    dd.pop("$defs", None)
    base["properties"]["candidates"] = {
        "type": "array", "items": dd, "minItems": 1, "maxItems": 3,
        "description": "Ranked ALTERNATIVE decisions for the SAME current slot. "
                       "candidates[0] == the primary decision. Each is a different way to "
                       "serve the SAME narrative need; NOT a multi-shot plan to capture all."
    }
    return base


CANDIDATES_INSTRUCTION = (
    "\n\nADDITIONALLY: in `candidates`, return up to 3 RANKED ALTERNATIVE decisions for "
    "the SAME current recommendation slot. candidates[0] MUST equal `decision`. "
    "candidates[1] and candidates[2] must be GENUINELY DIFFERENT creative approaches to "
    "serve the SAME narrative need — different subject_action / framing / angle — NOT "
    "paraphrases of candidates[0]. These are EPHEMERAL alternatives: the user captures AT "
    "MOST ONE. Do NOT add beats or shots to the plan for them; do NOT treat them as "
    "additional required captures. plan.beats and plan.shots must stay exactly as minimal "
    "as if you returned a single recommendation."
)


def build_request(eng, ci, su, cc, with_candidates: bool):
    import json as _json
    content = {"operation": "initialize", "creative_intent": ci,
               "scene_understanding": su, "capture_constraints": cc or {}}
    user = ("INITIALIZE. Produce the concept, plan (beats + shots), initial director_state, "
            "and the first decision for this task:\n" + _json.dumps(content, ensure_ascii=False))
    if su is None:
        user = ("NOTE: scene_understanding is NULL — the user SKIPPED the scene scan, so you "
                "have NO information about their physical surroundings. Do NOT invent or assume "
                "any visible objects, people, environment, layout, space, lighting, or safety "
                "conditions. Base the recommendation ONLY on the CreativeIntent and keep it "
                "environment-agnostic and safe.\n\n") + user
    from model_gateway import StructuredRequest
    schema = _candidates_schema() if with_candidates else eng._schema
    system = eng._system + (CANDIDATES_INSTRUCTION if with_candidates else "")
    return StructuredRequest(task="story_director.initialize", schema=schema,
                             prompt_version="story_director/v1", system=system,
                             user_content=user + (CANDIDATES_INSTRUCTION if with_candidates else ""),
                             max_repair_attempts=1, max_tokens=2200, temperature=0.3)


def norm(s): return " ".join((s or "").lower().split())


def main():
    eng = RealStoryDirectorEngine(BedrockModelGateway(model_id=MODEL))
    files = {Path(f).stem.replace(".fixture",""): f
             for f in glob.glob(str(_ROOT/"evals/story_director/*.fixture.json"))}
    rows = []
    for fid in SUBSET:
        fx = json.load(open(files[fid])); inp = fx["inputs"]
        ci, su_real, cc = inp["creative_intent"], inp.get("scene_understanding"), inp.get("capture_constraints")
        for scene_mode in ("scanned", "null"):
            su = su_real if scene_mode == "scanned" else None
            for cand in (False, True):
                t = time.time()
                try:
                    res = eng._gateway.generate_structured(build_request(eng, ci, su, cc, cand))
                    ms = int((time.time()-t)*1000)
                    data = eng._mint_ids(dict(res.data))
                    cands = data.pop("candidates", None)
                    out = DirectorOutput.model_validate(data)
                    eng._integrity_guard(out); eng._safety_guard(out)
                    row = {"fid": fid, "scene": scene_mode, "candidates_req": cand, "ms": ms,
                           "valid": True, "beats": len(out.plan.beats), "shots": len(out.plan.shots),
                           "action": out.decision.action.value,
                           "rec": out.decision.shot.instruction if out.decision.shot else None}
                    if cand and cands:
                        instrs = [c.get("shot",{}).get("instruction") if isinstance(c.get("shot"),dict) else None for c in cands]
                        instrs = [i for i in instrs if i]
                        uniq = len({norm(i) for i in instrs})
                        row["n_candidates"] = len(cands)
                        row["uniq_candidate_instr"] = uniq
                        row["candidate_instrs"] = instrs
                    if scene_mode == "null":
                        blob = norm((out.decision.shot.instruction if out.decision.shot else "") + " " +
                                    (out.decision.shot.purpose if out.decision.shot else ""))
                        row["fabrication_hits"] = [w for w in FAB_WORDS if w in blob]
                    rows.append(row)
                    tag = f"{fid}/{scene_mode}/{'cand' if cand else 'single'}"
                    extra = ""
                    if cand and cands: extra = f" ncand={row['n_candidates']} uniq={row['uniq_candidate_instr']}"
                    if scene_mode=="null": extra += f" fab={row.get('fabrication_hits')}"
                    print(f"  {tag:48s} valid b={row['beats']} s={row['shots']} {row['action']:12s} {ms:5d}ms{extra}")
                except (StructuredOutputError, ProviderError) as e:
                    rows.append({"fid":fid,"scene":scene_mode,"candidates_req":cand,"valid":False,"error":str(e)[:120]})
                    print(f"  {fid}/{scene_mode}/{'cand' if cand else 'single'} FAIL {type(e).__name__}: {str(e)[:80]}")
    out = _ROOT/"evals/results/direct_ux_enhancements.json"
    out.write_text(json.dumps({"model":MODEL,"rows":rows}, indent=2))
    # summary
    nullrows = [r for r in rows if r.get("scene")=="null" and r.get("valid")]
    fabbed = [r for r in nullrows if r.get("fabrication_hits")]
    candrows = [r for r in rows if r.get("candidates_req") and r.get("valid")]
    print("\n=== SUMMARY ===")
    print(" null-scene valid:", len(nullrows), "with fabrication hits:", len(fabbed))
    for r in fabbed: print("   FAB:", r["fid"], r["fabrication_hits"], "::", (r["rec"] or "")[:80])
    print(" candidate runs:", len(candrows),
          "| over-planning check (beats<=2 & shots<=2 expected per scene contribution):")
    for r in candrows:
        print(f"   {r['fid']}/{r['scene']}: beats={r['beats']} shots={r['shots']} ncand={r.get('n_candidates')} uniq={r.get('uniq_candidate_instr')}")
    print("wrote", out)


if __name__ == "__main__":
    main()
