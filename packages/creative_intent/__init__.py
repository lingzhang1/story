"""Creative Intent Engine — the real Creative Intent Resolver (Milestone C1).

Owns (milestone-c-creative-intent-design.md §1, §6; task):
  - the versioned system/task prompt (loaded from prompts/creative_intent/<ver>/)
  - the structured-output schema (the canonical CreativeIntent contract)
  - structured-request construction
  - bounded retry for invalid structured output
  - conversion of the model's structured output into the canonical
    CreativeIntentContract

It does NOT own provider SDKs, request mechanics, or timeouts — those belong to
the Model Gateway. The engine depends only on `contracts` + `model_gateway`
(allowed dependency chain, 03 §40). Resolution is SERVER-SIDE and goes through
the gateway; no provider id appears here.

Reference-media (image) resolution is out of scope for C1 (text/template only).
"""

from __future__ import annotations

from pathlib import Path
from typing import Protocol, runtime_checkable
from uuid import uuid4

from contracts.schemas.ai_contracts import CreativeIntentContract
from model_gateway import (
    ModelGateway,
    StructuredOutputError,
    StructuredRequest,
    StructuredResult,
)

PROMPT_VERSION = "creative_intent/v1"
SCHEMA_VERSION = "creative_intent.schema/1"
TASK = "creative_intent.resolve"

_PROMPT_DIR = Path(__file__).resolve().parent.parent.parent / "prompts" / "creative_intent" / "v1"


def _load_system_prompt() -> str:
    return (_PROMPT_DIR / "system.md").read_text()


def _tool_schema() -> dict:
    """JSON Schema the model output must satisfy — the canonical CreativeIntent
    contract, minus server-assigned fields (id/created_at are set by us, not the
    model) so the model only produces creative content."""
    schema = CreativeIntentContract.model_json_schema()
    # Remove server-owned fields from the model's required/returned surface.
    props = dict(schema.get("properties", {}))
    for server_field in ("id", "created_at", "source_inputs"):
        props.pop(server_field, None)
    schema["properties"] = props
    schema["required"] = ["summary"]
    schema["additionalProperties"] = False
    return schema


@runtime_checkable
class CreativeIntentEngine(Protocol):
    def resolve(self, raw_text: str) -> CreativeIntentContract:
        """Resolve free-form creative direction into a canonical CreativeIntent.
        Raises StructuredOutputError (invalid output) / ProviderError (transport)
        — callers return a designed failure path, never a fabricated intent."""
        ...


class RealCreativeIntentEngine:
    """Model-backed resolver. Config-driven provider via the injected gateway."""

    def __init__(self, gateway: ModelGateway, max_repair_attempts: int = 1):
        self._gateway = gateway
        self._system = _load_system_prompt()
        self._schema = _tool_schema()
        self._max_repair_attempts = max_repair_attempts

    def build_request(self, raw_text: str) -> StructuredRequest:
        return StructuredRequest(
            task=TASK,
            schema=self._schema,
            prompt_version=PROMPT_VERSION,
            system=self._system,
            user_content=f"User creative direction:\n{raw_text}",
            max_repair_attempts=self._max_repair_attempts,
            max_tokens=800,
            temperature=0.0,
        )

    def resolve(self, raw_text: str) -> CreativeIntentContract:
        req = self.build_request(raw_text)
        result: StructuredResult = self._gateway.generate_structured(req)
        return self._to_contract(result, raw_text)

    def _to_contract(self, result: StructuredResult, raw_text: str) -> CreativeIntentContract:
        data = dict(result.data)
        # Server owns identity + provenance; the model never sets these.
        data["id"] = str(uuid4())
        data.setdefault("raw_user_description", raw_text)
        data.setdefault("source_inputs", [{"type": "text", "value": raw_text}])
        try:
            return CreativeIntentContract.model_validate(data)
        except Exception as e:
            # Model output did not satisfy the canonical contract even after the
            # gateway's repair budget. Do NOT fabricate — surface a failure.
            raise StructuredOutputError(
                f"model output failed canonical CreativeIntent validation: {e}"
            ) from e


class MockCreativeIntentEngine:
    """Deterministic mock (no model). Dev/tests only — never a production intent.
    Mirrors the Milestone-A flattened mock behavior into the canonical shape."""

    def resolve(self, raw_text: str) -> CreativeIntentContract:
        return CreativeIntentContract(
            id=uuid4(),
            summary=f"A story derived from: {raw_text[:80]}",
            raw_user_description=raw_text,
            source_inputs=[{"type": "text", "value": raw_text}],
        )


__all__ = [
    "PROMPT_VERSION",
    "SCHEMA_VERSION",
    "TASK",
    "CreativeIntentEngine",
    "RealCreativeIntentEngine",
    "MockCreativeIntentEngine",
]
