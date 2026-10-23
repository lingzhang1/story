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

import re
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


# ===========================================================================
# StoryGuide/2 REFINEMENT — "Update Guide" (Guide v2.1, 2026-10-23).
#
# Takes the CURRENT v2 shooting script + captured/pinned state + Coverage + a user
# update, and produces the NEXT v2 shooting script (same StoryGuideV2Contract) PLUS
# a change log. ADDITIVE: the frozen generate-once v2 engine above is untouched.
#
# The MODEL proposes preserve/improve/reorder/replace/add/archive. The SERVER
# (reconcile_refinement) is the source of truth for identity + history:
#   - captured (has Coverage evidence) or PINNED scenes are preserved verbatim and
#     can NEVER be archived/removed by a refinement — enforced here even if the
#     model tries;
#   - a scene the model returns with an EXISTING id keeps that id (preserved/improved);
#   - a scene with an unknown/new id (or a model ordinal) gets a FRESH canonical id
#     beyond the max existing ordinal — retired ids are NEVER reused;
#   - an existing uncaptured+unpinned scene the model did NOT return is ARCHIVED
#     (recorded in archived_scene_ids + change log; its id is never reused).
# ===========================================================================

PROMPT_VERSION_REFINE = "story_guide/refine-v1"
TASK_REFINE = "story_guide.refine_v2"
GUIDE_REFINE_MAX_TOKENS = 3500
GUIDE_REFINE_TEMPERATURE = 0.3

_PROMPT_DIR_REFINE = Path(__file__).resolve().parent.parent.parent / "prompts" / "story_guide" / "refine-v1"

_SCENE_ID_RE = re.compile(r"scene_(\d+)$")


def _load_system_prompt_refine() -> str:
    return (_PROMPT_DIR_REFINE / "system.md").read_text()


@dataclass
class RefineInput:
    """Inputs for ONE Guide refinement. The current guide + per-scene captured/pinned
    state + the user's update. `current_scenes` are the canonical stored scenes (each a
    dict with at least id/title/what_to_capture/how_to_shoot/why_it_matters)."""

    story_id: UUID
    creative_intent: dict[str, Any]
    scope: dict[str, Any]
    current_framing_summary: str
    current_scenes: list[dict[str, Any]]
    captured_scene_ids: list[str]              # scenes with Coverage evidence (derived) — PROTECTED
    pinned_scene_ids: list[str]                # user-pinned — PROTECTED
    user_instruction: str | None = None        # one-time "Update Guide" instruction
    event_context: str | None = None           # persistent, editable event context
    source_creative_intent_version: str | None = None


def _max_scene_ordinal(scenes: list[dict[str, Any]]) -> int:
    hi = 0
    for s in scenes:
        m = _SCENE_ID_RE.match(str(s.get("id", "")))
        if m:
            hi = max(hi, int(m.group(1)))
    return hi


def _mint_cps(scene_id: str, raw: list[Any]) -> list[dict[str, Any]]:
    cps: list[dict[str, Any]] = []
    for j, p in enumerate(raw or [], 1):
        if not isinstance(p, dict):
            continue
        cp: dict[str, Any] = {"id": f"{scene_id}_cp_{j:02d}", "label": p.get("label", "")}
        if p.get("semantic_purpose"):
            cp["semantic_purpose"] = p["semantic_purpose"]
        cps.append(cp)
    return cps


