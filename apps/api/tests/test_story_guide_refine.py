"""story_guide/2 REFINEMENT ("Update Guide", Guide v2.1) — additive, feature-flagged backend tests.

Covers the acceptance criteria that live server-side:
  - feature-gate (404 when STORY_GUIDE_V2 off);
  - captured scenes survive refinement (preserved verbatim, never archived);
  - user-pinned scenes are protected (never silently removed, content untouched);
  - outdated uncaptured, unpinned scenes can be archived (recorded in change log);
  - new scenes receive fresh unique ids beyond the max existing ordinal (retired ids never reused);
  - a model that tries to rewrite/drop a protected scene cannot;
  - failed refinement preserves the current Guide (503, no fabrication);
  - the result is a normal StoryGuideV2Contract (every v2 consumer works unchanged).
Reconciler is pure + deterministic (no Bedrock); the endpoint uses the mock engine (no cost).
"""
from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from story_guide import (
    RefineInput,
    reconcile_refinement,
    RealStoryGuideRefineEngine,
    GuideUnavailableError,
)
from contracts.schemas.ai_contracts import StoryGuideV2Contract, StoryGuideRefinementResult


# --------------------------------------------------------------------------- #
# Pure reconciler tests (the server-authoritative identity + history rules).
# --------------------------------------------------------------------------- #

def _scene(i: int, title: str) -> dict:
    return {"id": f"scene_{i:02d}", "title": title, "what_to_capture": "w",
            "how_to_shoot": "h", "why_it_matters": "y"}


def _inp(current, captured=None, pinned=None, instruction="update") -> RefineInput:
    return RefineInput(
        story_id=uuid.uuid4(), creative_intent={}, scope={},
        current_framing_summary="orig", current_scenes=current,
        captured_scene_ids=captured or [], pinned_scene_ids=pinned or [],
        user_instruction=instruction)


def test_captured_scene_preserved_verbatim_even_if_model_rewrites_it():
    current = [_scene(1, "Temple morning"), _scene(2, "Street food")]
    # model tries to rewrite the CAPTURED scene_01 and drop scene_02
    model = {"framing_summary": "new", "scenes": [
        {"id": "scene_01", "title": "REWRITTEN", "what_to_capture": "X",
         "how_to_shoot": "h", "why_it_matters": "y"}]}
    merged, changes, archived = reconcile_refinement(model, _inp(current, captured=["scene_01"]))
    s01 = next(s for s in merged["scenes"] if s["id"] == "scene_01")
    assert s01["title"] == "Temple morning", "captured scene must keep its ORIGINAL content"
    assert any(c["scene_id"] == "scene_01" and c["disposition"] == "preserved" for c in changes)
    # scene_02 uncaptured + dropped -> archived
    assert "scene_02" in archived


