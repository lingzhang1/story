"""Edit Planner engine + endpoint + deterministic-validator tests (Milestone M-d, frozen edit_plan/2).

No real model is invoked — a FakeModelGateway returns preset plans. Exercises: a valid plan -> EditPlanV2Contract;
a non-executable plan -> rejected (never reaches the client); infeasible material -> structured failure; the
no-music path; and the endpoint's 200 / 503 / 422 behavior.
"""
from __future__ import annotations

import json
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.deps import get_edit_planner_engine
from app.main import create_app
from edit_planner import (
    EditPlanInputs,
    EditPlanInfeasibleError,
    MockEditPlannerEngine,
    RealEditPlannerEngine,
    validate_plan,
)
from model_gateway import FakeModelGateway, ProviderError, StructuredOutputError

M1 = str(uuid4())
M2 = str(uuid4())


def _inputs(music=False, **over):
    base = dict(
        story_id=str(uuid4()), creative_intent_id=str(uuid4()),
        creative_intent={"target_duration_seconds": 18.0, "desired_feeling": ["calm"]},
        story_guide={"framing_summary": "a quiet mood"},
        story_coverage={"sufficiency": "sufficient"},
        moments=[
            {"id": M1, "duration_seconds": 11.0, "useful_segments": [[1.0, 9.0]], "summary": "steam on a sill"},
            {"id": M2, "duration_seconds": 8.0, "useful_segments": [[0.5, 6.0]], "summary": "hands on mug"},
        ],
        music_plan={"character": {"mood_tags": ["calm"], "energy": "low"},
                    "audio_strategy": {"soundtrack_role": "sparse", "native_audio_priority": "selective"}},
    )
    if music:
        base["music_analysis"] = {"duration_seconds": 20.0, "bpm": 60.0, "beats": [0.0, 1.0], "downbeats": [0.0]}
        base["music_asset_id"] = "epidemic:track-abc"
    base.update(over)
    return EditPlanInputs(**base)


def _good_plan():
    return {"target_duration_seconds": 18.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 1.0, "source_end_seconds": 9.0,
         "output_duration_seconds": 10.0, "native_audio": "keep", "narrative_role": "opening stillness"},
        {"order": 1, "asset_id": M2, "source_start_seconds": 0.5, "source_end_seconds": 6.0,
         "output_duration_seconds": 5.5, "native_audio": "keep", "narrative_role": "intimate detail"},
    ]}


def test_engine_valid_plan_to_contract():
    eng = RealEditPlannerEngine(FakeModelGateway(response=_good_plan()))
    plan = eng.generate(_inputs())
    assert plan.schema_version == "edit_plan/2"
    assert len(plan.segments) == 2
    assert str(plan.segments[0].asset_id) == M1
    assert plan.segments[0].native_audio.value == "keep"


def test_engine_rejects_non_executable_plan_invented_moment():
    bad = _good_plan()
    bad["segments"][0]["asset_id"] = str(uuid4())  # not a known Moment
    eng = RealEditPlannerEngine(FakeModelGateway(response=bad))
    with pytest.raises(StructuredOutputError):  # validation failure -> never fabricate / never pass on
        eng.generate(_inputs())


def test_engine_rejects_anchor_without_analysis():
    bad = _good_plan()
    bad["segments"][0]["music_alignment"] = {"anchor": "downbeat"}
    eng = RealEditPlannerEngine(FakeModelGateway(response=bad))
    with pytest.raises(StructuredOutputError):
        eng.generate(_inputs(music=False))


def test_engine_infeasible_raises():
    plan = {"target_duration_seconds": 18.0, "feasible": False, "infeasible_reason": "not enough usable footage",
            "segments": [{"order": 0, "asset_id": M1, "source_start_seconds": 1.0, "source_end_seconds": 9.0,
                          "output_duration_seconds": 8.0, "native_audio": "keep"}]}
    eng = RealEditPlannerEngine(FakeModelGateway(response=plan))
    with pytest.raises(EditPlanInfeasibleError):
        eng.generate(_inputs())


def test_engine_no_music_planning_supported():
    eng = RealEditPlannerEngine(FakeModelGateway(response=_good_plan()))
    plan = eng.generate(_inputs(music=False))  # no music_analysis
    assert plan.music_asset_id is None and len(plan.segments) == 2


def test_engine_with_music_carries_provenance():
    p = _good_plan()
    p["segments"][0]["music_alignment"] = {"anchor": "highlight"}
    eng = RealEditPlannerEngine(FakeModelGateway(response=p))
    plan = eng.generate(_inputs(music=True))
    assert plan.music_asset_id == "epidemic:track-abc"
    assert plan.segments[0].music_alignment.anchor.value == "highlight"


def test_mock_engine_produces_valid_contract():
    plan = MockEditPlannerEngine().generate(_inputs())
    assert plan.schema_version == "edit_plan/2" and plan.segments


def test_validator_catches_speed_inconsistency():
    bad = _good_plan()
    bad["segments"][0]["speed"] = 2.0  # 8s span @2x should be ~4s, but output says 10s
    errs = validate_plan(bad, _inputs())
    assert any("inconsistent" in e for e in errs)


# ---- endpoint ----
def _client(engine):
    app = create_app()
    app.dependency_overrides[get_edit_planner_engine] = lambda: engine
    return TestClient(app)


def _req_body(music=False):
    i = _inputs(music=music)
    body = {
        "story_id": i.story_id, "creative_intent_id": i.creative_intent_id,
        "creative_intent": i.creative_intent, "story_guide": i.story_guide,
        "story_coverage": i.story_coverage, "moments": i.moments, "music_plan": i.music_plan,
    }
    if music:
        body["music_analysis"] = i.music_analysis
        body["music_asset_id"] = i.music_asset_id
    return body


def test_endpoint_success():
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    r = client.post("/v1/edit-plan", json=_req_body())
    assert r.status_code == 200, r.text
    assert r.json()["schema_version"] == "edit_plan/2"


def test_endpoint_503_on_provider_error():
    client = _client(RealEditPlannerEngine(FakeModelGateway(error=ProviderError("throttled"))))
    r = client.post("/v1/edit-plan", json=_req_body())
    assert r.status_code == 503


def test_endpoint_422_on_infeasible():
    plan = {"target_duration_seconds": 18.0, "feasible": False, "infeasible_reason": "insufficient footage",
            "segments": [{"order": 0, "asset_id": M1, "source_start_seconds": 1.0, "source_end_seconds": 9.0,
                          "output_duration_seconds": 8.0, "native_audio": "keep"}]}
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=plan)))
    r = client.post("/v1/edit-plan", json=_req_body())
    assert r.status_code == 422
    assert "infeasible" in r.json()["detail"].lower()


# ===========================================================================
# R-c executability-repair + deterministic normalization + error semantics.
# A SeqGateway returns a scripted sequence of plans so we can exercise the
# repair loop without a live model. No real model is invoked.
# ===========================================================================
from edit_planner import (  # noqa: E402
    MalformedPlanError, normalize_plan, timeline_total_seconds, validate_plan as _vp,
)
from model_gateway import StructuredResult, Usage  # noqa: E402


