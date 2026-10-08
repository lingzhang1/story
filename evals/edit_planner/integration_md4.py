"""M-d Batch 4 — integration validation (prototyping-only; NO rendering, NO export).

Proves the conceptual pipeline end to end with REAL provider data and the REAL Edit Planner engine:

  MusicPlan -> Epidemic search -> deterministic ranking -> selected track -> normalize to music_analysis/1
            -> Edit Planner (Opus 4.6, frozen edit_plan/2) -> executable EditPlan/2 (deterministic validator)

on the 5 frozen scenarios. Uses real Epidemic METADATA for ONE track per scenario (no downloads, no persisted
audio/metadata mirror). Requires STORY_EPIDEMIC_MODE=prototyping and the SM secret.

Usage: STORY_EPIDEMIC_MODE=prototyping TMPDIR=/tmp .venv/bin/python evals/edit_planner/integration_md4.py --run
Writes evals/results/edit_planner_md4_integration.json (derived facts only; no key, no audio, no raw metadata).
"""
from __future__ import annotations
import argparse, json, pathlib, sys, time
from uuid import uuid4

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO), str(REPO / "packages")]
RESULTS = REPO / "evals/results"
FIX = json.loads((pathlib.Path(__file__).parent / "fixtures.json").read_text())["scenarios"]

# map each scenario to an Epidemic search intent (mood term + vocal preference)
SEARCH = {
    "tmb_cinematic_60s": ("warm anticipatory cinematic build", "NONE"),
    "guitar_progression": ("warm intimate acoustic guitar", "NONE"),
    "sf_exploration": ("curious breezy upbeat city groove", "NONE"),
    "minimal_solitude": ("sparse calm ambient still", "NONE"),
    "energetic_shortform": ("high energy bold driving", "NONE"),
}


def uuidize_moments(moments):
    """Production contract needs UUID Moment ids; map the fixture's readable ids -> UUIDs."""
    out, idmap = [], {}
    for m in moments:
        nid = str(uuid4())
        idmap[m["id"]] = nid
        mm = dict(m); mm["id"] = nid
        out.append(mm)
    return out, idmap


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--run", action="store_true"); a = ap.parse_args()
    import music_provider as mp
    if not mp.prototyping_enabled():
        print("BLOCKED: set STORY_EPIDEMIC_MODE=prototyping to run the integration (provider half)."); return
    from model_gateway import BedrockModelGateway, StructuredOutputError, ProviderError
    from edit_planner import RealEditPlannerEngine, EditPlanInputs, EditPlanInfeasibleError, validate_plan

    client = mp.EpidemicClient()
    engine = RealEditPlannerEngine(BedrockModelGateway(model_id="us.anthropic.claude-opus-4-6-v1"))
    report = {"scenarios": {}}

    for name, sc in FIX.items():
        term, vocal = SEARCH[name]
        rec = {"search_term": term}
        # 1. REAL Epidemic search -> candidates
        raw = client.search(term, vocal_type=vocal, limit=5)
        cands = [mp.Candidate(track_id=t.get("id"), title=t.get("title", ""),
                              duration_seconds=float(t.get("length") or 0) or 1.0, bpm=(t.get("bpm") or None),
                              mood_tags=[(m.get("name") or m.get("id")) if isinstance(m, dict) else m
                                         for m in (t.get("moods") or [])],
                              vocal_type=t.get("vocalType")) for t in raw if t.get("id")]
        target = sc["creative_intent"]["target_duration_seconds"]
        ranked = mp.rank_candidates(sc["music_plan"], cands, target_duration=target)
        rec["n_candidates"] = len(ranked)
        if not ranked:
            rec["error"] = "no candidates"; report["scenarios"][name] = rec; continue
        top = ranked[0]
        rec["selected"] = {"title": top.title, "score": top.score, "factors": top.factors,
                           "duration_s": top.duration_seconds, "vocal": top.vocal_type}
        # 2. REAL metadata + beats + highlights + waveform -> normalize to music_analysis/1
        md = client.metadata(top.track_id)
        beats = client.beats(top.track_id)
        hi = client.highlights(top.track_id)
        wf = None
        if md.get("waveformUrl"):
            try:
                wf = client.waveform(md["waveformUrl"])
            except Exception:  # noqa
                wf = None
        analysis = mp.to_music_analysis_v1(
            duration_seconds=float(md.get("length") or top.duration_seconds), raw_bpm=md.get("bpm"),
            raw_beats=beats if isinstance(beats, list) else None, raw_highlights=hi, waveform=wf,
            vocal_type=md.get("vocalType"))
        rec["music_analysis"] = {"bpm": analysis.bpm, "tempo_reliable": analysis.tempo_reliable,
                                 "n_beats": len(analysis.beats), "n_downbeats": len(analysis.downbeats),
                                 "has_highlight": analysis.highlight_window is not None,
                                 "energy_pts": len(analysis.energy_curve), "vocal_type": analysis.vocal_type}
        # 3. Edit Planner with the REAL MusicAnalysis
        moments, _ = uuidize_moments(sc["moments"])
        inp = EditPlanInputs(
            story_id=str(uuid4()), creative_intent_id=str(uuid4()), creative_intent=sc["creative_intent"],
            story_guide=sc["story_guide"], story_coverage=sc["story_coverage"], moments=moments,
            music_plan=sc["music_plan"], music_asset_id=f"epidemic:{top.track_id}",
            music_analysis=analysis.model_dump(mode="json"))
        t0 = time.time()
        try:
            plan = engine.generate(inp)
            errs = validate_plan(json.loads(plan.model_dump_json())
                                 if False else {"segments": [s.model_dump(mode="json") for s in plan.segments],
                                                "feasible": plan.feasible,
                                                "infeasible_reason": plan.infeasible_reason}, inp)
            rec["edit_plan"] = {"ok": True, "latency_s": round(time.time()-t0, 2), "n_segments": len(plan.segments),
                                "total_out_s": round(sum(s.output_duration_seconds for s in plan.segments), 1),
                                "native_audio": [s.native_audio.value for s in plan.segments],
                                "anchors": [(s.music_alignment.anchor.value if s.music_alignment else None) for s in plan.segments],
                                "revalidate_errors": errs}
        except EditPlanInfeasibleError as e:
            rec["edit_plan"] = {"ok": True, "infeasible": True, "reason": str(e)}
        except (StructuredOutputError, ProviderError) as e:
            rec["edit_plan"] = {"ok": False, "error": str(e)[:200]}
        report["scenarios"][name] = rec
        ep = rec["edit_plan"]
        print(f"{name:20s} track='{top.title[:24]}' tempo_ok={analysis.tempo_reliable} "
              f"-> plan segs={ep.get('n_segments')} out={ep.get('total_out_s')}s anchors={ep.get('anchors')}")

    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "edit_planner_md4_integration.json").write_text(json.dumps(report, indent=2))
    print(f"\nwrote {RESULTS/'edit_planner_md4_integration.json'} (derived facts only)")


if __name__ == "__main__":
    main()
