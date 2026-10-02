"""Unit tests for the Story Director engine with a FAKE gateway (no network).

Proves: initialize/next build the right requests; server mints UUID ids over
model-supplied ones; referential integrity (shot->beat) and decision/shot
coherence are enforced; the safety guard rejects unsafe instructions; failures
surface instead of fabricating a plan.
"""

from __future__ import annotations

import pytest

from model_gateway import FakeModelGateway, ProviderError, StructuredOutputError
from story_director import (
    PROMPT_VERSION,
    TASK_INIT,
    DirectorOutput,
    RealStoryDirectorEngine,
)

_CI = {"summary": "TMB hike, peaceful + adventurous", "emphasis": ["journey"]}
_SU = {"summary": "A room with a backpack, chair, window.", "environment_tags": ["indoor"],
       "operator_space": "moderate", "subjects": [{"label": "backpack", "prominence": "high"}]}


def _good(model_shot_id="shot1"):
    # Model returns non-UUID ids (shot1 / b1) — the engine must mint UUIDs.
    return {
        "concept": {"id": "c1", "title": "Preparation", "summary": "The journey begins at home."},
        "plan": {
            "id": "p1", "concept_id": "c1",
            "beats": [{"id": "b_prep", "purpose": "Show preparation."}],
            "shots": [{"id": model_shot_id, "order": 1, "beat_id": "b_prep",
                       "purpose": "Capture the packed bag.", "instruction": "Film the backpack by the door."}],
        },
        "director_state": {"current_beat_id": "b_prep", "beat_progress": []},
        "decision": {"action": "capture_shot",
                     "shot": {"id": model_shot_id, "order": 1, "beat_id": "b_prep",
                              "purpose": "Capture the packed bag.", "instruction": "Film the backpack by the door."}},
    }


def test_initialize_mints_uuid_ids_and_validates():
    gw = FakeModelGateway(response=_good())
    out = RealStoryDirectorEngine(gw).initialize(_CI, _SU)
    assert isinstance(out, DirectorOutput)
    # ids were non-UUID in the response; engine minted valid UUIDs.
    import uuid
    uuid.UUID(str(out.concept.id)); uuid.UUID(str(out.plan.shots[0].id))
    # beat_id (free string) preserved and referenced correctly.
    assert out.plan.shots[0].beat_id == "b_prep"
    # decision shot id aligns with the plan shot id (same model id -> same UUID).
    assert str(out.decision.shot.id) == str(out.plan.shots[0].id)


def test_initialize_request_is_versioned():
    gw = FakeModelGateway(response=_good())
    RealStoryDirectorEngine(gw).initialize(_CI, _SU)
    req = gw.calls[0]
    assert req.task == TASK_INIT
    assert req.prompt_version == PROMPT_VERSION


def test_next_operation():
    gw = FakeModelGateway(response=_good())
    out = RealStoryDirectorEngine(gw).next({"creative_intent": _CI, "scene_understanding": _SU,
                                            "story_state": {"moments": []}})
    assert out.decision.action.value in ("capture_shot", "retry_shot", "rescan_scene", "create_now")


def test_shot_without_beat_is_rejected():
    bad = _good(); bad["plan"]["shots"][0]["beat_id"] = "nonexistent_beat"
    with pytest.raises(StructuredOutputError):
        RealStoryDirectorEngine(FakeModelGateway(response=bad)).initialize(_CI, _SU)


def test_shot_missing_purpose_or_instruction_rejected():
    bad = _good(); bad["plan"]["shots"][0]["purpose"] = None
    with pytest.raises(StructuredOutputError):
        RealStoryDirectorEngine(FakeModelGateway(response=bad)).initialize(_CI, _SU)


def test_capture_shot_without_shot_rejected():
    bad = _good(); bad["decision"] = {"action": "capture_shot"}
    with pytest.raises(StructuredOutputError):
        RealStoryDirectorEngine(FakeModelGateway(response=bad)).initialize(_CI, _SU)


def test_create_now_with_shot_rejected():
    bad = _good(); bad["decision"] = {"action": "create_now", "shot": bad["plan"]["shots"][0]}
    with pytest.raises(StructuredOutputError):
        RealStoryDirectorEngine(FakeModelGateway(response=bad)).initialize(_CI, _SU)


def test_create_now_without_shot_ok():
    ok = _good(); ok["decision"] = {"action": "create_now"}
    out = RealStoryDirectorEngine(FakeModelGateway(response=ok)).initialize(_CI, _SU)
    assert out.decision.action.value == "create_now"
    assert out.decision.shot is None


def test_safety_guard_rejects_walk_backward_near_edge():
    bad = _good()
    bad["plan"]["shots"][0]["instruction"] = "Walk backward toward the edge while filming your partner."
    with pytest.raises(StructuredOutputError):
        RealStoryDirectorEngine(FakeModelGateway(response=bad)).initialize(_CI, _SU)


def test_no_beats_rejected():
    bad = _good(); bad["plan"]["beats"] = []
    with pytest.raises(StructuredOutputError):
        RealStoryDirectorEngine(FakeModelGateway(response=bad)).initialize(_CI, _SU)


def test_provider_error_propagates():
    with pytest.raises(ProviderError):
        RealStoryDirectorEngine(FakeModelGateway(error=ProviderError("down"))).initialize(_CI, _SU)
