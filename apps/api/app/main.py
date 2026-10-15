"""Story API — FastAPI application (Milestone A walking skeleton).

Endpoints:
  GET  /health                     -> liveness (App Runner health check)
  POST /v1/stories                 -> create a Story (mock StoryEngine)
  POST /v1/stories/{id}/outputs    -> create a mock GeneratedOutput

The app depends on engine PROTOCOLS via app.deps (DI), so mocks can be
swapped for real AI engines without touching this module. All app/backend
routes live under /v1 (03-system-architecture.md §14).
"""

from __future__ import annotations

import json
import time
from uuid import UUID, uuid4

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, ConfigDict, Field

from contracts.schemas.ai_contracts import (
    CreativeIntentContract,
    MomentUnderstandingContract,
    SceneUnderstandingContract,
    StoryCoverageContract,
)
from contracts.schemas.dto import (
    CreateStoryRequest,
    GeneratedOutputDTO,
    StoryDTO,
)
from creative_intent import PROMPT_VERSION, SCHEMA_VERSION, CreativeIntentEngine
from scene_understanding import (
    PROMPT_VERSION as SU_PROMPT_VERSION,
    SCHEMA_VERSION as SU_SCHEMA_VERSION,
    SceneUnderstandingEngine,
)
from story_director import (
    PROMPT_VERSION as DIR_PROMPT_VERSION,
    SCHEMA_VERSION as DIR_SCHEMA_VERSION,
    DirectorOutput,
    StoryDirectorEngine,
)
from director_engine import DirectorEngine  # noqa: F401  (available for future shoot endpoint)
from edit_engine import EditEngine
from asset_engine import (
    AURequestMeta,
    AUFrame,
    AURetryableError,
    CaptureContext,
    AssetUnderstandingEngine,
    FRAME_POLICY as AU_FRAME_POLICY,
    PROMPT_VERSION as AU_PROMPT_VERSION,
    SCHEMA_VERSION as AU_SCHEMA_VERSION,
    EXPECTED_FRAMES as AU_EXPECTED_FRAMES,
)
from story_coverage import (
    CoverageInput,
    CoverageUnavailableError,
    StoryCoverageEngine,
    PROMPT_VERSION as COV_PROMPT_VERSION,
    SCHEMA_VERSION as COV_SCHEMA_VERSION,
)
from story_guide import GuideInput, GuideUnavailableError, StoryGuideEngine
from music_direction import MusicDirectionEngine
from edit_planner import (
    EditPlannerEngine,
    EditPlanInputs,
    EditPlanInfeasibleError,
    MalformedPlanError,
    preflight_directives,
)
import edit_planner as _edit_planner_mod
import edit_plan_jobs as _jobs


def _edit_planner_prompt_version() -> str:
    """The edit-plan prompt version actually in effect (reflects STORY_EDIT_PLAN_VERSION). Logged on each
    plan so a device render can PROVE which prompt (edit_plan/4 vs the v5 candidate) produced it."""
    return getattr(_edit_planner_mod, "PROMPT_VERSION", "edit_plan/?")

from duration_planner import (
    DurationPlannerEngine,
    DurationPlannerInputs,
    compute_duration_evidence,
)
from music_plan import MusicPlanEngine, MusicPlanInputs
import music_provider as _mp
from story_coverage_v2 import (
    CoverageV2Input,
    CoverageUnavailableError as CoverageV2UnavailableError,
    StoryCoverageV2Engine,
)
from contracts.schemas.ai_contracts import StoryGuideContract, StoryCoverageContractV2, MusicDirectionContract, EditPlanV2Contract, MusicPlanContract
from model_gateway import ProviderError, StructuredOutputError
from observability import get_logger
from story_engine import StoryEngine

from app.deps import (
    get_creative_intent_engine,
    get_director_engine,  # noqa: F401
    get_edit_engine,
    get_model_gateway,
    get_scene_understanding_engine,
    get_story_director_engine,
    get_story_engine,
    get_asset_understanding_engine,
    get_story_coverage_engine,
    get_story_guide_engine,
    get_story_coverage_v2_engine,
    get_music_direction_engine,
    get_edit_planner_engine,
    get_music_plan_engine,
    get_duration_planner_engine,
)
from app.store import InMemoryStoryStore

# Scene Understanding multipart limits (04-aws-infrastructure.md §32/§44).
_SU_MAX_FRAMES = 6
_SU_MAX_FRAME_BYTES = 2 * 1024 * 1024          # 2 MB per frame
_SU_MAX_TOTAL_BYTES = 8 * 1024 * 1024          # 8 MB total payload
_SU_ALLOWED_TYPES = {"image/jpeg", "image/jpg", "image/png"}

# Asset Understanding multipart limits (06-asset-understanding.md §2/§8).
# 24 timestamped frames @ 768px/JPEG ~0.6 ≈ 1-3 MB total; cap generously.
_AU_MAX_FRAMES = 24
_AU_MIN_FRAMES = 24                             # au_frames/1 is EXACTLY 24
_AU_MAX_FRAME_BYTES = 1 * 1024 * 1024           # 1 MB per frame (768px JPEG is far smaller)
_AU_MAX_TOTAL_BYTES = 12 * 1024 * 1024          # 12 MB total payload ceiling

# Bounded admission for BACKGROUND model inference (asset/scene understanding). The offload keeps AU off the
# event loop, but AU + interactive handlers share FastAPI's threadpool; without a cap, 20-25 AU jobs could still
# occupy most threads. This semaphore bounds concurrent AU so interactive requests (creative-intent, guide,
# director — none of which take this semaphore) always have threadpool headroom. Conservative start = 4; raise
# after measuring. It gates ADMISSION only; it never interrupts a running call.
import anyio
_AU_ADMISSION = anyio.Semaphore(4)
_AU_ALLOWED_TYPES = {"image/jpeg", "image/jpg"}

# Story Coverage (Milestone E) — JSON (text-only, no media). Generous moment cap.
_COV_MAX_MOMENTS = 200

# MVP Multimodal Edit Planner (Tier-1 contact sheets) — one tiled JPEG per Moment attached to the SAME
# /v1/edit-plan-mm request. Derived evidence only (never source video). Ephemeral: NOT persisted server-side.
# Limits mirror the AU multipart ceilings and act as a server-side backstop to the device-side adaptive
# preflight — the device should already fit under these; the server rejects anything that does not.
_MM_EDIT_MAX_SHEETS = 120                       # one sheet per Moment; 100-Moment stress case + headroom
_MM_EDIT_MAX_SHEET_BYTES = 1 * 1024 * 1024      # 1 MB per tiled contact-sheet JPEG
_MM_EDIT_MAX_TOTAL_BYTES = 20 * 1024 * 1024     # 20 MB total image payload ceiling
_MM_EDIT_ALLOWED_TYPES = {"image/jpeg", "image/jpg"}

# MVP application-level creative brief (VERSIONED). Injected into the Edit Planner USER message only — the
# frozen v5.2 system body is never touched. Owner-authored 2026-10-13. Bump the version suffix on any edit.
MM_CREATIVE_BRIEF_VERSION = "shortform_mvp/1"
MM_CREATIVE_BRIEF = (
    "When user intent does not require chronology, prioritize visually engaging and meaningful footage. "
    "Find a compelling opening, construct coherent visual progression, preserve important actions and "
    "payoffs, and choose shot durations appropriate to the material. Do not force a conventional "
    "travel-diary structure."
)


class StoryCoverageRequest(BaseModel):
    """POST /v1/story-coverage body. COMPACT structured inputs only — the client sends
    CreativeIntent + COMPLETE MomentUnderstanding records + pending_count. No media/frames."""

    model_config = ConfigDict(extra="forbid")
    story_id: UUID
    creative_intent: dict = Field(..., description="the resolved CreativeIntent (compact)")
    scope: dict = Field(default_factory=dict, description="{target_duration_seconds?, format?}")
    moment_understandings: list[dict] = Field(default_factory=list,
        description="completed MomentUnderstanding records (observed + story_context)")
    pending_count: int = Field(default=0, ge=0)


class StoryGuideRequest(BaseModel):
    """POST /v1/story-guide body. CreativeIntent + scope -> StoryGuide/1 (text-only). Generated ONCE
    at Story creation; no MomentUnderstanding required (a zero-Moment Story has a complete Guide)."""

    model_config = ConfigDict(extra="forbid")
    story_id: UUID
    creative_intent: dict = Field(..., description="the resolved CreativeIntent (compact)")
    scope: dict = Field(default_factory=dict, description="{target_duration_seconds?, format?}")
    source_creative_intent_version: str | None = Field(default=None)


class MusicDirectionRequest(BaseModel):
    """POST /v1/music-direction body (Milestone M-c). CreativeIntent + optional
    StoryGuide.framing_summary -> inferred MusicDirection (intended soundtrack feel).
    DETERMINISTIC, no model call. Does NOT consume StoryCoverage. A user-authored
    direction overrides this on the client; the server never regenerates over an edit."""

    model_config = ConfigDict(extra="forbid")
    creative_intent: dict = Field(..., description="the resolved CreativeIntent")
    guide_framing_summary: str | None = Field(
        default=None, description="StoryGuide.framing_summary as lightweight creative context (optional)"
    )