class SeqGateway:
    """Returns plans[0], plans[1], ... on successive calls (clamps at the last)."""
    def __init__(self, plans):
        self.plans = plans
        self.calls = 0

    def generate_structured(self, req):
        import json as _j
        p = self.plans[min(self.calls, len(self.plans) - 1)]
        self.calls += 1
        return StructuredResult(data=_j.loads(_j.dumps(p)), usage=Usage(100, 40, 140),
                                attempts=1, model="fake", provider="fake")


def _target12_inputs(**over):
    base = dict(
        story_id=str(uuid4()), creative_intent_id=str(uuid4()),
        creative_intent={"target_duration_seconds": 12.0},
        story_guide={}, story_coverage={},
        moments=[
            {"id": M1, "duration_seconds": 8.0, "useful_segments": [[0.0, 6.0]]},
            {"id": M2, "duration_seconds": 7.0, "useful_segments": [[0.0, 5.0]]},
        ],
        music_plan={})
    base.update(over)
    return EditPlanInputs(**base)


def _plan12(d0, d1, **seg_over):
    """Two-segment plan for the target-12 inputs; d0/d1 are output_duration_seconds."""
    s0 = {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 6.0,
          "output_duration_seconds": d0, "native_audio": "keep"}
    s1 = {"order": 1, "asset_id": M2, "source_start_seconds": 0.0, "source_end_seconds": 5.0,
          "output_duration_seconds": d1, "native_audio": "keep"}
    s0.update(seg_over.get("s0", {}))
    s1.update(seg_over.get("s1", {}))
    return {"target_duration_seconds": 12.0, "feasible": True, "segments": [s0, s1]}


# ---- reproduce the two exact production failures (validator level) ----
def test_asymmetric_duration_policy():
    # Asymmetric accept policy (owner 2026-10-13): generous overshoot (+50%), strict undershoot (-20%).
    inp = _target12_inputs(moments=_target12_inputs().moments + [
        {"id": "M3", "duration_seconds": 9.0, "useful_segments": [[0.0, 7.5]]}])
    def plan3(d0, d1, d2):
        return {"target_duration_seconds": 12.0, "feasible": True, "segments": [
            {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": d0,
             "output_duration_seconds": d0, "native_audio": "keep"},
            {"order": 1, "asset_id": M2, "source_start_seconds": 0.0, "source_end_seconds": d1,
             "output_duration_seconds": d1, "native_audio": "keep"},
            {"order": 2, "asset_id": "M3", "source_start_seconds": 0.0, "source_end_seconds": d2,
             "output_duration_seconds": d2, "native_audio": "keep"}]}
    # 15s vs 12 target = +25% overshoot -> now ACCEPTED (was rejected under old ±20%). Give the user a video.
    assert _vp(plan3(5.0, 5.0, 5.0), inp) == []
    # 18s vs 12 = +50% exactly -> still accepted (at the bound).
    assert _vp(plan3(6.0, 6.0, 6.0), inp) == []
    # 20s vs 12 = +67% overshoot -> rejected (beyond the generous upper bound).
    assert any("upper bound" in e for e in _vp(plan3(7.0, 7.0, 6.0), inp))
    # 8s vs 12 = -33% undershoot -> rejected (too short feels broken/empty).
    inp2 = _target12_inputs()
    short = {"target_duration_seconds": 12.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 4.0,
         "output_duration_seconds": 4.0, "native_audio": "keep"},
        {"order": 1, "asset_id": M2, "source_start_seconds": 0.0, "source_end_seconds": 4.0,
         "output_duration_seconds": 4.0, "native_audio": "keep"}]}
    assert any("lower bound" in e or "SHORT" in e for e in _vp(short, inp2))


def test_repro_failure2_speed_output_mismatch():
    # seg source span 7.5 @1.0x but output 2.5 — the second device failure.
    inp = _target12_inputs(moments=[{"id": M1, "duration_seconds": 9.0, "useful_segments": [[0.0, 7.5]]}])
    p = {"target_duration_seconds": 12.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 7.5,
         "output_duration_seconds": 2.5, "speed": 1.0, "native_audio": "keep"}]}
    errs = _vp(p, inp)
    assert any("inconsistent" in e for e in errs)


# ---- deterministic normalization: safe rounding only ----
def test_normalize_snaps_harmless_rounding():
    inp = _target12_inputs()
    # 6.03 for a 6.0 span @1.0 is within the snap window -> snapped to 6.0, no model needed.
    p = _plan12(6.03, 6.0)
    out, notes = normalize_plan(p, inp)
    assert out["segments"][0]["output_duration_seconds"] == 6.0
    assert notes and "snapped" in notes[0]
    assert not _vp(out, inp)  # now executable


def test_normalize_does_not_touch_large_mismatch():
    inp = _target12_inputs(moments=[{"id": M1, "duration_seconds": 9.0, "useful_segments": [[0.0, 7.5]]}])
    p = {"target_duration_seconds": 12.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 7.5,
         "output_duration_seconds": 2.5, "speed": 1.0, "native_audio": "keep"}]}
    out, notes = normalize_plan(p, inp)
    assert notes == []  # a 7.5->2.5 mismatch is NOT auto-corrected
    assert out["segments"][0]["output_duration_seconds"] == 2.5
    assert _vp(out, inp)  # still invalid -> must go to model repair


def test_normalize_never_changes_speed_or_range():
    inp = _target12_inputs()
    p = _plan12(6.03, 6.0, s0={"speed": 1.0})
    out, _ = normalize_plan(p, inp)
    s = out["segments"][0]
    assert s["source_start_seconds"] == 0.0 and s["source_end_seconds"] == 6.0 and s["speed"] == 1.0


# ---- the executability-repair loop ----
def test_valid_plan_accepted_without_repair():
    inp = _target12_inputs()
    eng = RealEditPlannerEngine(SeqGateway([_plan12(6.0, 6.0)]))
    plan = eng.generate(inp)
    assert len(plan.segments) == 2
    assert eng.last_diagnostics["first_pass_executable"] is True
    assert eng.last_diagnostics["model_calls"] == 1
    assert eng.last_diagnostics["repaired"] is False


def test_invalid_plan_repaired_successfully():
    inp = _target12_inputs()
    bad = _plan12(5.0, 5.0)         # 10s... actually within tol; make it clearly off:
    bad = _plan12(2.0, 2.0)         # 4s total vs 12 (>20% low) -> invalid
    good = _plan12(6.0, 6.0)        # 12s -> valid
    eng = RealEditPlannerEngine(SeqGateway([bad, good]))
    plan = eng.generate(inp)
    assert len(plan.segments) == 2
    assert eng.last_diagnostics["first_pass_executable"] is False
    assert eng.last_diagnostics["executability_repairs_used"] == 1
    assert eng.last_diagnostics["model_calls"] == 2
    assert eng.last_diagnostics["final"] == "executable"


def test_repair_still_invalid_raises_structured_failure():
    inp = _target12_inputs()
    bad = _plan12(2.0, 2.0)
    eng = RealEditPlannerEngine(SeqGateway([bad, bad]))
    with pytest.raises(StructuredOutputError):
        eng.generate(inp)
    assert eng.last_diagnostics["final"] == "invalid_after_repair"
    assert eng.last_diagnostics["model_calls"] == 2  # one initial + one repair, bounded


