"""Story Coverage Engine — persistent Story intelligence (Milestone E, FROZEN).

Design: milestone-e-story-coverage-reconciliation.md + ...-experiment.md (FROZEN 2026-10-06).
Produces the canonical StoryCoverage from CreativeIntent + all COMPLETE MomentUnderstanding records
+ pending_count, via the generic ModelGateway. ONE model (Opus 4.6, config-driven), NO routing/
fallback. Full recomputation; the snapshot is derived + recomputable + advisory.

Owns: the versioned Coverage prompt (prompts/story_coverage/<ver>/), the structured-output schema
(the canonical StoryCoverage contract), COMPACT structured-input construction (NEVER raw video/frames/
Director history/SceneUnderstanding/CaptureSessions), provenance minting, and the task failure path
(never fabricate coverage — raise so the caller keeps the previous valid cached snapshot).

Hybrid dimension `id` is a within-snapshot handle only (not durable identity).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol, runtime_checkable
from uuid import UUID

from contracts.schemas.ai_contracts import StoryCoverageContract
from model_gateway import (
    ModelGateway,
    ProviderError,
    StructuredOutputError,
    StructuredRequest,
    StructuredResult,
)

PROMPT_VERSION = "story_coverage/v1"
SCHEMA_VERSION = "story_coverage/1"
TASK = "story_coverage.compute"
DEFAULT_COVERAGE_MODEL = "us.anthropic.claude-opus-4-6-v1"  # strongest invocable Opus (experiment winner)
COVERAGE_MAX_TOKENS = 1500
COVERAGE_TEMPERATURE = 0.0

_PROMPT_DIR = Path(__file__).resolve().parent.parent.parent / "prompts" / "story_coverage" / "v1"


def _load_system_prompt() -> str:
    return (_PROMPT_DIR / "system.md").read_text()


def _tool_schema() -> dict:
    """JSON Schema the model output must satisfy — the canonical StoryCoverage minus
    server-minted provenance/version fields (set by the engine, not the model)."""
    schema = StoryCoverageContract.model_json_schema()
    props = dict(schema.get("properties", {}))
    for server_field in ("schema_version", "story_id", "moment_count", "pending_count",
                         "source_understanding_ids", "generated_at"):
        props.pop(server_field, None)
    schema["properties"] = props
    schema["required"] = ["dimensions", "strengths", "redundancies", "sufficiency"]
    schema["additionalProperties"] = False
    return schema


@dataclass
class CoverageInput:
    """Compact, structured inputs for ONE coverage recompute. The caller supplies the
    already-decoded MomentUnderstanding dicts (observed + story_context) for COMPLETE
    Moments only, plus the count of Moments whose AU is still pending."""

    story_id: UUID
    creative_intent: dict[str, Any]
    scope: dict[str, Any]                       # {target_duration_seconds?, format?}
    moment_understandings: list[dict[str, Any]]  # each: {moment_id, observed{...}, story_context{...}}
    pending_count: int = 0


class CoverageUnavailableError(RuntimeError):
    """Raised when coverage could not be computed (model/provider failure). The caller
    MUST keep the previous valid cached StoryCoverage — never fabricate coverage."""


@runtime_checkable
class StoryCoverageEngine(Protocol):
    def compute(self, inp: CoverageInput) -> StoryCoverageContract: ...


class RealStoryCoverageEngine:
    def __init__(self, gateway: ModelGateway, model_id: str | None = None):
        self._gateway = gateway
        self._model_id = model_id or DEFAULT_COVERAGE_MODEL
        self._system = _load_system_prompt()
        self._schema = _tool_schema()

    # --- compact input (NO raw media / frames / Director history / scenes) ---
    @staticmethod
    def _compact_moment(mu: dict[str, Any]) -> dict[str, Any]:
        o = mu.get("observed", {}) or {}
        sc = mu.get("story_context", {}) or {}
        return {
            "id": str(mu.get("moment_id") or mu.get("id") or ""),
            "summary": o.get("summary", ""),
            "subjects": o.get("subjects", []),
            "events": [e.get("description", "") for e in o.get("events", []) if isinstance(e, dict)],
            "temporal_order_note": o.get("temporal_order_note", ""),
            "useful_segments": [s.get("why_useful", "") for s in o.get("useful_segments", []) if isinstance(s, dict)],
            "story_utility": sc.get("story_utility"),
            "requested_shot_contribution": sc.get("requested_shot_contribution"),
            "requested_beat_contribution": sc.get("requested_beat_contribution"),
        }

    def build_request(self, inp: CoverageInput) -> StructuredRequest:
        import json as _json
        payload = {
            "creative_intent": inp.creative_intent,
            "scope": inp.scope,
            "pending_count": inp.pending_count,
            "moments": [self._compact_moment(m) for m in inp.moment_understandings],
        }
        user = ("Derive the StoryCoverage for THIS Story. STORY INPUT:\n" + _json.dumps(payload)
                + "\n\nReturn ONLY the StoryCoverage via the tool.")
        return StructuredRequest(
            task=TASK, schema=self._schema, prompt_version=PROMPT_VERSION, system=self._system,
            user_content=user, max_repair_attempts=2,
            max_tokens=COVERAGE_MAX_TOKENS, temperature=COVERAGE_TEMPERATURE,
        )

    def compute(self, inp: CoverageInput) -> StoryCoverageContract:
        req = self.build_request(inp)
        try:
            result: StructuredResult = self._gateway.generate_structured(req)
        except (StructuredOutputError, ProviderError) as e:
            raise CoverageUnavailableError(
                f"story coverage unavailable ({type(e).__name__}: {e}); keep cached coverage"
            ) from e
        return self._to_contract(result, inp)

    def _to_contract(self, result: StructuredResult, inp: CoverageInput) -> StoryCoverageContract:
        data = dict(result.data)
        data["schema_version"] = SCHEMA_VERSION
        data["story_id"] = str(inp.story_id)
        data["moment_count"] = len(inp.moment_understandings)
        data["pending_count"] = inp.pending_count
        src_ids = [str(m.get("moment_id") or m.get("id")) for m in inp.moment_understandings
                   if (m.get("moment_id") or m.get("id"))]
        data["source_understanding_ids"] = src_ids
        # The model fills evidence_moment_ids with whatever moment ids it SAW in the input (which may
        # be fixture strings like "m1", or real UUIDs). The contract types them as UUIDs — so remap
        # model-supplied evidence ids onto the ACTUAL input moment ids, dropping anything that does not
        # resolve to a real UUID (Milestone-B id discipline: never pass through free-string ids).
        valid_src = set(src_ids)
        for dim in data.get("dimensions", []):
            if isinstance(dim, dict):
                ev = dim.get("evidence_moment_ids") or []
                dim["evidence_moment_ids"] = [e for e in ev if isinstance(e, str) and e in valid_src]
        try:
            return StoryCoverageContract.model_validate(data)
        except Exception as e:
            raise CoverageUnavailableError(
                f"model output failed canonical StoryCoverage validation: {e}"
            ) from e


class MockStoryCoverageEngine:
    """Deterministic mock (no model). Dev/tests only — never production coverage."""

    def compute(self, inp: CoverageInput) -> StoryCoverageContract:
        from contracts.schemas.ai_contracts import CoverageSufficiency, SufficiencyStatus
        return StoryCoverageContract(
            story_id=inp.story_id,
            moment_count=len(inp.moment_understandings),
            pending_count=inp.pending_count,
            source_understanding_ids=[UUID(str(m["moment_id"])) for m in inp.moment_understandings
                                      if m.get("moment_id")],
            dimensions=[], strengths=[], redundancies=[],
            sufficiency=CoverageSufficiency(status=SufficiencyStatus.WORKABLE, reason="mock"),
            story_idea=None,
        )


__all__ = [
    "PROMPT_VERSION", "SCHEMA_VERSION", "TASK", "DEFAULT_COVERAGE_MODEL",
    "CoverageInput", "CoverageUnavailableError",
    "StoryCoverageEngine", "RealStoryCoverageEngine", "MockStoryCoverageEngine",
]
