"""Story Guide engine — the persistent long-horizon creative map (Milestone E2-a, FROZEN).

CreativeIntent -> StoryGuide, generated ONCE at Story creation, BEFORE any Moment exists.
ONE model (Opus 4.6, config-driven), frozen prompt story_guide/v1, frozen contract story_guide/1.
No MomentUnderstanding required; a zero-Moment Story has a complete Guide.

Owns: the versioned Guide prompt, the structured-output schema (StoryGuide minus server-minted
provenance), and SERVER/DOMAIN MINTING of canonical stable ids over the model's ordinal handles
(d1 -> dim_01, d1p1 -> dim_01_cp_01). The model's ids are NEVER canonical. On failure it raises so
Story creation is NOT lost and NO generic Guide is fabricated.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol, runtime_checkable
from uuid import UUID

from contracts.schemas.ai_contracts import StoryGuideContract
from model_gateway import (
    ModelGateway,
    ProviderError,
    StructuredOutputError,
    StructuredRequest,
    StructuredResult,
)

PROMPT_VERSION = "story_guide/v1"
SCHEMA_VERSION = "story_guide/1"
TASK = "story_guide.generate"
DEFAULT_GUIDE_MODEL = "us.anthropic.claude-opus-4-6-v1"  # frozen E2-a selection (restraint + framing)
GUIDE_MAX_TOKENS = 2000
GUIDE_TEMPERATURE = 0.0

_PROMPT_DIR = Path(__file__).resolve().parent.parent.parent / "prompts" / "story_guide" / "v1"


def _load_system_prompt() -> str:
    return (_PROMPT_DIR / "system.md").read_text()


def _tool_schema() -> dict:
    """Model-output schema: the StoryGuide the model emits with ORDINAL ids (the engine mints
    canonical ids afterward). Server fields (schema_version/story_id/generated_at/source_*) stripped."""
    return {
        "type": "object", "additionalProperties": False,
        "properties": {
            "framing_summary": {"type": "string"},
            "dimensions": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "properties": {
                    "id": {"type": "string"},
                    "label": {"type": "string"},
                    "purpose": {"type": "string"},
                    "capture_possibilities": {"type": "array", "items": {
                        "type": "object", "additionalProperties": False,
                        "properties": {
                            "id": {"type": "string"},
                            "label": {"type": "string"},
                            "semantic_purpose": {"type": "string"},
                        },
                        "required": ["id", "label"]}},
                },
                "required": ["id", "label", "purpose", "capture_possibilities"]}},
        },
        "required": ["framing_summary", "dimensions"],
    }


@dataclass
class GuideInput:
    """Inputs for ONE Guide generation. Guide is a function of CreativeIntent + scope ONLY."""

    story_id: UUID
    creative_intent: dict[str, Any]
    scope: dict[str, Any]                       # {target_duration_seconds?, format?}
    source_creative_intent_version: str | None = None


class GuideUnavailableError(RuntimeError):
    """Raised when the Guide could not be generated (model/provider/validation failure). The caller
    MUST preserve CreativeIntent and let the Story exist Guide-less + retryable — never fabricate."""


@runtime_checkable
class StoryGuideEngine(Protocol):
    def generate(self, inp: GuideInput) -> StoryGuideContract: ...


class RealStoryGuideEngine:
    def __init__(self, gateway: ModelGateway, model_id: str | None = None):
        self._gateway = gateway
        self._model_id = model_id or DEFAULT_GUIDE_MODEL
        self._system = _load_system_prompt()
        self._schema = _tool_schema()

    def build_request(self, inp: GuideInput) -> StructuredRequest:
        import json as _json
        payload = {"creative_intent": inp.creative_intent, "scope": inp.scope}
        user = ("Produce the StoryGuide for THIS Story.\n\nCREATIVE INTENT + SCOPE:\n"
                + _json.dumps(payload)
                + "\n\nScale the map to scope, use this Story's own domain vocabulary, honor explicit "
                  "constraints, keep capture_possibilities as a few examples. Return ONLY the StoryGuide.")
        return StructuredRequest(
            task=TASK, schema=self._schema, prompt_version=PROMPT_VERSION, system=self._system,
            user_content=user, max_repair_attempts=2,
            max_tokens=GUIDE_MAX_TOKENS, temperature=GUIDE_TEMPERATURE,
        )

    def generate(self, inp: GuideInput) -> StoryGuideContract:
        req = self.build_request(inp)
        try:
            result: StructuredResult = self._gateway.generate_structured(req)
        except (StructuredOutputError, ProviderError) as e:
            raise GuideUnavailableError(
                f"story guide unavailable ({type(e).__name__}: {e}); preserve CreativeIntent + retry"
            ) from e
        return self._to_contract(result, inp)

    @staticmethod
    def mint_ids(data: dict[str, Any]) -> dict[str, Any]:
        """Server-mint canonical stable ids over the model's ordinal handles. Coverage references
        these ids; the model's own ids are discarded."""
        out: dict[str, Any] = {"framing_summary": data.get("framing_summary", ""), "dimensions": []}
        for i, d in enumerate(data.get("dimensions", []), 1):
            if not isinstance(d, dict):
                continue
            dim_id = f"dim_{i:02d}"
            dim: dict[str, Any] = {"id": dim_id, "label": d.get("label", ""),
                                   "purpose": d.get("purpose", ""), "capture_possibilities": []}
            for j, p in enumerate(d.get("capture_possibilities", []) or [], 1):
                if not isinstance(p, dict):
                    continue
                cp: dict[str, Any] = {"id": f"{dim_id}_cp_{j:02d}", "label": p.get("label", "")}
                if p.get("semantic_purpose"):
                    cp["semantic_purpose"] = p["semantic_purpose"]
                dim["capture_possibilities"].append(cp)
            out["dimensions"].append(dim)
        return out

    def _to_contract(self, result: StructuredResult, inp: GuideInput) -> StoryGuideContract:
        data = self.mint_ids(dict(result.data))
        data["schema_version"] = SCHEMA_VERSION
        data["story_id"] = str(inp.story_id)
        if inp.source_creative_intent_version:
            data["source_creative_intent_version"] = inp.source_creative_intent_version
        try:
            return StoryGuideContract.model_validate(data)
        except Exception as e:
            raise GuideUnavailableError(
                f"model output failed canonical StoryGuide validation: {e}"
            ) from e