def test_pinned_scene_never_archived_even_if_model_omits_it():
    current = [_scene(1, "A"), _scene(2, "Pinned scene")]
    model = {"framing_summary": "n", "scenes": [
        {"id": "scene_01", "title": "A", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"}]}
    merged, changes, archived = reconcile_refinement(model, _inp(current, pinned=["scene_02"]))
    assert any(s["id"] == "scene_02" for s in merged["scenes"]), "pinned scene must survive"
    assert "scene_02" not in archived


def test_new_scene_gets_fresh_id_beyond_max_ordinal():
    current = [_scene(1, "A"), _scene(2, "B")]
    model = {"framing_summary": "n", "scenes": [
        {"id": "scene_01", "title": "A", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"},
        {"id": "scene_02", "title": "B", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"},
        {"id": "s_new", "title": "Bamboo grove", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"}]}
    merged, changes, archived = reconcile_refinement(model, _inp(current))
    ids = [s["id"] for s in merged["scenes"]]
    assert "scene_03" in ids, "new scene minted beyond max ordinal (02)"
    assert archived == []
    assert any(c["disposition"] == "added" and c["scene_id"] == "scene_03" for c in changes)


def test_archived_id_is_not_reused_for_a_new_scene():
    # scene_02 archived; a new scene must NOT take scene_02 — it takes scene_03.
    current = [_scene(1, "A"), _scene(2, "Outdated")]
    model = {"framing_summary": "n", "scenes": [
        {"id": "scene_01", "title": "A", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"},
        {"id": "brand_new", "title": "Fresh", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"}]}
    merged, changes, archived = reconcile_refinement(model, _inp(current))
    assert "scene_02" in archived
    new_ids = [s["id"] for s in merged["scenes"] if s["title"] == "Fresh"]
    assert new_ids == ["scene_03"], "retired id scene_02 must never be reused"


def test_improved_scene_keeps_id_and_is_logged_improved():
    current = [_scene(1, "A"), _scene(2, "B")]
    model = {"framing_summary": "n", "scenes": [
        {"id": "scene_01", "title": "A", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"},
        {"id": "scene_02", "title": "B refined and more specific", "what_to_capture": "w2",
         "how_to_shoot": "h", "why_it_matters": "y"}]}
    merged, changes, archived = reconcile_refinement(model, _inp(current))
    s02 = next(s for s in merged["scenes"] if s["id"] == "scene_02")
    assert s02["title"] == "B refined and more specific"
    assert any(c["scene_id"] == "scene_02" and c["disposition"] == "improved" for c in changes)


def test_reconciled_result_validates_as_v2_contract():
    current = [_scene(1, "A")]
    model = {"framing_summary": "n", "scenes": [
        {"id": "scene_01", "title": "A", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"}]}
    inp = _inp(current)
    merged, _, _ = reconcile_refinement(model, inp)
    merged["schema_version"] = "story_guide/2"
    merged["story_id"] = str(inp.story_id)
    StoryGuideV2Contract.model_validate(merged)  # must not raise


def test_empty_framing_falls_back_to_current():
    current = [_scene(1, "A")]
    model = {"framing_summary": "", "scenes": [
        {"id": "scene_01", "title": "A", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"}]}
    merged, _, _ = reconcile_refinement(model, _inp(current))
    assert merged["framing_summary"] == "orig"


# --------------------------------------------------------------------------- #
# Endpoint tests (mock engine; feature gate; failure preservation).
# --------------------------------------------------------------------------- #

def _client(v2_enabled: bool, monkeypatch, mock=True) -> TestClient:
    if mock:
        monkeypatch.setenv("STORY_GUIDE_MOCK", "1")
    if v2_enabled:
        monkeypatch.setenv("STORY_GUIDE_V2", "1")
    else:
        monkeypatch.delenv("STORY_GUIDE_V2", raising=False)
    return TestClient(create_app())


def _refine_body() -> dict:
    return {
        "story_id": str(uuid.uuid4()),
        "creative_intent": {"summary": "Japan trip"},
        "scope": {},
        "current_framing_summary": "Your week in Japan",
        "current_scenes": [
            {"id": "scene_01", "title": "Temple morning", "what_to_capture": "w",
             "how_to_shoot": "h", "why_it_matters": "y"},
            {"id": "scene_02", "title": "Street food", "what_to_capture": "w",
             "how_to_shoot": "h", "why_it_matters": "y"},
        ],
        "captured_scene_ids": ["scene_01"],
        "pinned_scene_ids": [],
        "user_instruction": "tomorrow we visit Arashiyama",
    }


def test_refine_route_404_when_flag_off(monkeypatch):
    c = _client(False, monkeypatch)
    r = c.post("/v1/story-guide-refine", json=_refine_body())
    assert r.status_code == 404


def test_refine_returns_result_with_changes_when_on(monkeypatch):
    c = _client(True, monkeypatch)
    r = c.post("/v1/story-guide-refine", json=_refine_body())
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["guide"]["schema_version"] == "story_guide/2"
    # captured scene_01 preserved
    assert any(s["id"] == "scene_01" for s in b["guide"]["scenes"])
    assert "changes" in b and isinstance(b["changes"], list)


def test_refine_failure_is_503_not_5xx_crash(monkeypatch):
    # A real engine whose gateway raises -> GuideUnavailableError -> 503 (current Guide preserved client-side).
    monkeypatch.setenv("STORY_GUIDE_V2", "1")
    monkeypatch.delenv("STORY_GUIDE_MOCK", raising=False)

    class _BoomEngine:
        def refine(self, inp):
            raise GuideUnavailableError("simulated provider failure")

    app = create_app()
    from app.main import get_story_guide_refine_engine
    app.dependency_overrides[get_story_guide_refine_engine] = lambda: _BoomEngine()
    c = TestClient(app)
    r = c.post("/v1/story-guide-refine", json=_refine_body())
    assert r.status_code == 503, r.text
    assert "preserve current Guide" in r.text
