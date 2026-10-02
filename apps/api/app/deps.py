"""Dependency injection seam for the Story API.

The application depends on engine INTERFACES (Protocols), never on the
concrete Mock classes. These provider functions are the single place a
real AI engine gets swapped in for a mock — via FastAPI dependency
overrides in tests, or by editing these providers when real engines land.

Return TYPES are the Protocols; return VALUES are the Milestone A mocks.
"""

from __future__ import annotations

import os

from director_engine import DirectorEngine, MockDirectorEngine
from edit_engine import EditEngine, MockEditEngine
from story_engine import MockStoryEngine, StoryEngine
from model_gateway import BedrockModelGateway, ModelGateway
from creative_intent import (
    CreativeIntentEngine,
    MockCreativeIntentEngine,
    RealCreativeIntentEngine,
)
from scene_understanding import (
    MockSceneUnderstandingEngine,
    RealSceneUnderstandingEngine,
    SceneUnderstandingEngine,
)


def get_story_engine() -> StoryEngine:
    """Provide the StoryEngine implementation (mock for Milestone A)."""
    return MockStoryEngine()


def get_director_engine() -> DirectorEngine:
    """Provide the DirectorEngine implementation (mock for Milestone A)."""
    return MockDirectorEngine()


def get_edit_engine() -> EditEngine:
    """Provide the EditEngine implementation (mock for Milestone A)."""
    return MockEditEngine()


def get_model_gateway() -> ModelGateway:
    """Provide the Model Gateway. ONE provider for C1 (Bedrock), config-driven
    via env (STORY_BEDROCK_MODEL / STORY_AWS_REGION)."""
    return BedrockModelGateway()


def get_creative_intent_engine() -> CreativeIntentEngine:
    """Provide the Creative Intent resolver.

    Real (model-backed) by default. Set STORY_CREATIVE_INTENT_MOCK=1 to use the
    deterministic mock (dev/offline) — the mock is NEVER a silent production
    fallback; it is only selected explicitly here.
    """
    if os.environ.get("STORY_CREATIVE_INTENT_MOCK") == "1":
        return MockCreativeIntentEngine()
    return RealCreativeIntentEngine(get_model_gateway())


def get_scene_understanding_engine() -> SceneUnderstandingEngine:
    """Provide the Scene Understanding analyzer.

    Task-specific, config-driven VISION model (STORY_SCENE_MODEL), separate from
    the Creative Intent model (Creative Intent model != Scene Understanding model).
    Default amazon.nova-pro-v1:0 — on-demand-invocable, image-capable, no Anthropic
    form gate. Set STORY_SCENE_UNDERSTANDING_MOCK=1 for the dev/offline mock (never
    a silent production fallback).
    """
    if os.environ.get("STORY_SCENE_UNDERSTANDING_MOCK") == "1":
        return MockSceneUnderstandingEngine()
    model = os.environ.get("STORY_SCENE_MODEL", "amazon.nova-pro-v1:0")
    return RealSceneUnderstandingEngine(BedrockModelGateway(model_id=model))
