"""Director model-ceiling comparison (C3B experiment).

Runs the SAME 15-fixture corpus / prompt / contracts / guards through each model
given on the command line. Changes ONLY the model. Reports per-case
beats/shots/decision/latency/tokens and per-model aggregates (decision tallies,
mean beats/shots, latency p50/p90, mean tokens), plus the critical
narrative-grounding triad (A/B/C) and the min-capture low-value case called out
separately.

Usage: TMPDIR=/tmp .venv/bin/python evals/run_director_model_compare.py \
         amazon.nova-pro-v1:0 us.anthropic.claude-opus-4-5-20251101-v1:0
"""
from __future__ import annotations
import glob, json, statistics, sys, time
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
for rel in (".", "packages", "apps/api"):
    p = str((_ROOT / rel).resolve())
    if p not in sys.path: sys.path.insert(0, p)

from story_director import RealStoryDirectorEngine  # noqa: E402
from model_gateway import BedrockModelGateway, ProviderError, StructuredOutputError  # noqa: E402

TRIAD = {"dir_ng_A_tmb_home_relevant": "A relevant-ordinary",
         "dir_ng_B_tmb_musicroom_irrelevant": "B irrelevant-ordinary (rescan preferred)",
         "dir_ng_C_musicroom_relevant_intent": "C relevant-intent same room"}
MINCAP = "dir_mincap_longstory_lowvalue"


def run_one(eng, fx):
    inp = fx["inputs"]; phase = fx.get("phase", "initialize")
    t = time.time()
    if phase == "next":
        out = eng._to_output(eng._gateway.generate_structured(eng.build_next_request(inp.get("prior", inp))))
    else:
        req = eng.build_initialize_request(inp["creative_intent"], inp["scene_understanding"], inp.get("capture_constraints"))
        res = eng._gateway.generate_structured(req)
        out = eng._to_output(res)
        return out, int((time.time()-t)*1000), res.usage
    return out, int((time.time()-t)*1000), None


def run_model(model, files):
    eng = RealStoryDirectorEngine(BedrockModelGateway(model_id=model))
    cases, lats, toks, acts = {}, [], [], {}
    beats_t = shots_t = ok = fail = 0
    print(f"\n################ MODEL {model} ################")
    for f in files:
        fx = json.load(open(f)); fid = fx["id"]
        try:
            out, ms, usage = run_one(eng, fx)
            b, s, act = len(out.plan.beats), len(out.plan.shots), out.decision.action.value
            tok = (usage.total_tokens if usage and usage.total_tokens else
                   ((usage.input_tokens or 0)+(usage.output_tokens or 0)) if usage else None)
            cases[fid] = {"beats": b, "shots": s, "action": act, "ms": ms, "tokens": tok,
                          "concept": out.concept.title,
                          "rec": (out.decision.shot.instruction if out.decision.shot else None)}
            acts[act] = acts.get(act, 0)+1; beats_t += b; shots_t += s; ok += 1
            lats.append(ms)
            if tok: toks.append(tok)
            flag = "  <<<" if (fid in TRIAD or fid == MINCAP) else ""
            print(f"  {fid:38s} b={b} s={s} {act:12s} {ms:5d}ms tok={tok}{flag}")
        except (StructuredOutputError, ProviderError) as e:
            fail += 1; print(f"  {fid:38s} FAIL {type(e).__name__}: {str(e)[:60]}")
    n = ok or 1
    lats.sort()
    p50 = statistics.median(lats) if lats else 0
    p90 = lats[int(len(lats)*0.9)] if lats else 0
    agg = {"model": model, "ok": ok, "fail": fail, "mean_beats": round(beats_t/n,2),
           "mean_shots": round(shots_t/n,2), "actions": acts,
           "p50_ms": int(p50), "p90_ms": int(p90),
           "mean_tokens": int(statistics.mean(toks)) if toks else None, "cases": cases}
    print(f"  --- {model}: ok {ok} fail {fail} | mean beats {agg['mean_beats']} shots {agg['mean_shots']}"
          f" | decisions {acts} | lat p50 {agg['p50_ms']}ms p90 {agg['p90_ms']}ms | mean_tok {agg['mean_tokens']}")
    return agg


def main():
    models = sys.argv[1:] or ["amazon.nova-pro-v1:0", "us.anthropic.claude-opus-4-5-20251101-v1:0"]
    files = sorted(glob.glob(str(_ROOT / "evals/story_director/*.fixture.json")))
    results = [run_model(m, files) for m in models]
    print("\n================ TRIAD + MIN-CAP SIDE BY SIDE ================")
    for fid, name in list(TRIAD.items()) + [(MINCAP, "min-cap long+low-value")]:
        print(f"\n[{name}] {fid}")
        for r in results:
            c = r["cases"].get(fid)
            if c: print(f"  {r['model'][:34]:34s} b={c['beats']} s={c['shots']} {c['action']:12s} :: {c['concept'][:38]}")
            else: print(f"  {r['model'][:34]:34s} (failed)")
            if c and c.get("rec"): print(f"       rec: {c['rec'][:100]}")
    print("\nJSON " + json.dumps({"results": results}))


if __name__ == "__main__":
    main()
