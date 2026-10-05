"""C4L-A — local no-AI heuristic adoption harness.

Runs the integrity_signals extractor over labeled control groups and reports, per
candidate check (catastrophic_exposure / catastrophic_shake / catastrophic_focus),
the signal distribution for the FAILURE cluster vs the LEGITIMATE cluster, so a hard
gate is adopted ONLY if there is a clear threshold gap with zero/near-zero false
rejection of legitimate footage. Also scans the full corpus duration distribution.

No AI, no network. Decision logic lives here (inspectable), not in the extractor.
"""
from __future__ import annotations
import json, pathlib, subprocess, statistics, sys

REPO = pathlib.Path(__file__).resolve().parents[1]
V = REPO / "evals/assets/private_local/videos"
SRC = REPO / "evals/shot_validation/tools/integrity_signals.swift"
BIN = pathlib.Path("/tmp/integrity_signals")

def ensure():
    if BIN.exists(): return
    subprocess.run(["swiftc","-O",str(SRC),"-o",str(BIN)],capture_output=True,text=True)
    if not BIN.exists(): raise RuntimeError("build failed")

def sig(rel: str, k: int = 8) -> dict:
    r = subprocess.run([str(BIN), str(V/rel), str(k)], capture_output=True, text=True)
    line = next((l for l in r.stdout.splitlines() if l.strip().startswith("{")), None)
    if not line: raise RuntimeError(f"no signal for {rel}: {r.stderr[:200]}")
    return json.loads(line)

# ---- Labeled control groups (from T01 + legitimate footage across the corpus) ----
GROUPS = {
    # exposure
    "fail_underexposed": ["T01_technical_controls/T01_E_underexposed.mov"],
    "fail_overexposed":  ["T01_technical_controls/T01_F_overexposed.mov"],
    # shake
    "fail_severe_shake": ["T01_technical_controls/T01_D_severe_shake.mov"],
    "legit_moderate_shake": ["T01_technical_controls/T01_C_moderate_shake.mov"],
    # focus
    "fail_out_of_focus": ["T01_technical_controls/T01_G_out_of_focus.mov"],
    # clean / legitimate controls (must NOT be rejected by any gate)
    "clean": ["T01_technical_controls/T01_A_clean_4s.mov",
              "T01_technical_controls/T01_H_partial_occlusion.mov"],
    "legit_lowlight": ["S08_end_of_day/S08_A_quiet_window.MOV",
                       "S08_end_of_day/S08_B_quiet_stove.MOV",
                       "S08_end_of_day/S08_C_sleepy_person.MOV"],
    "legit_handheld_motion": ["S05_trail_progression/S05_A_follow_behind.MOV",
                              "S06_difficulty/S06_D_heavy_footsteps.MOV",
                              "S02_departure/S02_F_slightly_shaky_but_good.mov"],
}

def stats(xs):
    xs=[x for x in xs if x is not None]
    if not xs: return {}
    return {"n":len(xs),"min":round(min(xs),2),"med":round(statistics.median(xs),2),"max":round(max(xs),2)}

def main():
    ensure()
    # 1) full-corpus duration scan (every fixture via media-map)
    mm = json.loads((REPO/"evals/shot_validation/media-map.json").read_text())
    durs=[]
    for fid,rel in mm["fixtures"].items():
        s=sig(rel,1); durs.append(s["duration_s"])
    durs.sort()
    print("=== DURATION DISTRIBUTION (n=%d fixtures) ==="%len(durs))
    print(" min=%.2fs  p05=%.2fs  p10=%.2fs  p25=%.2fs  med=%.2fs  max=%.2fs"%(
        durs[0],durs[int(0.05*len(durs))],durs[int(0.10*len(durs))],
        durs[int(0.25*len(durs))],statistics.median(durs),durs[-1]))
    print(" clips under 1.0s:",[round(d,2) for d in durs if d<1.0])
    print(" clips 1.0-2.0s:",[round(d,2) for d in durs if 1.0<=d<2.0])

    # 2) signal groups
    sigs={}
    for grp,rels in GROUPS.items():
        rows=[sig(r) for r in rels]
        sigs[grp]=rows
    print("\n=== SIGNAL DISTRIBUTIONS BY GROUP ===")
    def show(grp,field):
        return stats([r.get(field) for r in sigs.get(grp,[])])
    for grp in GROUPS:
        rows=sigs[grp]
        print(f"\n[{grp}] n={len(rows)}")
        print("  mean_luma:",stats([r['mean_luma'] for r in rows]),
              " p_dark:",stats([r['p_dark'] for r in rows]),
              " p_bright:",stats([r['p_bright'] for r in rows]))
        print("  luma_shift_mean:",stats([r['luma_shift_mean'] for r in rows]),
              " luma_shift_max:",stats([r['luma_shift_max'] for r in rows]))
        print("  sharpness_median:",stats([r['sharpness_median'] for r in rows]),
              " sharpness_min:",stats([r['sharpness_min'] for r in rows]))

    # 3) separation verdicts
    print("\n=== SEPARATION (fail cluster vs legitimate cluster) ===")
    def vals(grp,f): return [r[f] for r in sigs.get(grp,[])]
    # EXPOSURE: p_dark of underexposed vs legit_lowlight+clean; p_bright of over vs clean
    dark_fail=vals("fail_underexposed","mean_luma"); dark_legit=vals("legit_lowlight","mean_luma")+vals("clean","mean_luma")
    print(" EXPOSURE under: fail mean_luma",stats(dark_fail)," vs legit-lowlight+clean",stats(dark_legit))
    bright_fail=vals("fail_overexposed","mean_luma"); bright_legit=vals("clean","mean_luma")+vals("legit_lowlight","mean_luma")
    print(" EXPOSURE over:  fail mean_luma",stats(bright_fail)," vs legit",stats(bright_legit))
    # SHAKE: luma_shift of severe vs moderate+legit handheld
    sh_fail=vals("fail_severe_shake","luma_shift_mean"); sh_legit=vals("legit_moderate_shake","luma_shift_mean")+vals("legit_handheld_motion","luma_shift_mean")
    print(" SHAKE: severe luma_shift_mean",stats(sh_fail)," vs moderate+handheld",stats(sh_legit))
    # FOCUS: sharpness of out_of_focus vs clean+lowlight+motion
    f_fail=vals("fail_out_of_focus","sharpness_median"); f_legit=vals("clean","sharpness_median")+vals("legit_lowlight","sharpness_median")+vals("legit_handheld_motion","sharpness_median")
    print(" FOCUS: out_of_focus sharpness_median",stats(f_fail)," vs clean+lowlight+motion",stats(f_legit))

    out=REPO/"evals/results/c4l_a_heuristics.json"
    out.write_text(json.dumps({"durations":durs,"groups":{g:[r for r in sigs[g]] for g in sigs}},indent=2))
    print("\nwrote",out)

if __name__=="__main__": main()
