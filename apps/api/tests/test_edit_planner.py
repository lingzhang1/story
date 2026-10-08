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
