"""Endpoint tests for POST /v1/director/initialize and /v1/director/next."""

from __future__ import annotations

from fastapi.testclient import TestClient

from app.deps import get_story_director_engine
from app.main import create_app
from model_gateway import FakeModelGateway, ProviderError
from story_director import RealStoryDirectorEngine

_RESP = {
    "concept": {"id": "c1", "title": "Preparation", "summary": "The journey begins at home."},
    "plan": {"id": "p1", "concept_id": "c1",
             "beats": [{"id": "b1", "purpose": "Show preparation."}],
             "shots": [{"id": "s1", "order": 1, "beat_id": "b1",
                        "purpose": "Capture the bag.", "instruction": "Film the backpack by the door."}]},
    "director_state": {"current_beat_id": "b1", "beat_progress": []},
    "decision": {"action": "capture_shot",
                 "shot": {"id": "s1", "order": 1, "beat_id": "b1",
                          "purpose": "Capture the bag.", "instruction": "Film the backpack by the door."}},
}
_CI = {"summary": "TMB hike", "emphasis": ["journey"]}
_SU = {"summary": "A room with a backpack.", "environment_tags": ["indoor"], "operator_space": "moderate"}


def _client(engine):
    app = create_app()
    app.dependency_overrides[get_story_director_engine] = lambda: engine
    return TestClient(app)


def test_initialize_success():
    client = _client(RealStoryDirectorEngine(FakeModelGateway(response=_RESP)))
    r = client.post("/v1/director/initialize",
                    json={"creative_intent": _CI, "scene_understanding": _SU,
                          "capture_constraints": {"target_duration_seconds": 60}})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["concept"]["title"] == "Preparation"
    assert body["decision"]["action"] == "capture_shot"
    assert body["plan"]["shots"][0]["beat_id"] == "b1"


def test_next_success():
    client = _client(RealStoryDirectorEngine(FakeModelGateway(response=_RESP)))
    r = client.post("/v1/director/next", json={"prior": {"creative_intent": _CI, "story_state": {"moments": []}}})
    assert r.status_code == 200, r.text


def test_initialize_provider_failure_503():
    client = _client(RealStoryDirectorEngine(FakeModelGateway(error=ProviderError("down"))))
    r = client.post("/v1/director/initialize", json={"creative_intent": _CI, "scene_understanding": _SU})
    assert r.status_code == 503
    assert "director_unavailable" in r.json()["detail"]


def test_initialize_body_validation():
    client = _client(RealStoryDirectorEngine(FakeModelGateway(response=_RESP)))
    assert client.post("/v1/director/initialize", json={}).status_code == 422
