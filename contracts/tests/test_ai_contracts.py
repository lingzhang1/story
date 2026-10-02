"""Contract tests for the frozen AI structured-output + boundary contracts
(Milestone B). These prove that representative objects round-trip across the
contract boundary (serialize -> validate -> parse) and that MALFORMED objects
are REJECTED. The goal is to stop future AI implementation (Milestone C) from
silently changing the contract.

Covers (task §7): CreativeIntent, SceneUnderstanding, StoryConcept, StoryPlan,
ValidationResult — plus CaptureSession, which composes them.
"""

from __future__ import annotations

from uuid import uuid4

import pytest
from pydantic import ValidationError

from contracts.schemas.ai_contracts import (
    CaptureEntryPoint,
    CaptureSessionContract,
    CreativeIntentContract,
    CreativeIntentSource,
    CreativeIntentSourceType,
    OutputFormat,
    SceneSubject,
    SceneUnderstandingContract,
    ShotContract,
    StoryConceptContract,
    StoryPlanContract,
    ValidationIssue,
    ValidationRecommendation,
    ValidationResultContract,
)


def _roundtrip(model_cls, obj):
    """Serialize to JSON, re-parse, and assert equality — the boundary trip."""
    payload = obj.model_dump(mode="json")
    parsed = model_cls.model_validate(payload)
    assert parsed == obj
    return payload


# --------------------------------------------------------------------------
# CreativeIntent
# --------------------------------------------------------------------------


def test_creative_intent_round_trips():
    ci = CreativeIntentContract(
        id=uuid4(),
        source_inputs=[
            CreativeIntentSource(type=CreativeIntentSourceType.TEXT, value="cinematic hike"),
            CreativeIntentSource(
                type=CreativeIntentSourceType.REFERENCE_ASSET, asset_id=uuid4()
            ),
        ],
        summary="A cinematic journey through the Alps emphasizing scale.",
        desired_feeling=["cinematic", "emotional"],
        style_tags=["scenic", "slow-build"],
        emphasis=["mountain scale"],
        target_duration_seconds=60,
        target_format=OutputFormat.VERTICAL,
        raw_user_description="I want an emotional film of the mountains.",
    )
    payload = _roundtrip(CreativeIntentContract, ci)
    assert payload["target_format"] == "vertical"
    assert payload["source_inputs"][0]["type"] == "text"


def test_creative_intent_rejects_unknown_field():
    with pytest.raises(ValidationError):
        CreativeIntentContract.model_validate(
            {"id": str(uuid4()), "summary": "x", "provider_model": "claude-x"}
        )


def test_creative_intent_rejects_nonpositive_duration():
    with pytest.raises(ValidationError):
        CreativeIntentContract(id=uuid4(), summary="x", target_duration_seconds=0)


def test_creative_intent_rejects_bad_format_enum():
    with pytest.raises(ValidationError):
        CreativeIntentContract.model_validate(
            {"id": str(uuid4()), "summary": "x", "target_format": "cinemascope"}
        )


# --------------------------------------------------------------------------
# SceneUnderstanding
# --------------------------------------------------------------------------


def test_scene_understanding_round_trips():
    su = SceneUnderstandingContract(
        id=uuid4(),
        summary="Large mountain viewpoint with an open trail and two hikers.",
        environment_tags=["mountain", "ridge", "trail"],
        subjects=[SceneSubject(label="hiker", note="two people")],
        lighting="soft overcast",
        motion_opportunities=["walk toward ridge"],
        composition_opportunities=["large negative space"],
        constraints=["uneven ground"],
    )
    payload = _roundtrip(SceneUnderstandingContract, su)
    assert payload["subjects"][0]["label"] == "hiker"


def test_scene_understanding_requires_summary():
    with pytest.raises(ValidationError):
        SceneUnderstandingContract.model_validate({"id": str(uuid4())})


# --------------------------------------------------------------------------
# StoryConcept
# --------------------------------------------------------------------------


def test_story_concept_round_trips():
    sc = StoryConceptContract(
        id=uuid4(),
        title="Walk Into the Scale",
        summary="Walk away from the camera toward the ridge.",
        target_narrative_need_id="scale",
    )
    _roundtrip(StoryConceptContract, sc)


def test_story_concept_requires_title_and_summary():
    with pytest.raises(ValidationError):
        StoryConceptContract.model_validate({"id": str(uuid4()), "title": "only title"})


# --------------------------------------------------------------------------
# StoryPlan + Shot
# --------------------------------------------------------------------------


