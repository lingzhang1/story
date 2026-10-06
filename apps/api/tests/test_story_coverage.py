"""Story Coverage engine + endpoint tests (Milestone E, FROZEN). FakeModelGateway, no network.

Verifies: valid conversion + provenance minting; nullable story_idea; failure raises
CoverageUnavailableError (caller keeps cache) -> 503; compact-input only; pending_count carried.
"""

from __future__ import annotations

import json
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.deps import get_story_coverage_engine
from app.main import create_app
from story_coverage import (
    CoverageInput,
    CoverageUnavailableError,
    DEFAULT_COVERAGE_MODEL,
    PROMPT_VERSION,
    SCHEMA_VERSION,
    RealStoryCoverageEngine,
)
from contracts.schemas.ai_contracts import StoryCoverageContract
from model_gateway import FakeModelGateway, ProviderError, StructuredOutputError


def _mu(summary="a landscape", utility="strong_elsewhere", shot=None):
    return {"moment_id": str(uuid4()),
            "observed": {"summary": summary, "subjects": ["mountain"], "events": [],
                         "temporal_order_note": "", "useful_segments": []},
            "story_context": {"story_utility": utility, "requested_shot_contribution": shot,
                              "requested_beat_contribution": None}}


_GOOD = {
    "dimensions": [{"id": "human_scale", "label": "Human vs Landscape Scale", "purpose": "contrast",
                    "coverage": "strong", "note": "x", "evidence_moment_ids": []}],
    "strengths": ["strong landscape coverage"],
    "redundancies": [],
    "sufficiency": {"status": "workable", "reason": "thin on people"},
    "story_idea": {"title": "A quiet human moment", "description": "...", "rationale": "..."},
}
_GOOD_NULL_IDEA = {**_GOOD, "sufficiency": {"status": "sufficient", "reason": "enough"}, "story_idea": None}


def _inp(n=2, pending=0):
    return CoverageInput(story_id=uuid4(), creative_intent={"raw_text": "our trek"},
                         scope={"target_duration_seconds": 90}, moment_understandings=[_mu() for _ in range(n)],
                         pending_count=pending)


# --- engine ---------------------------------------------------------------

def test_compute_valid_and_mints_provenance():
    eng = RealStoryCoverageEngine(FakeModelGateway(response=_GOOD), model_id=DEFAULT_COVERAGE_MODEL)
    inp = _inp(3, pending=1)
    cov = eng.compute(inp)
    assert isinstance(cov, StoryCoverageContract)
    assert cov.schema_version == SCHEMA_VERSION
    assert cov.moment_count == 3
    assert cov.pending_count == 1
    assert len(cov.source_understanding_ids) == 3
    assert cov.sufficiency.status.value == "workable"
    assert cov.story_idea is not None


def test_nullable_story_idea_and_sufficient():
    eng = RealStoryCoverageEngine(FakeModelGateway(response=_GOOD_NULL_IDEA))
    cov = eng.compute(_inp(2))
    assert cov.story_idea is None
    assert cov.sufficiency.status.value == "sufficient"


def test_strong_elsewhere_moment_is_passed_compactly():
    gw = FakeModelGateway(response=_GOOD)
    eng = RealStoryCoverageEngine(gw)
    inp = _inp(1)
    inp.moment_understandings[0]["story_context"]["story_utility"] = "strong_elsewhere"
    eng.compute(inp)
    # the request the engine built carries the compact moment incl. story_utility, no raw media
    sent = gw.calls[0].user_content
    assert "strong_elsewhere" in sent
    assert "frames" not in sent and "jpeg" not in sent.lower()


def test_provider_failure_raises_unavailable_not_fabrication():
    eng = RealStoryCoverageEngine(FakeModelGateway(error=ProviderError("bedrock down")))
    with pytest.raises(CoverageUnavailableError):
        eng.compute(_inp(2))


def test_structured_failure_raises_unavailable():
    eng = RealStoryCoverageEngine(FakeModelGateway(error=StructuredOutputError("bad")))
    with pytest.raises(CoverageUnavailableError):
        eng.compute(_inp(1))


# --- endpoint --------------------------------------------------------------

def _client(engine):
    app = create_app()
    app.dependency_overrides[get_story_coverage_engine] = lambda: engine
    return TestClient(app)


def _body(n=2, pending=0):
    return {"story_id": str(uuid4()), "creative_intent": {"raw_text": "our trek"},
            "scope": {"target_duration_seconds": 90},
            "moment_understandings": [_mu() for _ in range(n)], "pending_count": pending}


def test_endpoint_success():
    client = _client(RealStoryCoverageEngine(FakeModelGateway(response=_GOOD)))
    r = client.post("/v1/story-coverage", json=_body(2, pending=1))
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["schema_version"] == "story_coverage/1"
    assert b["pending_count"] == 1
    assert b["sufficiency"]["status"] == "workable"
    assert b["story_idea"]["title"]


def test_endpoint_null_idea():
    client = _client(RealStoryCoverageEngine(FakeModelGateway(response=_GOOD_NULL_IDEA)))
    r = client.post("/v1/story-coverage", json=_body(2))
    assert r.status_code == 200, r.text
    assert r.json()["story_idea"] is None


def test_endpoint_failure_returns_503_not_fabrication():
    client = _client(RealStoryCoverageEngine(FakeModelGateway(error=ProviderError("down"))))
    r = client.post("/v1/story-coverage", json=_body(2))
    assert r.status_code == 503
    assert "story_coverage_unavailable" in r.json()["detail"]


def test_endpoint_rejects_extra_field():
    client = _client(RealStoryCoverageEngine(FakeModelGateway(response=_GOOD)))
    body = _body(1); body["frames"] = ["nope"]   # no media allowed on this endpoint
    r = client.post("/v1/story-coverage", json=body)
    assert r.status_code == 422
