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
    # model tries to rewrite the CAPTURED scene_01 and OMITS scene_02
    model = {"framing_summary": "new", "scenes": [
        {"id": "scene_01", "title": "REWRITTEN", "what_to_capture": "X",
         "how_to_shoot": "h", "why_it_matters": "y"}]}
    merged, changes, archived = reconcile_refinement(model, _inp(current, captured=["scene_01"]))
    s01 = next(s for s in merged["scenes"] if s["id"] == "scene_01")
    assert s01["title"] == "Temple morning", "captured scene must keep its ORIGINAL content"
    assert any(c["scene_id"] == "scene_01" and c["disposition"] == "preserved" for c in changes)
    # PRESERVE-FIRST: scene_02 was merely OMITTED (not explicitly archived) -> PRESERVED, not archived.
    assert any(s["id"] == "scene_02" for s in merged["scenes"]), "omitted scene must be preserved"
    assert "scene_02" not in archived


def test_explicit_archive_directive_archives_an_unprotected_scene():
    # Archival now requires an EXPLICIT changes entry — omission alone never archives.
    current = [_scene(1, "A"), _scene(2, "Outdated")]
    model = {"framing_summary": "n",
             "scenes": [{"id": "scene_01", "title": "A", "what_to_capture": "w",
                         "how_to_shoot": "h", "why_it_matters": "y"}],
             "changes": [{"scene_id": "scene_02", "disposition": "archived", "reason": "cancelled"}]}
    merged, changes, archived = reconcile_refinement(model, _inp(current))
    assert "scene_02" in archived, "explicit archive directive must archive it"
    assert not any(s["id"] == "scene_02" for s in merged["scenes"])