class EditPlanRequest(BaseModel):
    """POST /v1/edit-plan body (Milestone M-d, frozen edit_plan/2). Produces an EditPlan via one Opus 4.6
    call under a DETERMINISTIC validator. Music is OPTIONAL (no-music planning supported). The planner PLANS;
    the Media Engine (separate milestone) renders. On model/validation failure or infeasible material the
    endpoint returns a structured failure (never a fabricated plan)."""

    model_config = ConfigDict(extra="forbid")
    story_id: UUID
    creative_intent_id: UUID
    creative_intent: dict = Field(..., description="resolved CreativeIntent incl. target_duration_seconds")
    story_guide: dict = Field(default_factory=dict)
    story_coverage: dict = Field(default_factory=dict)
    moments: list[dict] = Field(..., description="completed MomentUnderstanding[], each with id/duration_seconds/useful_segments")
    music_plan: dict = Field(default_factory=dict)
    output_format: str = Field(default="vertical")
    music_asset_id: str | None = Field(default=None)
    music_plan_id: UUID | None = Field(default=None)
    music_analysis: dict | None = Field(default=None, description="frozen music_analysis/1; omit for no-music planning")
    sound_preference: str | None = Field(
        default=None, description="effective user sound preference: immersive|balanced|music_led (None = infer)")
    editorial_mode: str | None = Field(
        default=None, description="Story-length editorial mode: highlights|full|custom (None = infer from duration; back-compat)")
    revision_context: dict | None = Field(
        default=None,
        description="Creative Revision Foundation (additive, request-only). When present, carries "
                    "{mode: explore|revise, base_version_id, prior_edit_summaries[], base_plan?, directives?, "
                    "soft_direction?}. Injected into the USER message only; frozen v5.2 system body + EditPlan/2 "
                    "output are UNCHANGED. Absent => behavior identical to before. Part of the request snapshot "
                    "and therefore of the canonical async fingerprint (body-hashed) — never a fingerprint bypass.")


class InterpretRevisionRequest(BaseModel):
    """POST /v1/interpret-revision body (Phase 2 hybrid interpretation). ONE bounded structured model call that
    turns a free-form revision instruction into TYPED directives (keyed by stable Moment id) + soft prefs +
    unresolved clauses. Text-only; NO media/frames; never full planning. The client sends the instruction and
    the Story's NUMBERED Moments (number + short summary + stable id). The model refers to Moments by number;
    the server maps numbers -> ids so a model can never fabricate an id (an out-of-range number is unresolved)."""

    model_config = ConfigDict(extra="forbid")
    instruction: str = Field(..., description="the user's free-form revision instruction")
    moments: list[dict] = Field(..., description="numbered snapshot: [{number:int, id:str, summary?:str}]")


class DurationRecommendationRequest(BaseModel):
    """POST /v1/duration-recommendation body (Milestone R-d.2). Recommends a target duration from the Story's
    intent + material. Deterministic evidence is computed locally from moments[]; one Opus call adds the
    scope-aware recommendation. The user owns the final choice — this never sets the Story's duration. If an
    explicit CreativeIntent duration already exists the client preselects it and need not call this."""

    model_config = ConfigDict(extra="forbid")
    creative_intent: dict = Field(..., description="resolved CreativeIntent (may or may not carry target_duration_seconds)")
    moments: list[dict] = Field(..., description="completed MomentUnderstanding[], each with id/duration_seconds/useful_segments")
    story_guide: dict = Field(default_factory=dict)
    story_coverage: dict = Field(default_factory=dict)
    requested_scope: str | None = Field(default=None, description="'highlights' | 'complete' | None")


class MusicPlanRequest(BaseModel):
    """POST /v1/music-plan body (Milestone R-d, frozen music_plan/1). Produces the Story-level soundtrack
    SHAPE via one Opus 4.6 call at creation time. MusicDirection is AUTHORITATIVE for mood/energy (a
    user-authored direction is passed through). On model/provider failure the endpoint returns 503 — it
    NEVER fabricates a plan; the client falls back to no-music creation."""

    model_config = ConfigDict(extra="forbid")
    story_id: UUID
    creative_intent: dict = Field(..., description="resolved CreativeIntent incl. target_duration_seconds")
    music_direction: dict = Field(..., description="authoritative MusicDirection (user-authored overrides inferred)")
    target_duration_seconds: float = Field(..., gt=0.0)
    story_guide: dict = Field(default_factory=dict)
    story_coverage: dict = Field(default_factory=dict)
    sound_preference: str | None = Field(
        default=None, description="effective user sound preference: immersive|balanced|music_led (None = infer)")


class MusicCandidatesRequest(BaseModel):
    """POST /v1/music/candidates body — PROTOTYPING-ONLY Epidemic search+rank. Feature-flagged."""

    model_config = ConfigDict(extra="forbid")
    music_plan: dict = Field(..., description="MusicPlan/1 (character + audio_strategy drive the query)")
    target_duration_seconds: float = Field(..., gt=0.0)
    limit: int = Field(default=5, ge=1, le=10)
    cursor: str | None = Field(default=None, description="opaque next-page cursor; None = page 1 (also carries the top-pick analysis)")


class MusicTrackRequest(BaseModel):
    """POST /v1/music/analysis and /v1/music/soundtrack body — a specific chosen track. PROTOTYPING-ONLY."""

    model_config = ConfigDict(extra="forbid")
    track_id: str = Field(..., description="Epidemic track id (from a candidate)")
    duration_seconds: float | None = Field(default=None, gt=0.0, description="optional hint when metadata lacks length")


class MusicSearchRequest(BaseModel):
    """POST /v1/music/search body — user-driven free-text catalog search with pagination. PROTOTYPING-ONLY.
    Distinct from /v1/music/candidates (MusicPlan-driven ranked recommendation): this is 'let me browse'."""

    model_config = ConfigDict(extra="forbid")
    query: str = Field(..., min_length=1, max_length=200, description="free-text search term")
    page_size: int = Field(default=10, ge=1, le=20)
    cursor: str | None = Field(default=None, description="opaque next-page cursor from a prior response; None = first page")


class StoryCoverageV2Request(BaseModel):
    """POST /v1/story-coverage/v2 body — the FROZEN Guide-relative Coverage. CreativeIntent + the
    persisted frozen StoryGuide + completed MomentUnderstanding[] + pending_count -> StoryCoverage/2
    (internal Mapper + Judge composed). Text-only, no media."""

    model_config = ConfigDict(extra="forbid")
    story_id: UUID
    story_guide: dict = Field(..., description="the frozen StoryGuide/1 (dimensions w/ stable ids)")
    story_guide_version: str = Field(default="story_guide/1")
    creative_intent: dict = Field(...)
    scope: dict = Field(default_factory=dict)
    moment_understandings: list[dict] = Field(default_factory=list)
    pending_count: int = Field(default=0, ge=0)


class ResolveCreativeIntentRequest(BaseModel):
    """POST /v1/creative-intent body (text/template only for C1)."""

    model_config = ConfigDict(extra="forbid")

    raw_text: str = Field(min_length=1, description="User's free-form creative direction")


class DirectorInitializeRequest(BaseModel):
    """POST /v1/director/initialize body."""

    model_config = ConfigDict(extra="forbid")

    creative_intent: dict = Field(..., description="A CreativeIntent contract object")
    scene_understanding: dict | None = Field(
        default=None,
        description="A SceneUnderstanding contract object, or null when the user used "
                    "Skip Scan (Director then recommends environment-agnostically).")
    capture_constraints: dict | None = Field(default=None)
    selected_opportunity: dict | None = Field(
        default=None,
        description="OPTIONAL (E2-c): the high-level narrative opportunity the user explicitly chose "
                    "(Story Idea -> Show me, or Guide possibility -> Shoot). Shape: "
                    "{story_guide_dimension_id?, label, purpose, capture_possibility_label?}. null = "
                    "unchanged Director behavior. Semantic WHAT, never a literal shot/constraint.")


class DirectorNextRequest(BaseModel):
    """POST /v1/director/next body — prior plan/state + Story progress."""

    model_config = ConfigDict(extra="forbid")

    prior: dict = Field(..., description="Prior concept/plan/director_state + progress descriptors")

SERVICE_NAME = "story-api"
SERVICE_VERSION = "0.1.0"  # Milestone A