class MockStoryGuideEngine:
    """Deterministic mock (no model). Dev/tests only — never a production Guide."""

    def generate(self, inp: GuideInput) -> StoryGuideContract:
        from contracts.schemas.ai_contracts import StoryGuideDimension, CapturePossibility
        return StoryGuideContract(
            story_id=inp.story_id,
            framing_summary="For this Story: a mock creative map.",
            dimensions=[StoryGuideDimension(
                id="dim_01", label="Mock Dimension", purpose="placeholder purpose",
                capture_possibilities=[CapturePossibility(id="dim_01_cp_01", label="an example")],
            )],
        )


# ===========================================================================
# StoryGuide/2 — the AI SHOOTING SCRIPT (additive, versioned; 2026-10-23).
#
# Same engine SHAPE as v1 (build_request -> gateway -> server-mint stable ids ->
# validate), but produces story_guide/2 (scenes, not dimensions) via prompt
# story_guide/v2. Fully separate from the FROZEN v1 engine above — v1 is never
# touched. The model emits ordinal handles (s1/s1p1); the engine mints canonical
# scene ids (scene_01 / scene_01_cp_01) that StoryCoverage/2 keys STATE on exactly
# like a v1 dimension id. The model NEVER emits image ids/urls/attribution — the
# only image field is the generic `visual_reference_query` text; real provider
# metadata is attached SEPARATELY, server-side, after retrieval.
# ===========================================================================

from contracts.schemas.ai_contracts import StoryGuideV2Contract  # noqa: E402

PROMPT_VERSION_V2 = "story_guide/v2"
SCHEMA_VERSION_V2 = "story_guide/2"
TASK_V2 = "story_guide.generate_v2"
GUIDE_V2_MAX_TOKENS = 3000  # scenes carry more prose than v1 dimensions
GUIDE_V2_TEMPERATURE = 0.3   # a little warmth/variety in the director voice; still bounded

_PROMPT_DIR_V2 = Path(__file__).resolve().parent.parent.parent / "prompts" / "story_guide" / "v2"


def _load_system_prompt_v2() -> str:
    return (_PROMPT_DIR_V2 / "system.md").read_text()


def _tool_schema_v2() -> dict:
    """Model-output schema: the shooting script the model emits with ORDINAL ids (the engine mints
    canonical ids afterward). Server fields (schema_version/story_id/generated_at/source_*) stripped."""
    return {
        "type": "object", "additionalProperties": False,
        "properties": {
            "framing_summary": {"type": "string"},
            "scenes": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "properties": {
                    "id": {"type": "string"},
                    "title": {"type": "string"},
                    "what_to_capture": {"type": "string"},
                    "how_to_shoot": {"type": "string"},
                    "why_it_matters": {"type": "string"},
                    "visual_reference_query": {"type": "string"},
                    "capture_possibilities": {"type": "array", "items": {
                        "type": "object", "additionalProperties": False,
                        "properties": {
                            "id": {"type": "string"},
                            "label": {"type": "string"},
                            "semantic_purpose": {"type": "string"},
                        },
                        "required": ["id", "label"]}},
                },
                "required": ["id", "title", "what_to_capture", "how_to_shoot", "why_it_matters"]}},
        },
        "required": ["framing_summary", "scenes"],
    }


