"""Director corpus metrics — before/after a prompt iteration (C3B quality).

Runs every evals/story_director/*.fixture.json through the real engine (model
via arg) and records, per case: beats, shots, decision action, contrast_group.
Prints per-case lines + aggregate tallies (decision-action frequencies, mean
beats/shots) so a prompt change can be compared corpus-wide, never case-tuned.

Usage: TMPDIR=/tmp .venv/bin/python evals/run_director_corpus.py <model_id> [label]
"""
from __future__ import annotations
import glob, json, sys, time
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
for rel in (".", "packages", "apps/api"):
    p = str((_ROOT / rel).resolve())
    if p not in sys.path: sys.path.insert(0, p)

from story_director import RealStoryDirectorEngine  # noqa: E402
from model_gateway import BedrockModelGateway, ProviderError, StructuredOutputError  # noqa: E402


def run_case(eng, fx):
    inp = fx["inputs"]
    phase = fx.get("phase", "initialize")
    t = time.time()
    if phase == "next":
        out = eng.next(inp.get("prior", inp))
    else:
        out = eng.initialize(inp["creative_intent"], inp["scene_understanding"],
                             inp.get("capture_constraints"))
    return out, int((time.time() - t) * 1000)


def main():
    model = sys.argv[1] if len(sys.argv) > 1 else "amazon.nova-pro-v1:0"
    label = sys.argv[2] if len(sys.argv) > 2 else "run"
    eng = RealStoryDirectorEngine(BedrockModelGateway(model_id=model))
    files = sorted(glob.glob(str(_ROOT / "evals/story_director/*.fixture.json")))
    print(f"=== Director corpus [{label}] model={model}  ({len(files)} fixtures) ===")
    rows, actions, beats_t, shots_t, fails = [], {}, 0, 0, 0
    for f in files:
        fx = json.load(open(f))
        fid = fx["id"]
        try:
            out, ms = run_case(eng, fx)
            b, s, act = len(out.plan.beats), len(out.plan.shots), out.decision.action.value
            rows.append((fid, b, s, act, out.concept.title[:40], ms))
            actions[act] = actions.get(act, 0) + 1
            beats_t += b; shots_t += s
            print(f"  {fid:38s} beats={b} shots={s} {act:12s} {ms:5d}ms  {out.concept.title[:38]}")
        except (StructuredOutputError, ProviderError) as e:
            fails += 1
            print(f"  {fid:38s} FAIL {type(e).__name__}: {str(e)[:70]}")
    n = len(rows) or 1
    print(f"\n--- AGGREGATE [{label}] ---")
    print(f"  cases ok: {len(rows)}  fail: {fails}")
    print(f"  mean beats: {beats_t/n:.2f}  mean shots: {shots_t/n:.2f}")
    print(f"  decisions: {actions}")
    # JSON line for scripted before/after diff
    print("JSON " + json.dumps({"label": label, "ok": len(rows), "fail": fails,
          "mean_beats": round(beats_t/n,2), "mean_shots": round(shots_t/n,2),
          "actions": actions,
          "cases": {r[0]: {"beats": r[1], "shots": r[2], "action": r[3]} for r in rows}}))


if __name__ == "__main__":
    main()