def test_repair_bounded_no_duplicate_loops():
    inp = _target12_inputs()
    eng = RealEditPlannerEngine(SeqGateway([_plan12(2.0, 2.0), _plan12(2.0, 2.0), _plan12(6.0, 6.0)]))
    with pytest.raises(StructuredOutputError):
        eng.generate(inp)
    # exactly 1 initial + 1 repair; never consumes the 3rd scripted plan.
    assert eng.last_diagnostics["model_calls"] == 2


def test_repair_preserves_no_invented_moments():
    inp = _target12_inputs()
    bad = _plan12(6.0, 6.0, s0={"asset_id": str(uuid4())})  # invented id
    eng = RealEditPlannerEngine(SeqGateway([bad, bad]))
    with pytest.raises(StructuredOutputError):
        eng.generate(inp)  # invented moment never passes


# ---- duration accounting with dissolves (crossfade overlap) ----
def test_total_accounts_for_crossfade_overlap():
    segs = [
        {"output_duration_seconds": 6.0},
        {"output_duration_seconds": 6.0, "transition": {"type": "crossfade", "duration_seconds": 0.3}},
    ]
    # raw 12.0 minus 0.3 overlap = 11.7
    assert abs(timeline_total_seconds(segs) - 11.7) < 1e-9
    # fade_in does NOT shorten the timeline
    segs2 = [{"output_duration_seconds": 6.0, "transition": {"type": "fade_in", "duration_seconds": 0.3}}]
    assert abs(timeline_total_seconds(segs2) - 6.0) < 1e-9


def test_crossfade_plan_within_tolerance_valid():
    inp = _target12_inputs()
    # 6.6 + 6.6 - 0.6 overlap = 12.6 (within 20% of 12) and each output == span -> executable
    p = _plan12(6.6, 6.6,
                s0={"source_end_seconds": 6.0, "source_start_seconds": 0.0},
                s1={"source_end_seconds": 5.0, "source_start_seconds": 0.0,
                    "transition": {"type": "crossfade", "duration_seconds": 0.6}})
    # make outputs match spans exactly to isolate the total check
    p["segments"][0]["output_duration_seconds"] = 6.0
    p["segments"][1]["output_duration_seconds"] = 6.0
    errs = _vp(p, inp)
    assert not any("off target" in e for e in errs)


# ---- native-audio + music-alignment semantics unchanged ----
def test_native_audio_semantics_unchanged():
    inp = _target12_inputs()
    for na in ("keep", "duck", "mute"):
        p = _plan12(6.0, 6.0, s0={"native_audio": na})
        assert not any("native_audio" in e for e in _vp(p, inp))
    bad = _plan12(6.0, 6.0, s0={"native_audio": "loud"})
    assert any("native_audio" in e for e in _vp(bad, inp))


def test_music_alignment_without_analysis_still_rejected():
    inp = _target12_inputs()
    p = _plan12(6.0, 6.0, s0={"music_alignment": {"anchor": "downbeat"}})
    assert any("music_alignment" in e for e in _vp(p, inp))


# ---- malformed useful_segments -> clean 422 at the endpoint (no 500) ----
def test_endpoint_422_on_malformed_useful_segments():
    client = _client(RealEditPlannerEngine(SeqGateway([_plan12(6.0, 6.0)])))
    body = _req_body()
    # dict-shaped junk that the OLD validator crashed on (KeyError -> 500)
    body["moments"][0]["useful_segments"] = ["garbage"]
    r = client.post("/v1/edit-plan", json=body)
    assert r.status_code == 422, r.text
    assert "malformed" in r.json()["detail"].lower()


def test_endpoint_dict_useful_segments_tolerated():
    client = _client(RealEditPlannerEngine(SeqGateway([_plan12(6.0, 6.0)])))
    i = _target12_inputs()
    body = {"story_id": i.story_id, "creative_intent_id": i.creative_intent_id,
            "creative_intent": i.creative_intent, "story_guide": i.story_guide,
            "story_coverage": i.story_coverage,
            "moments": [dict(m) for m in i.moments], "music_plan": i.music_plan}
    body["moments"][0]["useful_segments"] = [{"start": 0.0, "end": 6.0}]  # dict shape read defensively
    r = client.post("/v1/edit-plan", json=body)
    assert r.status_code == 200, r.text


def test_endpoint_503_distinct_from_malformed_and_infeasible():
    # model-invalid-after-repair -> 503 with the executability detail, not the generic outage text.
    inp_bad = _plan12(2.0, 2.0)
    client = _client(RealEditPlannerEngine(SeqGateway([inp_bad, inp_bad])))
    r = client.post("/v1/edit-plan", json=_req_body())
    assert r.status_code == 503
    assert "executable" in r.json()["detail"].lower()


def test_feasible_false_empty_segments_surfaces_infeasible_not_no_segments():
    """R-d.2 fix: a model that honestly declares feasible=false with a reason + empty segments must raise
    EditPlanInfeasibleError (surfacing the reason), NOT be mislabeled 'no segments' -> StructuredOutputError.
    This was the real cause of crowded-library ('21 Moments') failures showing a false 'temporarily unavailable'."""
    import sys, pathlib
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "packages"))
    from edit_planner import (EditPlanInputs, RealEditPlannerEngine, validate_plan,
                              EditPlanInfeasibleError)
    from model_gateway import FakeModelGateway, StructuredOutputError
    inp = EditPlanInputs(story_id="x", creative_intent_id="x",
                         creative_intent={"target_duration_seconds": 55.0}, story_guide={}, story_coverage={},
                         moments=[{"id": "a", "duration_seconds": 5, "useful_segments": [[0, 4]]}], music_plan={})
    plan = {"target_duration_seconds": 55.0, "segments": [], "feasible": False,
            "infeasible_reason": "too many Moments for this length"}
    assert validate_plan(plan, inp) == []            # no longer flagged 'no segments'
    eng = RealEditPlannerEngine(FakeModelGateway(response=plan), executability_repair_attempts=2)
    try:
        eng.generate(inp)
        assert False, "should raise infeasible"
    except EditPlanInfeasibleError as e:
        assert "too many Moments" in str(e)          # the real reason is surfaced
    except StructuredOutputError:
        assert False, "regressed: feasible=false mislabeled as no-segments"


def test_empty_segments_without_feasible_false_still_fails():
    """A truly empty plan (no feasible=false declaration) is STILL a 'no segments' error — the fix is narrow."""
    import sys, pathlib
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "packages"))
    from edit_planner import EditPlanInputs, validate_plan
    inp = EditPlanInputs(story_id="x", creative_intent_id="x",
                         creative_intent={"target_duration_seconds": 55.0}, story_guide={}, story_coverage={},
                         moments=[{"id": "a", "duration_seconds": 5, "useful_segments": [[0, 4]]}], music_plan={})
    assert "no segments" in validate_plan({"target_duration_seconds": 55.0, "segments": []}, inp)


def _infeasible_engine(reason="too many Moments for 55s"):
    from edit_planner import EditPlanInfeasibleError
    class E:
        last_diagnostics = {"model_calls": 3}
        def generate(self, inputs): raise EditPlanInfeasibleError(reason)
    return E()


