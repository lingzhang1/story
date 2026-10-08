"""Self-test for the M-d.3 Edit Planner deterministic validator. No model calls.

Usage: TMPDIR=/tmp .venv/bin/python evals/edit_planner/test_validator.py
"""
from __future__ import annotations
import json, pathlib, sys
HERE = pathlib.Path(__file__).parent
sys.path[:0] = [str(HERE)]
import run_experiment as R

FIX = json.loads((HERE / "fixtures.json").read_text())["scenarios"]
sc = FIX["minimal_solitude"]  # 2 moments: m_window(11s, useful[1,9]), m_hands(8s, useful[0.5,6])


def plan(segs):
    return {"target_duration_seconds": sc["creative_intent"]["target_duration_seconds"], "segments": segs}


def seg(**kw):
    base = {"order": 0, "asset_id": "m_window", "source_start_seconds": 1.0, "source_end_seconds": 9.0,
            "output_duration_seconds": 9.0, "native_audio": "keep"}
    base.update(kw); return base


def check(name, p, scenario, expect_valid):
    errs = R.validate(p, scenario)
    ok = (not errs) == expect_valid
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: valid={not errs} errs={errs}")
    return ok


results = []
# valid baseline: source spans inside useful_segments, output consistent with span/speed, total within +/-20% of 18s.
# m_window useful [1,9] -> span 8.0 slowed to 0.8x -> 10.0s out; m_hands useful [0.5,6] -> span 5.5 @1.0 -> 5.5s out; total 15.5s (ok)
results.append(check("valid_baseline", plan([
    seg(order=0, asset_id="m_window", source_start_seconds=1.0, source_end_seconds=9.0, output_duration_seconds=10.0, speed=0.8),
    seg(order=1, asset_id="m_hands", source_start_seconds=0.5, source_end_seconds=6.0, output_duration_seconds=5.5),
]), sc, True))
# invalid asset id
results.append(check("invented_moment", plan([seg(asset_id="m_nope")]), sc, False))
# source end beyond moment duration (m_hands is 8s)
results.append(check("source_oob", plan([seg(asset_id="m_hands", source_start_seconds=1.0, source_end_seconds=20.0, output_duration_seconds=10.0)]), sc, False))
# totally outside useful_segments (m_window useful=[1,9]; pick [9.5,10.5] within 11s dur but outside useful)
results.append(check("outside_useful", plan([seg(asset_id="m_window", source_start_seconds=9.5, source_end_seconds=10.5, output_duration_seconds=1.0)]), sc, False))
# duration >20% off (target 18, give 30)
results.append(check("duration_off", plan([seg(output_duration_seconds=30.0)]), sc, False))
# non-monotonic order
results.append(check("bad_order", plan([seg(order=1), seg(order=0, asset_id="m_hands", source_start_seconds=0.5, source_end_seconds=6.0, output_duration_seconds=8.0)]), sc, False))
# missing native_audio
bad = seg(); del bad["native_audio"]
results.append(check("missing_native_audio", plan([bad]), sc, False))
# arm-A alignment anchor set without analysis -> invalid (sc has no music_analysis key in arm A view)
sc_noanalysis = {k: v for k, v in sc.items() if k != "music_analysis"}
results.append(check("anchor_without_analysis", plan([seg(music_alignment={"anchor": "downbeat"})]), sc_noanalysis, False))

print(f"\n{sum(results)}/{len(results)} validator self-tests passed")
sys.exit(0 if all(results) else 1)
