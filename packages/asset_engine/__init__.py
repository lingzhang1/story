"""Asset Understanding Engine — MVP Moment analyzer (Milestone D, FROZEN).

Design: 06-asset-understanding.md (FROZEN 2026-10-05). Produces the canonical
MomentUnderstanding from a 24-frame ORDERED timestamped timeline via the generic
ModelGateway. ONE model (Sonnet 4.6, config-driven), NO routing/escalation, NO
native video. Reuses the exact four-layer contract and the gateway tool-use path
the C-series engines use.

Owns:
  - the versioned AU prompt (prompts/asset_understanding/<ver>/)
  - the structured-output schema (the canonical MomentUnderstanding contract)
  - multimodal request construction (24 timestamped image blocks + context text)
  - the FROZEN retry policy (§5): one OUTER retry on malformed/truncated/provider
    failure, same model/evidence/prompt; second failure -> typed retryable failure;
    NEVER fall back to Opus/Nova, never route.
  - conversion of model output into MomentUnderstandingContract (server mints
    provenance/version fields; model never supplies them)

Does NOT own provider SDKs / image mechanics / timeouts — those are the gateway's.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol, runtime_checkable
from uuid import UUID, uuid4

from contracts.schemas.ai_contracts import MomentUnderstandingContract
from model_gateway import (
    ImageInput,
    ModelGateway,
    ProviderError,
    StructuredOutputError,
    StructuredRequest,
    StructuredResult,
)

PROMPT_VERSION = "au_prompt/1"
SCHEMA_VERSION = "moment_understanding/1"
FRAME_POLICY = "au_frames/1"
TASK = "asset_understanding.analyze"

# FROZEN model/inference config (06 §4). Config-driven id; default is the frozen
# production model. max_tokens 2400 removes the long-clip truncation failure.
DEFAULT_AU_MODEL = "us.anthropic.claude-sonnet-4-6"
AU_MAX_TOKENS = 2400
AU_TEMPERATURE = 0.0
EXPECTED_FRAMES = 24


@dataclass
class AUFrame:
    """One ordered evidence frame: JPEG bytes + its timestamp in the clip (ms)."""

    data: bytes
    t_ms: int


@dataclass
class CaptureContext:
    """Optional requested Shot/Beat context. Absent for spontaneous/imported Moments —
    the engine then leaves requested_shot/beat_contribution null (never fabricated)."""

    shot: dict | None = None
    beat: dict | None = None


@dataclass
class AURequestMeta:
    """Non-evidence inputs for one AU job."""

    moment_id: UUID
    source_capture_id: UUID | None = None
    capture_context: CaptureContext | None = None


@dataclass
class AUResult:
    understanding: MomentUnderstandingContract
    attempts: int
    retried: bool
    usage_input_tokens: int | None = None
    usage_output_tokens: int | None = None
    model: str | None = None


class AURetryableError(RuntimeError):
    """Raised after the single frozen retry is exhausted (§5). The caller leaves
    the AU job PENDING/retryable — it NEVER falls back to another model."""


_PROMPT_DIR = Path(__file__).resolve().parent.parent.parent / "prompts" / "asset_understanding" / "v1"


def _load_system_prompt() -> str:
    return (_PROMPT_DIR / "system.md").read_text()


def _tool_schema() -> dict:
    """JSON Schema the model output must satisfy — the canonical MomentUnderstanding
    contract minus server-assigned fields (ids/versions/provenance set by us)."""
    schema = MomentUnderstandingContract.model_json_schema()
    props = dict(schema.get("properties", {}))
    for server_field in (
        "moment_id", "source_capture_id", "schema_version", "frame_policy",
        "prompt_version", "model_id", "n_frames", "created_at",
    ):
        props.pop(server_field, None)
    schema["properties"] = props
    schema["required"] = ["observed", "story_context"]
    schema["additionalProperties"] = False
    return schema


@runtime_checkable
class AssetUnderstandingEngine(Protocol):
    def analyze(self, frames: list[AUFrame], meta: AURequestMeta) -> AUResult:
        """Analyze a 24-frame ordered timeline into a canonical MomentUnderstanding.
        Applies the frozen one-retry policy; raises AURetryableError when exhausted."""
        ...


class RealAssetUnderstandingEngine:
    """Model-backed AU analyzer. Config-driven provider via the gateway. The frozen
    single OUTER retry wraps the gateway call; the gateway's own in-call tool-use
    repair stays at the default (1) — the two are complementary."""

    def __init__(self, gateway: ModelGateway, model_id: str | None = None):
        self._gateway = gateway
        self._model_id = model_id or DEFAULT_AU_MODEL
        self._system = _load_system_prompt()
        self._schema = _tool_schema()

    def build_request(self, frames: list[AUFrame], meta: AURequestMeta) -> StructuredRequest:
        stamps = ", ".join(f"frame{i}@{f.t_ms}ms" for i, f in enumerate(frames))
        ctx = meta.capture_context
        ctx_line = ""
        if ctx is not None and (ctx.shot is not None or ctx.beat is not None):
            import json as _json
            ctx_line = "capture_context=" + _json.dumps({"shot": ctx.shot, "beat": ctx.beat}) + "\n"
        user_content = (
            f"These {len(frames)} frames are ordered samples across ONE captured Moment. "
            f"Ordered frames: {stamps}\n{ctx_line}"
            "Produce the structured MomentUnderstanding. Call the tool once."
        )
        return StructuredRequest(
            task=TASK,
            schema=self._schema,
            prompt_version=PROMPT_VERSION,
            system=self._system,
            user_content=user_content,
            images=[ImageInput(data=f.data, media_type="image/jpeg") for f in frames],
            max_repair_attempts=1,
            max_tokens=AU_MAX_TOKENS,
            temperature=AU_TEMPERATURE,
        )

    def analyze(self, frames: list[AUFrame], meta: AURequestMeta) -> AUResult:
        if not frames:
            raise AURetryableError("no frames provided")
        req = self.build_request(frames, meta)

        # FROZEN §5: one OUTER retry on malformed/truncated/provider failure.
        last_err: Exception | None = None
        for outer in range(2):  # attempt 1 + one retry
            try:
                result: StructuredResult = self._gateway.generate_structured(req)
                understanding = self._to_contract(result, frames, meta)
                return AUResult(
                    understanding=understanding,
                    attempts=outer + 1,
                    retried=outer > 0,
                    usage_input_tokens=(result.usage.input_tokens if result.usage else None),
                    usage_output_tokens=(result.usage.output_tokens if result.usage else None),
                    model=result.model or self._model_id,
                )
            except (StructuredOutputError, ProviderError) as e:
                last_err = e
                continue  # retry once; NO model fallback, NO routing
        raise AURetryableError(
            f"AU failed after one retry (no fallback by design): {type(last_err).__name__}: {last_err}"
        )

    def _to_contract(
        self, result: StructuredResult, frames: list[AUFrame], meta: AURequestMeta
    ) -> MomentUnderstandingContract:
        data = dict(result.data)
        # Server mints provenance/version/id fields — the model never supplies them.
        data["moment_id"] = str(meta.moment_id)
        data["source_capture_id"] = str(meta.source_capture_id) if meta.source_capture_id else None
        data["schema_version"] = SCHEMA_VERSION
        data["frame_policy"] = FRAME_POLICY
        data["prompt_version"] = PROMPT_VERSION
        data["model_id"] = result.model or self._model_id
        data["n_frames"] = len(frames)
        # If no capture context, strip any model-supplied requested contributions.
        has_ctx = bool(
            meta.capture_context
            and (meta.capture_context.shot is not None or meta.capture_context.beat is not None)
        )
        if not has_ctx and isinstance(data.get("story_context"), dict):
            data["story_context"]["requested_shot_contribution"] = None
            data["story_context"]["requested_beat_contribution"] = None
        try:
            return MomentUnderstandingContract.model_validate(data)
        except Exception as e:
            raise StructuredOutputError(
                f"model output failed canonical MomentUnderstanding validation: {e}"
            ) from e


class MockAssetUnderstandingEngine:
    """Deterministic mock (no model). Dev/tests only — never a production result."""

    def analyze(self, frames: list[AUFrame], meta: AURequestMeta) -> AUResult:
        from contracts.schemas.ai_contracts import (
            MomentObserved,
            MomentStoryContext,
            StoryUtility,
        )

        return AUResult(
            understanding=MomentUnderstandingContract(
                moment_id=meta.moment_id,
                source_capture_id=meta.source_capture_id,
                model_id="mock",
                n_frames=len(frames),
                observed=MomentObserved(summary=f"Mock understanding ({len(frames)} frames)."),
                story_context=MomentStoryContext(story_utility=StoryUtility.NONE),
            ),
            attempts=1,
            retried=False,
            model="mock",
        )


# --- Legacy Milestone-A stub (kept so the pre-AU interface still imports) -----


@dataclass(frozen=True)
class AssetUnderstandingStub:
    asset_id: UUID
    semantic_description: str = "unanalyzed (mock)"
    scene_tags: list[str] = field(default_factory=list)


@runtime_checkable
class AssetEngine(Protocol):
    def analyze(self, asset_id: UUID) -> AssetUnderstandingStub: ...


class MockAssetEngine:
    def analyze(self, asset_id: UUID) -> AssetUnderstandingStub:
        return AssetUnderstandingStub(asset_id=asset_id)


__all__ = [
    "PROMPT_VERSION",
    "SCHEMA_VERSION",
    "FRAME_POLICY",
    "TASK",
    "DEFAULT_AU_MODEL",
    "AU_MAX_TOKENS",
    "EXPECTED_FRAMES",
    "AUFrame",
    "CaptureContext",
    "AURequestMeta",
    "AUResult",
    "AURetryableError",
    "AssetUnderstandingEngine",
    "RealAssetUnderstandingEngine",
    "MockAssetUnderstandingEngine",
    "AssetUnderstandingStub",
    "AssetEngine",
    "MockAssetEngine",
]