def test_story_plan_round_trips_with_shots():
    concept_id = uuid4()
    plan = StoryPlanContract(
        id=uuid4(),
        concept_id=concept_id,
        shots=[
            ShotContract(
                id=uuid4(),
                order=1,
                instruction="Keep the camera still and walk toward the ridge.",
                target_duration_seconds=6,
                framing="wide",
                subject_action="walk away from camera",
            ),
            ShotContract(id=uuid4(), order=2, instruction="Hold a quiet beat."),
        ],
        estimated_duration_seconds=12,
    )
    payload = _roundtrip(StoryPlanContract, plan)
    assert len(payload["shots"]) == 2
    assert payload["shots"][0]["order"] == 1


def test_shot_rejects_negative_order():
    with pytest.raises(ValidationError):
        ShotContract(id=uuid4(), order=-1, instruction="x")


def test_shot_rejects_nonpositive_duration():
    with pytest.raises(ValidationError):
        ShotContract(id=uuid4(), order=0, instruction="x", target_duration_seconds=0)


# --------------------------------------------------------------------------
# ValidationResult
# --------------------------------------------------------------------------


def test_validation_result_round_trips_accept():
    vr = ValidationResultContract(
        usable=True, recommendation=ValidationRecommendation.ACCEPT, confidence=0.9
    )
    _roundtrip(ValidationResultContract, vr)


def test_validation_result_round_trips_retake_with_issues():
    vr = ValidationResultContract(
        usable=False,
        recommendation=ValidationRecommendation.RETAKE,
        confidence=0.4,
        issues=[ValidationIssue.TOO_SHORT, ValidationIssue.SEVERE_SHAKE],
    )
    payload = _roundtrip(ValidationResultContract, vr)
    assert payload["issues"] == ["too_short", "severe_shake"]


def test_validation_result_rejects_unknown_issue():
    with pytest.raises(ValidationError):
        ValidationResultContract.model_validate(
            {"usable": False, "recommendation": "retake", "issues": ["blurry_art"]}
        )


def test_validation_result_rejects_confidence_out_of_range():
    with pytest.raises(ValidationError):
        ValidationResultContract(
            usable=True, recommendation=ValidationRecommendation.ACCEPT, confidence=1.5
        )


def test_validation_result_rejects_bad_recommendation():
    with pytest.raises(ValidationError):
        ValidationResultContract.model_validate({"usable": True, "recommendation": "maybe"})


# --------------------------------------------------------------------------
# CaptureSession (composes the above)
# --------------------------------------------------------------------------


def test_capture_session_round_trips_standalone_create_now():
    ci = CreativeIntentContract(id=uuid4(), summary="quick scenic clip")
    cs = CaptureSessionContract(
        id=uuid4(),
        entry_point=CaptureEntryPoint.CREATE_NOW,
        creative_intent=ci,
        # story_id intentionally omitted -> standalone Create Now (02 §14)
    )
    payload = _roundtrip(CaptureSessionContract, cs)
    assert payload["story_id"] is None
    assert payload["entry_point"] == "create_now"


def test_capture_session_round_trips_in_story_with_full_direction():
    ci = CreativeIntentContract(id=uuid4(), summary="emotional hike")
    su = SceneUnderstandingContract(id=uuid4(), summary="ridge viewpoint")
    sc = StoryConceptContract(id=uuid4(), title="Scale", summary="walk toward ridge")
    plan = StoryPlanContract(
        id=uuid4(),
        concept_id=sc.id,
        shots=[ShotContract(id=uuid4(), order=1, instruction="walk toward ridge")],
    )
    cs = CaptureSessionContract(
        id=uuid4(),
        entry_point=CaptureEntryPoint.SHOOT_MOMENT,
        creative_intent=ci,
        story_id=uuid4(),
        scene_understanding=su,
        selected_concept=sc,
        story_plan=plan,
        capture_asset_ids=[uuid4()],
    )
    _roundtrip(CaptureSessionContract, cs)


def test_capture_session_rejects_bad_entry_point():
    ci = CreativeIntentContract(id=uuid4(), summary="x")
    with pytest.raises(ValidationError):
        CaptureSessionContract.model_validate(
            {
                "id": str(uuid4()),
                "entry_point": "random_button",
                "creative_intent": ci.model_dump(mode="json"),
            }
        )


# --------------------------------------------------------------------------
# JSON Schema generation for the frozen contracts
# --------------------------------------------------------------------------


def test_ai_contract_schemas_build():
    from contracts.generate_schema import AI_CONTRACTS, build_ai_schema

    for title, (model, _filename) in AI_CONTRACTS.items():
        schema = build_ai_schema(title, model)
        assert schema["title"] == title
        assert "properties" in schema
        assert schema["$schema"].startswith("https://json-schema.org/")