class RealStoryGuideV2Engine:
    """story_guide/2 engine. Mirrors RealStoryGuideEngine; emits a scene-based shooting script."""

    def __init__(self, gateway: ModelGateway, model_id: str | None = None):
        self._gateway = gateway
        self._model_id = model_id or DEFAULT_GUIDE_MODEL
        self._system = _load_system_prompt_v2()
        self._schema = _tool_schema_v2()

    def build_request(self, inp: GuideInput) -> StructuredRequest:
        import json as _json
        payload = {"creative_intent": inp.creative_intent, "scope": inp.scope}
        user = ("Produce the shooting script for THIS Story.\n\nCREATIVE INTENT + SCOPE:\n"
                + _json.dumps(payload)
                + "\n\nScale the number of scenes to scope, use THIS event's own arc and vocabulary, honor "
                  "explicit constraints, and keep each scene concrete and event-specific. If the context is "
                  "too thin to personalize honestly, give 1-2 gentle general scenes and invite more detail — "
                  "never fabricate specifics. Return ONLY the shooting script.")
        return StructuredRequest(
            task=TASK_V2, schema=self._schema, prompt_version=PROMPT_VERSION_V2, system=self._system,
            user_content=user, max_repair_attempts=2,
            max_tokens=GUIDE_V2_MAX_TOKENS, temperature=GUIDE_V2_TEMPERATURE,
        )

    def generate(self, inp: GuideInput) -> StoryGuideV2Contract:
        req = self.build_request(inp)
        try:
            result: StructuredResult = self._gateway.generate_structured(req)
        except (StructuredOutputError, ProviderError) as e:
            raise GuideUnavailableError(
                f"story guide v2 unavailable ({type(e).__name__}: {e}); preserve CreativeIntent + retry"
            ) from e
        return self._to_contract(result, inp)

    @staticmethod
    def mint_ids(data: dict[str, Any]) -> dict[str, Any]:
        """Server-mint canonical stable scene/possibility ids over the model's ordinal handles.
        Coverage references these ids; the model's own ids are discarded. Scenes with no title are
        skipped (an empty scene is not a scene)."""
        out: dict[str, Any] = {"framing_summary": data.get("framing_summary", ""), "scenes": []}
        for i, s in enumerate(data.get("scenes", []), 1):
            if not isinstance(s, dict):
                continue
            scene_id = f"scene_{i:02d}"
            scene: dict[str, Any] = {
                "id": scene_id,
                "title": s.get("title", ""),
                "what_to_capture": s.get("what_to_capture", ""),
                "how_to_shoot": s.get("how_to_shoot", ""),
                "why_it_matters": s.get("why_it_matters", ""),
                "capture_possibilities": [],
            }
            q = s.get("visual_reference_query")
            if isinstance(q, str) and q.strip():
                scene["visual_reference_query"] = q.strip()
            for j, p in enumerate(s.get("capture_possibilities", []) or [], 1):
                if not isinstance(p, dict):
                    continue
                cp: dict[str, Any] = {"id": f"{scene_id}_cp_{j:02d}", "label": p.get("label", "")}
                if p.get("semantic_purpose"):
                    cp["semantic_purpose"] = p["semantic_purpose"]
                scene["capture_possibilities"].append(cp)
            out["scenes"].append(scene)
        return out

    def _to_contract(self, result: StructuredResult, inp: GuideInput) -> StoryGuideV2Contract:
        data = self.mint_ids(dict(result.data))
        data["schema_version"] = SCHEMA_VERSION_V2
        data["story_id"] = str(inp.story_id)
        if inp.source_creative_intent_version:
            data["source_creative_intent_version"] = inp.source_creative_intent_version
        try:
            return StoryGuideV2Contract.model_validate(data)
        except Exception as e:
            raise GuideUnavailableError(
                f"model output failed canonical StoryGuide/2 validation: {e}"
            ) from e


class MockStoryGuideV2Engine:
    """Deterministic mock (no model). Dev/tests only — never a production Guide."""

    def generate(self, inp: GuideInput) -> StoryGuideV2Contract:
        from contracts.schemas.ai_contracts import StoryGuideScene, SceneCapturePossibility
        return StoryGuideV2Contract(
            story_id=inp.story_id,
            framing_summary="For this Story: a mock shooting script.",
            scenes=[StoryGuideScene(
                id="scene_01", title="Mock Scene",
                what_to_capture="an example filming opportunity",
                how_to_shoot="hold a steady wide shot for a few seconds",
                why_it_matters="it sets the scene",
                visual_reference_query="wide establishing shot example",
                capture_possibilities=[SceneCapturePossibility(id="scene_01_cp_01", label="an example")],
            )],
        )


__all__ = [
    "PROMPT_VERSION", "SCHEMA_VERSION", "TASK", "DEFAULT_GUIDE_MODEL",
    "GuideInput", "GuideUnavailableError",
    "StoryGuideEngine", "RealStoryGuideEngine", "MockStoryGuideEngine",
    # story_guide/2 (shooting script)
    "PROMPT_VERSION_V2", "SCHEMA_VERSION_V2", "TASK_V2",
    "RealStoryGuideV2Engine", "MockStoryGuideV2Engine",
]
