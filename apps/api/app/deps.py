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
from story_director import (
    MockStoryDirectorEngine,
    RealStoryDirectorEngine,
    StoryDirectorEngine,
)
from asset_engine import (
    AssetUnderstandingEngine,
    DEFAULT_AU_MODEL,
    MockAssetUnderstandingEngine,
    RealAssetUnderstandingEngine,
)
from story_coverage import (
    StoryCoverageEngine,
    DEFAULT_COVERAGE_MODEL,
    MockStoryCoverageEngine,
    RealStoryCoverageEngine,
)
from story_guide import (
    StoryGuideEngine,
    DEFAULT_GUIDE_MODEL,
    MockStoryGuideEngine,
    RealStoryGuideEngine,
)
from story_coverage_v2 import (
    DEFAULT_COVERAGE_MODEL as DEFAULT_COVERAGE_V2_MODEL,
    RealStoryCoverageV2Engine,
    StoryCoverageV2Engine,
)
from music_direction import (
    DeterministicMusicDirectionEngine,
    MusicDirectionEngine,
)
from edit_planner import (
    EditPlannerEngine,
    MODEL_ID as EDIT_PLANNER_MODEL,
    RealEditPlannerEngine,
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


def get_story_director_engine() -> StoryDirectorEngine:
    """Provide the Story Director — the most intelligence-sensitive component.

    Task-specific, config-driven model (STORY_DIRECTOR_MODEL), independent of the
    Creative Intent / Scene Understanding / Shot Validation models. Default
    amazon.nova-pro-v1:0 (on-demand-invocable, no Anthropic use-case gate; passed
    the C3A offline quality gate). Switch to a Claude id via STORY_DIRECTOR_MODEL
    once the account's Anthropic use-case form is confirmed — config, no code change.
    Set STORY_DIRECTOR_MOCK=1 for the dev/offline mock (never a silent fallback).
    """
    if os.environ.get("STORY_DIRECTOR_MOCK") == "1":
        return MockStoryDirectorEngine()
    model = os.environ.get("STORY_DIRECTOR_MODEL", "us.anthropic.claude-opus-4-5-20251101-v1:0")
    return RealStoryDirectorEngine(BedrockModelGateway(model_id=model))


def get_asset_understanding_engine() -> AssetUnderstandingEngine:
    """Provide the Asset Understanding analyzer (Milestone D, FROZEN).

    ONE model, config-driven via STORY_AU_MODEL (default us.anthropic.claude-sonnet-4-6 —
    the frozen production AU model). NO routing/escalation/native-video. Set
    STORY_ASSET_UNDERSTANDING_MOCK=1 for the dev/offline mock (never a silent fallback).
    """
    if os.environ.get("STORY_ASSET_UNDERSTANDING_MOCK") == "1":
        return MockAssetUnderstandingEngine()
    model = os.environ.get("STORY_AU_MODEL", DEFAULT_AU_MODEL)
    return RealAssetUnderstandingEngine(BedrockModelGateway(model_id=model), model_id=model)


def get_story_coverage_engine() -> StoryCoverageEngine:
    """Provide the Story Coverage engine (Milestone E, FROZEN).

    ONE model, config-driven via STORY_COVERAGE_MODEL (default us.anthropic.claude-opus-4-6-v1 —
    the experiment winner: uniquely avoided false-sufficient AND false-insufficient while missing
    zero worthwhile ideas). NO Nova/Sonnet fallback, NO routing. Set STORY_COVERAGE_MOCK=1 for the
    dev/offline mock (never a silent production fallback).
    """
    if os.environ.get("STORY_COVERAGE_MOCK") == "1":
        return MockStoryCoverageEngine()
    model = os.environ.get("STORY_COVERAGE_MODEL", DEFAULT_COVERAGE_MODEL)
    return RealStoryCoverageEngine(BedrockModelGateway(model_id=model), model_id=model)


def get_story_guide_engine() -> StoryGuideEngine:
    """Provide the Story Guide engine (Milestone E2-a, FROZEN).

    CreativeIntent -> persistent StoryGuide, ONCE per Story. ONE model, config-driven via
    STORY_GUIDE_MODEL (default us.anthropic.claude-opus-4-6-v1 — the E2-a selection: restraint +
    scope discipline + framing voice; task-specific, NOT a general Opus rule). Set STORY_GUIDE_MOCK=1
    for the dev/offline mock (never a silent production fallback — Guide failure preserves CreativeIntent).
    """
    if os.environ.get("STORY_GUIDE_MOCK") == "1":
        return MockStoryGuideEngine()
    model = os.environ.get("STORY_GUIDE_MODEL", DEFAULT_GUIDE_MODEL)
    return RealStoryGuideEngine(BedrockModelGateway(model_id=model), model_id=model)


def get_story_coverage_v2_engine() -> StoryCoverageV2Engine:
    """Provide the StoryCoverage/2 engine (Milestone E2-b, FROZEN).

    Composes the internal two-call pipeline (Mapper story_coverage/mapper-v1 + Judge
    story_judgment/v2) into the public StoryCoverageContractV2. ONE model, config-driven via
    STORY_COVERAGE_MODEL (default us.anthropic.claude-opus-4-6-v1) for BOTH internal calls. The
    deterministic evidence builder firewalls Guide/completion signals away from the Judge.
    """
    model = os.environ.get("STORY_COVERAGE_MODEL", DEFAULT_COVERAGE_V2_MODEL)
    return RealStoryCoverageV2Engine(BedrockModelGateway(model_id=model), model_id=model)


def get_music_direction_engine() -> MusicDirectionEngine:
    """Provide the MusicDirection inference engine (Milestone M-c).

    DETERMINISTIC — no model call. Projects the already-resolved CreativeIntent
    (+ optional StoryGuide.framing_summary) into the intended soundtrack character.
    No STORY_*_MODEL env var and no gateway: inference is a cheap categorical
    projection, not a second model surface (M-c owner decision).
    """
    return DeterministicMusicDirectionEngine()


def get_edit_planner_engine() -> EditPlannerEngine:
    """Provide the production Edit Planner engine (Milestone M-d, frozen edit_plan/2).

    One Opus 4.6 call via the generic ModelGateway + the frozen prompt edit_plan/2, under a DETERMINISTIC
    validator (the model never self-certifies). Model is config-driven (STORY_EDIT_PLANNER_MODEL) but defaults
    to the frozen us.anthropic.claude-opus-4-6-v1. Music inputs are optional (no-music planning supported).
    """
    model = os.environ.get("STORY_EDIT_PLANNER_MODEL", EDIT_PLANNER_MODEL)
    return RealEditPlannerEngine(BedrockModelGateway(model_id=model))
