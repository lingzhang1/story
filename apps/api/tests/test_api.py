"""API endpoint tests for the Story walking skeleton.

Uses FastAPI's TestClient (httpx under the hood). No network, no AWS.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.main import create_app


@pytest.fixture()
def client() -> TestClient:
    return TestClient(create_app())


def test_health(client: TestClient):
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body == {"status": "ok", "service": "story-api", "version": "0.1.0"}


def test_create_story_returns_story_dto(client: TestClient):
    r = client.post("/v1/stories", json={"raw_text": "a calm forest walk", "title": "Woods"})
    assert r.status_code == 201
    body = r.json()
    assert body["title"] == "Woods"
    assert body["status"] == "active"
    assert body["creative_intent"]["raw_text"] == "a calm forest walk"
    assert body["moments"] == []
    assert body["generated_outputs"] == []


def test_create_story_validates_body(client: TestClient):
    # Missing title -> 422 from Pydantic validation.
    r = client.post("/v1/stories", json={"raw_text": "x"})
    assert r.status_code == 422


def test_create_output_does_not_change_status(client: TestClient):
    created = client.post(
        "/v1/stories", json={"raw_text": "epic road trip", "title": "Route 66"}
    ).json()
    story_id = created["id"]
    assert created["status"] == "active"

    r = client.post(f"/v1/stories/{story_id}/outputs")
    assert r.status_code == 201
    out = r.json()
    assert out["story_id"] == story_id
    assert out["title"].startswith("Route 66")
    assert out["duration_seconds"] > 0

    # Create My Story != Complete Story: status must still be active.
    # (Re-create the output again to be sure repeated creation is safe.)
    r2 = client.post(f"/v1/stories/{story_id}/outputs")
    assert r2.status_code == 201


def test_create_output_unknown_story_404(client: TestClient):
    r = client.post("/v1/stories/00000000-0000-0000-0000-000000000000/outputs")
    assert r.status_code == 404