def reconcile_refinement(
    model_data: dict[str, Any],
    inp: RefineInput,
) -> tuple[dict[str, Any], list[dict[str, Any]], list[str]]:
    """SERVER-AUTHORITATIVE merge of the model's proposed scenes into the next guide.

    Returns (merged_guide_dict, change_log, archived_ids). Enforces the hard rules
    regardless of what the model proposed:
      - every captured/pinned scene is in the output, PRESERVED with its original id
        and original content (model edits to a protected scene are ignored);
      - a model scene whose id matches an existing scene keeps that id (preserved/
        improved); a model scene with an unknown id gets a fresh canonical id;
      - any existing uncaptured+unpinned scene the model dropped is archived.
    """
    by_id = {str(s.get("id")): s for s in inp.current_scenes if s.get("id")}
    protected = set(inp.captured_scene_ids) | set(inp.pinned_scene_ids)
    next_ord = _max_scene_ordinal(inp.current_scenes)

    out_scenes: list[dict[str, Any]] = []
    changes: list[dict[str, Any]] = []
    emitted_ids: set[str] = set()

    def _emit_protected(sid: str) -> None:
        """Force a protected scene into the output verbatim (idempotent)."""
        if sid in emitted_ids:
            return
        orig = by_id[sid]
        out_scenes.append(dict(orig))
        emitted_ids.add(sid)
        changes.append({"scene_id": sid, "disposition": "preserved",
                        "title": orig.get("title", ""),
                        "reason": "captured/pinned — preserved"})

    for ms in model_data.get("scenes", []) or []:
        if not isinstance(ms, dict):
            continue
        raw_id = str(ms.get("id", ""))
        if raw_id in by_id:
            # References an existing scene.
            if raw_id in protected:
                # PROTECTED: keep the ORIGINAL content, ignore any model rewrite.
                _emit_protected(raw_id)
                continue
            if raw_id in emitted_ids:
                continue
            # Uncaptured, unpinned existing scene the model kept/improved -> keep id, take model content.
            orig = by_id[raw_id]
            improved = (
                ms.get("title") != orig.get("title")
                or ms.get("what_to_capture") != orig.get("what_to_capture")
                or ms.get("how_to_shoot") != orig.get("how_to_shoot")
                or ms.get("why_it_matters") != orig.get("why_it_matters")
            )
            scene: dict[str, Any] = {
                "id": raw_id,
                "title": ms.get("title", orig.get("title", "")),
                "what_to_capture": ms.get("what_to_capture", orig.get("what_to_capture", "")),
                "how_to_shoot": ms.get("how_to_shoot", orig.get("how_to_shoot", "")),
                "why_it_matters": ms.get("why_it_matters", orig.get("why_it_matters", "")),
                "capture_possibilities": _mint_cps(raw_id, ms.get("capture_possibilities", [])),
            }
            q = ms.get("visual_reference_query")
            if isinstance(q, str) and q.strip():
                scene["visual_reference_query"] = q.strip()
            out_scenes.append(scene)
            emitted_ids.add(raw_id)
            changes.append({"scene_id": raw_id,
                            "disposition": "improved" if improved else "preserved",
                            "title": scene["title"], "reason": ms.get("_reason")})
        else:
            # Genuinely NEW scene -> mint a fresh canonical id beyond the max existing ordinal.
            next_ord += 1
            sid = f"scene_{next_ord:02d}"
            scene = {
                "id": sid,
                "title": ms.get("title", ""),
                "what_to_capture": ms.get("what_to_capture", ""),
                "how_to_shoot": ms.get("how_to_shoot", ""),
                "why_it_matters": ms.get("why_it_matters", ""),
                "capture_possibilities": _mint_cps(sid, ms.get("capture_possibilities", [])),
            }
            q = ms.get("visual_reference_query")
            if isinstance(q, str) and q.strip():
                scene["visual_reference_query"] = q.strip()
            # Skip an empty new scene (no title) — not a scene.
            if not scene["title"].strip():
                continue
            out_scenes.append(scene)
            emitted_ids.add(sid)
            changes.append({"scene_id": sid, "disposition": "added",
                            "title": scene["title"], "reason": ms.get("_reason")})

    # Force any protected scene the model omitted back into the output (it may NOT be dropped).
    for sid in by_id:
        if sid in protected and sid not in emitted_ids:
            _emit_protected(sid)

    # Any existing uncaptured + unpinned scene not re-emitted is archived (id recorded, never reused).
    archived_ids: list[str] = []
    for sid, orig in by_id.items():
        if sid not in emitted_ids and sid not in protected:
            archived_ids.append(sid)
            changes.append({"scene_id": sid, "disposition": "archived",
                            "title": orig.get("title", ""), "reason": "retired by refinement"})

    merged = {
        "framing_summary": model_data.get("framing_summary", inp.current_framing_summary) or inp.current_framing_summary,
        "scenes": out_scenes,
    }
    return merged, changes, archived_ids


