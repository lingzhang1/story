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
def test_repro_failure1_total_off_target():
    # 5+5+5 = 15s vs target 12 (>20%) — the first device failure.
    inp = _target12_inputs(moments=_target12_inputs().moments + [
        {"id": "M3", "duration_seconds": 9.0, "useful_segments": [[0.0, 7.5]]}])
    p = {"target_duration_seconds": 12.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 5.0,
         "output_duration_seconds": 5.0, "native_audio": "keep"},
        {"order": 1, "asset_id": M2, "source_start_seconds": 0.0, "source_end_seconds": 5.0,
         "output_duration_seconds": 5.0, "native_audio": "keep"},
        {"order": 2, "asset_id": "M3", "source_start_seconds": 0.0, "source_end_seconds": 5.0,
         "output_duration_seconds": 5.0, "native_audio": "keep"}]}
    errs = _vp(p, inp)
    assert any("off target" in e for e in errs)


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
