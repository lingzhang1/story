"""Unit tests for the Creative Intent engine with a FAKE Model Gateway.

No network, no real model. Proves: the engine builds a schema-bearing request,
converts valid structured output into the canonical contract (server owns
id/source_inputs), and surfaces failures instead of fabricating an intent.
"""

from __future__ import annotations

import pytest

from contracts.schemas.ai_contracts import CreativeIntentContract
from creative_intent import PROMPT_VERSION, TASK, RealCreativeIntentEngine
from model_gateway import (
    FakeModelGateway,
    ProviderError,
    StructuredOutputError,
)


def test_resolve_converts_valid_output_to_canonical_contract():
    gw = FakeModelGateway(
        response={
            "summary": "A calm, contemplative morning in Kyoto.",
            "desired_feeling": ["calm", "contemplative"],
            "pace": "slow",
            "emphasis": ["atmosphere"],
        }
    )
    engine = RealCreativeIntentEngine(gw)
    intent = engine.resolve("a quiet calm morning in kyoto")

    assert isinstance(intent, CreativeIntentContract)
    assert intent.summary.startswith("A calm")
    assert intent.pace.value == "slow"
    # Server-owned fields are filled by the engine, not the model.
    assert intent.id is not None
    assert intent.raw_user_description == "a quiet calm morning in kyoto"
    assert intent.source_inputs and intent.source_inputs[0].type.value == "text"


def test_request_carries_prompt_version_task_and_schema():
    gw = FakeModelGateway(response={"summary": "x"})
    engine = RealCreativeIntentEngine(gw)
    engine.resolve("make something cool")
    req = gw.calls[0]
    assert req.task == TASK
    assert req.prompt_version == PROMPT_VERSION
    assert "summary" in req.schema["properties"]
    # Server-owned fields are not asked of the model.
    assert "id" not in req.schema["properties"]
    assert req.schema["required"] == ["summary"]


def test_underspecified_input_yields_minimal_intent_not_fabrication():
    # Model honestly returns only a summary for a vague prompt.
    gw = FakeModelGateway(response={"summary": "Something cool, details unspecified."})
    engine = RealCreativeIntentEngine(gw)
    intent = engine.resolve("make something cool here")
    assert intent.summary
    assert intent.pace is None
    assert intent.desired_feeling == []
    assert intent.emphasis == []


def test_invalid_structured_output_raises_not_fabricates():
    # Model returns a payload that violates the canonical contract (bad enum).
    gw = FakeModelGateway(response={"summary": "x", "pace": "blazing"})
    engine = RealCreativeIntentEngine(gw)
    with pytest.raises(StructuredOutputError):
        engine.resolve("fast energetic city night")


def test_provider_error_propagates():
    gw = FakeModelGateway(error=ProviderError("bedrock down"))
    engine = RealCreativeIntentEngine(gw)
    with pytest.raises(ProviderError):
        engine.resolve("anything")


def test_structured_output_error_propagates():
    gw = FakeModelGateway(error=StructuredOutputError("no tool_use"))
    engine = RealCreativeIntentEngine(gw)
    with pytest.raises(StructuredOutputError):
        engine.resolve("anything")