def test_endpoint_material_insufficient_maps_422():
    """coverage < target -> genuine material infeasibility -> 422 (shorter-Story recovery is appropriate)."""
    from fastapi.testclient import TestClient
    from app.main import create_app
    from app.deps import get_edit_planner_engine
    app = create_app(); app.dependency_overrides[get_edit_planner_engine] = lambda: _infeasible_engine()
    c = TestClient(app)
    body = {"story_id": "00000000-0000-0000-0000-000000000001",
            "creative_intent_id": "00000000-0000-0000-0000-000000000002",
            "creative_intent": {"target_duration_seconds": 55.0},
            "moments": [{"id": "m1", "duration_seconds": 10, "useful_segments": [[0, 8]]}]}  # 8s << 55s
    r = c.post("/v1/edit-plan", json=body)
    assert r.status_code == 422 and "material" in r.json()["detail"]


def test_endpoint_sufficient_material_but_model_refused_maps_503_not_shorter():
    """coverage >= target but model declared infeasible = PLANNING DEFECT -> 503 (NOT a 422 shorter-Story)."""
    from fastapi.testclient import TestClient
    from app.main import create_app
    from app.deps import get_edit_planner_engine
    app = create_app(); app.dependency_overrides[get_edit_planner_engine] = lambda: _infeasible_engine()
    c = TestClient(app)
    # 21 short Moments, ~5s useful each = ~105s coverage >> 55s target: material is plenty.
    moms = [{"id": f"m{i}", "duration_seconds": 7, "useful_segments": [[0, 5]]} for i in range(21)]
    body = {"story_id": "00000000-0000-0000-0000-000000000001",
            "creative_intent_id": "00000000-0000-0000-0000-000000000002",
            "creative_intent": {"target_duration_seconds": 55.0}, "moments": moms}
    r = c.post("/v1/edit-plan", json=body)
    assert r.status_code == 503          # NOT 422 -> client won't be told to shorten a Story with ample footage
    assert "material" not in r.json()["detail"]


# ---- truncation escalation: stop_reason=max_tokens -> retry at the higher cap, then succeed ----
class _TruncThenOkGateway:
    """First call returns a truncated EMPTY plan (stop_reason=max_tokens); the escalated retry returns a
    valid plan. Records the max_tokens each call was issued with so we can assert the escalation happened."""
    def __init__(self, good_plan):
        self.good = good_plan
        self.caps_seen = []
        self.n = 0

    def generate_structured(self, req):
        import json as _j
        self.caps_seen.append(req.max_tokens)
        self.n += 1
        if self.n == 1:
            # truncated: feasible but empty segments, stopped at the cap
            return StructuredResult(data={"target_duration_seconds": 12.0, "feasible": True, "segments": []},
                                    usage=Usage(100, req.max_tokens, 100 + req.max_tokens),
                                    attempts=1, model="fake", provider="fake", stop_reason="max_tokens")
        return StructuredResult(data=_j.loads(_j.dumps(self.good)), usage=Usage(100, 300, 400),
                                attempts=1, model="fake", provider="fake", stop_reason="end_turn")


def test_truncation_escalates_max_tokens_and_recovers():
    gw = _TruncThenOkGateway(_plan12(6.0, 6.0))
    eng = RealEditPlannerEngine(gw, max_tokens=2600, max_tokens_ceiling=16384)
    plan = eng.generate(_target12_inputs())
    assert len(plan.segments) == 2                      # recovered a valid plan
    assert gw.caps_seen[0] == 2600                       # first try at base cap
    assert gw.caps_seen[1] == 16384                      # escalated retry at the ceiling
    assert eng.last_diagnostics.get("truncation_escalations", 0) >= 1


def test_no_escalation_when_not_truncated():
    # a clean first result must NOT trigger a second (escalated) call
    gw = _TruncThenOkGateway(_plan12(6.0, 6.0)); gw.n = 1  # force "already past the truncation branch"
    gw2 = SeqGateway([_plan12(6.0, 6.0)])
    eng = RealEditPlannerEngine(gw2, max_tokens=8192, max_tokens_ceiling=16384)
    eng.generate(_target12_inputs())
    assert gw2.calls == 1                                # exactly one call, no escalation


# ===========================================================================
# MVP Multimodal Edit Planner — contact sheets + versioned creative brief.
# The frozen v5.2 SYSTEM body is never touched; images + brief ride the USER
# message / StructuredRequest.images. Text-only path stays byte-identical.
# ===========================================================================
from model_gateway import ImageInput  # noqa: E402


def test_engine_attaches_images_and_brief_to_request():
    gw = FakeModelGateway(response=_good_plan())
    eng = RealEditPlannerEngine(gw)
    inp = _inputs(images=[ImageInput(data=b"JPEGBYTES")],
                  creative_brief="Prioritize visually engaging footage.",
                  image_moment_order=[M1])
    eng.generate(inp)
    req = gw.calls[-1]
    assert len(req.images) == 1 and req.images[0].data == b"JPEGBYTES"
    assert "=== CREATIVE DIRECTION ===" in req.user_content
    assert "Prioritize visually engaging footage." in req.user_content
    assert f"in this order: {M1}" in req.user_content


def test_engine_text_only_request_has_no_images_or_brief():
    gw = FakeModelGateway(response=_good_plan())
    RealEditPlannerEngine(gw).generate(_inputs())  # no images / brief
    req = gw.calls[-1]
    assert req.images == []
    assert "CREATIVE DIRECTION" not in req.user_content
    assert "Contact-sheet images" not in req.user_content


def _mm_parts(music=False, moment_ids=None, brief=None):
    body = _req_body(music=music)
    ids = moment_ids if moment_ids is not None else [m["id"] for m in body["moments"][:1]]
    data = {"body": json.dumps(body), "sheet_order": json.dumps(ids)}
    if brief is not None:
        data["brief"] = brief
    return body, ids, data


def test_endpoint_mm_success_with_sheets():
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body, ids, data = _mm_parts()
    if "brief" in data:  # creative_brief is a separate form field named creative_brief
        data["creative_brief"] = data.pop("brief")
    files = [("sheets", (f"{mid}.jpg", b"\xff\xd8\xff" + b"x" * 50, "image/jpeg")) for mid in ids]
    r = client.post("/v1/edit-plan-mm", data=data, files=files)
    assert r.status_code == 200, r.text
    assert r.json()["schema_version"] == "edit_plan/2"


def test_endpoint_mm_text_only_fallback_no_sheets():
    # No sheets attached => the SAME frozen planning path, 200 (graceful text-only).
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body = _req_body()
    r = client.post("/v1/edit-plan-mm",
                    data={"body": json.dumps(body), "sheet_order": json.dumps([])})
    assert r.status_code == 200, r.text


def test_endpoint_mm_rejects_sheet_for_unknown_moment():
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body = _req_body()
    bad_id = str(uuid4())
    files = [("sheets", (f"{bad_id}.jpg", b"\xff\xd8\xffxx", "image/jpeg"))]
    r = client.post("/v1/edit-plan-mm",
                    data={"body": json.dumps(body), "sheet_order": json.dumps([bad_id])},
                    files=files)
    assert r.status_code == 422
    assert "unknown Moment id" in r.json()["detail"]


