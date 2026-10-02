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


def test_creative_intent_pace_and_constraints():
    from contracts.schemas.ai_contracts import Pace

    ci = CreativeIntentContract(
        id=uuid4(),
        summary="epic but not cheesy hike",
        pace=Pace.FAST,
        creative_constraints=["epic but not cheesy", "focus on the environment, not us"],
    )
    payload = _roundtrip(CreativeIntentContract, ci)
    assert payload["pace"] == "fast"
    assert "epic but not cheesy" in payload["creative_constraints"]


def test_creative_intent_rejects_bad_pace():
    with pytest.raises(ValidationError):
        CreativeIntentContract.model_validate(
            {"id": str(uuid4()), "summary": "x", "pace": "blazing"}
        )


def test_creative_intent_rejects_retired_avoid_field():
    # `avoid` was superseded by `creative_constraints`; extra="forbid" rejects it.
    with pytest.raises(ValidationError):
        CreativeIntentContract.model_validate(
            {"id": str(uuid4()), "summary": "x", "avoid": ["staged"]}
        )


# --------------------------------------------------------------------------
# SceneUnderstanding
# --------------------------------------------------------------------------


def test_scene_understanding_round_trips():
    from contracts.schemas.ai_contracts import OperatorSpace, SubjectProminence

    su = SceneUnderstandingContract(
        id=uuid4(),
        summary="Large mountain viewpoint with an open trail and two hikers.",
        environment_tags=["mountain", "ridge", "trail"],
        subjects=[
            SceneSubject(label="hiker", note="two people", prominence=SubjectProminence.MEDIUM),
            SceneSubject(label="mountain range", prominence=SubjectProminence.HIGH),
        ],
        lighting="soft overcast",
        operator_space=OperatorSpace.OPEN,
        motion_opportunities=["walk toward ridge"],
        composition_opportunities=["large negative space"],
        constraints=["uneven ground"],
    )
    payload = _roundtrip(SceneUnderstandingContract, su)
    assert payload["subjects"][0]["label"] == "hiker"
    assert payload["subjects"][0]["prominence"] == "medium"
    assert payload["operator_space"] == "open"


def test_scene_understanding_requires_summary():
    with pytest.raises(ValidationError):
        SceneUnderstandingContract.model_validate({"id": str(uuid4())})


def test_scene_understanding_rejects_bad_operator_space():
    with pytest.raises(ValidationError):
        SceneUnderstandingContract.model_validate(
            {"id": str(uuid4()), "summary": "x", "operator_space": "cramped"}
        )


def test_scene_understanding_rejects_bad_prominence():
    with pytest.raises(ValidationError):
        SceneUnderstandingContract.model_validate(
            {
                "id": str(uuid4()),
                "summary": "x",
                "subjects": [{"label": "person", "prominence": "huge"}],
            }
        )


def test_scene_understanding_rejects_unknown_field():
    # scene_type was deliberately NOT added; extra="forbid" rejects it.
    with pytest.raises(ValidationError):
        SceneUnderstandingContract.model_validate(
            {"id": str(uuid4()), "summary": "x", "scene_type": "mountain trail"}
        )


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


def test_story_plan_with_beats_and_shot_beat_links():
    from contracts.schemas.ai_contracts import StoryBeat

    plan = StoryPlanContract(
        id=uuid4(),
        concept_id=uuid4(),
        beats=[
            StoryBeat(id="beat_scale", purpose="Establish the human/landscape scale contrast."),
            StoryBeat(id="beat_journey", purpose="Show progression deeper into the landscape."),
        ],
        shots=[
            ShotContract(
                id=uuid4(),
                order=1,
                instruction="Have your partner walk down the trail; keep them small.",
                beat_id="beat_scale",
                purpose="Establish scale by keeping the person small against the mountain.",
                framing="wide",
                camera_motion="static",
                subject_action="walk away along trail",
                target_duration_seconds=3,
            ),
        ],
    )
    payload = _roundtrip(StoryPlanContract, plan)
    assert payload["beats"][0]["id"] == "beat_scale"
    assert payload["shots"][0]["beat_id"] == "beat_scale"
    # purpose (semantic) and instruction (user-facing) are distinct, both present.
    assert payload["shots"][0]["purpose"] != payload["shots"][0]["instruction"]


def test_story_beat_rejects_extra_fields():
    from contracts.schemas.ai_contracts import StoryBeat

    # No beat_type/importance_score/etc — extra="forbid".
    with pytest.raises(ValidationError):
        StoryBeat.model_validate({"id": "b1", "purpose": "x", "beat_type": "establishing"})


def test_director_decision_capture_shot_round_trips():
    from contracts.schemas.ai_contracts import DirectorActionType, DirectorDecision

    d = DirectorDecision(
        action=DirectorActionType.CAPTURE_SHOT,
        shot=ShotContract(id=uuid4(), order=1, instruction="walk down the trail", beat_id="beat_scale"),
        reason="scale beat still unfulfilled; strongest next shot",
    )
    payload = _roundtrip(DirectorDecision, d)
    assert payload["action"] == "capture_shot"
    assert payload["shot"]["beat_id"] == "beat_scale"


def test_director_decision_create_now_needs_no_shot():
    from contracts.schemas.ai_contracts import DirectorActionType, DirectorDecision

    d = DirectorDecision(action=DirectorActionType.CREATE_NOW)
    payload = _roundtrip(DirectorDecision, d)
    assert payload["action"] == "create_now"
    assert payload["shot"] is None


def test_director_decision_rejects_bad_action():
    with pytest.raises(ValidationError):
        from contracts.schemas.ai_contracts import DirectorDecision

        DirectorDecision.model_validate({"action": "do_a_barrel_roll"})


def test_director_state_round_trips():
    from contracts.schemas.ai_contracts import (
        BeatProgress,
        BeatStatus,
        DirectorActionType,
        DirectorDecision,
        DirectorState,
    )

    state = DirectorState(
        current_beat_id="beat_journey",
        beat_progress=[
            BeatProgress(beat_id="beat_scale", status=BeatStatus.FULFILLED, supporting_asset_ids=[uuid4()]),
            BeatProgress(beat_id="beat_journey", status=BeatStatus.PARTIAL),
        ],
        last_decision=DirectorDecision(action=DirectorActionType.RETRY_SHOT,
                                       shot=ShotContract(id=uuid4(), order=2, instruction="try again")),
    )
    payload = _roundtrip(DirectorState, state)
    assert payload["beat_progress"][0]["status"] == "fulfilled"
    assert payload["current_beat_id"] == "beat_journey"


def test_beat_progress_rejects_bad_status():
    with pytest.raises(ValidationError):
        from contracts.schemas.ai_contracts import BeatProgress

        BeatProgress.model_validate({"beat_id": "b1", "status": "mostly_done"})


def test_capture_session_carries_director_state():
    from contracts.schemas.ai_contracts import BeatProgress, DirectorState

    ci = CreativeIntentContract(id=uuid4(), summary="emotional hike")
    cs = CaptureSessionContract(
        id=uuid4(),
        entry_point=CaptureEntryPoint.SHOOT_MOMENT,
        creative_intent=ci,
        director_state=DirectorState(
            current_beat_id="beat_scale",
            beat_progress=[BeatProgress(beat_id="beat_scale")],
        ),
    )
    payload = _roundtrip(CaptureSessionContract, cs)
    assert payload["director_state"]["beat_progress"][0]["beat_id"] == "beat_scale"
    assert payload["director_state"]["beat_progress"][0]["status"] == "unfulfilled"


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