class RealStoryGuideRefineEngine:
    """story_guide/refine-v1 engine. Model proposes; reconcile_refinement decides identity + history."""

    def __init__(self, gateway: ModelGateway, model_id: str | None = None):
        self._gateway = gateway
        self._model_id = model_id or DEFAULT_GUIDE_MODEL
        self._system = _load_system_prompt_refine()
        self._schema = _tool_schema_refine()

    def build_request(self, inp: RefineInput) -> StructuredRequest:
        import json as _json
        # Compact, model-facing view: each scene + whether it is captured/pinned (protected).
        protected = set(inp.captured_scene_ids) | set(inp.pinned_scene_ids)
        scenes_view = []
        for s in inp.current_scenes:
            sid = str(s.get("id", ""))
            scenes_view.append({
                "id": sid,
                "title": s.get("title", ""),
                "what_to_capture": s.get("what_to_capture", ""),
                "how_to_shoot": s.get("how_to_shoot", ""),
                "why_it_matters": s.get("why_it_matters", ""),
                "captured": sid in set(inp.captured_scene_ids),
                "pinned": sid in set(inp.pinned_scene_ids),
                "protected": sid in protected,
            })
        payload = {
            "creative_intent": inp.creative_intent,
            "scope": inp.scope,
            "event_context": inp.event_context or "",
            "current_framing_summary": inp.current_framing_summary,
            "current_scenes": scenes_view,
            "user_update": inp.user_instruction or "",
        }
        user = ("Refine THIS Story's shooting script.\n\nCURRENT STATE + UPDATE:\n"
                + _json.dumps(payload)
                + "\n\nPreserve every scene with protected=true verbatim (same id). Keep the same id for any "
                  "scene that stays conceptually the same; mint a fresh ordinal only for a genuinely new scene. "
                  "Archive outdated uncaptured, unpinned scenes by leaving them out, and record an 'archived' "
                  "change entry for each. Honor the newest update; never fabricate plans. Return the FULL "
                  "updated active script + the change log.")
        return StructuredRequest(
            task=TASK_REFINE, schema=self._schema, prompt_version=PROMPT_VERSION_REFINE, system=self._system,
            user_content=user, max_repair_attempts=2,
            max_tokens=GUIDE_REFINE_MAX_TOKENS, temperature=GUIDE_REFINE_TEMPERATURE,
        )

    def refine(self, inp: RefineInput):
        from contracts.schemas.ai_contracts import StoryGuideRefinementResult, StoryGuideV2Contract
        req = self.build_request(inp)
        try:
            result: StructuredResult = self._gateway.generate_structured(req)
        except (StructuredOutputError, ProviderError) as e:
            raise GuideUnavailableError(
                f"story guide refine unavailable ({type(e).__name__}: {e}); preserve current Guide + retry"
            ) from e
        merged, changes, archived = reconcile_refinement(dict(result.data), inp)
        merged["schema_version"] = SCHEMA_VERSION_V2
        merged["story_id"] = str(inp.story_id)
        if inp.source_creative_intent_version:
            merged["source_creative_intent_version"] = inp.source_creative_intent_version
        try:
            guide = StoryGuideV2Contract.model_validate(merged)
        except Exception as e:
            raise GuideUnavailableError(
                f"refined output failed canonical StoryGuide/2 validation: {e}"
            ) from e
        return StoryGuideRefinementResult(guide=guide, changes=changes, archived_scene_ids=archived)


def _tool_schema_refine() -> dict:
    """Model-output schema for a refinement: the FULL updated active scene list (ordinal/existing ids) +
    a per-scene change log. The engine reconciles ids + history afterward."""
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
            "changes": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "properties": {
                    "scene_id": {"type": "string"},
                    "disposition": {"type": "string",
                                    "enum": ["preserved", "improved", "added", "archived"]},
                    "title": {"type": "string"},
                    "reason": {"type": "string"},
                },
                "required": ["scene_id", "disposition"]}},
        },
        "required": ["framing_summary", "scenes"],
    }


class MockStoryGuideRefineEngine:
    """Deterministic mock (no model). Dev/tests only. Echoes current scenes + appends one new scene."""

    def refine(self, inp: RefineInput):
        from contracts.schemas.ai_contracts import StoryGuideRefinementResult, StoryGuideV2Contract
        # Keep everything, add one scene — exercises the reconciler's add/preserve paths.
        model_data = {
            "framing_summary": inp.current_framing_summary,
            "scenes": [dict(s) for s in inp.current_scenes] + [{
                "id": "s99", "title": "Mock added scene",
                "what_to_capture": "a new opportunity from the update",
                "how_to_shoot": "hold a steady shot", "why_it_matters": "it reflects the update",
            }],
        }
        merged, changes, archived = reconcile_refinement(model_data, inp)
        merged["schema_version"] = SCHEMA_VERSION_V2
        merged["story_id"] = str(inp.story_id)
        guide = StoryGuideV2Contract.model_validate(merged)
        return StoryGuideRefinementResult(guide=guide, changes=changes, archived_scene_ids=archived)


__all__ = [
    "PROMPT_VERSION", "SCHEMA_VERSION", "TASK", "DEFAULT_GUIDE_MODEL",
    "GuideInput", "GuideUnavailableError",
    "StoryGuideEngine", "RealStoryGuideEngine", "MockStoryGuideEngine",
    # story_guide/2 (shooting script)
    "PROMPT_VERSION_V2", "SCHEMA_VERSION_V2", "TASK_V2",
    "RealStoryGuideV2Engine", "MockStoryGuideV2Engine",
    # story_guide/2 refinement (Guide v2.1)
    "PROMPT_VERSION_REFINE", "SCHEMA_VERSION_V2", "TASK_REFINE",
    "RefineInput", "RealStoryGuideRefineEngine", "MockStoryGuideRefineEngine",
    "reconcile_refinement",
]
