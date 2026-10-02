"""Scene Understanding Engine — the real multimodal scene analyzer (Milestone C2).

Owns (milestone-c-scene-understanding-design.md §6-8; task):
  - the versioned Scene Understanding prompt (prompts/scene_understanding/<ver>/)
  - the structured-output schema (the canonical SceneUnderstanding contract)
  - multimodal structured-request construction (text + representative frames)
  - a light semantic post-validator (no shot/edit/intent/safety-cert language)
  - conversion of model output into the canonical SceneUnderstandingContract
  - task-level failure behaviour (never fabricate a scene)

It does NOT own provider SDKs / image message mechanics / timeouts — those are
the Model Gateway's. Depends only on contracts + model_gateway (03 §40).

Scene Understanding describes OBSERVABLE REALITY only. It must not infer intent,
plan shots, direct the user, edit, or certify safety (04-scene-understanding.md
§23; prompt enforces this; the post-validator is a backstop).
"""

from __future__ import annotations

from pathlib import Path
from typing import Protocol, runtime_checkable
from uuid import uuid4

from contracts.schemas.ai_contracts import SceneUnderstandingContract
from model_gateway import (
    ImageInput,
    ModelGateway,
    StructuredOutputError,
    StructuredRequest,
    StructuredResult,
)

PROMPT_VERSION = "scene_understanding/v1"
SCHEMA_VERSION = "scene_understanding.schema/1"
TASK = "scene_understanding.analyze"

_PROMPT_DIR = (
    Path(__file__).resolve().parent.parent.parent / "prompts" / "scene_understanding" / "v1"
)

# Phrases that indicate the model leaked a Director/Edit/safety responsibility
# into Scene Understanding. Backstop only — the prompt is the primary guard.
_FORBIDDEN_SUBSTRINGS = (
    "safe to ",
    "you should ",
    "walk toward",
    "walk backward",
    "pan across",
    "cut to",
    "cut on",
    "zoom in on",
)


def _load_system_prompt() -> str:
    return (_PROMPT_DIR / "system.md").read_text()


def _tool_schema() -> dict:
    """JSON Schema the model output must satisfy — the canonical SceneUnderstanding
    contract minus server-assigned fields (id/created_at set by us, not the model)."""
    schema = SceneUnderstandingContract.model_json_schema()
    props = dict(schema.get("properties", {}))
    for server_field in ("id", "created_at"):
        props.pop(server_field, None)
    schema["properties"] = props
    schema["required"] = ["summary"]
    schema["additionalProperties"] = False
    return schema


@runtime_checkable
class SceneUnderstandingEngine(Protocol):
    def analyze(self, frames: list[bytes], media_type: str = "image/jpeg") -> SceneUnderstandingContract:
        """Analyze representative scan frames into a canonical SceneUnderstanding.
        Raises StructuredOutputError / ProviderError — callers return a designed
        failure, never a fabricated scene."""
        ...


class RealSceneUnderstandingEngine:
    """Model-backed multimodal analyzer. Config-driven provider via the gateway."""

    def __init__(self, gateway: ModelGateway, max_repair_attempts: int = 1):
        self._gateway = gateway
        self._system = _load_system_prompt()
        self._schema = _tool_schema()
        self._max_repair_attempts = max_repair_attempts

    def build_request(self, frames: list[bytes], media_type: str = "image/jpeg") -> StructuredRequest:
        return StructuredRequest(
            task=TASK,
            schema=self._schema,
            prompt_version=PROMPT_VERSION,
            system=self._system,
            user_content=(
                f"These {len(frames)} frames are different viewpoints from one short "
                "scan of the same place. Describe the single observable scene for a "
                "video director. Call the tool once."
            ),
            images=[ImageInput(data=f, media_type=media_type) for f in frames],
            max_repair_attempts=self._max_repair_attempts,
            max_tokens=900,
            temperature=0.0,
        )

    def analyze(self, frames: list[bytes], media_type: str = "image/jpeg") -> SceneUnderstandingContract:
        if not frames:
            raise StructuredOutputError("no frames provided")
        req = self.build_request(frames, media_type)
        result: StructuredResult = self._gateway.generate_structured(req)
        return self._to_contract(result)

    def _to_contract(self, result: StructuredResult) -> SceneUnderstandingContract:
        data = dict(result.data)
        data["id"] = str(uuid4())
        try:
            scene = SceneUnderstandingContract.model_validate(data)
        except Exception as e:
            raise StructuredOutputError(
                f"model output failed canonical SceneUnderstanding validation: {e}"
            ) from e
        self._semantic_guard(scene)
        return scene

    @staticmethod
    def _semantic_guard(scene: SceneUnderstandingContract) -> None:
        """Backstop: reject output that leaked directing/editing/safety language."""
        blob = " ".join(
            [scene.summary]
            + scene.motion_opportunities
            + scene.composition_opportunities
            + scene.constraints
        ).lower()
        hit = next((s for s in _FORBIDDEN_SUBSTRINGS if s in blob), None)
        if hit is not None:
            raise StructuredOutputError(
                f"scene output leaked a non-observational phrase ({hit!r}); "
                "Scene Understanding must describe observable reality only"
            )


class MockSceneUnderstandingEngine:
    """Deterministic mock (no model). Dev/tests only — never a production scene."""

    def analyze(self, frames: list[bytes], media_type: str = "image/jpeg") -> SceneUnderstandingContract:
        return SceneUnderstandingContract(
            id=uuid4(),
            summary=f"A scanned environment ({len(frames)} frames). Mock scene — no analysis.",
            environment_tags=["unanalyzed"],
        )


__all__ = [
    "PROMPT_VERSION",
    "SCHEMA_VERSION",
    "TASK",
    "SceneUnderstandingEngine",
    "RealSceneUnderstandingEngine",
    "MockSceneUnderstandingEngine",
]
