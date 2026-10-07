"""E2-b step 1: generate the FROZEN StoryGuide for each Coverage fixture, using the
frozen Guide engine (Opus 4.6, prompts/story_guide/v1, story_guide/1 schema). The TMB
'our trek' family (A, B, C, D, E, G, H1, H2, H3, I, L) that shares the SAME CreativeIntent
family must share ONE Guide so the H1/H2/H3 stable-identity test is meaningful; distinct
intents (F1 valley-8s, F2 rich-trek-120s, J solitude, K guitar) get their own Guide.

Guide is a function of CreativeIntent + scope ONLY (never Moments), so fixtures with the
same intent+scope share a Guide. We key the Guide cache by (subject, intent-summary, scope).

Server-mints canonical ids over the model's ordinal ids (d1->dim_<n>, d1p1->cp_<n>).

Usage: TMPDIR=/tmp .venv/bin/python evals/story_guide/gen_fixture_guides.py --run
Writes evals/story_guide/fixture_guides.json  (fixture_key -> frozen StoryGuide)
"""
from __future__ import annotations
import argparse, json, pathlib, sys, time, uuid

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO), str(REPO / "packages")]
from model_gateway import BedrockModelGateway, StructuredRequest

GUIDE_MODEL = "us.anthropic.claude-opus-4-6-v1"
PROMPT = (REPO / "prompts/story_guide/v1/system.md").read_text()
COV_FIX = json.loads((REPO / "evals/story_coverage/fixtures.json").read_text())["fixtures"]

# Reuse the EXACT experimental Guide schema from the E2-a runner (ordinal ids).
from importlib.util import spec_from_file_location, module_from_spec
_spec = spec_from_file_location("e2a_run", REPO / "evals/story_guide/run_experiment.py")
_e2a = module_from_spec(_spec); _spec.loader.exec_module(_e2a)
GUIDE_SCHEMA = _e2a.GUIDE_SCHEMA

# Which fixtures SHARE a Guide (same CreativeIntent family). The TMB 'trek' intent is the
# through-line of the Milestone-E suite; H1/H2/H3 MUST share so identity stability is testable.
GUIDE_GROUPS = {
    "tmb_trek_90": ["B_broad_coverage", "G_conflicting", "H1_accum", "H2_accum", "H3_accum", "L_pending_au"],
    "tmb_scenery_60": ["A_scenery_only"],
    "tmb_scenery_45": ["C_redundant_scenery"],
    "tmb_depart_30": ["D_strong_elsewhere"],
    "tmb_trip_30": ["E_contextless"],
    "tmb_valley_8": ["F1_one_exceptional_short"],
    "tmb_trek_120": ["F2_one_exceptional_rich"],
    "tmb_sufficient_20": ["I_no_intervention_sufficient"],
    "solitude_40": ["J_anti_checklist_solitude"],
    "guitar_45": ["K_nontravel_guitar"],
}


def mint_ids(data: dict) -> dict:
    """Server-mint canonical stable ids over the model's ordinal handles."""
    out = {"schema_version": "story_guide/1",
           "framing_summary": data["framing_summary"], "dimensions": []}
    for i, d in enumerate(data.get("dimensions", []), 1):
        dim = {"id": f"dim_{i:02d}", "label": d["label"], "purpose": d["purpose"],
               "capture_possibilities": []}
        for j, p in enumerate(d.get("capture_possibilities", []), 1):
            cp = {"id": f"{dim['id']}_cp_{j:02d}", "label": p["label"]}
            if p.get("semantic_purpose"):
                cp["semantic_purpose"] = p["semantic_purpose"]
            dim["capture_possibilities"].append(cp)
        out["dimensions"].append(dim)
    return out


def gen_guide(gw, ci, scope):
    payload = {"creative_intent": ci, "scope": scope}
    user = ("Produce the StoryGuide for THIS Story.\n\nCREATIVE INTENT + SCOPE:\n"
            + json.dumps(payload, indent=2)
            + "\n\nScale the map to scope, use this Story's own domain vocabulary, honor explicit "
              "constraints, keep capture_possibilities as a few examples. Return ONLY the StoryGuide.")
    req = StructuredRequest(task="story_guide.generate", schema=GUIDE_SCHEMA,
                            prompt_version="story_guide/v1", system=PROMPT,
                            user_content=user, max_repair_attempts=2, max_tokens=2000, temperature=0.0)
    return gw.generate_structured(req)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--run", action="store_true"); a = ap.parse_args()
    if not a.run:
        print("dry run"); return
    gw = BedrockModelGateway(model_id=GUIDE_MODEL)
    per_fixture = {}
    for group, keys in GUIDE_GROUPS.items():
        rep = keys[0]
        fx = COV_FIX[rep]
        ci = fx["creative_intent"]; scope = fx["scope"]
        t = time.time()
        r = gen_guide(gw, ci, scope)
        guide = mint_ids(r.data); guide["story_id"] = str(uuid.uuid4())
        dt = time.time() - t
        print(f"[{group}] {len(guide['dimensions'])} dims, {dt:.1f}s, {r.usage.total_tokens if r.usage else '?'} tok "
              f"-> {', '.join(d['label'] for d in guide['dimensions'])}")
        for k in keys:
            # each fixture gets its OWN story_id but the SAME guide body for the group
            g = json.loads(json.dumps(guide)); g["story_id"] = str(uuid.uuid4())
            per_fixture[k] = {"group": group, "guide": g}
    out = REPO / "evals/story_guide/fixture_guides.json"
    out.write_text(json.dumps(per_fixture, indent=2))
    print("wrote", out, "for", len(per_fixture), "fixtures")


if __name__ == "__main__":
    main()