def create_app() -> FastAPI:
    """Construct the FastAPI app. A factory so tests get a fresh instance
    (and a fresh in-memory store) per app."""
    app = FastAPI(title="Story API", version=SERVICE_VERSION)
    log = get_logger("story-api")

    # Non-persistent demo store (see app/store.py). One per app instance.
    store = InMemoryStoryStore()

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "service": SERVICE_NAME, "version": SERVICE_VERSION}

    @app.post("/v1/creative-intent", response_model=CreativeIntentContract, status_code=200)
    def resolve_creative_intent(
        body: ResolveCreativeIntentRequest,
        engine: CreativeIntentEngine = Depends(get_creative_intent_engine),
    ) -> CreativeIntentContract:
        """Resolve free-form creative direction into a canonical CreativeIntent
        via the Model Gateway. On model/provider failure, return a designed
        failure (503) — NEVER a fabricated intent."""
        correlation_id = str(uuid4())
        started = time.monotonic()
        # Observability: never log raw user content by default (len only).
        base_fields = {
            "operation": "resolve_creative_intent",
            "correlation_id": correlation_id,
            "task": "creative_intent.resolve",
            "prompt_version": PROMPT_VERSION,
            "schema_version": SCHEMA_VERSION,
            "input_chars": len(body.raw_text),
        }
        try:
            intent = engine.resolve(body.raw_text)
        except StructuredOutputError as e:
            log.warning(
                "creative_intent_structured_output_failed",
                extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                       "success": False, "structured_output_failed": True, "error": str(e)[:300]},
            )
            raise HTTPException(
                status_code=503,
                detail="creative_intent_unavailable: model did not return a valid structured result; retry",
            )
        except ProviderError as e:
            log.warning(
                "creative_intent_provider_failed",
                extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                       "success": False, "provider_error": True, "error": str(e)[:300]},
            )
            raise HTTPException(
                status_code=503,
                detail="creative_intent_unavailable: model provider error; retry",
            )

        log.info(
            "creative_intent_resolved",
            extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                   "success": True},
        )
        return intent

    @app.post("/v1/interpret-revision", status_code=200)
    def interpret_revision_endpoint(
        body: InterpretRevisionRequest,
    ) -> dict:
        """Phase 2 — hybrid NL revision interpretation. ONE bounded structured model call turning a free-form
        instruction into typed directives (stable ids) + soft_direction + unresolved[]. The client calls this
        only when its deterministic parse cannot fully cover the instruction. On model/provider failure returns
        503 (the client falls back to its deterministic parse). Never full planning; no media."""
        from edit_planner.revision_interpreter import interpret_revision as _interp, PROMPT_VERSION as _IV
        correlation_id = str(uuid4())
        started = time.monotonic()
        base_fields = {"operation": "interpret_revision", "correlation_id": correlation_id,
                       "task": "revision.interpret", "prompt_version": _IV,
                       "input_chars": len(body.instruction), "moment_count": len(body.moments)}
        try:
            result = _interp(body.instruction, body.moments, get_model_gateway())
        except StructuredOutputError as e:
            log.warning("interpret_revision_structured_output_failed",
                        extra={**base_fields, "success": False, "error": str(e)[:300]})
            raise HTTPException(status_code=503,
                                detail="interpret_revision_unavailable: model did not return a valid result; retry")
        except ProviderError as e:
            log.warning("interpret_revision_provider_failed",
                        extra={**base_fields, "success": False, "error": str(e)[:300]})
            raise HTTPException(status_code=503, detail="interpret_revision_unavailable: provider error; retry")
        log.info("interpret_revision_ok",
                 extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                        "success": True, "has_directives": bool(result.directives),
                        "unresolved_count": len(result.unresolved)})
        # Phase 4 preflight: refuse to let the client spend an expensive revision job on a known-unsatisfiable
        # or malformed directive set. eligible_ids = the Moment ids the client sent in the snapshot.
        eligible = {str(m["id"]) for m in body.moments if "id" in m}
        blocking = preflight_directives(result.directives, eligible)
        return {"directives": result.directives, "soft_direction": result.soft_direction,
                "unresolved": result.unresolved, "blocking": blocking,
                "can_submit": not blocking and not result.unresolved}

    @app.post("/v1/scene-understanding", response_model=SceneUnderstandingContract, status_code=200)
    async def scene_understanding(
        context: str = Form(..., description="JSON: {capture_session_id, mode, story_id?}"),
        frames: list[UploadFile] = File(..., description="3-6 representative JPEG scan frames"),
        engine: SceneUnderstandingEngine = Depends(get_scene_understanding_engine),
    ) -> SceneUnderstandingContract:
        """Analyze representative scan frames into a canonical SceneUnderstanding
        via a real multimodal model. Frames are ephemeral — NOT persisted server
        side. On model/provider failure, return a designed failure (503), never a
        fabricated scene."""
        correlation_id = str(uuid4())
        started = time.monotonic()

        # --- validate the multipart request BEFORE touching a model ----------
        if not frames:
            raise HTTPException(status_code=422, detail="no frames provided")
        if len(frames) > _SU_MAX_FRAMES:
            raise HTTPException(status_code=413, detail=f"too many frames (max {_SU_MAX_FRAMES})")

        frame_bytes: list[bytes] = []
        total = 0
        for f in frames:
            if (f.content_type or "").lower() not in _SU_ALLOWED_TYPES:
                raise HTTPException(status_code=415, detail=f"unsupported frame type: {f.content_type}")
            data = await f.read()
            if len(data) > _SU_MAX_FRAME_BYTES:
                raise HTTPException(status_code=413, detail="a frame exceeds the per-frame size limit")
            total += len(data)
            if total > _SU_MAX_TOTAL_BYTES:
                raise HTTPException(status_code=413, detail="total payload exceeds the size limit")
            frame_bytes.append(data)

        import json as _json
        try:
            ctx = _json.loads(context)
            if not isinstance(ctx, dict):
                raise ValueError("context must be a JSON object")
        except ValueError as e:
            raise HTTPException(status_code=422, detail=f"invalid context json: {e}")

        base_fields = {
            "operation": "scene_understanding",
            "correlation_id": correlation_id,
            "task": "scene_understanding.analyze",
            "prompt_version": SU_PROMPT_VERSION,
            "schema_version": SU_SCHEMA_VERSION,
            "frame_count": len(frame_bytes),
            "compressed_payload_bytes": total,
            "mode": ctx.get("mode"),
        }
        try:
            # Offload the blocking Bedrock call off the event loop (same reason as asset_understanding).
            scene = await run_in_threadpool(engine.analyze, frame_bytes)
        except StructuredOutputError as e:
            log.warning(
                "scene_understanding_structured_output_failed",
                extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                       "success": False, "structured_output_failed": True, "error": str(e)[:300]},
            )
            raise HTTPException(
                status_code=503,
                detail="scene_understanding_unavailable: model did not return a valid scene; rescan/retry",
            )
        except ProviderError as e:
            log.warning(
                "scene_understanding_provider_failed",
                extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                       "success": False, "provider_error": True, "error": str(e)[:300]},
            )
            raise HTTPException(
                status_code=503,
                detail="scene_understanding_unavailable: model provider error; retry",
            )
        # Frames are discarded here (not persisted) — ephemeral inference input.
        log.info(
            "scene_understanding_resolved",
            extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                   "success": True, "subject_count": len(scene.subjects)},
        )
        return scene

    @app.post("/v1/asset-understanding", response_model=MomentUnderstandingContract, status_code=200)
    async def asset_understanding(
        meta: str = Form(..., description="JSON: {moment_id, source_capture_id?, capture_context?}"),
        frames_meta: str = Form(..., description="JSON: [{t_ms}, ...] ordered, one per frame"),
        frames: list[UploadFile] = File(..., description="exactly 24 ordered JPEG timeline frames"),
        engine: AssetUnderstandingEngine = Depends(get_asset_understanding_engine),
    ) -> MomentUnderstandingContract:
        """Analyze a 24-frame ORDERED timestamped Moment timeline into a canonical
        MomentUnderstanding via Sonnet 4.6 (FROZEN, 06-asset-understanding.md). Frames are
        ephemeral — NOT persisted server-side. On exhausted retry/provider failure, return a
        designed RETRYABLE failure (503) so the on-device queue leaves the job PENDING; never a
        fabricated understanding and never a model fallback."""
        import json as _json
        correlation_id = str(uuid4())
        started = time.monotonic()

        # --- parse meta --------------------------------------------------------
        try:
            m = _json.loads(meta)
            if not isinstance(m, dict) or "moment_id" not in m:
                raise ValueError("meta must be a JSON object with moment_id")
            moment_id = UUID(str(m["moment_id"]))
            source_capture_id = UUID(str(m["source_capture_id"])) if m.get("source_capture_id") else None
        except (ValueError, KeyError) as e:
            raise HTTPException(status_code=422, detail=f"invalid meta json: {e}")

        cap_ctx_raw = m.get("capture_context")
        capture_context = None
        if isinstance(cap_ctx_raw, dict):
            capture_context = CaptureContext(shot=cap_ctx_raw.get("shot"), beat=cap_ctx_raw.get("beat"))

        # --- validate frames + timestamps -------------------------------------
        try:
            fmeta = _json.loads(frames_meta)
            if not isinstance(fmeta, list):
                raise ValueError("frames_meta must be a JSON array")
        except ValueError as e:
            raise HTTPException(status_code=422, detail=f"invalid frames_meta json: {e}")

        if not frames:
            raise HTTPException(status_code=422, detail="no frames provided")
        if len(frames) != _AU_MIN_FRAMES:
            raise HTTPException(
                status_code=422,
                detail=f"au_frames/1 requires exactly {_AU_MIN_FRAMES} frames; got {len(frames)}",
            )
        if len(fmeta) != len(frames):
            raise HTTPException(status_code=422, detail="frames_meta length must match frames count")

        au_frames: list[AUFrame] = []
        total = 0
        last_t = -1
        for f, fm in zip(frames, fmeta):
            if (f.content_type or "").lower() not in _AU_ALLOWED_TYPES:
                raise HTTPException(status_code=415, detail=f"unsupported frame type: {f.content_type}")
            if not isinstance(fm, dict) or "t_ms" not in fm:
                raise HTTPException(status_code=422, detail="each frames_meta entry needs t_ms")
            try:
                t_ms = int(fm["t_ms"])
            except (TypeError, ValueError):
                raise HTTPException(status_code=422, detail="t_ms must be an integer (ms)")
            if t_ms < 0 or t_ms <= last_t:
                raise HTTPException(status_code=422, detail="frame timestamps must be monotonically increasing")
            last_t = t_ms
            data = await f.read()
            if len(data) > _AU_MAX_FRAME_BYTES:
                raise HTTPException(status_code=413, detail="a frame exceeds the per-frame size limit")
            total += len(data)
            if total > _AU_MAX_TOTAL_BYTES:
                raise HTTPException(status_code=413, detail="total payload exceeds the size limit")
            au_frames.append(AUFrame(data=data, t_ms=t_ms))

        base_fields = {
            "operation": "asset_understanding",
            "correlation_id": correlation_id,
            "task": "asset_understanding.analyze",
            "prompt_version": AU_PROMPT_VERSION,
            "schema_version": AU_SCHEMA_VERSION,
            "frame_policy": AU_FRAME_POLICY,
            "frame_count": len(au_frames),
            "compressed_payload_bytes": total,
            "has_capture_context": capture_context is not None,
            # NEVER log: frame bytes, raw prose, filenames, moment prose (06 §11).
        }

        req_meta = AURequestMeta(
            moment_id=moment_id, source_capture_id=source_capture_id, capture_context=capture_context
        )
        try:
            # OFFLOAD the blocking Bedrock call off the event loop. This handler is `async def`, so calling the
            # synchronous engine.analyze() directly froze the single-worker event loop for the full ~10-14s model
            # latency — serializing EVERY request behind each AU call and timing out interactive ones (the P0
            # "Couldn't create your Story" while another Story imports). run_in_threadpool runs it on a worker
            # thread so the loop stays free for interactive requests (creative-intent et al.). The semaphore
            # bounds concurrent AU so it never occupies the whole threadpool (interactive handlers don't take it).
            async with _AU_ADMISSION:
                au = await run_in_threadpool(engine.analyze, au_frames, req_meta)
        except AURetryableError as e:
            log.warning(
                "asset_understanding_retryable_failure",
                extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                       "success": False, "retryable": True, "error": str(e)[:300]},
            )
            raise HTTPException(
                status_code=503,
                detail="asset_understanding_unavailable: analysis failed after retry; job stays pending",
            )
        # Frames discarded here (not persisted) — ephemeral inference input.
        log.info(
            "asset_understanding_resolved",
            extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                   "success": True, "retried": au.retried, "attempts": au.attempts,
                   "model": au.model, "input_tokens": au.usage_input_tokens,
                   "output_tokens": au.usage_output_tokens,
                   "event_count": len(au.understanding.observed.events),
                   "story_utility": au.understanding.story_context.story_utility.value},
        )
        return au.understanding

    @app.post("/v1/story-coverage", response_model=StoryCoverageContract, status_code=200)
    def story_coverage(
        body: StoryCoverageRequest,
        engine: StoryCoverageEngine = Depends(get_story_coverage_engine),
    ) -> StoryCoverageContract:
        """Compute a StoryCoverage snapshot from CreativeIntent + completed MomentUnderstanding[] +
        pending_count via Opus (FROZEN, Milestone E). Full recomputation; text-only (no media). On
        model/provider failure, return 503 so the client keeps its previous valid cached coverage —
        never a fabricated snapshot."""
        correlation_id = str(uuid4())
        started = time.monotonic()
        if len(body.moment_understandings) > _COV_MAX_MOMENTS:
            raise HTTPException(status_code=413, detail=f"too many moments (max {_COV_MAX_MOMENTS})")

        base_fields = {
            "operation": "story_coverage", "correlation_id": correlation_id,
            "task": "story_coverage.compute", "prompt_version": COV_PROMPT_VERSION,
            "schema_version": COV_SCHEMA_VERSION,
            "moment_count": len(body.moment_understandings), "pending_count": body.pending_count,
            # NEVER log: raw understanding prose / summaries. Metadata only (06/E §privacy).
        }
        try:
            cov = engine.compute(CoverageInput(
                story_id=body.story_id, creative_intent=body.creative_intent, scope=body.scope,
                moment_understandings=body.moment_understandings, pending_count=body.pending_count,
            ))
        except CoverageUnavailableError as e:
            log.warning("story_coverage_unavailable",
                extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                       "success": False, "error": str(e)[:300]})
            raise HTTPException(
                status_code=503,
                detail="story_coverage_unavailable: could not compute; keep previous cached coverage")
        log.info("story_coverage_resolved",
            extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                   "success": True, "sufficiency": cov.sufficiency.status.value,
                   "dimension_count": len(cov.dimensions), "has_story_idea": cov.story_idea is not None})
        return cov

    @app.post("/v1/story-guide", response_model=StoryGuideContract, status_code=200)
    def story_guide(
        body: StoryGuideRequest,
        engine: StoryGuideEngine = Depends(get_story_guide_engine),
    ) -> StoryGuideContract:
        """Generate the persistent StoryGuide from CreativeIntent (Milestone E2-a, FROZEN). ONCE per
        Story, text-only, Opus 4.6. Server mints canonical stable dimension/possibility ids. On failure
        return 503 so Story creation is NOT lost and NO generic Guide is fabricated — the client keeps
        CreativeIntent and retries."""
        correlation_id = str(uuid4())
        started = time.monotonic()
        base = {"operation": "story_guide", "correlation_id": correlation_id,
                "task": "story_guide.generate", "prompt_version": "story_guide/v1",
                "schema_version": "story_guide/1"}
        try:
            guide = engine.generate(GuideInput(
                story_id=body.story_id, creative_intent=body.creative_intent, scope=body.scope,
                source_creative_intent_version=body.source_creative_intent_version))
        except GuideUnavailableError as e:
            log.warning("story_guide_unavailable",
                extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                       "success": False, "error": str(e)[:300]})
            raise HTTPException(status_code=503,
                detail="story_guide_unavailable: could not generate; preserve CreativeIntent and retry")
        log.info("story_guide_resolved",
            extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                   "success": True, "dimension_count": len(guide.dimensions)})
        return guide

    @app.post("/v1/music-direction", response_model=MusicDirectionContract, status_code=200)
    def music_direction(
        body: MusicDirectionRequest,
        engine: MusicDirectionEngine = Depends(get_music_direction_engine),
    ) -> MusicDirectionContract:
        """Infer the intended soundtrack CHARACTER from CreativeIntent (+ optional Guide framing),
        Milestone M-c. DETERMINISTIC — no model call, no StoryCoverage, not regenerated per Moment.
        A user-authored MusicDirection overrides this (client-persisted); this endpoint only supplies
        the inferred default. Invalid CreativeIntent -> 422 (never fabricate a generic feel)."""
        correlation_id = str(uuid4())
        started = time.monotonic()
        base = {"operation": "music_direction", "correlation_id": correlation_id,
                "task": "music_direction.infer", "schema_version": "music_direction/1"}
        try:
            intent = CreativeIntentContract.model_validate(body.creative_intent)
        except Exception as e:
            log.warning("music_direction_bad_intent",
                extra={**base, "success": False, "error": str(e)[:300]})
            raise HTTPException(status_code=422,
                detail="invalid creative_intent for music-direction inference")
        direction = engine.infer(intent, guide_framing_summary=body.guide_framing_summary)
        log.info("music_direction_inferred",
            extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                   "success": True, "mood_tag_count": len(direction.mood_tags)})
        return direction

    @app.post("/v1/edit-plan", response_model=EditPlanV2Contract, status_code=200)
    def edit_plan(
        body: EditPlanRequest,
        engine: EditPlannerEngine = Depends(get_edit_planner_engine),
    ) -> EditPlanV2Contract:
        """Produce an executable EditPlan (Milestone M-d, frozen edit_plan/2): CreativeIntent + StoryGuide/1 +
        StoryCoverage/2 + MomentUnderstanding[] + MusicPlan/1 (+ optional MusicAsset + MusicAnalysis) -> ONE
        Opus 4.6 call under a DETERMINISTIC validator. Music is OPTIONAL. The planner PLANS; the Media Engine
        (separate milestone) renders. On model failure / non-executable plan -> 503 (never fabricate). On
        infeasible material -> 422 with the reason (preserve the user's Story + Moments; allow retry)."""
        correlation_id = str(uuid4())
        started = time.monotonic()
        base = {"operation": "edit_plan", "correlation_id": correlation_id,
                "task": "edit_plan.generate", "schema_version": "edit_plan/2",
                "has_music_analysis": body.music_analysis is not None, "moment_count": len(body.moments),
                "planning_mode": "text_only"}
        inputs = EditPlanInputs(
            story_id=str(body.story_id), creative_intent_id=str(body.creative_intent_id),
            creative_intent=body.creative_intent, story_guide=body.story_guide,
            story_coverage=body.story_coverage, moments=body.moments, music_plan=body.music_plan,
            output_format=body.output_format, music_asset_id=body.music_asset_id,
            music_plan_id=str(body.music_plan_id) if body.music_plan_id else None,
            music_analysis=body.music_analysis, sound_preference=body.sound_preference,
            editorial_mode=body.editorial_mode, revision_context=body.revision_context)
        return _execute_edit_plan(engine, inputs, base, started)

    def _execute_edit_plan(engine, inputs, base, started):
        """Shared planning core for the text-only (/v1/edit-plan) and multimodal (/v1/edit-plan-mm) endpoints:
        run engine.generate under the identical exception ladder + logging. Keeping ONE core guarantees the
        multimodal path has the SAME deterministic validation, infeasibility handling, and failure semantics as
        the frozen text-only path — the only difference between the two is the EditPlanInputs it is handed."""
        body_moments = inputs.moments
        try:
            plan = engine.generate(inputs)
        except MalformedPlanError as e:
            # Structurally malformed inputs/plan (e.g. wrong-shaped useful_segments) — a CLIENT fault.
            # Clean 422, never an unhandled 500.
            log.warning("edit_plan_malformed", extra={**base, "success": False, "reason": str(e)[:300]})
            raise HTTPException(status_code=422, detail=f"edit plan input malformed: {e}")
        except EditPlanInfeasibleError as e:
            # §4 safeguard: a MODEL-declared infeasibility is NOT automatically true. The planner is allowed
            # to OMIT redundant/less-valuable Moments, so "too many Moments for Ns" is not valid grounds to
            # refuse. Corroborate against deterministic evidence (non-overlapping useful coverage vs target):
            #   coverage < target  -> genuine MATERIAL infeasibility: 422, client may create a shorter Story.
            #   coverage >= target -> material is sufficient; the model refused anyway = PLANNING DEFECT, not
            #                         material insufficiency. Distinct 422 that must NOT route to shorter-Story.
            ev = compute_duration_evidence(body_moments)
            cov = ev.get("total_useful_coverage_seconds") or 0.0
            target = (inputs.creative_intent or {}).get("target_duration_seconds") or 0.0
            material_insufficient = bool(target) and cov < target
            klass = "material_infeasible" if material_insufficient else "planning_defect_unsupported_infeasibility"
            log.warning("edit_plan_infeasible",
                        extra={**base, "success": False, "reason": str(e)[:300], "classification": klass,
                               "useful_coverage_s": round(cov, 1), "target_s": target,
                               "model_calls": (getattr(engine, "last_diagnostics", {}) or {}).get("model_calls")})
            if material_insufficient:
                # Genuine insufficiency — the existing shorter-Story / keep-shooting recovery is correct.
                raise HTTPException(status_code=422, detail=f"edit plan infeasible (material): {e}")
            # Material IS sufficient but the model refused — do not fabricate a plan, but do NOT tell the user
            # to shorten a Story that has enough footage. Surface it as a distinct retryable planning failure.
            raise HTTPException(status_code=503,
                                detail="edit plan could not be produced for this Story; retry")
        except StructuredOutputError as e:
            # The model produced a schema-valid but NON-executable plan that survived bounded repair.
            # Distinct from a provider outage so clients/logs do not conflate the two. Still 503 (retryable).
            diag = getattr(engine, "last_diagnostics", {}) or {}
            log.warning("edit_plan_invalid_after_repair",
                        extra={**base, "success": False, "error": str(e)[:300],
                               "model_calls": diag.get("model_calls"),
                               "repairs_used": diag.get("executability_repairs_used"),
                               "raw_feasible": diag.get("raw_feasible"),
                               "raw_infeasible_reason": diag.get("raw_infeasible_reason"),
                               "raw_segment_count": diag.get("raw_segment_count"),
                               # TRUNCATION diagnostics: last_stop_reason=='max_tokens' + last_output_tokens≈max_tokens
                               # proves the empty plan is an OUTPUT-TRUNCATION, not the model choosing empty.
                               "last_stop_reason": diag.get("last_stop_reason"),
                               "last_output_tokens": diag.get("last_output_tokens"),
                               "max_tokens": diag.get("max_tokens"),
                               "last_max_tokens_used": diag.get("last_max_tokens_used"),
                               "truncation_escalations": diag.get("truncation_escalations", 0),
                               "input_tokens": diag.get("input_tokens"),
                               # INPUT SIZE: moment count + the serialized request payload bytes.
                               "n_moments": len(body_moments),
                               "request_bytes": len(json.dumps(body_moments, default=str))})
            raise HTTPException(status_code=503,
                                detail="edit plan could not be made executable; retry")
        except ProviderError as e:
            log.warning("edit_plan_unavailable", extra={**base, "success": False, "error": str(e)[:300]})
            raise HTTPException(status_code=503, detail="edit planner temporarily unavailable; retry")
        diag = getattr(engine, "last_diagnostics", {}) or {}
        log.info("edit_plan_generated",
            extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                   "success": True, "segment_count": len(plan.segments), "feasible": plan.feasible,
                   "prompt_version": _edit_planner_prompt_version(),
                   "first_pass_executable": diag.get("first_pass_executable"),
                   "normalized": diag.get("normalized"), "repaired": diag.get("repaired"), "used_fallback": diag.get("used_fallback"),
                   "model_calls": diag.get("model_calls"),
                   "truncation_escalations": diag.get("truncation_escalations", 0),
                   "last_max_tokens_used": diag.get("last_max_tokens_used"),
                   "critique_attempted": diag.get("critique_attempted", False),
                   "critique_applied": diag.get("critique_applied"),
                   "critique_rejected_reason": diag.get("critique_rejected_reason")})
        return plan

    @app.post("/v1/edit-plan-mm", response_model=EditPlanV2Contract, status_code=200)
    async def edit_plan_mm(
        body: str = Form(..., description="JSON EditPlanRequest body (same shape as /v1/edit-plan)"),
        sheet_order: str = Form(..., description="JSON array of Moment ids, one per contact-sheet, in sheets[] order"),
        creative_brief: str | None = Form(default=None, description="versioned app-level brief; omit for none"),
        critique_revision: bool = Form(default=False, description="Phase-6 Arm D: run ONE bounded critique->revision pass after a valid plan (OFF by default; costs 2 extra model calls)"),
        sheets: list[UploadFile] = File(default=[], description="bounded Tier-1 contact-sheet JPEGs, one per Moment"),
        engine: EditPlannerEngine = Depends(get_edit_planner_engine),
    ) -> EditPlanV2Contract:
        """MVP MULTIMODAL Edit Planner. Same frozen edit_plan/2 contract, same deterministic validator, same
        exception semantics as /v1/edit-plan — it additionally attaches bounded, DERIVED Tier-1 contact-sheet
        JPEGs (one per Moment) and an optional versioned creative brief to the SAME planning call. Images are
        EPHEMERAL (never persisted) and are validated against server-side size/count ceilings as a backstop to
        the device adaptive preflight. On ANY image-input problem the device is expected to retry text-only via
        /v1/edit-plan; this endpoint never fabricates missing evidence. The frozen v5.2 SYSTEM body is untouched
        — the brief and the image-mapping line live only in the user message."""
        import json as _json
        from model_gateway import ImageInput
        correlation_id = str(uuid4())
        started = time.monotonic()

        # DIAGNOSTICS: every multimodal REJECTION is logged with a stable `reject_reason` code + the counts
        # needed to tell the branches apart in CloudWatch, so a device fallback is never a silent mystery.
        # The exact `detail` the client receives is logged verbatim too. No image bytes / content are logged.
        def _reject(status: int, detail: str, reason: str, **extra):
            log.warning("edit_plan_mm_rejected",
                        extra={"operation": "edit_plan", "correlation_id": correlation_id,
                               "task": "edit_plan.generate", "schema_version": "edit_plan/2",
                               "success": False, "http_status": status, "reject_reason": reason,
                               "detail": detail[:400], "sheet_part_count": len(sheets),
                               "sheet_order_len": _order_len, "creative_brief_present": bool(creative_brief),
                               **extra})
            raise HTTPException(status_code=status, detail=detail)

        _order_len: int | None = None  # filled once sheet_order parses; None => parse failed before it

        # --- parse the JSON body as the SAME shape /v1/edit-plan validates (reuse the Pydantic model) --------
        try:
            parsed = EditPlanRequest.model_validate_json(body)
        except Exception as e:
            _reject(422, f"invalid edit-plan body json: {e}", "body_json_invalid")
        try:
            order = _json.loads(sheet_order)
            if not isinstance(order, list) or not all(isinstance(x, str) for x in order):
                raise ValueError("sheet_order must be a JSON array of Moment id strings")
        except ValueError as e:
            _reject(422, f"invalid sheet_order json: {e}", "sheet_order_json_invalid")
        except Exception as e:  # json.loads can raise JSONDecodeError (a ValueError subclass) or others
            _reject(422, f"invalid sheet_order json: {e}", "sheet_order_json_invalid")
        _order_len = len(order)

        # --- validate the contact sheets (count / per-sheet bytes / total bytes / type) ---------------------
        if len(sheets) > _MM_EDIT_MAX_SHEETS:
            _reject(413, f"too many contact sheets (> {_MM_EDIT_MAX_SHEETS})", "too_many_sheets",
                    limit=_MM_EDIT_MAX_SHEETS)
        if len(order) != len(sheets):
            _reject(422, "sheet_order length must match sheets count", "order_sheet_count_mismatch")
        known_ids = {str(m.get("id")) for m in parsed.moments if isinstance(m, dict)}
        images: list[ImageInput] = []
        total = 0
        for f, mid in zip(sheets, order):
            if (f.content_type or "").lower() not in _MM_EDIT_ALLOWED_TYPES:
                _reject(415, f"unsupported sheet type: {f.content_type}", "unsupported_sheet_type",
                        content_type=str(f.content_type), moment_count=len(parsed.moments))
            if mid not in known_ids:
                # A sheet that maps to no Moment in the body is a client bug — never silently drop a Moment,
                # and never attach an orphan image. Log a SAMPLE of known ids (never the images) so an
                # id-mismatch (casing, wrong id source) is diagnosable from the log alone.
                _reject(422, f"contact sheet maps to unknown Moment id {mid}", "unknown_moment_id",
                        unknown_id=mid, moment_count=len(parsed.moments),
                        known_ids_sample=sorted(known_ids)[:3])
            data = await f.read()
            if len(data) > _MM_EDIT_MAX_SHEET_BYTES:
                _reject(413, "a contact sheet exceeds the per-sheet size limit", "sheet_too_large",
                        moment_id=mid, sheet_bytes=len(data), per_sheet_limit=_MM_EDIT_MAX_SHEET_BYTES)
            total += len(data)
            if total > _MM_EDIT_MAX_TOTAL_BYTES:
                _reject(413, "total image payload exceeds the size limit", "total_payload_too_large",
                        total_bytes=total, total_limit=_MM_EDIT_MAX_TOTAL_BYTES)
            images.append(ImageInput(data=data, media_type="image/jpeg"))

        base = {"operation": "edit_plan", "correlation_id": correlation_id,
                "task": "edit_plan.generate", "schema_version": "edit_plan/2",
                "has_music_analysis": parsed.music_analysis is not None, "moment_count": len(parsed.moments),
                "planning_mode": "multimodal" if images else "text_only",
                "sheet_count": len(images), "image_payload_bytes": total,
                "creative_brief_present": bool(creative_brief),
                "critique_revision_requested": bool(critique_revision)}
        inputs = EditPlanInputs(
            story_id=str(parsed.story_id), creative_intent_id=str(parsed.creative_intent_id),
            creative_intent=parsed.creative_intent, story_guide=parsed.story_guide,
            story_coverage=parsed.story_coverage, moments=parsed.moments, music_plan=parsed.music_plan,
            output_format=parsed.output_format, music_asset_id=parsed.music_asset_id,
            music_plan_id=str(parsed.music_plan_id) if parsed.music_plan_id else None,
            music_analysis=parsed.music_analysis, sound_preference=parsed.sound_preference,
            editorial_mode=parsed.editorial_mode, revision_context=parsed.revision_context,
            images=images, creative_brief=creative_brief, image_moment_order=order,
            critique_revision=bool(critique_revision))
        # Offload the blocking Bedrock call off the event loop (this handler is async). Same pattern as AU.
        import anyio as _anyio
        return await _anyio.to_thread.run_sync(_execute_edit_plan, engine, inputs, base, started)

    # ========================================================================================================
    # ASYNC EDIT PLANNING (owner-approved 2026-10-13) — beats App Runner's ~120s request ceiling by running the
    # plan/critique/validate pipeline in a Lambda worker. Submit returns a job id FAST (no model call); the
    # worker (apps/api/app/worker.py) reuses the SAME _execute_edit_plan core. Contract:
    # specs/.../async-edit-planning-CONTRACT.md. Dev only. The sync endpoints above stay for back-compat.
    # ========================================================================================================
    def _job_store() -> "_jobs.JobStore":
        # Test seam: app.state._job_store_override lets the endpoint tests inject a fake (no AWS). Prod builds
        # a real JobStore (lazy boto3 clients) from env.
        ov = getattr(app.state, "_job_store_override", None)
        return ov if ov is not None else _jobs.JobStore()

    def _dev_access_ok() -> bool:
        # Adjustment 1: UUIDv5 secrecy is NOT authentication. In dev the job API is gated by an env flag so it
        # is not open to the world; a real auth principal replaces this when auth lands. Default ON in dev.
        import os as _os
        return _os.environ.get("STORY_JOBS_API_ENABLED", "1") == "1"

    @app.post("/v1/edit-plan-jobs", status_code=202)
    async def submit_edit_plan_job(
        operation_id: str = Form(..., description="client idempotency key; a NEW version uses a NEW id"),
        owner: str = Form(default="dev", description="advisory only — NOT trusted as identity (adjustment 1)"),
        body: str = Form(..., description="JSON EditPlanRequest body (same shape as /v1/edit-plan)"),
        sheet_order: str = Form(default="[]", description="JSON array of Moment ids, one per sheet"),
        creative_brief: str | None = Form(default=None),
        critique_revision: bool = Form(default=False),
        approach: str = Form(default="storytelling", description="storytelling|visual_first (diagnostics)"),
        test_delay_s: int = Form(default=0, description="ACCEPTANCE-ONLY: artificial worker delay (honored only when the worker enables it); simulates a long job"),
        sheets: list[UploadFile] = File(default=[]),
    ):
        """Submit an async Edit Planning job. Returns {job_id,status} promptly (no model call). Idempotent on
        operation_id; a same-id DIFFERENT-payload submit is 409. Stages derived sheets to encrypted S3, then
        enqueues for the worker."""
        import json as _json
        if not _dev_access_ok():
            raise HTTPException(status_code=404, detail="not found")
        try:
            parsed = EditPlanRequest.model_validate_json(body)
        except Exception as e:
            raise HTTPException(status_code=422, detail=f"invalid edit-plan body json: {e}")
        try:
            order = _json.loads(sheet_order)
            assert isinstance(order, list) and all(isinstance(x, str) for x in order)
        except Exception as e:
            raise HTTPException(status_code=422, detail=f"invalid sheet_order json: {e}")
        if len(sheets) > _MM_EDIT_MAX_SHEETS:
            raise HTTPException(status_code=413, detail=f"too many contact sheets (> {_MM_EDIT_MAX_SHEETS})")
        if len(order) != len(sheets):
            raise HTTPException(status_code=422, detail="sheet_order length must match sheets count")
        known_ids = {str(m.get("id")) for m in parsed.moments if isinstance(m, dict)}
        staged: list[tuple[str, bytes]] = []
        digests: list[str] = []
        total = 0
        for f, mid in zip(sheets, order):
            if (f.content_type or "").lower() not in _MM_EDIT_ALLOWED_TYPES:
                raise HTTPException(status_code=415, detail=f"unsupported sheet type: {f.content_type}")
            if mid not in known_ids:
                raise HTTPException(status_code=422, detail=f"contact sheet maps to unknown Moment id {mid}")
            data = await f.read()
            if len(data) > _MM_EDIT_MAX_SHEET_BYTES:
                raise HTTPException(status_code=413, detail="a contact sheet exceeds the per-sheet size limit")
            total += len(data)
            if total > _MM_EDIT_MAX_TOTAL_BYTES:
                raise HTTPException(status_code=413, detail="total image payload exceeds the size limit")
            staged.append((mid, data))
            digests.append(_jobs.sheet_digest(data))

        store = _job_store()
        fp = _jobs.payload_fingerprint(body, order, bool(critique_revision), approach,
                                       creative_brief=creative_brief, sheet_digests=digests)
        jid = _jobs.job_id_for(operation_id)
        # Stage BEFORE create so the worker always finds its inputs. Re-staging on a duplicate is harmless
        # (same prefix, same content). Body carries brief + critique + approach so the worker is self-contained.
        import json as _j2
        body_envelope = _j2.dumps({"body": body, "sheet_order": order, "creative_brief": creative_brief,
                                    "critique_revision": bool(critique_revision), "approach": approach,
                                    "_test_delay_s": int(test_delay_s or 0)})
        prefix = store.stage_request(jid, body_envelope, staged)
        try:
            job_id, created = store.create_or_get(
                operation_id=operation_id, owner=owner, approach=approach,
                critique_requested=bool(critique_revision), staging_prefix=prefix,
                sheet_order=order, payload_fingerprint=fp)
        except _jobs.PayloadConflict as e:
            raise HTTPException(status_code=409, detail=str(e))
        if created:
            store.enqueue(job_id)
        log.info("edit_plan_job_submitted", extra={"operation": "edit_plan_job", "job_id": job_id,
                 "job_created": created, "approach": approach, "sheet_count": len(staged),
                 "image_payload_bytes": total, "critique_requested": bool(critique_revision)})
        return {"job_id": job_id, "status": "queued"}

    @app.get("/v1/edit-plan-jobs/{job_id}")
    def get_edit_plan_job(job_id: str):
        if not _dev_access_ok():
            raise HTTPException(status_code=404, detail="not found")
        job = _job_store().get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="job not found")
        out = {k: job.get(k) for k in ("job_id", "status", "approach", "failure_category",
                                       "failure_detail", "diagnostics")}
        if job.get("status") == "completed":
            out["plan"] = job.get("plan")
        return out

    @app.post("/v1/edit-plan-jobs/{job_id}/cancel")
    def cancel_edit_plan_job(job_id: str):
        if not _dev_access_ok():
            raise HTTPException(status_code=404, detail="not found")
        store = _job_store()
        if not store.get(job_id):
            raise HTTPException(status_code=404, detail="job not found")
        return {"job_id": job_id, "status": store.request_cancel(job_id)}

    @app.post("/v1/edit-plan-jobs/_reconcile")
    def reconcile_edit_plan_jobs():
        """Lost-enqueue recovery sweep (concern 6). Called by a scheduled EventBridge rule in CDK; also
        callable manually in dev. Re-enqueues only never-leased stranded queued jobs, capped."""
        if not _dev_access_ok():
            raise HTTPException(status_code=404, detail="not found")
        return {"reenqueued": _job_store().reconcile_lost_enqueue()}

    @app.post("/v1/music-plan", response_model=MusicPlanContract, status_code=200)
    def music_plan(
        body: MusicPlanRequest,
        engine: MusicPlanEngine = Depends(get_music_plan_engine),
    ) -> MusicPlanContract:
        """Produce the Story-level MusicPlan (Milestone R-d, frozen music_plan/1): CreativeIntent +
        authoritative MusicDirection + StoryGuide + StoryCoverage/2 + target duration -> ONE Opus 4.6 call,
        structured tool-use. Generated at creation time, NOT per Moment. The engine NEVER fabricates: on
        model/provider failure the endpoint returns 503 so the client falls back to no-music creation."""
        correlation_id = str(uuid4())
        started = time.monotonic()
        base = {"operation": "music_plan", "correlation_id": correlation_id,
                "task": "music_plan.generate", "schema_version": "music_plan/1",
                "target_s": body.target_duration_seconds}
        inputs = MusicPlanInputs(
            story_id=str(body.story_id),
            creative_intent=body.creative_intent,
            music_direction=body.music_direction,
            target_duration_seconds=body.target_duration_seconds,
            story_guide=body.story_guide,
            story_coverage=body.story_coverage,
            sound_preference=body.sound_preference,
        )
        try:
            plan = engine.generate(inputs)
        except StructuredOutputError as e:
            log.warning("music_plan_invalid", extra={**base, "success": False, "error": str(e)[:300]})
            raise HTTPException(status_code=503, detail="music plan could not be produced; create without music or retry")
        except ProviderError as e:
            log.warning("music_plan_unavailable", extra={**base, "success": False, "error": str(e)[:300]})
            raise HTTPException(status_code=503, detail="music planner temporarily unavailable; retry")
        diag = getattr(engine, "last_diagnostics", {}) or {}
        log.info("music_plan_generated",
                 extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                        "success": True, "regions": diag.get("regions"),
                        "soundtrack_role": plan.audio_strategy.soundtrack_role,
                        "native_audio_priority": plan.audio_strategy.native_audio_priority,
                        "model_calls": diag.get("model_calls")})
        return plan

    @app.post("/v1/duration-recommendation", status_code=200)
    def duration_recommendation(
        body: DurationRecommendationRequest,
        engine: DurationPlannerEngine = Depends(get_duration_planner_engine),
    ):
        """Recommend a target duration (Milestone R-d.2, frozen duration_recommendation/1). Deterministic
        evidence (useful-segment union, longest continuous span, feasible band) is computed LOCALLY; one Opus
        call adds the scope-aware recommendation. Returns {evidence, recommendation}. On model/provider failure
        the endpoint STILL returns 200 with the deterministic evidence and recommendation=null, so the client
        falls back to manual duration selection rather than failing creation. There is NO universal default."""
        correlation_id = str(uuid4())
        started = time.monotonic()
        base = {"operation": "duration_recommendation", "correlation_id": correlation_id,
                "task": "duration.recommend", "prompt_version": "duration_recommendation/1"}
        evidence = compute_duration_evidence(body.moments)
        explicit = None
        ci = body.creative_intent or {}
        if isinstance(ci.get("target_duration_seconds"), (int, float)):
            explicit = float(ci["target_duration_seconds"])
        if evidence.get("zero_usable_material"):
            log.info("duration_recommendation_no_material", extra={**base, "success": True, "zero_material": True})
            return {"evidence": evidence, "recommendation": None, "explicit_target_seconds": explicit,
                    "note": "no usable material; keep shooting"}
        recommendation = None
        error = None
        try:
            recommendation = engine.recommend(DurationPlannerInputs(
                creative_intent=ci, evidence=evidence,
                story_guide=body.story_guide, story_coverage=body.story_coverage,
                requested_scope=body.requested_scope))
        except (StructuredOutputError, ProviderError) as e:
            error = str(e)[:300]
            log.warning("duration_recommendation_unavailable", extra={**base, "success": False, "error": error})
        diag = getattr(engine, "last_diagnostics", {}) or {}
        log.info("duration_recommendation_done",
                 extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                        "success": recommendation is not None,
                        "n_moments": evidence.get("n_moments"),
                        "feasible_ceiling_s": evidence.get("feasible_band_seconds", [0, 0])[1],
                        "longest_continuous_s": evidence.get("longest_continuous_span_seconds"),
                        "recommended": recommendation.get("recommended_range_seconds") if recommendation else None,
                        "model_calls": diag.get("model_calls")})
        return {"evidence": evidence, "recommendation": recommendation,
                "explicit_target_seconds": explicit,
                "note": None if recommendation else "recommendation unavailable; choose a duration manually"}

    @app.post("/v1/music/candidates", status_code=200)
    def music_candidates(body: MusicCandidatesRequest):
        """PROTOTYPING-ONLY (Milestone M-d): MusicPlan -> Epidemic search -> deterministic ranked candidates +
        normalized music_analysis/1 for the top pick. Gated behind STORY_EPIDEMIC_MODE=prototyping; returns 404
        when the flag is off so it is invisible in normal production. No sublicense/safelist/export path here."""
        if not _mp.prototyping_enabled():
            raise HTTPException(status_code=404, detail="not found")  # invisible unless prototyping-enabled
        correlation_id = str(uuid4())
        base = {"operation": "music_candidates", "correlation_id": correlation_id, "mode": "prototyping"}
        try:
            client = _mp.get_music_client()
        except _mp.EpidemicAuthError:
            raise HTTPException(status_code=503, detail="music provider auth unavailable")
        char = (body.music_plan or {}).get("character", {})
        term = " ".join(char.get("mood_tags", []) or ["music"])
        strat = (body.music_plan or {}).get("audio_strategy", {})
        vocal = "NONE" if strat.get("native_audio_priority") in ("important", "selective") else None
        is_page1 = body.cursor is None
        try:
            if hasattr(client, "search_page"):
                raw, next_cursor = client.search_page(term, page_size=body.limit, cursor=body.cursor)
            else:
                raw, next_cursor = client.search(term, vocal_type=vocal, limit=body.limit), None
        except _mp.EpidemicProviderError as e:
            log.warning("music_candidates_provider_error", extra={**base, "error": str(e)[:200]})
            raise HTTPException(status_code=503, detail="music provider temporarily unavailable")
        cands = [_mp.Candidate(track_id=t.get("id"), title=t.get("title", ""),
                               duration_seconds=float(t.get("length") or 0) or 1.0,
                               bpm=(t.get("bpm") or None), mood_tags=t.get("moods", []) or [],
                               vocal_type=t.get("vocalType"))
                 for t in raw if t.get("id")]
        ranked = _mp.rank_candidates(body.music_plan, cands, target_duration=body.target_duration_seconds)
        # Enrich each ranked candidate with a PREVIEW url (consumer can audition before choosing). Best-effort:
        # a provider hiccup on one preview must not fail the whole list.
        out = []
        for c in ranked[: body.limit]:
            preview = None
            try:
                preview = client.preview_url(c.track_id)
            except _mp.EpidemicProviderError:
                # The Epidemic /stream (preview) endpoint can return 402 once the free-tier PREVIEW allowance
                # is spent. The DOWNLOAD link is a separate free-tier allowance and returns the same
                # {url, expires} shape (a direct, AVPlayer-playable MP3 — the render already uses it), so fall
                # back to it for the audition. Still best-effort: if both fail, preview stays None.
                try:
                    preview = client.download_link(c.track_id)
                except _mp.EpidemicProviderError:
                    preview = None
            out.append({"track_id": c.track_id, "title": c.title, "score": c.score,
                        "factors": c.factors, "duration_seconds": c.duration_seconds,
                        "vocal_type": c.vocal_type, "preview_url": preview})
        # Compute MusicAnalysis/1 for the TOP pick only, and ONLY on page 1 — the Edit Planner consumes the
        # page-1 top pick; later pages are browse-only, and a selected track gets its analysis via
        # /v1/music/analysis when chosen. Normalized through the frozen music_analysis/1 path. Best-effort.
        top_analysis = None
        if is_page1 and ranked:
            top = ranked[0]
            try:
                top_analysis = _mp.to_music_analysis_v1(
                    duration_seconds=top.duration_seconds,
                    raw_bpm=top.bpm,
                    raw_beats=client.beats(top.track_id),
                    raw_highlights=client.highlights(top.track_id),
                    waveform=client.waveform_for_track(top.track_id),
                    vocal_type=top.vocal_type,
                ).model_dump(mode="json")
            except _mp.EpidemicProviderError as e:
                log.warning("music_candidates_analysis_error", extra={**base, "error": str(e)[:200]})
                top_analysis = None
        log.info("music_candidates_ranked", extra={**base, "n": len(ranked), "page1": is_page1,
                                                   "has_more": next_cursor is not None})
        return {"candidates": out, "top_track_id": ranked[0].track_id if (is_page1 and ranked) else None,
                "top_music_analysis": top_analysis, "next_cursor": next_cursor}

    @app.post("/v1/music/search", status_code=200)
    def music_search(body: MusicSearchRequest):
        """PROTOTYPING-ONLY: user-driven free-text catalog search with cursor pagination. Returns candidate
        rows (same shape as /v1/music/candidates, incl. a preview url) plus a next_cursor for load-more.
        Unlike /candidates this does NOT rank by a MusicPlan or compute a top analysis — it is a browse
        surface. Flag-gated 404 when prototyping is off."""
        if not _mp.prototyping_enabled():
            raise HTTPException(status_code=404, detail="not found")
        base = {"operation": "music_search", "correlation_id": str(uuid4()), "mode": "prototyping"}
        try:
            client = _mp.get_music_client()
        except _mp.EpidemicAuthError:
            raise HTTPException(status_code=503, detail="music provider auth unavailable")
        if not hasattr(client, "search_page"):
            # defensive: a provider without pagination support — should not happen (both implement it)
            raise HTTPException(status_code=503, detail="music search unavailable")
        try:
            raw, next_cursor = client.search_page(body.query, page_size=body.page_size, cursor=body.cursor)
        except _mp.EpidemicProviderError as e:
            log.warning("music_search_provider_error", extra={**base, "error": str(e)[:200]})
            raise HTTPException(status_code=503, detail="music provider temporarily unavailable")
        out = []
        for t in raw:
            tid = t.get("id")
            if not tid:
                continue
            preview = None
            try:
                preview = client.preview_url(tid)
            except _mp.EpidemicProviderError:
                preview = None
            out.append({
                "track_id": tid,
                "title": t.get("title", ""),
                "score": 0.0,  # search results are unranked (no MusicPlan); kept for DTO parity
                "duration_seconds": float(t.get("length") or 0.0),
                "vocal_type": t.get("vocalType"),
                "preview_url": preview,
            })
        log.info("music_search_page", extra={**base, "n": len(out), "has_more": next_cursor is not None})
        return {"candidates": out, "next_cursor": next_cursor}

    @app.post("/v1/music/analysis", status_code=200)
    def music_analysis(body: MusicTrackRequest):
        """PROTOTYPING-ONLY: MusicAnalysis/1 for a SPECIFIC chosen track (used when the user picks a candidate
        other than the top pick, so the Edit Planner gets analysis for the actual selection). Flag-gated 404."""
        if not _mp.prototyping_enabled():
            raise HTTPException(status_code=404, detail="not found")
        base = {"operation": "music_analysis", "correlation_id": str(uuid4()), "mode": "prototyping"}
        try:
            client = _mp.get_music_client()
            meta = client.metadata(body.track_id)
            analysis = _mp.to_music_analysis_v1(
                duration_seconds=float(meta.get("length") or body.duration_seconds or 1.0),
                raw_bpm=meta.get("bpm"),
                raw_beats=client.beats(body.track_id),
                raw_highlights=client.highlights(body.track_id),
                waveform=client.waveform_for_track(body.track_id),
                vocal_type=meta.get("vocalType"),
            )
        except _mp.EpidemicAuthError:
            raise HTTPException(status_code=503, detail="music provider auth unavailable")
        except _mp.EpidemicProviderError as e:
            log.warning("music_analysis_provider_error", extra={**base, "error": str(e)[:200]})
            raise HTTPException(status_code=503, detail="music provider temporarily unavailable")
        return analysis.model_dump(mode="json")

    @app.post("/v1/music/soundtrack", status_code=200)
    def music_soundtrack(body: MusicTrackRequest):
        """PROTOTYPING-ONLY: return a short-lived AUTHORIZED download link for the SELECTED track so the device
        can fetch the audio for a PRIVATE, NON-COMMERCIAL test render. Flag-gated 404 when the prototyping flag
        is off. This is NOT a sublicense/export surface: COMMERCIAL export stays behind a SEPARATE flag
        (STORY_MUSIC_COMMERCIAL_EXPORT) that remains OFF — when the business API lands, only that flag + the
        provider key swap change, not this code path."""
        if not _mp.prototyping_enabled():
            raise HTTPException(status_code=404, detail="not found")
        base = {"operation": "music_soundtrack", "correlation_id": str(uuid4()), "mode": "prototyping"}
        try:
            client = _mp.get_music_client()
            link = client.download_link(body.track_id, quality="normal")
        except _mp.EpidemicAuthError:
            raise HTTPException(status_code=503, detail="music provider auth unavailable")
        except _mp.EpidemicProviderError as e:
            log.warning("music_soundtrack_provider_error", extra={**base, "error": str(e)[:200]})
            raise HTTPException(status_code=503, detail="music provider temporarily unavailable")
        log.info("music_soundtrack_link", extra={**base, "track_id": body.track_id})
        # usage='prototyping_test' makes the non-commercial constraint explicit to the client.
        return {"track_id": body.track_id, "download_url": link, "usage": "prototyping_test",
                "commercial_export_enabled": False}

    @app.post("/v1/story-coverage/v2", response_model=StoryCoverageContractV2, status_code=200)
    def story_coverage_v2(
        body: StoryCoverageV2Request,
        engine: StoryCoverageV2Engine = Depends(get_story_coverage_v2_engine),
    ) -> StoryCoverageContractV2:
        """Compute StoryCoverage/2 (Milestone E2-b, FROZEN): StoryGuide + completed
        MomentUnderstanding[] + pending_count -> composed Mapper + Judge. Full recomputation,
        text-only. On model/provider failure return 503 so the client keeps its previous valid cached
        coverage — never a fabricated snapshot."""
        correlation_id = str(uuid4())
        started = time.monotonic()
        if len(body.moment_understandings) > _COV_MAX_MOMENTS:
            raise HTTPException(status_code=413, detail=f"too many moments (max {_COV_MAX_MOMENTS})")
        base = {"operation": "story_coverage_v2", "correlation_id": correlation_id,
                "task": "story_coverage.v2", "schema_version": "story_coverage/2",
                "moment_count": len(body.moment_understandings), "pending_count": body.pending_count}
        try:
            cov = engine.compute(CoverageV2Input(
                story_id=body.story_id, story_guide=body.story_guide,
                story_guide_version=body.story_guide_version, creative_intent=body.creative_intent,
                scope=body.scope, moment_understandings=body.moment_understandings,
                pending_count=body.pending_count))
        except CoverageV2UnavailableError as e:
            log.warning("story_coverage_v2_unavailable",
                extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                       "success": False, "error": str(e)[:300]})
            raise HTTPException(status_code=503,
                detail="story_coverage_v2_unavailable: could not compute; keep previous cached coverage")
        log.info("story_coverage_v2_resolved",
            extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                   "success": True, "sufficiency": cov.sufficiency.status.value,
                   "dimension_coverage_count": len(cov.dimension_coverage),
                   "has_story_idea": cov.story_idea is not None})
        return cov

    def _director_log(op: str, out, started, correlation_id):
        log.info(
            "director_resolved",
            extra={
                "operation": op, "correlation_id": correlation_id,
                "prompt_version": DIR_PROMPT_VERSION, "schema_version": DIR_SCHEMA_VERSION,
                "latency_ms": round((time.monotonic() - started) * 1000), "success": True,
                "decision_action": out.decision.action.value,
                "beat_count": len(out.plan.beats), "shot_count": len(out.plan.shots),
            },
        )

    def _director_fail(op, e, started, correlation_id, kind):
        log.warning(
            "director_failed",
            extra={"operation": op, "correlation_id": correlation_id,
                   "prompt_version": DIR_PROMPT_VERSION, "schema_version": DIR_SCHEMA_VERSION,
                   "latency_ms": round((time.monotonic() - started) * 1000),
                   "success": False, kind: True, "error": str(e)[:300]},
        )
        raise HTTPException(status_code=503, detail=f"director_unavailable: {kind}; retry")

    @app.post("/v1/director/initialize", response_model=DirectorOutput, status_code=200)
    def director_initialize(
        body: DirectorInitializeRequest,
        engine: StoryDirectorEngine = Depends(get_story_director_engine),
    ) -> DirectorOutput:
        """CreativeIntent + SceneUnderstanding + constraints -> concept + plan +
        state + first decision. 503 on failure — never a fabricated plan."""
        cid = str(uuid4())
        started = time.monotonic()
        try:
            out = engine.initialize(body.creative_intent, body.scene_understanding,
                                    body.capture_constraints, body.selected_opportunity)
        except StructuredOutputError as e:
            _director_fail("initialize", e, started, cid, "structured_output_failed")
        except ProviderError as e:
            _director_fail("initialize", e, started, cid, "provider_error")
        _director_log("initialize", out, started, cid)
        return out

    @app.post("/v1/director/next", response_model=DirectorOutput, status_code=200)
    def director_next(
        body: DirectorNextRequest,
        engine: StoryDirectorEngine = Depends(get_story_director_engine),
    ) -> DirectorOutput:
        """Prior plan/state + Story progress -> updated state + one decision."""
        cid = str(uuid4())
        started = time.monotonic()
        try:
            out = engine.next(body.prior)
        except StructuredOutputError as e:
            _director_fail("next", e, started, cid, "structured_output_failed")
        except ProviderError as e:
            _director_fail("next", e, started, cid, "provider_error")
        _director_log("next", out, started, cid)
        return out

    @app.post("/v1/stories", response_model=StoryDTO, status_code=201)
    def create_story(
        body: CreateStoryRequest,
        story_engine: StoryEngine = Depends(get_story_engine),
    ) -> StoryDTO:
        """Derive a CreativeIntent from raw_text and create a Story."""
        intent = story_engine.derive_creative_intent(body.raw_text)
        story = story_engine.create_story(body.title, intent)
        store.put(story)
        log.info(
            "story_created",
            extra={"operation": "create_story", "story_id": str(story.id)},
        )
        return StoryDTO.from_domain(story)

    @app.post(
        "/v1/stories/{story_id}/outputs",
        response_model=GeneratedOutputDTO,
        status_code=201,
    )
    def create_output(
        story_id: UUID,
        edit_engine: EditEngine = Depends(get_edit_engine),
    ) -> GeneratedOutputDTO:
        """Create a mock GeneratedOutput for a Story.

        INVARIANT: Create != Complete. This MUST NOT change story.status.
        """
        story = store.get(story_id)
        if story is None:
            raise HTTPException(status_code=404, detail="Story not found")

        status_before = story.status
        output = edit_engine.create_generated_output(story)
        story.add_generated_output(output)  # domain method leaves status untouched

        # Defensive assertion of the product invariant.
        assert story.status == status_before, "Create My Story must not change status"

        log.info(
            "generated_output_created",
            extra={
                "operation": "create_output",
                "story_id": str(story.id),
                "output_id": str(output.id),
                "status_unchanged": story.status == status_before,
            },
        )
        return GeneratedOutputDTO.from_domain(output)

    return app


# Module-level app for `uvicorn app.main:app`.
app = create_app()
