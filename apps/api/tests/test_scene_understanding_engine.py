"""Unit tests for the Scene Understanding engine with a FAKE multimodal gateway.

No network, no real model. Proves: the engine builds a multimodal request
carrying the frames, converts valid structured output into the canonical
contract (server owns id), the semantic guard rejects leaked directing/safety
language, and failures surface instead of fabricating a scene.
"""

from __future__ import annotations

import pytest

from contracts.schemas.ai_contracts import SceneUnderstandingContract
from model_gateway import FakeModelGateway, ProviderError, StructuredOutputError
from scene_understanding import PROMPT_VERSION, TASK, RealSceneUnderstandingEngine

_FRAMES = [b"\xff\xd8fakejpeg1", b"\xff\xd8fakejpeg2"]


def test_analyze_converts_valid_output():
    gw = FakeModelGateway(response={
        "summary": "Open alpine trail with a large mountain backdrop and strong depth.",
        "environment_tags": ["mountain", "trail"],
        "subjects": [{"label": "hiker", "prominence": "low"}, {"label": "mountain", "prominence": "high"}],
        "operator_space": "open",
        "lighting": "bright daylight",
        "motion_opportunities": ["a person could walk along the open trail"],
        "composition_opportunities": ["trail creates a strong line toward the mountains"],
    })
    engine = RealSceneUnderstandingEngine(gw)
    scene = engine.analyze(_FRAMES)
    assert isinstance(scene, SceneUnderstandingContract)
    assert scene.operator_space.value == "open"
    assert scene.subjects[0].prominence.value == "low"
    assert scene.id is not None


def test_request_is_multimodal_and_versioned():
    gw = FakeModelGateway(response={"summary": "x"})
    engine = RealSceneUnderstandingEngine(gw)
    engine.analyze(_FRAMES)
    req = gw.calls[0]
    assert req.task == TASK
    assert req.prompt_version == PROMPT_VERSION
    assert len(req.images) == 2                      # frames passed as images
    assert req.images[0].media_type == "image/jpeg"
    assert "id" not in req.schema["properties"]      # server-owned


def test_no_frames_raises():
    engine = RealSceneUnderstandingEngine(FakeModelGateway(response={"summary": "x"}))
    with pytest.raises(StructuredOutputError):
        engine.analyze([])


def test_semantic_guard_rejects_directing_language():
    # Model leaked a shot instruction into an opportunity — must be rejected.
    gw = FakeModelGateway(response={
        "summary": "A trail.",
        "motion_opportunities": ["walk toward the ridge and hold steady"],
    })
    engine = RealSceneUnderstandingEngine(gw)
    with pytest.raises(StructuredOutputError):
        engine.analyze(_FRAMES)


def test_semantic_guard_rejects_safety_certification():
    gw = FakeModelGateway(response={
        "summary": "A ledge. It is safe to stand near the edge.",
    })
    engine = RealSceneUnderstandingEngine(gw)
    with pytest.raises(StructuredOutputError):
        engine.analyze(_FRAMES)


def test_semantic_guard_rejects_physical_property_inference():
    # Device regression: inferring weight / load-bearing from an image.
    gw = FakeModelGateway(response={
        "summary": "A red backpack on a chair.",
        "constraints": ["The chair is small and may not be able to support a lot of weight."],
    })
    engine = RealSceneUnderstandingEngine(gw)
    with pytest.raises(StructuredOutputError):
        engine.analyze(_FRAMES)


def test_semantic_guard_rejects_object_manipulation_motion():
    # Device regression: object-manipulation masquerading as a motion opportunity.
    gw = FakeModelGateway(response={
        "summary": "A room with a backpack.",
        "motion_opportunities": ["The backpack could be moved to another location."],
    })
    engine = RealSceneUnderstandingEngine(gw)
    with pytest.raises(StructuredOutputError):
        engine.analyze(_FRAMES)


def test_invalid_output_raises_not_fabricates():
    gw = FakeModelGateway(response={"summary": "x", "operator_space": "cramped"})  # bad enum
    engine = RealSceneUnderstandingEngine(gw)
    with pytest.raises(StructuredOutputError):
        engine.analyze(_FRAMES)


def test_provider_error_propagates():
    gw = FakeModelGateway(error=ProviderError("bedrock down"))
    engine = RealSceneUnderstandingEngine(gw)
    with pytest.raises(ProviderError):
        engine.analyze(_FRAMES)
