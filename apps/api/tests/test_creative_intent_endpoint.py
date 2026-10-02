"""Endpoint tests for POST /v1/creative-intent (no network).

Overrides the creative-intent-engine dependency with engines backed by a
FakeModelGateway, so the real endpoint + validation + failure path are
exercised without invoking a model.
"""

from __future__ import annotations

from fastapi.testclient import TestClient

from app.deps import get_creative_intent_engine
from app.main import create_app
from creative_intent import RealCreativeIntentEngine
from model_gateway import FakeModelGateway, ProviderError, StructuredOutputError


def _client_with_engine(engine):
    app = create_app()
    app.dependency_overrides[get_creative_intent_engine] = lambda: engine
    return TestClient(app)


def test_resolve_returns_canonical_intent():
    engine = RealCreativeIntentEngine(
        FakeModelGateway(response={
            "summary": "An energetic night in Times Square.",
            "desired_feeling": ["energetic"],
            "pace": "fast",
            "emphasis": ["environment"],
        })
    )
    client = _client_with_engine(engine)
    resp = client.post("/v1/creative-intent", json={"raw_text": "fast energetic times square at night"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["summary"].startswith("An energetic")
    assert body["pace"] == "fast"
    assert body["raw_user_description"] == "fast energetic times square at night"
    assert "id" in body and body["id"]


def test_resolve_body_validation():
    engine = RealCreativeIntentEngine(FakeModelGateway(response={"summary": "x"}))
    client = _client_with_engine(engine)
    # missing raw_text
    assert client.post("/v1/creative-intent", json={}).status_code == 422
    # empty raw_text (min_length=1)
    assert client.post("/v1/creative-intent", json={"raw_text": ""}).status_code == 422


def test_resolve_structured_output_failure_returns_503_not_fabrication():
    engine = RealCreativeIntentEngine(FakeModelGateway(error=StructuredOutputError("no tool_use")))
    client = _client_with_engine(engine)
    resp = client.post("/v1/creative-intent", json={"raw_text": "anything"})
    assert resp.status_code == 503
    assert "creative_intent_unavailable" in resp.json()["detail"]


def test_resolve_provider_failure_returns_503():
    engine = RealCreativeIntentEngine(FakeModelGateway(error=ProviderError("bedrock down")))
    client = _client_with_engine(engine)
    resp = client.post("/v1/creative-intent", json={"raw_text": "anything"})
    assert resp.status_code == 503


def test_resolve_invalid_model_output_returns_503():
    # Model returns schema-shaped but canonical-invalid payload (bad enum).
    engine = RealCreativeIntentEngine(FakeModelGateway(response={"summary": "x", "pace": "blazing"}))
    client = _client_with_engine(engine)
    resp = client.post("/v1/creative-intent", json={"raw_text": "fast city"})
    assert resp.status_code == 503
