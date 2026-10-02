"""Endpoint tests for POST /v1/scene-understanding (multipart, no network).

Overrides the scene-understanding-engine dependency with engines backed by a
FakeModelGateway, so the real multipart handler + validation + failure path are
exercised without invoking a model.
"""

from __future__ import annotations

import io
import json

from fastapi.testclient import TestClient
from PIL import Image

from app.deps import get_scene_understanding_engine
from app.main import create_app
from model_gateway import FakeModelGateway, ProviderError
from scene_understanding import RealSceneUnderstandingEngine


def _jpeg(n: int = 32) -> bytes:
    b = io.BytesIO()
    Image.new("RGB", (n, n), (120, 130, 110)).save(b, format="JPEG")
    return b.getvalue()


def _client(engine):
    app = create_app()
    app.dependency_overrides[get_scene_understanding_engine] = lambda: engine
    return TestClient(app)


def _ctx(**kw):
    base = {"capture_session_id": "s1", "mode": "shoot_moment"}
    base.update(kw)
    return json.dumps(base)


_GOOD = {
    "summary": "A plain indoor room with a bright window.",
    "environment_tags": ["indoor"],
    "subjects": [{"label": "window", "prominence": "medium"}],
    "operator_space": "moderate",
}


def test_scene_understanding_success():
    client = _client(RealSceneUnderstandingEngine(FakeModelGateway(response=_GOOD)))
    resp = client.post(
        "/v1/scene-understanding",
        data={"context": _ctx()},
        files=[("frames", ("f0.jpg", _jpeg(), "image/jpeg")),
               ("frames", ("f1.jpg", _jpeg(), "image/jpeg"))],
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["operator_space"] == "moderate"
    assert body["environment_tags"] == ["indoor"]


def test_rejects_too_many_frames():
    client = _client(RealSceneUnderstandingEngine(FakeModelGateway(response=_GOOD)))
    files = [("frames", (f"f{i}.jpg", _jpeg(), "image/jpeg")) for i in range(7)]
    resp = client.post("/v1/scene-understanding", data={"context": _ctx()}, files=files)
    assert resp.status_code == 413


def test_rejects_unsupported_type():
    client = _client(RealSceneUnderstandingEngine(FakeModelGateway(response=_GOOD)))
    resp = client.post(
        "/v1/scene-understanding",
        data={"context": _ctx()},
        files=[("frames", ("f.gif", b"GIF89a", "image/gif"))],
    )
    assert resp.status_code == 415


def test_rejects_malformed_context():
    client = _client(RealSceneUnderstandingEngine(FakeModelGateway(response=_GOOD)))
    resp = client.post(
        "/v1/scene-understanding",
        data={"context": "not-json"},
        files=[("frames", ("f.jpg", _jpeg(), "image/jpeg"))],
    )
    assert resp.status_code == 422


def test_provider_failure_returns_503_not_fabrication():
    client = _client(RealSceneUnderstandingEngine(FakeModelGateway(error=ProviderError("bedrock down"))))
    resp = client.post(
        "/v1/scene-understanding",
        data={"context": _ctx()},
        files=[("frames", ("f.jpg", _jpeg(), "image/jpeg"))],
    )
    assert resp.status_code == 503
    assert "scene_understanding_unavailable" in resp.json()["detail"]


def test_requires_frames():
    client = _client(RealSceneUnderstandingEngine(FakeModelGateway(response=_GOOD)))
    resp = client.post("/v1/scene-understanding", data={"context": _ctx()})
    assert resp.status_code == 422