def test_explicit_archive_of_protected_scene_is_refused():
    # A model that explicitly archives a captured/pinned scene must be ignored (protected wins).
    current = [_scene(1, "Captured"), _scene(2, "B")]
    model = {"framing_summary": "n",
             "scenes": [{"id": "scene_02", "title": "B", "what_to_capture": "w",
                         "how_to_shoot": "h", "why_it_matters": "y"}],
             "changes": [{"scene_id": "scene_01", "disposition": "archived", "reason": "nope"}]}
    merged, changes, archived = reconcile_refinement(model, _inp(current, captured=["scene_01"]))
    assert "scene_01" not in archived, "captured scene can never be archived"
    assert any(s["id"] == "scene_01" for s in merged["scenes"])


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
    # scene_02 EXPLICITLY archived; a new scene must NOT take scene_02 — it takes scene_03.
    current = [_scene(1, "A"), _scene(2, "Outdated")]
    model = {"framing_summary": "n", "scenes": [
        {"id": "scene_01", "title": "A", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"},
        {"id": "brand_new", "title": "Fresh", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"}],
        "changes": [{"scene_id": "scene_02", "disposition": "archived", "reason": "superseded"}]}
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


# --------------------------------------------------------------------------- #
# Phase B — preservation-first reconciliation scenarios (owner B3 1–6).
# A partial model emission must NEVER collapse the guide; omission preserves.
# --------------------------------------------------------------------------- #

def _japan8():
    titles = ["Airport", "Morning street", "Scramble", "Ramen", "Train to Kyoto",
              "Temple", "Kyoto alley", "Last look"]
    return [_scene(i + 1, t) for i, t in enumerate(titles)]


def test_scenario1_add_context_preserves_unrelated_scenes():
    # User: "Tomorrow we're visiting a BBQ restaurant." Model emits only the new food scene.
    current = _japan8()
    model = {"framing_summary": "now with food", "scenes": [
        {"id": "food_new", "title": "BBQ dinner", "what_to_capture": "w", "how_to_shoot": "h",
         "why_it_matters": "y"}]}
    merged, changes, archived = reconcile_refinement(model, _inp(current, instruction="Tomorrow BBQ restaurant"))
    ids = [s["id"] for s in merged["scenes"]]
    # all 8 originals preserved + 1 added = 9; nothing archived
    for i in range(1, 9):
        assert f"scene_{i:02d}" in ids, f"original scene_{i:02d} preserved"
    assert len(merged["scenes"]) == 9, "8 preserved + 1 added, no wholesale replacement"
    assert "scene_09" in ids, "new food scene added"
    assert archived == []


def test_scenario3_explicit_cancellation_archives_only_named_and_keeps_captured():
    # "We canceled Kyoto, going to Osaka." Kyoto scenes 05/06/07 superseded; scene_06 is CAPTURED.
    current = _japan8()
    model = {"framing_summary": "Osaka now", "scenes": [
        {"id": "osaka_new", "title": "Osaka street food", "what_to_capture": "w", "how_to_shoot": "h",
         "why_it_matters": "y"}],
        "changes": [
            {"scene_id": "scene_05", "disposition": "archived", "reason": "Kyoto cancelled"},
            {"scene_id": "scene_06", "disposition": "archived", "reason": "Kyoto cancelled"},  # but captured!
            {"scene_id": "scene_07", "disposition": "archived", "reason": "Kyoto cancelled"}]}
    merged, changes, archived = reconcile_refinement(
        model, _inp(current, captured=["scene_06"], instruction="canceled Kyoto, Osaka instead"))
    ids = [s["id"] for s in merged["scenes"]]
    assert "scene_06" in ids and "scene_06" not in archived, "captured Kyoto scene preserved despite archive attempt"
    assert "scene_05" in archived and "scene_07" in archived, "uncaptured Kyoto scenes archived"
    assert any(s["title"] == "Osaka street food" for s in merged["scenes"])


def test_scenario4_preference_change_does_not_delete_existing():
    # "I want more food and street-life footage." Model emits food scenes; mountain/temple stay.
    current = _japan8()
    model = {"framing_summary": "food-forward", "scenes": [
        {"id": "f1", "title": "Street-life montage", "what_to_capture": "w", "how_to_shoot": "h",
         "why_it_matters": "y"}]}
    merged, changes, archived = reconcile_refinement(model, _inp(current, instruction="more food + street life"))
    assert archived == [], "a preference change must not delete existing scenes"
    assert any(s["title"] == "Temple" for s in merged["scenes"]), "temple scene preserved"


def test_scenario5_captured_scene_ids_and_lineage_stable_across_refine():
    current = _japan8()
    model = {"framing_summary": "n", "scenes": [
        {"id": "scene_02", "title": "Morning street (sharper)", "what_to_capture": "w2",
         "how_to_shoot": "h", "why_it_matters": "y"}]}
    merged, _, archived = reconcile_refinement(model, _inp(current, captured=["scene_01", "scene_04"]))
    ids = [s["id"] for s in merged["scenes"]]
    assert "scene_01" in ids and "scene_04" in ids, "captured ids stable"
    assert archived == []
    s01 = next(s for s in merged["scenes"] if s["id"] == "scene_01")
    assert s01["title"] == "Airport", "captured content unchanged"


def test_scenario6_explicit_replacement_permitted_but_captured_survive():
    # "Replace the entire shooting plan with a food-focused story." Model archives all UNCAPTURED, adds food.
    current = _japan8()
    archive_all_uncaptured = [
        {"scene_id": f"scene_{i:02d}", "disposition": "archived", "reason": "full food replacement"}
        for i in range(1, 9) if i != 4]  # scene_04 is captured
    model = {"framing_summary": "a food story", "scenes": [
        {"id": "nf1", "title": "Market tour", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"},
        {"id": "nf2", "title": "Ramen deep-dive", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y"}],
        "changes": archive_all_uncaptured}
    merged, changes, archived = reconcile_refinement(
        model, _inp(current, captured=["scene_04"], instruction="replace entire plan, food-focused"))
    ids = [s["id"] for s in merged["scenes"]]
    assert "scene_04" in ids and "scene_04" not in archived, "captured scene survives a full replacement"
    assert len(archived) == 7, "the 7 uncaptured scenes explicitly archived"
    assert any(s["title"] == "Market tour" for s in merged["scenes"])
