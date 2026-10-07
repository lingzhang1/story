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


# --------------------------------------------------------------------------
# MomentUnderstanding (06-asset-understanding.md, FROZEN) — observed vs story_context
# --------------------------------------------------------------------------


def test_moment_understanding_round_trips_with_context():
    from contracts.schemas.ai_contracts import MomentUnderstandingContract

    data = {
        "moment_id": str(uuid4()),
        "source_capture_id": str(uuid4()),
        "model_id": "us.anthropic.claude-sonnet-4-6",
        "n_frames": 24,
        "observed": {
            "summary": "A woman shoulders a pack and departs down a corridor.",
            "subjects": ["woman", "backpack"],
            "events": [{"start_time": 0.0, "end_time": 4.0, "description": "shoulders the pack"}],
            "temporal_order_note": "gear-up then departure",
            "useful_segments": [{"start_time": 0.0, "end_time": 20.0, "why_useful": "complete departure"}],
        },
        "story_context": {
            "story_utility": "strong_elsewhere",
            "requested_shot_contribution": "fulfilled",
            "requested_beat_contribution": "serves beat_departure",
        },
    }
    m = MomentUnderstandingContract.model_validate(data)
    assert m.observed.summary.startswith("A woman")
    assert m.story_context.story_utility.value == "strong_elsewhere"
    # round-trip through JSON preserves the observed/story_context split
    again = MomentUnderstandingContract.model_validate_json(m.model_dump_json())
    assert again.observed.events[0].description == "shoulders the pack"
    assert again.story_context.requested_beat_contribution == "serves beat_departure"


def test_moment_understanding_nullable_contributions_for_spontaneous():
    from contracts.schemas.ai_contracts import MomentUnderstandingContract

    m = MomentUnderstandingContract.model_validate({
        "moment_id": str(uuid4()),
        "observed": {"summary": "spontaneous clip", "subjects": [], "events": [],
                     "temporal_order_note": "", "useful_segments": []},
        "story_context": {"story_utility": "none"},
    })
    assert m.source_capture_id is None
    assert m.story_context.requested_shot_contribution is None
    assert m.story_context.requested_beat_contribution is None


def test_moment_understanding_rejects_unknown_field_and_bad_utility():
    import pytest
    from contracts.schemas.ai_contracts import MomentUnderstandingContract

    with pytest.raises(Exception):
        MomentUnderstandingContract.model_validate({
            "moment_id": str(uuid4()),
            "observed": {"summary": "x", "subjects": [], "events": [], "temporal_order_note": "",
                         "useful_segments": []},
            "story_context": {"story_utility": "none"},
            "environment": "should-be-rejected",  # dropped field must not be accepted
        })
    with pytest.raises(Exception):
        MomentUnderstandingContract.model_validate({
            "moment_id": str(uuid4()),
            "observed": {"summary": "x", "subjects": [], "events": [], "temporal_order_note": "",
                         "useful_segments": []},
            "story_context": {"story_utility": "sometimes"},  # not in enum
        })


# --------------------------------------------------------------------------
# StoryCoverage (Milestone E, FROZEN) — hybrid dimensions, nullable idea, categorical
# --------------------------------------------------------------------------


def test_story_coverage_round_trips_hybrid():
    from contracts.schemas.ai_contracts import StoryCoverageContract

    data = {
        "story_id": str(uuid4()), "moment_count": 3, "pending_count": 1,
        "source_understanding_ids": [str(uuid4()), str(uuid4())],
        "dimensions": [
            {"id": "human_scale", "label": "Human vs. Landscape Scale", "purpose": "contrast",
             "coverage": "strong", "note": "many scale shots", "evidence_moment_ids": [str(uuid4())]},
            {"id": "companionship", "label": "Companionship", "coverage": "could_use_more"},
        ],
        "strengths": ["strong landscape"], "redundancies": ["m1..m3 similar panoramas"],
        "sufficiency": {"status": "workable", "reason": "thin on people"},
        "story_idea": {"title": "A quiet human moment", "description": "...", "rationale": "..."},
    }
    c = StoryCoverageContract.model_validate(data)
    assert c.dimensions[0].coverage.value == "strong"
    assert c.sufficiency.status.value == "workable"
    again = StoryCoverageContract.model_validate_json(c.model_dump_json())
    assert again.dimensions[1].coverage.value == "could_use_more"
    assert again.story_idea.title == "A quiet human moment"


def test_story_coverage_nullable_idea_and_categorical_only():
    import pytest
    from contracts.schemas.ai_contracts import StoryCoverageContract

    c = StoryCoverageContract.model_validate({
        "story_id": str(uuid4()), "moment_count": 0,
        "dimensions": [], "strengths": [], "redundancies": [],
        "sufficiency": {"status": "insufficient"}, "story_idea": None})
    assert c.story_idea is None and c.pending_count == 0
    # coverage/sufficiency are categorical enums — a numeric score is rejected
    with pytest.raises(Exception):
        StoryCoverageContract.model_validate({
            "story_id": str(uuid4()), "moment_count": 1,
            "dimensions": [{"id": "d", "label": "L", "coverage": 0.8}],  # numeric not allowed
            "strengths": [], "redundancies": [], "sufficiency": {"status": "workable"}, "story_idea": None})