def test_endpoint_mm_rejects_order_count_mismatch():
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body = _req_body()
    files = [("sheets", (f"{M1}.jpg", b"\xff\xd8\xffxx", "image/jpeg"))]
    r = client.post("/v1/edit-plan-mm",
                    data={"body": json.dumps(body), "sheet_order": json.dumps([M1, M2])},  # 2 ids, 1 sheet
                    files=files)
    assert r.status_code == 422


# ---- 422 DIAGNOSTICS: every multimodal rejection logs edit_plan_mm_rejected with a stable reject_reason ----
# so a device fallback is never a silent mystery — the next device run's CloudWatch names the exact branch.
def test_mm_rejection_logs_reason_unknown_moment(caplog):
    import logging
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body = _req_body()
    bad_id = str(uuid4())
    files = [("sheets", (f"{bad_id}.jpg", b"\xff\xd8\xffxx", "image/jpeg"))]
    with caplog.at_level(logging.WARNING):
        r = client.post("/v1/edit-plan-mm",
                        data={"body": json.dumps(body), "sheet_order": json.dumps([bad_id])},
                        files=files)
    assert r.status_code == 422
    rec = next((x for x in caplog.records if getattr(x, "message", "") == "edit_plan_mm_rejected"
                or x.getMessage() == "edit_plan_mm_rejected"), None)
    assert rec is not None, "expected an edit_plan_mm_rejected diagnostic log"
    assert getattr(rec, "reject_reason", None) == "unknown_moment_id"
    assert getattr(rec, "http_status", None) == 422
    assert getattr(rec, "sheet_part_count", None) == 1
    assert getattr(rec, "sheet_order_len", None) == 1
    # The verbatim detail is logged (truncated) so the client-facing reason is reconstructable from the log.
    assert "unknown Moment id" in getattr(rec, "detail", "")
    # A sample of KNOWN ids is logged (never the images) so an id-mismatch is diagnosable from the log alone.
    assert isinstance(getattr(rec, "known_ids_sample", None), list)


def test_mm_rejection_logs_reason_count_mismatch(caplog):
    import logging
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body = _req_body()
    files = [("sheets", (f"{M1}.jpg", b"\xff\xd8\xffxx", "image/jpeg"))]
    with caplog.at_level(logging.WARNING):
        r = client.post("/v1/edit-plan-mm",
                        data={"body": json.dumps(body), "sheet_order": json.dumps([M1, M2])},
                        files=files)
    assert r.status_code == 422
    rec = next((x for x in caplog.records if x.getMessage() == "edit_plan_mm_rejected"), None)
    assert rec is not None
    assert getattr(rec, "reject_reason", None) == "order_sheet_count_mismatch"
    assert getattr(rec, "sheet_part_count", None) == 1
    assert getattr(rec, "sheet_order_len", None) == 2


# ---- Phase-6 / Arm D: bounded critique -> revision pass (flag-gated) --------------------------------------
def _crit(text="hook is weak; lead with M2's expressive moment"):
    return {"critique": text}


def test_critique_applied_when_revision_valid():
    # plan -> critique -> VALID revised plan: the revision is adopted (final plan = revised).
    orig = _plan12(6.0, 6.0)
    revised = _plan12(6.0, 6.0, )  # structurally valid, different enough to represent a revision
    revised = json.loads(json.dumps(revised)); revised["segments"][0]["source_start_seconds"] = 0.0
    eng = RealEditPlannerEngine(SeqGateway([orig, _crit(), revised]))
    inp = _target12_inputs(creative_brief="Make a punchy short-form edit.", critique_revision=True)
    plan = eng.generate(inp)
    d = eng.last_diagnostics
    assert d.get("critique_attempted") is True
    assert d.get("critique_applied") is True
    assert d.get("model_calls") == 3   # plan + critique + revise
    assert plan.feasible


def test_critique_retains_original_when_revision_invalid():
    # plan (valid) -> critique -> INVALID revised plan: keep the original valid plan, never fail the Story.
    orig = _plan12(6.0, 6.0)
    bad_rev = _plan12(6.0, 6.0); bad_rev = json.loads(json.dumps(bad_rev))
    bad_rev["segments"][0]["output_duration_seconds"] = 99.0   # breaks duration-consistency -> invalid
    eng = RealEditPlannerEngine(SeqGateway([orig, _crit(), bad_rev]))
    inp = _target12_inputs(creative_brief="brief", critique_revision=True)
    plan = eng.generate(inp)                 # must still succeed (original retained)
    d = eng.last_diagnostics
    assert d.get("critique_applied") is False
    assert d.get("critique_rejected_reason") == "revision_invalid"
    assert plan.feasible


def test_critique_skipped_without_brief():
    # critique requires a brief to critique against; no brief => no critique pass (single model call).
    eng = RealEditPlannerEngine(SeqGateway([_plan12(6.0, 6.0)]))
    inp = _target12_inputs(critique_revision=True)   # brief omitted
    eng.generate(inp)
    d = eng.last_diagnostics
    assert d.get("critique_attempted") in (None, False)
    assert d.get("model_calls") == 1


def test_critique_off_by_default():
    # flag not set => never attempts a critique even with a brief.
    eng = RealEditPlannerEngine(SeqGateway([_plan12(6.0, 6.0)]))
    inp = _target12_inputs(creative_brief="brief")   # critique_revision defaults False
    eng.generate(inp)
    assert eng.last_diagnostics.get("critique_attempted") in (None, False)
    assert eng.last_diagnostics.get("model_calls") == 1


# ---------------------------------------------------------------------------
# Creative Revision Foundation — revision_context (additive; USER-message only).
# ---------------------------------------------------------------------------
from edit_planner import _build_user, _revision_context_block, diversity_diagnostics  # noqa: E402


def test_revision_context_absent_user_message_unchanged():
    """When revision_context is None, the USER message carries NO version-context block (behavior unchanged)."""
    msg = _build_user(_inputs())
    assert "VERSION CONTEXT" not in msg


def test_revision_context_explore_injects_objective_and_summaries():
    ctx = {"mode": "explore", "base_version_id": "v-parent",
           "prior_edit_summaries": [{"version_id": "v-parent", "segments": [{"asset_id": M1}, {"asset_id": M2}]}]}
    msg = _build_user(_inputs(revision_context=ctx))
    assert "=== VERSION CONTEXT ===" in msg
    assert "base_version_id: v-parent" in msg
    assert "MEANINGFULLY DIFFERENT" in msg          # explicit alternative-edit objective
    assert "v-parent" in msg                         # the prior summary is present
    # frozen system body is untouched: the block lives only in the user message
    assert "VERSION CONTEXT" not in RealEditPlannerEngine(FakeModelGateway(response=_good_plan()))._system


def test_revision_context_history_is_bounded():
    many = [{"version_id": f"v{i}", "segments": [{"asset_id": M1}]} for i in range(10)]
    block = _revision_context_block({"mode": "explore", "prior_edit_summaries": many})
    # bounded to <= 4 summaries injected (defense-in-depth)
    assert block.count('"version_id"') <= 4


