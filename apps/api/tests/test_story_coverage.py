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


# --- Phase 10: regression-harness integrity (fixture corpus is FROZEN) --------
#
# These guard the permanent Story Coverage regression suite so a future edit cannot
# silently drop a fixture, un-classify A, or erase the decision history. They do NOT
# call a model — they assert the corpus + its owner-approved classification.

import pathlib

_FIX_PATH = pathlib.Path(__file__).resolve().parents[3] / "evals/story_coverage/fixtures.json"


def _load_fixtures():
    return json.loads(_FIX_PATH.read_text())["fixtures"]


def test_regression_corpus_present_and_complete():
    """The 15 frozen fixtures (A-L incl. F1/F2, H1/H2/H3) must all remain present."""
    fx = _load_fixtures()
    required = {
        "A_scenery_only", "B_broad_coverage", "C_redundant_scenery", "D_strong_elsewhere",
        "E_contextless", "F1_one_exceptional_short", "F2_one_exceptional_rich", "G_conflicting",
        "H1_accum", "H2_accum", "H3_accum", "I_no_intervention_sufficient",
        "J_anti_checklist_solitude", "K_nontravel_guitar", "L_pending_au",
    }
    assert required.issubset(set(fx)), f"missing frozen fixtures: {required - set(fx)}"


def test_every_fixture_is_classified_strict_or_envelope():
    """Each fixture carries an explicit eval_mode; only owner-reviewed ones are envelope."""
    fx = _load_fixtures()
    for fid, f in fx.items():
        assert f.get("eval_mode") in ("strict", "semantic_envelope"), f"{fid} unclassified"
    # Only A is currently owner-classified ambiguous; new ones require explicit review.
    envelope = [fid for fid, f in fx.items() if f.get("eval_mode") == "semantic_envelope"]
    assert envelope == ["A_scenery_only"], f"unexpected envelope set: {envelope}"


def test_fixture_A_envelope_and_decision_note_preserved():
    """A's accepted envelope + the owner decision note (history) must be intact."""
    a = _load_fixtures()["A_scenery_only"]
    env = a["semantic_envelope"]
    assert set(env["acceptable"]["sufficiency"]) == {"workable", "sufficient"}
    assert "null" in env["acceptable"]["story_idea"]
    # Forbidden set still bans the two dangerous outcomes.
    assert any("insufficient" in x for x in env["forbidden"])
    assert any("more" in x and "scenery" in x for x in env["forbidden"])
    note = env["decision_note"]
    assert note["owner_decision_date"] == "2026-10-06"
    assert "workable + idea" in note["initial_human_reference"]      # original human ref preserved
    assert note["repeated_production_variance"]                       # history not rewritten


def test_strict_fixtures_keep_exact_human_reference():
    """Strict fixtures retain their exact sufficiency + idea_should_exist expectations."""
    fx = _load_fixtures()
    for fid, f in fx.items():
        if f.get("eval_mode") != "strict":
            continue
        hr = f["human_reference"]
        assert hr["sufficiency"] in ("insufficient", "workable", "sufficient"), fid
        assert isinstance(hr["idea_should_exist"], bool), fid
