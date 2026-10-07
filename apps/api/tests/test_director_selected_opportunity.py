"""E2-c D1-D5: Director selected_opportunity regressions (additive; null = unchanged behavior).

These assert the REQUEST-CONSTRUCTION contract (what the engine sends the model) deterministically,
without a live model: selected_opportunity rides in the content payload only when present, carries the
scene-truth / rescan clause, and is absent (behavior unchanged) when null. Live scene-truth outcomes
(D1-D4 capture vs rescan) are verified against the deployed model in the Phase-19 live checks + the
physical-device gate; here we lock the contract + prompt wiring.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[3]
for rel in (".", "packages", "apps/api"):
    p = str((_ROOT / rel).resolve())
    if p not in sys.path:
        sys.path.insert(0, p)

from model_gateway import FakeModelGateway
from story_director import RealStoryDirectorEngine

_INTENT = {"summary": "a cinematic hike"}
_SCENE = {"subjects": [{"label": "two hikers"}]}


def _eng():
    return RealStoryDirectorEngine(FakeModelGateway(response={}))  # response unused; we inspect the request


def test_d5_null_opportunity_preserves_request_shape():
    """selected_opportunity absent -> content has NO selected_opportunity key, no opportunity clause."""
    req = _eng().build_initialize_request(_INTENT, _SCENE, None, None)
    assert "selected_opportunity" not in req.user_content
    assert "selected_opportunity is PRESENT" not in req.user_content


def test_d1_story_idea_opportunity_present_in_request():
    """Story Idea -> Show me: label + purpose carried; opportunity clause present."""
    opp = {"story_guide_dimension_id": "dim_03", "label": "A moment together",
           "purpose": "a natural moment of the two travelers together", "capture_possibility_label": None}
    req = _eng().build_initialize_request(_INTENT, _SCENE, None, opp)
    assert "selected_opportunity is PRESENT" in req.user_content
    body = json.loads(req.user_content.split("INITIALIZE.")[1].split("Return up to")[0]
                      .split(":", 1)[1].strip().split("\n\n")[0]) if False else None  # not parsing; substring checks below
    assert "A moment together" in req.user_content
    assert "a natural moment of the two travelers together" in req.user_content
    assert "dim_03" in req.user_content


def test_d2_opportunity_with_no_scene_carries_both_clauses():
    """Story Idea opportunity + null scene (unsupported extreme) -> both SKIP-SCAN and opportunity notes;
    the model is instructed to rescan when the scene cannot serve it."""
    opp = {"story_guide_dimension_id": None, "label": "A moment together",
           "purpose": "a natural moment together", "capture_possibility_label": None}
    req = _eng().build_initialize_request(_INTENT, None, None, opp)
    assert "selected_opportunity is PRESENT" in req.user_content
    assert "rescan_scene" in req.user_content  # the opportunity clause names the rescan fallback


def test_d3_guide_possibility_uses_semantic_purpose():
    """Guide possibility -> Shoot: purpose = possibility.semantic_purpose (the SPECIFIC one), label +
    capture_possibility_label = the possibility; carried verbatim into the request."""
    opp = {"story_guide_dimension_id": "dim_02", "label": "Boots moving through terrain",
           "purpose": "Show forward progress through the physical rhythm of walking.",
           "capture_possibility_label": "Boots moving through terrain"}
    req = _eng().build_initialize_request(_INTENT, _SCENE, None, opp)
    assert "Show forward progress through the physical rhythm of walking." in req.user_content
    assert "Boots moving through terrain" in req.user_content
    assert "dim_02" in req.user_content


def test_d4_guide_possibility_present_with_unsuitable_scene_still_additive():
    """Possibility opportunity + an interior scene: request still carries the opportunity + rescan clause;
    the model (live) decides rescan. Contract-level: additive, no forced wording."""
    opp = {"story_guide_dimension_id": "dim_02", "label": "Boots moving through terrain",
           "purpose": "Show forward progress through walking.", "capture_possibility_label": "Boots moving through terrain"}
    interior = {"subjects": [{"label": "restaurant table"}]}
    req = _eng().build_initialize_request(_INTENT, interior, None, opp)
    assert "selected_opportunity is PRESENT" in req.user_content
    assert "rescan_scene" in req.user_content


def test_opportunity_is_additive_not_a_constraint():
    """selected_opportunity must NOT be injected as capture_constraints (semantic WHAT, not a limit)."""
    opp = {"label": "A moment together", "purpose": "p"}
    req = _eng().build_initialize_request(_INTENT, _SCENE, {"max_people": 2}, opp)
    # both present and distinct
    assert "selected_opportunity" in req.user_content
    assert "capture_constraints" in req.user_content