def test_revision_context_revise_carries_directives_and_soft():
    ctx = {"mode": "revise", "base_version_id": "v1",
           "soft_direction": "more cinematic",
           "directives": {"must_include": [M1], "exclude": [], "opening": M2}}
    block = _revision_context_block(ctx)
    assert "REVISE INTENT (soft): more cinematic" in block
    assert "HARD REQUIREMENT" in block
    assert f"MUST include a segment from each of these Moment ids: {M1}" in block
    assert f"the FIRST segment (order 0) MUST be Moment id {M2}" in block
    assert "PRESERVE unaffected edits" in block


def test_diversity_diagnostics_identical_is_near_identical():
    parent = {"segments": [{"asset_id": M1}, {"asset_id": M2}]}
    new = {"segments": [{"asset_id": M1}, {"asset_id": M2}]}
    d = diversity_diagnostics(parent, new)
    assert d["moment_set_jaccard"] == 1.0
    assert d["near_identical"] is True
    assert d["opening_changed"] is False and d["order_changed"] is False


def test_diversity_diagnostics_reordered_detected():
    parent = {"segments": [{"asset_id": M1}, {"asset_id": M2}]}
    new = {"segments": [{"asset_id": M2}, {"asset_id": M1}]}   # same set, swapped opening/ending/order
    d = diversity_diagnostics(parent, new)
    assert d["moment_set_jaccard"] == 1.0
    assert d["opening_changed"] is True
    assert d["ending_changed"] is True
    assert d["order_changed"] is True
    assert d["near_identical"] is False


def test_diversity_diagnostics_different_set():
    M3 = str(uuid4())
    parent = {"segments": [{"asset_id": M1}, {"asset_id": M2}]}
    new = {"segments": [{"asset_id": M1}, {"asset_id": M3}]}
    d = diversity_diagnostics(parent, new)
    assert 0.0 < d["moment_set_jaccard"] < 1.0
    assert d["near_identical"] is False


def test_revision_context_in_request_fingerprint():
    """revision_context lives in the request body, so the canonical async fingerprint (body-hashed) already
    covers it — a changed revision_context => different fingerprint, with NO fingerprint-logic change."""
    from edit_plan_jobs import payload_fingerprint
    body_a = json.dumps({"story_id": "s", "revision_context": {"mode": "explore", "base_version_id": "v1"}})
    body_b = json.dumps({"story_id": "s", "revision_context": {"mode": "explore", "base_version_id": "v2"}})
    fp_a = payload_fingerprint(body_a, [], False, "storytelling", creative_brief=None, sheet_digests=[])
    fp_b = payload_fingerprint(body_b, [], False, "storytelling", creative_brief=None, sheet_digests=[])
    assert fp_a != fp_b
    # identical body => identical fingerprint (transport recovery resumes the same job)
    fp_a2 = payload_fingerprint(body_a, [], False, "storytelling", creative_brief=None, sheet_digests=[])
    assert fp_a == fp_a2


# ---------------------------------------------------------------------------
# P0 — EditPlan renderer capability: speed must be 0.5x–2.0x (MediaEngineV1 limit).
# Reject (not clamp) unsupported speeds so bounded repair can pick an executable alternative.
# ---------------------------------------------------------------------------
def _speed_plan(speed):
    """A single-segment plan whose output_duration is CONSISTENT with (span / speed), so the ONLY
    thing a validator can object to is the speed value itself — isolating the renderer-range gate."""
    span = 8.0  # M1 source [1,9]
    out = round(span / speed, 3) if (isinstance(speed, (int, float)) and speed and speed > 0) else 8.0
    return {"target_duration_seconds": 18.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 1.0, "source_end_seconds": 9.0,
         "speed": speed, "output_duration_seconds": out, "native_audio": "keep"},
    ]}


def _speed_errs(plan):
    return [e for e in validate_plan(plan, _inputs()) if "speed" in e]


def test_speed_0_5_accepted():
    assert _speed_errs(_speed_plan(0.5)) == []


def test_speed_1_0_accepted():
    assert _speed_errs(_speed_plan(1.0)) == []


def test_speed_2_0_accepted():
    assert _speed_errs(_speed_plan(2.0)) == []


def test_speed_0_49_rejected():
    errs = _speed_errs(_speed_plan(0.49))
    assert any("out of renderer-supported range" in e for e in errs)


def test_speed_4_0_rejected():
    # The exact hiking failure: 4.0x passes the schema (speed>0) but is unrenderable.
    errs = _speed_errs(_speed_plan(4.0))
    assert any("out of renderer-supported range" in e and "[0.5, 2.0]" in e for e in errs)


def test_speed_non_finite_rejected():
    for bad in (float("inf"), float("nan"), "fast"):
        errs = _speed_errs(_speed_plan(bad))
        assert any("finite number" in e for e in errs), f"did not reject speed={bad!r}"


def test_absent_speed_defaults_to_1x_accepted():
    # An omitted speed is the schema default (1.0) and must stay valid — no regression.
    plan = _speed_plan(1.0)
    plan["segments"][0].pop("speed")
    assert _speed_errs(plan) == []


def test_existing_valid_plans_unchanged():
    # The canonical good plan (no explicit speed) still passes the FULL validator unchanged.
    assert validate_plan(_good_plan(), _inputs()) == []


# ---------------------------------------------------------------------------
# Phase 2 — bounded repair: an unsupported speed routes to ONE repair call carrying the exact
# validator error; the repaired plan is re-validated and must be clean, or the Story fails honestly.
# ---------------------------------------------------------------------------
from model_gateway import StructuredResult, Usage  # noqa: E402


