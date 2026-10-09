"""MusicPlan engine + endpoint tests (Milestone R-d Batch A, frozen music_plan/1).

No real model is invoked — a FakeModelGateway returns a preset plan or a preset error. Exercises: a valid
model output -> MusicPlanContract with server-minted provenance/story_id/target; MusicDirection carried as
authority; the energy-arc + audio-strategy passthrough; and the endpoint's 200 / 503 behavior (never
fabricates a plan on failure).
"""
from __future__ import annotations

from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.deps import get_music_plan_engine
from app.main import create_app
from music_plan import MusicPlanInputs, RealMusicPlanEngine
from model_gateway import FakeModelGateway, ProviderError, StructuredOutputError

SID = str(uuid4())


def _inputs(**over):
    base = dict(
        story_id=SID,
        creative_intent={"target_duration_seconds": 60.0, "desired_feeling": ["awe", "calm"], "theme": "a hike"},
        music_direction={"mood_tags": ["cinematic", "emotional"], "energy": "dynamic"},
        target_duration_seconds=60.0,
        story_guide={"framing_summary": "a patient ascent that opens up"},
        story_coverage={"sufficiency": "sufficient"},
    )
    base.update(over)
    return MusicPlanInputs(**base)


def _good_plan():
    return {
        "character": {"mood_tags": ["cinematic", "emotional"], "energy": "dynamic"},
        "energy_arc": [
            {"label": "patient opening", "start_fraction": 0.0, "end_fraction": 0.6, "intensity": "rising"},
            {"label": "the peaks arrive", "start_fraction": 0.6, "end_fraction": 1.0, "intensity": "high"},
        ],
        "audio_strategy": {"soundtrack_role": "continuous", "native_audio_priority": "selective",
                           "guidance": "lift under the scenery, step back for the wind"},
        "track_selection_criteria": {"mood_tags": ["cinematic"], "energy": "dynamic",
                                     "structure_hint": "gradual build"},
    }


# ---- engine ----

def test_engine_valid_plan_to_contract():
    eng = RealMusicPlanEngine(FakeModelGateway(response=_good_plan()))
    plan = eng.generate(_inputs())
    assert plan.schema_version == "music_plan/1"
    assert str(plan.story_id) == SID
    assert plan.target_duration_seconds == 60.0
    assert plan.character.energy.value == "dynamic"
    assert len(plan.energy_arc) == 2
    assert plan.audio_strategy.soundtrack_role.value == "continuous"
    assert plan.audio_strategy.native_audio_priority.value == "selective"


def test_engine_mints_provenance_server_side():
    eng = RealMusicPlanEngine(FakeModelGateway(response=_good_plan()))
    plan = eng.generate(_inputs())
    assert plan.provenance is not None
    assert plan.provenance.model_id == "us.anthropic.claude-opus-4-6-v1"
    assert plan.provenance.prompt_version == "music_plan/1"
    assert set(plan.provenance.inputs) == {"creative_intent", "music_direction", "story_guide", "story_coverage"}


def test_engine_single_region_minimal_story():
    plan_data = {
        "character": {"mood_tags": ["still"], "energy": "low"},
        "energy_arc": [{"label": "stable low", "start_fraction": 0.0, "end_fraction": 1.0, "intensity": "low"}],
        "audio_strategy": {"soundtrack_role": "sparse", "native_audio_priority": "important"},
    }
    eng = RealMusicPlanEngine(FakeModelGateway(response=plan_data))
    plan = eng.generate(_inputs(target_duration_seconds=8.0, creative_intent={"target_duration_seconds": 8.0}))
    assert len(plan.energy_arc) == 1
    assert plan.energy_arc[0].intensity.value == "low"
    assert plan.audio_strategy.native_audio_priority.value == "important"


def test_engine_provider_failure_propagates_never_fabricates():
    eng = RealMusicPlanEngine(FakeModelGateway(error=ProviderError("bedrock down")))
    with pytest.raises(ProviderError):
        eng.generate(_inputs())


def test_engine_structured_failure_propagates():
    eng = RealMusicPlanEngine(FakeModelGateway(error=StructuredOutputError("bad shape")))
    with pytest.raises(StructuredOutputError):
        eng.generate(_inputs())


# ---- endpoint ----

def _client(engine):
    app = create_app()
    app.dependency_overrides[get_music_plan_engine] = lambda: engine
    return TestClient(app)


def _req_body(**over):
    base = dict(
        story_id=SID,
        creative_intent={"target_duration_seconds": 60.0, "desired_feeling": ["awe"]},
        music_direction={"mood_tags": ["cinematic"], "energy": "dynamic"},
        target_duration_seconds=60.0,
        story_guide={"framing_summary": "a hike"},
        story_coverage={},
    )
    base.update(over)
    return base


def test_endpoint_200_returns_plan():
    c = _client(RealMusicPlanEngine(FakeModelGateway(response=_good_plan())))
    r = c.post("/v1/music-plan", json=_req_body())
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["schema_version"] == "music_plan/1"
    assert body["story_id"] == SID
    assert body["audio_strategy"]["soundtrack_role"] == "continuous"
    assert len(body["energy_arc"]) == 2


def test_endpoint_503_on_provider_failure():
    c = _client(RealMusicPlanEngine(FakeModelGateway(error=ProviderError("down"))))
    r = c.post("/v1/music-plan", json=_req_body())
    assert r.status_code == 503


def test_endpoint_503_on_structured_failure():
    c = _client(RealMusicPlanEngine(FakeModelGateway(error=StructuredOutputError("bad"))))
    r = c.post("/v1/music-plan", json=_req_body())
    assert r.status_code == 503


def test_endpoint_rejects_missing_music_direction():
    c = _client(RealMusicPlanEngine(FakeModelGateway(response=_good_plan())))
    body = _req_body()
    del body["music_direction"]
    r = c.post("/v1/music-plan", json=body)
    assert r.status_code == 422  # pydantic: music_direction required