# --------------------------------------------------------------------------
# MusicPlan (Milestone M-b, FROZEN music_plan/1 — Opus 4.6)
# --------------------------------------------------------------------------


def _music_plan_payload(**overrides):
    data = {
        "schema_version": "music_plan/1",
        "story_id": str(uuid4()),
        "target_duration_seconds": 60.0,
        "character": {"mood_tags": ["warm", "intimate"], "energy": "medium"},
        "energy_arc": [
            {"label": "quiet, tentative", "start_fraction": 0.0, "end_fraction": 0.4,
             "intensity": "low", "note": "fumbling first chords"},
            {"label": "the song arrives", "start_fraction": 0.4, "end_fraction": 1.0,
             "intensity": "falling", "note": "step back so the real guitar lands"},
        ],
        "audio_strategy": {
            "soundtrack_role": "sparse",
            "native_audio_priority": "important",
            "guidance": "the real guitar performance should become the focus",
        },
        "track_selection_criteria": {
            "mood_tags": ["acoustic", "hopeful"], "energy": "medium",
            "structure_hint": "gentle build then recede",
        },
        "provenance": {
            "model_id": "us.anthropic.claude-opus-4-6-v1",
            "prompt_version": "music_plan/1",
            "inputs": ["creative_intent", "music_direction", "story_guide", "story_coverage"],
        },
    }
    data.update(overrides)
    return data


def test_music_plan_round_trips():
    from contracts.schemas.ai_contracts import MusicPlanContract

    obj = MusicPlanContract.model_validate(_music_plan_payload())
    payload = _roundtrip(MusicPlanContract, obj)
    assert payload["schema_version"] == "music_plan/1"
    # MusicDirection stays authoritative: character is a resolved snapshot only.
    assert payload["character"]["energy"] == "medium"


def test_music_plan_minimal_requires_character_and_audio_strategy():
    """Scope-sensitive: an 8s Story is ONE region; only character + arc +
    audio_strategy are required. track_selection_criteria + provenance optional."""
    from contracts.schemas.ai_contracts import MusicPlanContract

    obj = MusicPlanContract.model_validate({
        "story_id": str(uuid4()),
        "target_duration_seconds": 8.0,
        "character": {"mood_tags": ["punchy"], "energy": "high"},
        "energy_arc": [{"label": "one hit", "start_fraction": 0.0, "end_fraction": 1.0, "intensity": "high"}],
        "audio_strategy": {"soundtrack_role": "continuous", "native_audio_priority": "low"},
    })
    assert obj.track_selection_criteria is None
    assert obj.provenance is None
    assert len(obj.energy_arc) == 1  # scope-sensitive, no mechanical 4 sections


def test_music_plan_intensity_is_categorical_not_numeric():
    from contracts.schemas.ai_contracts import MusicPlanContract

    with pytest.raises(ValidationError):
        MusicPlanContract.model_validate(_music_plan_payload(
            energy_arc=[{"label": "x", "start_fraction": 0.0, "end_fraction": 1.0, "intensity": 0.8}]))


def test_music_plan_fractions_are_normalized_0_1():
    from contracts.schemas.ai_contracts import MusicPlanContract

    with pytest.raises(ValidationError):
        MusicPlanContract.model_validate(_music_plan_payload(
            energy_arc=[{"label": "x", "start_fraction": 0.0, "end_fraction": 12.0, "intensity": "high"}]))


def test_music_plan_rejects_unknown_field_no_key_moments():
    """key_moments[] was ABLATED OUT in M-b — the frozen contract forbids it,
    and extra='forbid' rejects any Moment/clip/cut leakage."""
    from contracts.schemas.ai_contracts import MusicPlanContract

    with pytest.raises(ValidationError):
        MusicPlanContract.model_validate(_music_plan_payload(
            key_moments=[{"kind": "payoff", "at_fraction": 0.75}]))
    # no Moment ids / cut points can be smuggled in either
    with pytest.raises(ValidationError):
        MusicPlanContract.model_validate(_music_plan_payload(moment_ids=[str(uuid4())]))


def test_music_plan_native_audio_strategy_vocabularies():
    from contracts.schemas.ai_contracts import MusicPlanContract

    for role in ("continuous", "supportive", "sparse"):
        for prio in ("low", "selective", "important"):
            MusicPlanContract.model_validate(_music_plan_payload(
                audio_strategy={"soundtrack_role": role, "native_audio_priority": prio}))
    with pytest.raises(ValidationError):
        MusicPlanContract.model_validate(_music_plan_payload(
            audio_strategy={"soundtrack_role": "loud", "native_audio_priority": "important"}))


def test_music_plan_schema_dropped_key_moments_and_in_sync():
    """The GENERATED canonical schema has no key_moments and matches the Pydantic model."""
    import json
    from pathlib import Path
    from contracts.generate_schema import build_ai_schema
    from contracts.schemas.ai_contracts import MusicPlanContract

    generated = build_ai_schema("MusicPlan", MusicPlanContract)
    assert "key_moments" not in generated["properties"]
    on_disk = json.loads(
        (Path(__file__).resolve().parents[1] / "schemas" / "music-plan.schema.json").read_text())
    # the committed schema must equal what the generator emits (no drift)
    assert on_disk["properties"].keys() == generated["properties"].keys()
    assert "key_moments" not in on_disk["properties"]
