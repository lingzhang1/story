"""Production-path Story Coverage regression gate (Milestone E §evaluation).

Runs the ACTUAL production engine (story_coverage.RealStoryCoverageEngine via the real
BedrockModelGateway tool-use path — Opus 4.6, story_coverage/v1 ORIGINAL prompt) over the frozen
15-fixture corpus, scored vs human references. Confirms the original Opus behavior holds in
production: 0 false-sufficient, 0 false-insufficient, 0 missed worthwhile ideas, no anti-checklist
regression, full structured validity.

Usage: TMPDIR=/tmp .venv/bin/python evals/story_coverage/run_production_gate.py --run
"""
from __future__ import annotations
import argparse, json, pathlib, sys, time
from statistics import median

REPO = pathlib.Path(__file__).resolve().parents[2]
for rel in (".", "packages", "apps/api"):
    p = str((REPO / rel).resolve())
    if p not in sys.path:
        sys.path.insert(0, p)

FIX = json.loads((REPO / "evals/story_coverage/fixtures.json").read_text())["fixtures"]


def to_mu(m, id_map):
    """Fixture moment -> MomentUnderstanding dict the engine expects (skip pending).
    Fixtures use short ids ('m1'); production uses UUIDs, so mint one per fixture moment."""
    if m.get("pending"):
        return None
    import uuid
    real = id_map.setdefault(m["id"], str(uuid.uuid4()))
    return {"moment_id": real, "observed": m["observed"], "story_context": m["story_context"]}


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--run", action="store_true"); a = ap.parse_args()
    import uuid
    from story_coverage import RealStoryCoverageEngine, CoverageInput, CoverageUnavailableError, DEFAULT_COVERAGE_MODEL
    from model_gateway import BedrockModelGateway
    eng = RealStoryCoverageEngine(BedrockModelGateway(model_id=DEFAULT_COVERAGE_MODEL), model_id=DEFAULT_COVERAGE_MODEL)

    rows = []
    for fid, fx in FIX.items():
        id_map = {}
        mus = [x for x in (to_mu(m, id_map) for m in fx["moments"]) if x]
        pending = fx.get("pending_count", 0)
        print(f"\n== {fid} ==")
        if not a.run:
            rows.append({"fixture": fid}); continue
        t = time.time()
        try:
            cov = eng.compute(CoverageInput(story_id=uuid.uuid4(), creative_intent=fx["creative_intent"],
                              scope=fx["scope"], moment_understandings=mus, pending_count=pending))
            dt = time.time() - t
            rows.append({"fixture": fid, "ok": True, "latency_s": round(dt, 1),
                         "data": cov.model_dump(mode="json")})
            print(f"   OK {dt:.1f}s suff={cov.sufficiency.status.value:12s} dims={len(cov.dimensions)} "
                  f"idea={'YES' if cov.story_idea else 'null'}")
        except CoverageUnavailableError as e:
            rows.append({"fixture": fid, "ok": False, "error": str(e)[:200]})
            print(f"   FAIL {str(e)[:120]}")

    out = REPO / "evals/results/story_coverage_production_gate.json"
    out.write_text(json.dumps({"model": "us.anthropic.claude-opus-4-6-v1", "rows": rows}, indent=2))

    if a.run:
        # STRICT: exact/required semantic expectations vs human_reference.
        # SEMANTIC_ENVELOPE (owner-classified, e.g. A): outcome must fall inside the
        # approved acceptable set + pass forbidden checks; an acceptable `sufficient`
        # on A is NOT counted as false-sufficient.
        strict = {"suff_ok": 0, "idea_ok": 0, "false_suff": 0, "false_insuff": 0,
                  "unnec": 0, "missed": 0, "n": 0}
        env = {"within": 0, "outside": 0, "n": 0, "notes": []}
        valid = 0
        lat = []
        for r in rows:
            if not r.get("ok"):
                continue
            fx = FIX[r["fixture"]]; d = r["data"]
            valid += 1; lat.append(r["latency_s"])
            su = d["sufficiency"]["status"]; idea = d.get("story_idea") is not None
            mode = fx.get("eval_mode", "strict")

            if mode == "semantic_envelope":
                env["n"] += 1
                acc = fx["semantic_envelope"]["acceptable"]
                ok_suff = su in acc["sufficiency"]
                idea_tok = "one_optional_complementary_idea" if idea else "null"
                ok_idea = idea_tok in acc["story_idea"]
                # forbidden: insufficient is the only machine-checkable forbidden here;
                # scenery-request / camera-direction / template are human-review flags.
                forbidden_hit = (su == "insufficient")
                if ok_suff and ok_idea and not forbidden_hit:
                    env["within"] += 1
                    env["notes"].append(f"{r['fixture']}: WITHIN (suff={su}, idea={'yes' if idea else 'null'})")
                else:
                    env["outside"] += 1
                    env["notes"].append(f"{r['fixture']}: OUTSIDE (suff={su}, idea={'yes' if idea else 'null'})")
                continue

            hr = fx["human_reference"]
            strict["n"] += 1
            if su == hr["sufficiency"]: strict["suff_ok"] += 1
            if su == "sufficient" and hr["sufficiency"] != "sufficient": strict["false_suff"] += 1
            if su == "insufficient" and hr["sufficiency"] != "insufficient": strict["false_insuff"] += 1
            if idea == hr["idea_should_exist"]: strict["idea_ok"] += 1
            if idea and not hr["idea_should_exist"]: strict["unnec"] += 1
            if not idea and hr["idea_should_exist"]: strict["missed"] += 1

        print(f"\n=== PRODUCTION GATE (Opus, original prompt, valid={valid}/15) ===")
        print(f"\n  STRICT FIXTURES (n={strict['n']}):")
        print(f"    suff_ok={strict['suff_ok']}/{strict['n']} idea_match={strict['idea_ok']}/{strict['n']} "
              f"false_suff={strict['false_suff']} false_insuff={strict['false_insuff']} "
              f"unnec={strict['unnec']} missed={strict['missed']}")
        print(f"    STRICT BASELINE (experiment, A excluded): false_suff=0 false_insuff=0 missed=0")
        print(f"\n  SEMANTIC-ENVELOPE FIXTURES (n={env['n']}):")
        print(f"    within_envelope={env['within']}/{env['n']} outside_envelope={env['outside']}/{env['n']}")
        for note in env["notes"]:
            print(f"      {note}")
        print(f"\n  validity={valid}/15  p50_latency={median(lat):.1f}s" if lat else "  no valid rows")
    print("wrote", out)


if __name__ == "__main__":
    main()