class _SeqGateway:
    """Returns a preset response per call, in order (last repeats). Records every request so a test
    can assert the exact validator error was fed back into the repair prompt."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = []
        self.last_fallback = False

    def generate_structured(self, req):
        self.calls.append(req)
        idx = min(len(self.calls) - 1, len(self._responses) - 1)
        return StructuredResult(
            data=json.loads(json.dumps(self._responses[idx])),
            usage=Usage(input_tokens=100, output_tokens=40, total_tokens=140),
            attempts=1, model="fake", provider="fake",
        )


def test_invalid_speed_triggers_bounded_repair():
    # First call: 4.0x (unrenderable). Repair call: a duration-valid plan within 0.5x–2.0x.
    bad, good = _speed_plan(4.0), _good_plan()
    gw = _SeqGateway([bad, good])
    eng = RealEditPlannerEngine(gw)
    plan = eng.generate(_inputs())
    assert eng.last_diagnostics["repaired"] is True
    assert eng.last_diagnostics["executability_repairs_used"] == 1
    # the EXACT validator error reached the repair prompt
    assert len(gw.calls) == 2
    assert "out of renderer-supported range" in gw.calls[1].user_content
    assert all((s.speed or 1.0) <= 2.0 for s in plan.segments)


def test_repaired_plan_passes_full_validation():
    gw = _SeqGateway([_speed_plan(4.0), _good_plan()])
    plan = RealEditPlannerEngine(gw).generate(_inputs())
    # round-trip the emitted contract back through the validator — zero errors.
    emitted = {"target_duration_seconds": 18.0, "feasible": True, "segments": [
        {"order": s.order, "asset_id": str(s.asset_id),
         "source_start_seconds": s.source_start_seconds, "source_end_seconds": s.source_end_seconds,
         "speed": s.speed, "output_duration_seconds": s.output_duration_seconds,
         "native_audio": s.native_audio.value} for s in plan.segments]}
    assert validate_plan(emitted, _inputs()) == []


def test_repair_preserves_target_duration():
    # The repaired alternative keeps the total within the accept band of the 18s target.
    gw = _SeqGateway([_speed_plan(4.0), _good_plan()])
    plan = RealEditPlannerEngine(gw).generate(_inputs())
    total = sum(s.output_duration_seconds for s in plan.segments)
    assert 18.0 * 0.8 <= total <= 18.0 * 1.5


def test_repair_still_invalid_fails_honestly():
    # Repair ALSO returns an unsupported speed -> never shipped; honest StructuredOutputError.
    gw = _SeqGateway([_speed_plan(4.0), _speed_plan(3.0)])
    eng = RealEditPlannerEngine(gw)
    with pytest.raises(StructuredOutputError):
        eng.generate(_inputs())
    assert eng.last_diagnostics["final"] == "invalid_after_repair"
    # bounded: exactly one repair attempt, no unbounded loop
    assert len(gw.calls) == 2


def test_critique_revision_cannot_reintroduce_invalid_speed():
    # Valid base plan, but the critique->revision pass emits a 4.0x speed. The deterministic validator
    # rejects the revision and the ORIGINAL valid plan is retained (revision never silently adopted).
    base = _good_plan()
    revised_bad = _speed_plan(4.0)
    gw = _SeqGateway([base, "critique text", revised_bad])
    # critique call returns a {"critique": ...} dict; wrap the text as that shape
    gw._responses[1] = {"critique": "lead with a stronger hook"}
    eng = RealEditPlannerEngine(gw)
    plan = eng.generate(_inputs(creative_brief="punchy, fast", critique_revision=True))
    assert eng.last_diagnostics.get("critique_applied") is False
    assert eng.last_diagnostics.get("critique_rejected_reason") == "revision_invalid"
    # original valid plan survived — no 4.0x speed leaked through
    assert all((s.speed or 1.0) <= 2.0 for s in plan.segments)


# ---------------------------------------------------------------------------
# Explicit Moment References — deterministic hard-directive validation.
# Directives carry RESOLVED stable Moment ids (asset_id values), never display numbers.
# ---------------------------------------------------------------------------
def _ctx(directives, mode="revise"):
    return {"mode": mode, "base_version_id": "v1", "directives": directives}


def test_directive_must_include_satisfied():
    plan = _good_plan()  # uses M1 and M2
    errs = validate_plan(plan, _inputs(revision_context=_ctx({"must_include": [M1]})))
    assert [e for e in errs if "must_include" in e] == []


def test_directive_must_include_violated():
    plan = _good_plan()
    plan["segments"] = [s for s in plan["segments"] if s["asset_id"] != M2]  # drop M2
    errs = validate_plan(plan, _inputs(revision_context=_ctx({"must_include": [M2]})))
    assert any("must_include" in e and "appears in no segment" in e for e in errs)


def test_directive_exclude_violated():
    plan = _good_plan()  # contains M2
    errs = validate_plan(plan, _inputs(revision_context=_ctx({"exclude": [M2]})))
    assert any("exclude" in e and "must NOT be used" in e for e in errs)


def test_directive_opening_satisfied_and_violated():
    plan = _good_plan()  # order 0 is M1
    ok = validate_plan(plan, _inputs(revision_context=_ctx({"opening": M1})))
    assert [e for e in ok if "opening" in e] == []
    bad = validate_plan(plan, _inputs(revision_context=_ctx({"opening": M2})))
    assert any("opening" in e and "first segment must be" in e for e in bad)


def test_directive_ending_satisfied_and_violated():
    plan = _good_plan()  # last is M2
    ok = validate_plan(plan, _inputs(revision_context=_ctx({"ending": M2})))
    assert [e for e in ok if "ending" in e] == []
    bad = validate_plan(plan, _inputs(revision_context=_ctx({"ending": M1})))
    assert any("ending" in e and "last segment must be" in e for e in bad)


def test_directive_unknown_moment_is_error_not_silent():
    # A reference to a Moment not in the eligible source set must be flagged (deleted/unavailable case),
    # never silently ignored or substituted.
    ghost = str(uuid4())
    errs = validate_plan(_good_plan(), _inputs(revision_context=_ctx({"must_include": [ghost]})))
    assert any(ghost in e and "not in the eligible source set" in e for e in errs)


def test_directive_conflict_include_and_exclude():
    errs = validate_plan(_good_plan(), _inputs(revision_context=_ctx({"must_include": [M1], "exclude": [M1]})))
    assert any("conflict" in e and M1 in e for e in errs)


def test_directive_duplicate_references_safe():
    # Duplicate ids in must_include are handled without error when satisfied.
    errs = validate_plan(_good_plan(), _inputs(revision_context=_ctx({"must_include": [M1, M1]})))
    assert [e for e in errs if "must_include" in e] == []


def test_no_directives_behaves_unchanged():
    # revision_context without directives (or absent) must not add any directive errors.
    assert validate_plan(_good_plan(), _inputs()) == []
    assert validate_plan(_good_plan(), _inputs(revision_context=_ctx({}))) == []
    assert validate_plan(_good_plan(), _inputs(revision_context={"mode": "explore"})) == []


def test_directive_lines_rendered_for_model():
    block = _revision_context_block(_ctx({"must_include": [M1], "exclude": [M2], "opening": M1, "ending": M2}))
    assert f"MUST include a segment from each of these Moment ids: {M1}" in block
    assert f"MUST NOT use any of these Moment ids: {M2}" in block
    assert f"FIRST segment (order 0) MUST be Moment id {M1}" in block
    assert f"LAST segment MUST be Moment id {M2}" in block


# ---------------------------------------------------------------------------
# Ordering directives — order_after (A somewhere after B) + order_adjacent (A immediately after B).
# ---------------------------------------------------------------------------
def _plan3(a, b, c):
    """3-segment plan with the given asset ids in order a,b,c (all consistent 1x)."""
    segs = []
    for i, aid in enumerate([a, b, c]):
        segs.append({"order": i, "asset_id": aid, "source_start_seconds": 1.0, "source_end_seconds": 7.0,
                     "output_duration_seconds": 6.0, "native_audio": "keep"})
    return {"target_duration_seconds": 18.0, "feasible": True, "segments": segs}


def _inputs3(a, b, c):
    return _inputs(moments=[
        {"id": a, "duration_seconds": 9.0, "useful_segments": [[1.0, 8.0]], "summary": "a"},
        {"id": b, "duration_seconds": 9.0, "useful_segments": [[1.0, 8.0]], "summary": "b"},
        {"id": c, "duration_seconds": 9.0, "useful_segments": [[1.0, 8.0]], "summary": "c"},
    ])


def test_order_after_satisfied_and_violated():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    base = _inputs3(a, b, c)
    # plan order a,b,c : "c after a" holds; "a after c" fails
    ok = validate_plan(_plan3(a, b, c), _with_rc(base, {"order_after": [[c, a]]}))
    assert [e for e in ok if "order_after" in e] == []
    bad = validate_plan(_plan3(a, b, c), _with_rc(base, {"order_after": [[a, c]]}))
    assert any("must come after" in e for e in bad)


def test_order_adjacent_satisfied_and_violated():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    base = _inputs3(a, b, c)
    # a,b,c : b immediately after a holds; c immediately after a fails (c is 2 later)
    ok = validate_plan(_plan3(a, b, c), _with_rc(base, {"order_adjacent": [[b, a]]}))
    assert [e for e in ok if "order_adjacent" in e] == []
    bad = validate_plan(_plan3(a, b, c), _with_rc(base, {"order_adjacent": [[c, a]]}))
    assert any("immediately follow" in e for e in bad)


def test_order_unknown_moment_is_error():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    ghost = str(uuid4())
    errs = validate_plan(_plan3(a, b, c), _with_rc(_inputs3(a, b, c), {"order_after": [[a, ghost]]}))
    assert any(ghost in e and "not in the eligible source set" in e for e in errs)


def test_order_contradictory_conflict():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    errs = validate_plan(_plan3(a, b, c), _with_rc(_inputs3(a, b, c),
                         {"order_after": [[a, b], [b, a]]}))
    assert any("contradictory ordering" in e for e in errs)


def test_order_excluded_moment_conflict():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    errs = validate_plan(_plan3(a, b, c), _with_rc(_inputs3(a, b, c),
                         {"exclude": [a], "order_after": [[a, b]]}))
    assert any("excluded but also named in an ordering" in e for e in errs)


def test_order_impossible_adjacency_conflict():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    # a immediately after b AND a immediately after c — impossible
    errs = validate_plan(_plan3(a, b, c), _with_rc(_inputs3(a, b, c),
                         {"order_adjacent": [[a, b], [a, c]]}))
    assert any("immediately after multiple Moments" in e for e in errs)


def test_opening_plus_adjacent_use_moment5_to_start_moment2_follow():
    # The owner's exact instruction, resolved: opening=A ("moment 5 to start"),
    # order_adjacent [B,A] ("moment 2 follow" = B immediately after A).
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    base = _inputs3(a, b, c)
    rc = {"opening": a, "order_adjacent": [[b, a]]}
    # plan a,b,c satisfies both; plan b,a,c violates opening
    assert validate_plan(_plan3(a, b, c), _with_rc(base, rc)) == []
    bad = validate_plan(_plan3(b, a, c), _with_rc(base, rc))
    assert any("opening" in e for e in bad)


def _with_rc(inp, directives):
    """Clone an EditPlanInputs adding a revise revision_context with the given directives."""
    import dataclasses
    return dataclasses.replace(inp, revision_context={"mode": "revise", "directives": directives})


# ---------------------------------------------------------------------------
# Phase 2 — hybrid revision interpreter (unit, fake gateway).
# ---------------------------------------------------------------------------
def test_interpret_revision_maps_numbers_to_ids_and_flags_unresolved():
    from edit_planner.revision_interpreter import interpret_revision

    class _GW:
        def __init__(self, d): self._d = d
        def generate_structured(self, req):
            from model_gateway import StructuredResult, Usage
            return StructuredResult(data=self._d, usage=Usage())

    numbered = [{"number": 1, "id": "id-a", "summary": "summit"},
                {"number": 2, "id": "id-b", "summary": "river"}]
    gw = _GW({"must_include": [], "exclude": [], "opening": 1, "ending": None,
              "order_after": [], "order_adjacent": [[2, 1]],
              "soft_direction": "faster cuts", "unsupported": ["make it dreamier"]})
    r = interpret_revision("use moment 1 to start and moment 2 follow, faster cuts, dreamier", numbered, gw)
    assert r.directives["opening"] == "id-a"
    assert r.directives["order_adjacent"] == [["id-b", "id-a"]]
    assert r.soft_direction == "faster cuts"
    assert "make it dreamier" in r.unresolved
    assert r.needs_clarification

    # out-of-range number -> unresolved, never a fabricated id
    gw2 = _GW({"must_include": [9], "exclude": [], "opening": None, "ending": None,
               "order_after": [], "order_adjacent": [], "soft_direction": "", "unsupported": []})
    r2 = interpret_revision("include moment 9", numbered, gw2)
    assert r2.directives == {}
    assert any("9" in u for u in r2.unresolved)


# ---------------------------------------------------------------------------
# Phase 5 — deterministic revision fast path (zero model calls).
# ---------------------------------------------------------------------------
def test_deterministic_transform_reorders_and_prunes():
    from edit_planner.deterministic_revision import apply_deterministic_revision as A
    def seg(o, a): return {"order": o, "asset_id": a, "source_start_seconds": 0.0,
                           "source_end_seconds": 4.0, "output_duration_seconds": 4.0, "native_audio": "keep"}
    base = {"schema_version": "edit_plan/2", "feasible": True,
            "segments": [seg(0, "a"), seg(1, "b"), seg(2, "c"), seg(3, "d")]}
    def ids(p): return [s["asset_id"] for s in sorted(p["segments"], key=lambda s: s["order"])]
    assert ids(A(base, {"opening": "c"})) == ["c", "a", "b", "d"]
    assert ids(A(base, {"exclude": ["b"]})) == ["a", "c", "d"]
    assert ids(A(base, {"opening": "a", "order_adjacent": [["c", "a"]]})) == ["a", "c", "b", "d"]
    assert ids(A(base, {"ending": "a"})) == ["b", "c", "d", "a"]
    # must_include a Moment not in the base plan cannot be done by reorder -> None (fall back to AI)
    assert A(base, {"must_include": ["zz"]}) is None
    # order renumbered 0..n-1
    assert [s["order"] for s in sorted(A(base, {"opening": "c"})["segments"], key=lambda s: s["order"])] == [0, 1, 2, 3]


def test_engine_deterministic_fast_path_zero_model_calls():
    # A revise carrying base_plan + a structural directive and NO soft_direction must resolve with 0 model calls.
    a, b = M1, M2
    def seg(o, aid): return {"order": o, "asset_id": aid, "source_start_seconds": 1.0,
                             "source_end_seconds": 7.0, "output_duration_seconds": 6.0, "native_audio": "keep"}
    # base plan must itself be duration-valid for the target (reorder keeps total unchanged); use a target
    # that matches the base so the fast-path result passes the duration gate.
    base_plan = {"schema_version": "edit_plan/2", "target_duration_seconds": 12.0, "feasible": True,
                 "segments": [seg(0, a), seg(1, b)]}
    rc = {"mode": "revise", "base_version_id": "v1", "base_plan": base_plan,
          "directives": {"opening": b}}   # make B the opening
    # A gateway that FAILS if called — proves the fast path never calls the model.
    class _Boom:
        last_fallback = False
        def generate_structured(self, req):
            raise AssertionError("model must NOT be called on the deterministic fast path")
    eng = RealEditPlannerEngine(_Boom())
    plan = eng.generate(_inputs(revision_context=rc, creative_intent={"target_duration_seconds": 12.0, "desired_feeling": ["calm"]}))
    assert eng.last_diagnostics["revision_path"] == "deterministic"
    assert eng.last_diagnostics["model_calls"] == 0
    assert str(plan.segments[0].asset_id) == b   # opening honored
