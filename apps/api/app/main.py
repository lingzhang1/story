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
import os
import time
from uuid import UUID, uuid4

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, Response, UploadFile
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
from story_guide import GuideInput, GuideUnavailableError, RefineInput, StoryGuideEngine
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
import media_store as _media  # R2/R3: account-owned cloud media ownership + presigned upload/download
import story_store as _stories  # R7: account-owned Story document sync (optimistic concurrency)
import understanding_store as _understanding  # R7-E: account-level Moment Understanding sync
from understanding_store import music_favorites as _music_favorites  # P1-E: saved catalog-track references


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
import scene_image as _scene_image
from story_coverage_v2 import (
    CoverageV2Input,
    CoverageUnavailableError as CoverageV2UnavailableError,
    StoryCoverageV2Engine,
)
from contracts.schemas.ai_contracts import StoryGuideContract, StoryGuideV2Contract, StoryGuideRefinementResult, StoryCoverageContractV2, MusicDirectionContract, EditPlanV2Contract, MusicPlanContract
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
    get_story_guide_v2_engine,
    get_story_guide_refine_engine,
    get_story_coverage_v2_engine,
    get_music_direction_engine,
    get_edit_planner_engine,
    get_music_plan_engine,
    get_duration_planner_engine,
)
from app.store import InMemoryStoryStore
from app.auth import (  # P0 Beta Auth: trusted-identity dependencies + central deny-by-default boundary
    optional_user, require_user, Principal, auth_boundary, _docs_public,
)
from app.throttle import throttle_middleware  # P0 Beta Security Phase 3: per-user rate limiting
from app import quota_gate  # P0 Beta Security Phase 4: per-user AI quota + spend protection

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


class MediaInitiateRequest(BaseModel):
    """POST /v1/media/initiate body (R2/R3). The device declares the FULL-FILE sha256 (hex) + size of the
    original it is about to upload; the server mints an account-owned record + a presigned PUT. Ownership is
    NOT in the body — it derives from the authenticated principal."""

    model_config = ConfigDict(extra="forbid")
    content_sha256: str = Field(..., description="device-computed full-file sha256 (64-char hex); integrity anchor")
    size_bytes: int = Field(..., gt=0)
    content_type: str = Field(default="video/quicktime")
    device_asset_id: str = Field(default="", description="local AssetModel.id (opaque; client reconciliation)")
    source_moment_id: str = Field(default="")
    # R7-D — "moment" (captured original, default) or "generated" (rendered MP4 backup). A generated upload
    # carries source_output_id (the GeneratedOutput id) instead of source_moment_id; same pipeline otherwise.
    media_kind: str = Field(default="moment")
    source_output_id: str = Field(default="")


class MediaMultipartInitiateRequest(BaseModel):
    """POST /v1/media/multipart/initiate body (R4-B). Declares the full-file sha256 + size AND the per-part
    sha256 (base64), in order. Ownership derives from the authenticated principal."""

    model_config = ConfigDict(extra="forbid")
    content_sha256: str = Field(..., description="full-file sha256 (64-char hex); provenance + single-PUT guarantee")
    size_bytes: int = Field(..., gt=0)
    part_shas: list[str] = Field(..., description="per-part sha256 (base64), in part order")
    content_type: str = Field(default="video/quicktime")
    device_asset_id: str = Field(default="")
    source_moment_id: str = Field(default="")
    media_kind: str = Field(default="moment")       # R7-D: "moment" | "generated"
    source_output_id: str = Field(default="")       # R7-D: set for a generated-video backup


class MediaPresignPartsRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    part_numbers: list[int] = Field(..., description="1-based part numbers to presign")


class StoryPutRequest(BaseModel):
    """PUT /v1/stories/{story_id} body (R7). Optimistic concurrency + idempotency: base_revision is the
    revision the client last observed (0 to create); mutation_id is a stable client-minted key so a
    lost-response retry is NOT read as a conflict. referenced_cloud_media_ids lists the cloud assets the doc
    depends on so the server can verify (C3: a cloud_media_id is never authorization)."""

    model_config = ConfigDict(extra="forbid")
    base_revision: int = Field(..., ge=0)
    mutation_id: str = Field(..., min_length=1, max_length=200)
    doc: dict = Field(..., description="story_doc/1 body")
    deleted: bool = Field(default=False)
    referenced_cloud_media_ids: list[str] = Field(default_factory=list)


class StoryOutputBackupRequest(BaseModel):
    """POST /v1/stories/{story_id}/outputs/{output_id}/backup — register a completed render's verified
    cloud_media_id on the output. The server verifies the asset is THIS account's and cloud_verified."""

    model_config = ConfigDict(extra="forbid")
    cloud_media_id: str = Field(..., min_length=1)


class UnderstandingRecord(BaseModel):
    """One Moment Understanding record for batch PUT (R7-E)."""
    model_config = ConfigDict(extra="forbid")
    moment_id: str = Field(..., min_length=1)
    understanding_json: str = Field(..., min_length=1)
    schema_version: str = Field(..., min_length=1)
    prompt_version: str = Field(default="")
    frame_policy: str = Field(default="")
    content_sha256: str = Field(default="")   # the Moment's media sha; reuse on B gated on an exact match
    model_id: str = Field(default="")


class UnderstandingPutRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    records: list[UnderstandingRecord] = Field(..., min_length=1, max_length=200)


class UnderstandingGetRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    moment_ids: list[str] = Field(..., min_length=1, max_length=400)


class MusicFavorite(BaseModel):
    """One saved catalog-track reference (P1-E). LICENSING: a reference only — never audio bytes."""
    model_config = ConfigDict(extra="forbid")
    track_id: str = Field(..., min_length=1)
    title: str = Field(default="")
    duration_seconds: float = Field(default=0.0)
    saved_at: int = Field(default=0)


class MusicFavoritesPutRequest(BaseModel):
    """PUT /v1/music/favorites body (P1-E). Optimistic concurrency: base_revision is the revision the client
    last observed (0 to create). The whole list is replaced (the client sends its merged set)."""
    model_config = ConfigDict(extra="forbid")
    base_revision: int = Field(..., ge=0)
    favorites: list[MusicFavorite] = Field(default_factory=list, max_length=2000)


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


class StoryGuideRefineRequest(BaseModel):
    """POST /v1/story-guide-refine body (Guide v2.1). The CURRENT v2 shooting script + per-scene
    captured/pinned state + the user's update -> the NEXT v2 shooting script + change log. ADDITIVE;
    the frozen generate-once v2 path is unchanged. captured/pinned ids are PROTECTED (never archived)."""

    model_config = ConfigDict(extra="forbid")
    story_id: UUID
    creative_intent: dict = Field(..., description="the resolved CreativeIntent (compact)")
    scope: dict = Field(default_factory=dict, description="{target_duration_seconds?, format?}")
    current_framing_summary: str = Field(default="")
    current_scenes: list[dict] = Field(default_factory=list,
        description="the current canonical v2 scenes (id/title/what_to_capture/how_to_shoot/why_it_matters)")
    captured_scene_ids: list[str] = Field(default_factory=list,
        description="scene ids with Coverage evidence (PROTECTED — never archived)")
    pinned_scene_ids: list[str] = Field(default_factory=list,
        description="user-pinned scene ids (PROTECTED — never archived)")
    user_instruction: str | None = Field(default=None, description="one-time Update Guide instruction")
    event_context: str | None = Field(default=None, description="persistent editable event context")
    source_creative_intent_version: str | None = Field(default=None)


class SceneImageRequest(BaseModel):
    """POST /v1/scene-image body. ONE reference image for a StoryGuide/2 scene. `query` is the scene's
    GENERIC visual_reference_query (server-authored by the v2 prompt); the server re-sanitizes + hard-bounds
    it. story_id/scene_id are provenance only (logging/cache scoping) — never sent to the provider."""

    model_config = ConfigDict(extra="forbid")
    query: str = Field(..., description="generic scene/composition phrase (bounded + sanitized server-side)")
    story_id: UUID | None = Field(default=None)
    scene_id: str | None = Field(default=None)


class SceneImageTrackRequest(BaseModel):
    """POST /v1/scene-image/track body. Fires Unsplash download-tracking when a photo is actually USED."""

    model_config = ConfigDict(extra="forbid")
    download_location: str = Field(..., description="the Unsplash download_location URL from a prior result")


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
    editorial_type: str | None = Field(
        default=None,
        description="EditPlan v5.3 resolved consumer editorial TYPE: highlights|full_story (None = v5.2 behavior). "
                    "P1-A canonical two-type model, resolved at the attempt boundary. Additive, request-only, "
                    "USER-message advisory; frozen v5.2 system body + EditPlan/2 output UNCHANGED. Part of the "
                    "request snapshot and the canonical async fingerprint (body-hashed).")
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


# Scene-image (Unsplash) proxy: process-global metadata cache + lazily-built client. The key is read
# from Secrets Manager ONCE on first use and the client reused, so each request does not re-hit Secrets
# Manager. `_SCENE_IMAGE_CLIENT_FACTORY` is a test seam — tests set it to a fake (no network, no key).
_SCENE_IMAGE_CACHE = None
_SCENE_IMAGE_CLIENT = None
_SCENE_IMAGE_CLIENT_FACTORY = None  # type: ignore[var-annotated]


def _scene_image_cache():
    global _SCENE_IMAGE_CACHE
    if _SCENE_IMAGE_CACHE is None:
        _SCENE_IMAGE_CACHE = _scene_image.MetadataCache()
    return _SCENE_IMAGE_CACHE


def _scene_image_client():
    """Return a cached Unsplash client. Builds it from the Secrets Manager key on first use (raising
    SceneImageAuthError if the key cannot be read). A test factory, when set, wins and bypasses the key."""
    global _SCENE_IMAGE_CLIENT
    if _SCENE_IMAGE_CLIENT_FACTORY is not None:
        return _SCENE_IMAGE_CLIENT_FACTORY()
    if _SCENE_IMAGE_CLIENT is None:
        key = _scene_image.load_key()  # SceneImageAuthError if missing/denied/empty
        _SCENE_IMAGE_CLIENT = _scene_image.UnsplashClient(key)
    return _SCENE_IMAGE_CLIENT


def create_app() -> FastAPI:
    """Construct the FastAPI app. A factory so tests get a fresh instance
    (and a fresh in-memory store) per app."""
    # Docs endpoints (/docs, /redoc, /openapi.json) are PUBLIC only in development (or with an explicit
    # STORY_DOCS_PUBLIC=1 opt-in); in beta/gamma/prod they are disabled so the schema is not exposed
    # unauthenticated (req 4). Disabling at construction time means FastAPI never registers the routes.
    _docs_on = _docs_public()
    app = FastAPI(
        title="Story API",
        version=SERVICE_VERSION,
        docs_url="/docs" if _docs_on else None,
        redoc_url="/redoc" if _docs_on else None,
        openapi_url="/openapi.json" if _docs_on else None,
    )
    # Central deny-by-default authentication boundary (P0 Beta Security Phase 1). Every non-allowlisted route
    # is protected here; the per-route require_user/optional_user dependencies reuse the principal this
    # resolves (verify-once). Registered via the HTTP-middleware decorator form.
    #
    # Middleware runs in REVERSE registration order, so register throttle FIRST and auth LAST: auth_boundary
    # is then the OUTERMOST layer (runs before throttle), so request.state.principal is resolved before the
    # throttle middleware reads it. P0 Beta Security Phase 3.
    # Middleware runs in REVERSE registration order, so register quota FIRST (innermost, closest to the
    # handler), throttle next, and auth LAST (outermost). Auth resolves request.state.principal first; then
    # throttle (rate per minute); then quota (cumulative AI spend/allowance + active-job slots). P0 Beta
    # Security Phases 3 (throttle) + 4 (quota).
    app.middleware("http")(quota_gate.quota_middleware)
    app.middleware("http")(throttle_middleware)
    app.middleware("http")(auth_boundary)
    log = get_logger("story-api")

    # Wire the throttle metric hook to the Observability EMF emitter (reuse, no new infra). The throttle
    # class is carried on the allow-listed low-cardinality `op_type` dimension (<=6 values) — NEVER a
    # story_user_id. Fire-and-forget: a metric failure never breaks a request.
    try:
        from observability import emit_metrics as _emit_metrics

        def _throttle_metric(name: str, cls: str) -> None:
            _emit_metrics({name: 1}, {"op_type": f"throttle_{cls}"})

        app.state._throttle_metric_hook = _throttle_metric

        # Phase 4: quota metrics on the SAME low-cardinality op_type dimension (quota_<class>), never a uid.
        def _quota_metric(name: str, cls: str) -> None:
            _emit_metrics({name: 1}, {"op_type": f"quota_{cls}"})

        app.state._quota_metric_hook = _quota_metric
    except Exception:  # noqa: BLE001 — observability optional; middleware no-ops without the hook
        pass

    # Non-persistent demo store (see app/store.py). One per app instance.
    store = InMemoryStoryStore()

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "service": SERVICE_NAME, "version": SERVICE_VERSION}

    @app.get("/v1/me", status_code=200)
    def whoami(principal: Principal = Depends(require_user)) -> dict[str, str]:
        """R1.1 — the ONE canonical account identity. Returns the backend-minted, immutable `story_user_id`
        the server uses for all ownership/authorization, so the iOS client stops keying ownership on the
        Cognito `sub` (two different identifiers was the R1.1 bug). ALWAYS requires a valid access token
        (`require_user`, never the optional/legacy-dev path): an unauthenticated or invalid-token caller gets
        401, so the client can NEVER resolve a canonical identity from an anonymous session and must not fall
        back to `sub`/`dev`. The resolution is the same atomic `cognito_sub -> story_user_id` claim used on
        every protected request, so `/v1/me` and a later protected call always agree."""
        return {"story_user_id": principal.story_user_id}

    # ========================================================================================================
    # CLOUD MEDIA (R2/R3) — account-owned original-media storage. ALL endpoints use require_user (auth required
    # even in dev; the legacy `dev` principal can NEVER reach these). Ownership derives from the verified
    # story_user_id — no client-supplied owner. Bytes go DIRECT to S3 via presigned URLs (never proxied through
    # App Runner). No deletion / no eviction in this increment. See packages/media_store.
    # ========================================================================================================
    def _media_store() -> "_media.MediaStore":
        ov = getattr(app.state, "_media_store_override", None)
        return ov if ov is not None else _media.MediaStore()

    @app.post("/v1/media/initiate", status_code=200)
    def media_initiate(body: MediaInitiateRequest, principal: Principal = Depends(require_user)):
        """Begin an account-owned upload. Idempotent on (owner, content_sha256): a re-initiate of the same
        content recovers the same record + a fresh presigned PUT. Returns the cloud_media_id, the presigned
        upload URL (bounded TTL), and the S3 key. Ownership is the trusted story_user_id."""
        if len(body.content_sha256.strip()) != 64:
            raise HTTPException(status_code=422, detail="content_sha256 must be a 64-char hex sha256")
        if body.size_bytes <= 0:
            raise HTTPException(status_code=422, detail="size_bytes must be positive")
        store = _media_store()
        try:
            rec, created = store.initiate_upload(
                owner=principal.story_user_id, content_sha256=body.content_sha256.strip(),
                size_bytes=body.size_bytes, content_type=body.content_type,
                device_asset_id=body.device_asset_id, source_moment_id=body.source_moment_id,
                media_kind=body.media_kind, source_output_id=body.source_output_id)
        except _media.MediaOwnershipConflict as e:
            raise HTTPException(status_code=409, detail=str(e))
        presign = store.presign_upload(owner=principal.story_user_id, cloud_media_id=rec["cloud_media_id"])
        return {"cloud_media_id": rec["cloud_media_id"], "state": rec["state"], "created": created,
                "upload": presign}

    @app.post("/v1/media/{cloud_media_id}/complete", status_code=200)
    def media_complete(cloud_media_id: str, principal: Principal = Depends(require_user)):
        """Durably verify the uploaded object (exists + size + full-file sha256 via S3 ChecksumSHA256) and, only
        then, mark it cloud_verified. Idempotent. 404 if not the caller's; 422 on a verification failure (record
        stays `uploading`, recoverable). No client input authorizes verification."""
        store = _media_store()
        try:
            rec = store.complete_upload(owner=principal.story_user_id, cloud_media_id=cloud_media_id)
        except _media.MediaNotFound:
            raise HTTPException(status_code=404, detail="media not found")
        except _media.MediaVerificationError as e:
            raise HTTPException(status_code=422, detail=f"verification failed: {e}")
        return {"cloud_media_id": rec["cloud_media_id"], "state": rec["state"],
                "verified_at": rec.get("verified_at", 0)}

    @app.get("/v1/media/{cloud_media_id}", status_code=200)
    def media_status(cloud_media_id: str, principal: Principal = Depends(require_user)):
        """Status/recovery for ONE of the caller's media records. 404 for anything not owned by the caller
        (another account's media is never revealed)."""
        rec = _media_store().get(principal.story_user_id, cloud_media_id)
        if rec is None:
            raise HTTPException(status_code=404, detail="media not found")
        return {k: rec.get(k) for k in
                ("cloud_media_id", "state", "size_bytes", "content_sha256", "s3_key",
                 "verified_at", "created_at", "updated_at", "device_asset_id", "source_moment_id",
                 "media_kind", "source_output_id")}

    @app.get("/v1/media/{cloud_media_id}/download", status_code=200)
    def media_download(cloud_media_id: str, principal: Principal = Depends(require_user)):
        """A short-lived presigned GET for the caller's own VERIFIED object. 404 if not the caller's; 409 if not
        yet verified. Scoped to an object under the caller's own prefix only."""
        store = _media_store()
        try:
            out = store.presign_download(owner=principal.story_user_id, cloud_media_id=cloud_media_id)
        except _media.MediaNotFound:
            raise HTTPException(status_code=404, detail="media not found")
        except _media.MediaVerificationError:
            raise HTTPException(status_code=409, detail="media not yet verified")
        return out

    @app.get("/v1/media", status_code=200)
    def media_list(principal: Principal = Depends(require_user)):
        """List the caller's own media records (Query on the owner PK — never a cross-account Scan)."""
        recs = _media_store().list_for_owner(principal.story_user_id)
        return {"media": [{k: r.get(k) for k in ("cloud_media_id", "state", "size_bytes",
                                                 "verified_at", "device_asset_id", "source_moment_id",
                                                 "media_kind", "source_output_id")}
                          for r in recs]}

    # ========================================================================================================
    # R7 — account-owned Story metadata sync (optimistic concurrency + idempotency). All require_user,
    # account-scoped to principal.story_user_id. A cloud_media_id is NEVER authorization (C3).
    # ========================================================================================================
    def _story_store() -> "_stories.StoryStore":
        ov = getattr(app.state, "_story_store_override", None)
        if ov is not None:
            return ov
        return _stories.StoryStore(media=_media_store())

    @app.get("/v1/stories", status_code=200)
    def stories_index(principal: Principal = Depends(require_user)):
        """The caller's Story INDEX (no bodies) — full-account pull on a new device. Query on the owner PK."""
        return {"stories": _story_store().index(principal.story_user_id)}

    @app.get("/v1/stories/{story_id}", status_code=200)
    def story_get(story_id: str, principal: Principal = Depends(require_user)):
        """The caller's full Story document + current revision. 404 if not this account's (no cross-account)."""
        rec = _story_store().get(principal.story_user_id, story_id)
        if rec is None:
            raise HTTPException(status_code=404, detail="story not found")
        return rec

    @app.put("/v1/stories/{story_id}", status_code=200)
    def story_put(story_id: str, body: StoryPutRequest, principal: Principal = Depends(require_user)):
        """Create (base_revision 0) or update (base_revision == current) with optimistic concurrency +
        mutation_id idempotency. C3: verify every referenced cloud asset is THIS account's AND cloud_verified
        before accepting; unverified refs mark the doc incomplete_deps rather than falsely reporting complete.
        On a genuine concurrent modification -> 409 with the server's current {revision, doc}."""
        store = _story_store()
        owner = principal.story_user_id
        all_ok, _unverified = store.verify_dependencies(owner, body.referenced_cloud_media_ids)
        try:
            out = store.put(owner=owner, story_id=story_id, base_revision=body.base_revision,
                            mutation_id=body.mutation_id, doc=body.doc, deleted=body.deleted,
                            incomplete_deps=not all_ok)
        except _stories.StoryDocumentTooLarge as e:
            # Phase-1 #5: explicit failure, never truncate. 413 so the client externalizes large plans (C2).
            raise HTTPException(status_code=413,
                                detail={"error": "story_document_too_large", "size": e.size,
                                        "max": _stories.MAX_DOC_BYTES})
        except _stories.StoryMutationConflict:
            # Phase-1 #4: same mutation_id reused with a DIFFERENT payload — reject, never a false success.
            raise HTTPException(status_code=409,
                                detail={"error": "mutation_id_payload_mismatch"})
        except _stories.StoryConflict as c:
            # 409: the client is stale and a DIFFERENT mutation won. Return the server state for Keep Both /
            # Use Cloud Version (never a silent overwrite).
            raise HTTPException(status_code=409, detail={"conflict": True, "current": c.current})
        return out

    @app.post("/v1/stories/{story_id}/outputs/{output_id}/backup", status_code=200)
    def story_output_backup(story_id: str, output_id: str, body: StoryOutputBackupRequest,
                            principal: Principal = Depends(require_user)):
        """Register a completed render's cloud_media_id on an output. Refuses an asset that is not THIS
        account's or not cloud_verified (decision 2 #5/#8/#9; C3). The client then syncs the doc carrying the
        reference; this endpoint only validates + acknowledges the backup."""
        owner = principal.story_user_id
        all_ok, unverified = _story_store().verify_dependencies(owner, [body.cloud_media_id])
        if not all_ok:
            raise HTTPException(status_code=409,
                                detail={"error": "cloud_media_not_verified", "unverified": unverified})
        return {"story_id": story_id, "output_id": output_id,
                "cloud_media_id": body.cloud_media_id, "backed_up": True}

    # ========================================================================================================
    # R7-E — account-level Moment Understanding sync (shared across Stories; keyed by moment_id). require_user,
    # account-scoped. Lets Device B RESTORE understanding instead of re-running Asset Understanding (Bedrock).
    # ========================================================================================================
    def _understanding_store() -> "_understanding.UnderstandingStore":
        ov = getattr(app.state, "_understanding_store_override", None)
        return ov if ov is not None else _understanding.UnderstandingStore()

    @app.post("/v1/understanding/batch-get", status_code=200)
    def understanding_batch_get(body: UnderstandingGetRequest, principal: Principal = Depends(require_user)):
        """Return the caller's own understanding records for the given moment_ids (account-scoped; a wrong
        owner finds nothing). POST (not GET) so a large moment_id list travels in the body, not the URL."""
        recs = _understanding_store().get_many(principal.story_user_id, body.moment_ids)
        return {"understanding": recs}

    @app.put("/v1/understanding", status_code=200)
    def understanding_put(body: UnderstandingPutRequest, principal: Principal = Depends(require_user)):
        """Batch upsert the caller's Moment Understanding. Idempotent; explicit 413 on an oversized record
        (never truncated — a huge understanding externalizes to S3 ai_artifact at the client, future)."""
        store = _understanding_store()
        results = []
        for r in body.records:
            try:
                out = store.put(owner=principal.story_user_id, moment_id=r.moment_id,
                                understanding_json=r.understanding_json, schema_version=r.schema_version,
                                prompt_version=r.prompt_version, frame_policy=r.frame_policy,
                                content_sha256=r.content_sha256, model_id=r.model_id)
                results.append(out)
            except _understanding.UnderstandingTooLarge as e:
                raise HTTPException(status_code=413,
                                    detail={"error": "understanding_too_large", "moment_id": r.moment_id,
                                            "size": e.size, "max": _understanding.MAX_UNDERSTANDING_BYTES})
        return {"written": results}

    # ========================================================================================================
    # P1-E — account-owned My Music FAVORITES (saved catalog-track REFERENCES; never audio bytes). require_user,
    # account-scoped. Lets a reinstalled / new device RESTORE the saved-track library. Reuses the R7-E
    # understanding table under a reserved sentinel key — NO new table / CDK / IAM. Licensing-safe: references
    # only; provider audio is never uploaded or stored here.
    # ========================================================================================================
    def _music_favorites_store() -> "_music_favorites.MusicFavoritesStore":
        ov = getattr(app.state, "_music_favorites_store_override", None)
        return ov if ov is not None else _music_favorites.MusicFavoritesStore(_understanding_store())

    @app.get("/v1/music/favorites", status_code=200)
    def music_favorites_get(principal: Principal = Depends(require_user)):
        """The caller's saved catalog-track references + the current revision. A never-written account returns
        an empty list at revision 0 (NOT an error) — a fresh client shows an empty library, never a failure."""
        return _music_favorites_store().get(principal.story_user_id)

    @app.put("/v1/music/favorites", status_code=200)
    def music_favorites_put(body: MusicFavoritesPutRequest, principal: Principal = Depends(require_user)):
        """Replace the caller's saved favorites with optimistic concurrency. base_revision must equal the
        server's current revision (0 to create); a mismatch returns 409 with the server's current {favorites,
        revision} so the client MERGES (never a silent overwrite — req §5 two-device safety). References only."""
        favs = [{"track_id": f.track_id, "title": f.title,
                 "duration_seconds": f.duration_seconds, "saved_at": f.saved_at} for f in body.favorites]
        try:
            return _music_favorites_store().put(
                owner=principal.story_user_id, base_revision=body.base_revision, favorites=favs)
        except _music_favorites.FavoritesConflict as c:
            raise HTTPException(status_code=409, detail={"conflict": True, "current": c.current})

    # ---- R4-B: large-file MULTIPART (all require_user; account-scoped; no bytes via App Runner) -----
    @app.post("/v1/media/multipart/initiate", status_code=200)
    def media_multipart_initiate(body: MediaMultipartInitiateRequest,
                                 principal: Principal = Depends(require_user)):
        """Begin (or idempotently recover) a multipart upload. Idempotent on (owner, content_sha256): a
        re-initiate recovers the SAME record + S3 upload_id (never a duplicate object). part_shas are the
        device's per-part sha256 (base64), in order — recorded for composite verification."""
        if len(body.content_sha256.strip()) != 64:
            raise HTTPException(status_code=422, detail="content_sha256 must be a 64-char hex sha256")
        if body.size_bytes <= 0 or not body.part_shas:
            raise HTTPException(status_code=422, detail="size_bytes>0 and non-empty part_shas required")
        store = _media_store()
        try:
            rec, created = store.initiate_multipart(
                owner=principal.story_user_id, content_sha256=body.content_sha256.strip(),
                size_bytes=body.size_bytes, part_shas_b64=body.part_shas, content_type=body.content_type,
                device_asset_id=body.device_asset_id, source_moment_id=body.source_moment_id,
                media_kind=body.media_kind, source_output_id=body.source_output_id)
        except _media.MediaOwnershipConflict as e:
            raise HTTPException(status_code=409, detail=str(e))
        return {"cloud_media_id": rec["cloud_media_id"], "state": rec["state"], "created": created,
                "upload_id": rec.get("upload_id"), "part_count": rec.get("part_count")}

    @app.post("/v1/media/{cloud_media_id}/parts", status_code=200)
    def media_presign_parts(cloud_media_id: str, body: MediaPresignPartsRequest,
                            principal: Principal = Depends(require_user)):
        """Presigned upload-part URLs for the requested part numbers (caller's own MPU only)."""
        store = _media_store()
        try:
            out = store.presign_parts(owner=principal.story_user_id, cloud_media_id=cloud_media_id,
                                      part_numbers=body.part_numbers)
        except _media.MediaNotFound:
            raise HTTPException(status_code=404, detail="media not found")
        except _media.MediaVerificationError as e:
            raise HTTPException(status_code=409, detail=str(e))
        return out

    @app.get("/v1/media/{cloud_media_id}/parts/uploaded", status_code=200)
    def media_uploaded_parts(cloud_media_id: str, principal: Principal = Depends(require_user)):
        """Reconcile: the parts S3 already has for the caller's MPU (so the client re-uploads only the rest)."""
        store = _media_store()
        try:
            parts = store.list_uploaded_parts(owner=principal.story_user_id, cloud_media_id=cloud_media_id)
        except _media.MediaNotFound:
            raise HTTPException(status_code=404, detail="media not found")
        except _media.MediaVerificationError as e:
            raise HTTPException(status_code=409, detail=str(e))
        return {"uploaded_parts": parts}

    @app.post("/v1/media/{cloud_media_id}/multipart/complete", status_code=200)
    def media_multipart_complete(cloud_media_id: str, principal: Principal = Depends(require_user)):
        """Complete + durably verify the multipart object (size + composite checksum) -> cloud_verified. A
        successful CompleteMultipartUpload alone is NOT sufficient; size + composite must match."""
        store = _media_store()
        try:
            rec = store.complete_multipart(owner=principal.story_user_id, cloud_media_id=cloud_media_id)
        except _media.MediaNotFound:
            raise HTTPException(status_code=404, detail="media not found")
        except _media.MediaVerificationError as e:
            raise HTTPException(status_code=422, detail=f"verification failed: {e}")
        return {"cloud_media_id": rec["cloud_media_id"], "state": rec["state"],
                "verified_at": rec.get("verified_at", 0)}

    @app.post("/v1/creative-intent", response_model=CreativeIntentContract, status_code=200)
    def resolve_creative_intent(
        body: ResolveCreativeIntentRequest,
        engine: CreativeIntentEngine = Depends(get_creative_intent_engine),
        principal: Principal = Depends(optional_user),
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
        principal: Principal = Depends(optional_user),
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
        from edit_planner.revision_interpreter import ground_directives
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

        # Phase 3 — hard-directive GROUNDING guard. If the interpreter invented a hard constraint the user did
        # not ask for (observed: an exclude set produced from an inclusion/ordering-only instruction), do NOT
        # silently drop it and do NOT submit. Attempt ONE bounded reinterpretation (same v2 prompt, same model)
        # — a transient over-generation usually clears on retry at temperature 0 given the explicit v2 rules.
        # If the second pass STILL emits the unsupported constraint, surface it as a blocking reason so the
        # client asks the user to clarify, rather than shipping a wrong exclusion or quietly deleting it.
        grounding = ground_directives(result)
        reinterpreted = False
        if grounding:
            reinterpreted = True
            try:
                result2 = _interp(body.instruction, body.moments, get_model_gateway())
                if not ground_directives(result2):
                    result = result2
                    grounding = []
                else:
                    result = result2
                    grounding = ground_directives(result2)
            except (StructuredOutputError, ProviderError):
                pass  # keep the first result + its grounding reasons; handled as blocking below

        log.info("interpret_revision_ok",
                 extra={**base_fields, "latency_ms": round((time.monotonic() - started) * 1000),
                        "success": True, "has_directives": bool(result.directives),
                        "unresolved_count": len(result.unresolved),
                        "reinterpreted": reinterpreted, "grounding_flags": len(grounding)})
        # Phase 4 preflight: refuse to let the client spend an expensive revision job on a known-unsatisfiable
        # or malformed directive set. eligible_ids = the Moment ids the client sent in the snapshot.
        eligible = {str(m["id"]) for m in body.moments if "id" in m}
        blocking = preflight_directives(result.directives, eligible) + grounding
        return {"directives": result.directives, "soft_direction": result.soft_direction,
                "unresolved": result.unresolved, "blocking": blocking,
                "can_submit": not blocking and not result.unresolved}

    @app.post("/v1/scene-understanding", response_model=SceneUnderstandingContract, status_code=200)
    async def scene_understanding(
        context: str = Form(..., description="JSON: {capture_session_id, mode, story_id?}"),
        frames: list[UploadFile] = File(..., description="3-6 representative JPEG scan frames"),
        engine: SceneUnderstandingEngine = Depends(get_scene_understanding_engine),
        principal: Principal = Depends(optional_user),
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
        principal: Principal = Depends(optional_user),
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
                   "requested_model": au.requested_model, "served_provider": au.served_provider,
                   "used_fallback": au.used_fallback,
                   "event_count": len(au.understanding.observed.events),
                   "story_utility": au.understanding.story_context.story_utility.value},
        )
        return au.understanding

    @app.post("/v1/story-coverage", response_model=StoryCoverageContract, status_code=200)
    def story_coverage(
        body: StoryCoverageRequest,
        engine: StoryCoverageEngine = Depends(get_story_coverage_engine),
        principal: Principal = Depends(optional_user),
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
        principal: Principal = Depends(optional_user),
    ) -> StoryGuideContract:
        """RETIRED (owner 2026-10-24): v1 Story Guide GENERATION is removed — the shooting-script
        /v1/story-guide-v2 (story_guide/2) is the sole generation path. Returns 410 Gone so a stale client
        gets a clear signal to use v2 (not a silent 404). The story_guide/1 CONTRACT/decode is retained
        elsewhere so previously-persisted v1 guides still RENDER as a legacy fallback; only generation is gone."""
        raise HTTPException(
            status_code=410,
            detail="story_guide_v1_retired: v1 guide generation is removed; use /v1/story-guide-v2")

    @app.post("/v1/story-guide-v2", response_model=StoryGuideV2Contract, status_code=200)
    def story_guide_v2(
        body: StoryGuideRequest,
        engine=Depends(get_story_guide_v2_engine),
        principal: Principal = Depends(optional_user),
    ) -> StoryGuideV2Contract:
        """Generate the AI SHOOTING SCRIPT (story_guide/2) from CreativeIntent. This is now the SOLE
        guide-generation path (v1 /v1/story-guide generation is retired -> 410; v1 persisted guides still
        render client-side as a legacy fallback). On failure: 503, preserve CreativeIntent, NO fabricated
        Guide. Server mints canonical stable scene ids; the model never emits image ids/urls/attribution."""
        correlation_id = str(uuid4())
        started = time.monotonic()
        base = {"operation": "story_guide_v2", "correlation_id": correlation_id,
                "task": "story_guide.generate_v2", "prompt_version": "story_guide/v2",
                "schema_version": "story_guide/2"}
        try:
            guide = engine.generate(GuideInput(
                story_id=body.story_id, creative_intent=body.creative_intent, scope=body.scope,
                source_creative_intent_version=body.source_creative_intent_version))
        except GuideUnavailableError as e:
            log.warning("story_guide_v2_unavailable",
                extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                       "success": False, "error": str(e)[:300]})
            raise HTTPException(status_code=503,
                detail="story_guide_unavailable: could not generate; preserve CreativeIntent and retry")
        log.info("story_guide_v2_resolved",
            extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                   "success": True, "scene_count": len(guide.scenes)})
        return guide

    @app.post("/v1/story-guide-refine", response_model=StoryGuideRefinementResult, status_code=200)
    def story_guide_refine(
        body: StoryGuideRefineRequest,
        engine=Depends(get_story_guide_refine_engine),
        principal: Principal = Depends(optional_user),
    ) -> StoryGuideRefinementResult:
        """Refine (Update Guide) an existing story_guide/2 shooting script (Guide v2.1). The model
        proposes preserve/improve/reorder/replace/add/archive over the CURRENT scenes + the user's
        update; the ENGINE reconciles identity + history server-side: captured (Coverage-evidenced)
        and user-PINNED scenes are preserved verbatim and NEVER archived, preserved/improved scenes
        keep their stable ids, genuinely-new scenes get fresh ids beyond the max existing ordinal
        (retired ids never reused), and dropped uncaptured+unpinned scenes are archived (recorded).

        ADDITIVE/versioned. v1 generation is retired (410); v2 is the sole guide path, so refine is always
        available (no STORY_GUIDE_V2 gate). On failure: 503, preserve the CURRENT Guide, NO fabrication —
        the client keeps the existing shooting script and retries."""
        correlation_id = str(uuid4())
        started = time.monotonic()
        base = {"operation": "story_guide_refine", "correlation_id": correlation_id,
                "task": "story_guide.refine_v2", "prompt_version": "story_guide/refine-v1",
                "schema_version": "story_guide/2"}
        try:
            result = engine.refine(RefineInput(
                story_id=body.story_id, creative_intent=body.creative_intent, scope=body.scope,
                current_framing_summary=body.current_framing_summary,
                current_scenes=body.current_scenes,
                captured_scene_ids=body.captured_scene_ids, pinned_scene_ids=body.pinned_scene_ids,
                user_instruction=body.user_instruction, event_context=body.event_context,
                source_creative_intent_version=body.source_creative_intent_version))
        except GuideUnavailableError as e:
            log.warning("story_guide_refine_unavailable",
                extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                       "success": False, "error": str(e)[:300]})
            raise HTTPException(status_code=503,
                detail="story_guide_unavailable: could not refine; preserve current Guide and retry")
        n_arch = len(result.archived_scene_ids)
        n_add = sum(1 for c in result.changes if c.disposition.value == "added")
        log.info("story_guide_refine_resolved",
            extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                   "success": True, "scene_count": len(result.guide.scenes),
                   "added": n_add, "archived": n_arch})
        return result

    @app.post("/v1/scene-image", status_code=200)
    def scene_image(
        body: SceneImageRequest,
        principal: Principal = Depends(optional_user),
    ):
        """BOUNDED Unsplash reference-image lookup for ONE StoryGuide/2 scene (backend proxy).

        FEATURE-GATED by STORY_SCENE_IMAGES (404 when off). This is NOT a public image-search proxy:
        the query is a GENERIC scene/composition phrase (originating from our own server-authored v2
        `visual_reference_query`) which we RE-SANITIZE and hard-bound here (length cap, control-char
        strip, URL/email reject) so no personal data / user media can be smuggled to the provider.

        Returns METADATA ONLY (photo id, hotlinked urls.*, attribution text + utm links, and the
        download_location tracking URL). Image bytes are NEVER fetched or re-hosted — the app hotlinks
        urls.* directly. The Unsplash key stays in Secrets Manager, read in-process, never logged.

        FAIL-SOFT by contract: a disabled flag -> 404; any auth/provider/rate-limit/timeout/empty-match
        -> 200 with {image: null, status: <reason>} so the client renders a text-only card. It MUST
        NEVER 5xx or block the Guide/UI. The download_location is returned but NOT triggered here —
        the client calls /v1/scene-image/track only when a photo is actually USED (Unsplash's rule)."""
        if not _scene_image.enabled():
            raise HTTPException(status_code=404, detail="scene_image not enabled")
        correlation_id = str(uuid4())
        started = time.monotonic()
        base = {"operation": "scene_image", "correlation_id": correlation_id, "provider": "unsplash"}
        # 1) sanitize/bound the query — a query error is an honest text-only fallback, not a 4xx that
        #    would surface as an error in the UI.
        try:
            q = _scene_image.sanitize_query(body.query)
        except _scene_image.SceneImageQueryError as e:
            log.info("scene_image_query_rejected", extra={**base, "success": False, "reason": str(e)[:120]})
            return {"image": None, "status": "invalid_query"}
        # 2) metadata cache (bounds provider calls; costs near-zero on repeat renders/re-opens).
        cache = _scene_image_cache()
        cached = cache.get(q)
        if cached is not None:
            if cached is _scene_image.MetadataCache._MISS:
                return {"image": None, "status": "no_match", "cached": True}
            return {"image": cached.to_wire(), "status": "ok", "cached": True}
        # 3) live provider call (bounded timeout). All failure classes -> graceful text-only fallback.
        try:
            client = _scene_image_client()
        except _scene_image.SceneImageAuthError as e:
            log.warning("scene_image_auth_unavailable", extra={**base, "success": False, "error": str(e)[:160]})
            return {"image": None, "status": "unavailable"}
        try:
            img = client.search_one(q)
        except _scene_image.SceneImageAuthError as e:
            log.warning("scene_image_auth_rejected", extra={**base, "success": False, "error": str(e)[:160]})
            return {"image": None, "status": "unavailable"}
        except _scene_image.SceneImageProviderError as e:
            log.warning("scene_image_provider_error", extra={**base, "success": False, "error": str(e)[:160]})
            return {"image": None, "status": "provider_error"}
        if img is None:
            cache.put(q, _scene_image.MetadataCache._MISS)
            log.info("scene_image_no_match", extra={**base, "success": True})
            return {"image": None, "status": "no_match"}
        cache.put(q, img)
        log.info("scene_image_resolved",
                 extra={**base, "latency_ms": round((time.monotonic() - started) * 1000),
                        "success": True, "photo_id": img.photo_id})
        return {"image": img.to_wire(), "status": "ok"}

    @app.post("/v1/scene-image/track", status_code=204)
    def scene_image_track(
        body: SceneImageTrackRequest,
        principal: Principal = Depends(optional_user),
    ):
        """Fire Unsplash's download-tracking endpoint when a reference photo is actually USED/selected
        as a scene reference (Unsplash's documented requirement — NOT fired on mere display). Best-effort
        and always 204: tracking failure must never surface to the user. Gated by STORY_SCENE_IMAGES."""
        if not _scene_image.enabled():
            raise HTTPException(status_code=404, detail="scene_image not enabled")
        loc = (body.download_location or "").strip()
        # Only ever call back to the Unsplash tracking host — never an arbitrary caller-supplied URL (SSRF guard).
        if loc.startswith("https://api.unsplash.com/"):
            try:
                _scene_image_client().trigger_download(loc)
            except Exception:
                pass
        return Response(status_code=204)

    @app.post("/v1/music-direction", response_model=MusicDirectionContract, status_code=200)
    def music_direction(
        body: MusicDirectionRequest,
        principal: Principal = Depends(optional_user),
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
        principal: Principal = Depends(optional_user),
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
            editorial_mode=body.editorial_mode, editorial_type=body.editorial_type, revision_context=body.revision_context)
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
        principal: Principal = Depends(optional_user),
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
            editorial_mode=parsed.editorial_mode, editorial_type=parsed.editorial_type, revision_context=parsed.revision_context,
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

    # P0 Beta Auth Increment 2: scope job identity + ownership to the authenticated principal.
    def _scoped_op_id(principal, operation_id: str) -> str:
        """Namespace the client operation_id by the trusted story_user_id BEFORE job_id_for/fingerprint, so
        two users submitting the SAME client op-id get DIFFERENT deterministic job ids and can never collide
        on idempotency. The worker is unaffected (it only ever sees the derived job_id). Scoping is applied
        here, at the trusted seam — the frozen jobs module is untouched."""
        return f"{principal.story_user_id}\x1f{operation_id.strip()}"

    def _require_owned(job: dict, principal) -> None:
        """Enforce job ownership. A job owned by a DIFFERENT principal is reported as 404 (never 403) so a
        caller cannot even discover another user's job exists. Legacy owner='dev' jobs are owned by the legacy
        principal only — a real story_user_id never equals 'dev', so they are invisible to authenticated users
        and vice-versa."""
        if job.get("owner") != principal.story_user_id:
            raise HTTPException(status_code=404, detail="job not found")

    @app.post("/v1/edit-plan-jobs", status_code=202)
    async def submit_edit_plan_job(
        request: Request,  # FastAPI injects; first param (no default) so it is excluded from the OpenAPI schema
        operation_id: str = Form(..., description="client idempotency key; a NEW version uses a NEW id"),
        owner: str = Form(default="dev", description="IGNORED — ownership derives from the authenticated principal (Increment 2)"),
        body: str = Form(..., description="JSON EditPlanRequest body (same shape as /v1/edit-plan)"),
        sheet_order: str = Form(default="[]", description="JSON array of Moment ids, one per sheet"),
        creative_brief: str | None = Form(default=None),
        critique_revision: bool = Form(default=False),
        approach: str = Form(default="storytelling", description="storytelling|visual_first (diagnostics)"),
        evidence_accounting: str | None = Form(default=None, description="P0 privacy-safe evidence-funnel census JSON (counts + reason buckets + opaque ids); persisted on the job item for post-cleanup investigation"),
        build_provenance: str | None = Form(default=None, description="P0 build provenance JSON (app/build/commit/policy versions); proves which code a run executed"),
        test_delay_s: int = Form(default=0, description="ACCEPTANCE-ONLY: artificial worker delay (honored only when the worker enables it); simulates a long job"),
        sheets: list[UploadFile] = File(default=[]),
        principal: Principal = Depends(optional_user),
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
        # Increment 2: scope the operation id to the authenticated principal so idempotency + the deterministic
        # job id are per-user (no cross-user collision); persist the trusted story_user_id as owner (client
        # `owner` is ignored).
        scoped_op = _scoped_op_id(principal, operation_id)
        fp = _jobs.payload_fingerprint(body, order, bool(critique_revision), approach,
                                       creative_brief=creative_brief, sheet_digests=digests)
        jid = _jobs.job_id_for(scoped_op)
        # Stage BEFORE create so the worker always finds its inputs. Re-staging on a duplicate is harmless
        # (same prefix, same content). Body carries brief + critique + approach so the worker is self-contained.
        import json as _j2
        # P0 diagnostics — parse defensively; a malformed blob is dropped (never fails the create). These are
        # privacy-safe (counts + reason buckets + opaque ids / version strings); the worker persists them onto
        # the job item so they survive the staged-payload TTL.
        def _safe_obj(s: str | None) -> dict | None:
            if not s:
                return None
            try:
                v = _j2.loads(s)
                return v if isinstance(v, dict) else None
            except Exception:
                return None
        _evidence = _safe_obj(evidence_accounting)
        _provenance = _safe_obj(build_provenance)
        body_envelope = _j2.dumps({"body": body, "sheet_order": order, "creative_brief": creative_brief,
                                    "critique_revision": bool(critique_revision), "approach": approach,
                                    "evidence_accounting": _evidence, "build_provenance": _provenance,
                                    "_test_delay_s": int(test_delay_s or 0)})
        prefix = store.stage_request(jid, body_envelope, staged)
        try:
            job_id, created = store.create_or_get(
                operation_id=scoped_op, owner=principal.story_user_id, approach=approach,
                critique_requested=bool(critique_revision), staging_prefix=prefix,
                sheet_order=order, payload_fingerprint=fp)
        except _jobs.PayloadConflict as e:
            raise HTTPException(status_code=409, detail=str(e))
        # P0 Beta Security Phase 4: reserve the AI allowance + an active-job slot EXACTLY ONCE for a newly
        # created job (a recovered duplicate reserves nothing new — idempotent on scoped_op/job slot). In
        # enforce mode an over-quota submit is short-circuited 429 BEFORE enqueue; observe never denies.
        denied = quota_gate.submit_reserve(request, principal.story_user_id, scoped_op, job_id, created=created)
        if denied is not None:
            return denied
        if created:
            store.enqueue(job_id)
        log.info("edit_plan_job_submitted", extra={"operation": "edit_plan_job", "job_id": job_id,
                 "job_created": created, "approach": approach, "sheet_count": len(staged),
                 "image_payload_bytes": total, "critique_requested": bool(critique_revision)})
        return {"job_id": job_id, "status": "queued"}

    @app.get("/v1/edit-plan-jobs/{job_id}")
    def get_edit_plan_job(job_id: str, principal: Principal = Depends(optional_user)):
        if not _dev_access_ok():
            raise HTTPException(status_code=404, detail="not found")
        job = _job_store().get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="job not found")
        _require_owned(job, principal)  # cross-user -> 404
        out = {k: job.get(k) for k in ("job_id", "status", "approach", "failure_category",
                                       "failure_detail", "diagnostics")}
        if job.get("status") == "completed":
            out["plan"] = job.get("plan")
        return out

    @app.post("/v1/edit-plan-jobs/{job_id}/cancel")
    def cancel_edit_plan_job(job_id: str, principal: Principal = Depends(optional_user)):
        if not _dev_access_ok():
            raise HTTPException(status_code=404, detail="not found")
        store = _job_store()
        job = store.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="job not found")
        _require_owned(job, principal)  # cross-user -> 404
        return {"job_id": job_id, "status": store.request_cancel(job_id)}

    @app.post("/v1/edit-plan-jobs/_reconcile")
    def reconcile_edit_plan_jobs(principal: Principal = Depends(optional_user)):
        """Lost-enqueue recovery sweep (concern 6). Called by a scheduled EventBridge rule in CDK; also
        callable manually in dev. Re-enqueues only never-leased stranded queued jobs, capped. Requires a
        principal (not anonymous); it re-enqueues by job_id only and discloses no job data cross-user."""
        if not _dev_access_ok():
            raise HTTPException(status_code=404, detail="not found")
        return {"reenqueued": _job_store().reconcile_lost_enqueue()}

    # ========================================================================================================
    # ASYNC STORY COVERAGE/2 (milestone-async-story-coverage-reliability). The sync /v1/story-coverage/v2 above
    # runs TWO sequential Opus calls (Mapper + Judge) ~191s cold — past App Runner's hard 120s request wall, so
    # the device never receives the result and loops. These endpoints submit the SAME computation as a job the
    # worker runs off the request path, then the client polls. Reuses the edit-plan job store via the
    # coverage_v2 operation discriminator — no new infra. Frozen prompts/story_coverage/2 contract untouched.
    # ========================================================================================================
    _COV_JOB_MAX_INLINE_BYTES = 350_000   # DynamoDB item ceiling is 400KB; inline the compact body under this.

    @app.post("/v1/story-coverage/v2/jobs", status_code=202)
    def submit_coverage_job(
        request: Request,  # FastAPI injects; first param (no default) so it is excluded from the OpenAPI schema
        operation_id: str = Form(..., description="canonical coverage op-id (see coverage_operation_id); a changed snapshot uses a new id"),
        owner: str = Form(default="dev", description="IGNORED — ownership derives from the authenticated principal (Increment 2)"),
        body: str = Form(..., description="JSON StoryCoverageV2Request body (same shape as POST /v1/story-coverage/v2)"),
        test_delay_s: int = Form(default=0, description="ACCEPTANCE-ONLY: artificial worker delay (honored only when the worker enables it)"),
        principal: Principal = Depends(optional_user),
    ):
        """Submit an async Coverage/2 job. Returns {job_id,status} promptly (no model call). Idempotent on
        operation_id; a same-id DIFFERENT-payload submit is 409 (payload conflict preserved). Recovers an
        existing queued/running/completed job for the SAME snapshot without launching new inference."""
        import json as _json
        if not _dev_access_ok():
            raise HTTPException(status_code=404, detail="not found")
        # Validate the body against the SAME frozen request model the sync endpoint uses (never reinterpret).
        try:
            parsed = StoryCoverageV2Request.model_validate_json(body)
        except Exception as e:
            raise HTTPException(status_code=422, detail=f"invalid story-coverage body json: {e}")
        if len(parsed.moment_understandings) > _COV_MAX_MOMENTS:
            raise HTTPException(status_code=413, detail=f"too many moments (max {_COV_MAX_MOMENTS})")
        # Re-serialize the VALIDATED body so the fingerprint + the worker see a canonical form (and optionally
        # fold in the acceptance-only test delay). Keeps the stored body independent of client whitespace.
        canon = parsed.model_dump(mode="json")
        if test_delay_s and int(test_delay_s) > 0:
            canon["_test_delay_s"] = int(test_delay_s)
        body_json = _json.dumps(canon, sort_keys=True, default=str)

        store = _job_store()
        scoped_op = _scoped_op_id(principal, operation_id)  # Increment 2: per-user job identity + idempotency
        fp = _jobs.coverage_payload_fingerprint(body_json, scoped_op)
        # Compact bodies inline into the DynamoDB item; a large body stages to encrypted S3 (worker reads either).
        staging_prefix = ""
        if len(body_json.encode("utf-8")) > _COV_JOB_MAX_INLINE_BYTES:
            jid = _jobs.job_id_for(scoped_op)
            staging_prefix = store.stage_request(jid, body_json, [])
            body_json = ""   # not inlined; worker loads from S3
        try:
            job_id, created = store.create_or_get_coverage(
                operation_id=scoped_op, owner=principal.story_user_id, body_json=body_json,
                payload_fingerprint=fp, staging_prefix=staging_prefix)
        except _jobs.PayloadConflict as e:
            raise HTTPException(status_code=409, detail=str(e))
        # P0 Beta Security Phase 4: reserve AI allowance + active-job slot exactly once (same as edit-plan).
        denied = quota_gate.submit_reserve(request, principal.story_user_id, scoped_op, job_id, created=created)
        if denied is not None:
            return denied
        if created:
            store.enqueue(job_id)
        log.info("coverage_job_submitted", extra={"operation": "coverage_job", "job_id": job_id,
                 "job_created": created, "moment_count": len(parsed.moment_understandings),
                 "pending_count": parsed.pending_count, "inlined": not staging_prefix})
        return {"job_id": job_id, "status": "queued", "created": created}

    @app.get("/v1/story-coverage/v2/jobs/{job_id}")
    def get_coverage_job(job_id: str, principal: Principal = Depends(optional_user)):
        """Durable status. Polling NEVER triggers inference — it only reads DynamoDB. On completion returns the
        StoryCoverage/2 result AND the operation_id, so the client can reject a result that is stale for the
        CURRENT Story (safeguard 4: input-freshness is enforced client-side against the live fingerprint)."""
        if not _dev_access_ok():
            raise HTTPException(status_code=404, detail="not found")
        job = _job_store().get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="job not found")
        _require_owned(job, principal)  # cross-user -> 404
        if job.get("operation_type", _jobs.OP_EDIT_PLAN) != _jobs.OP_COVERAGE_V2:
            # Never serve an edit-plan job through the coverage status route (dispatch isolation).
            raise HTTPException(status_code=409, detail="job is not a coverage_v2 job")
        out = {k: job.get(k) for k in ("job_id", "status", "operation_id", "failure_category",
                                       "failure_detail", "diagnostics")}
        # Return the CLIENT operation_id (strip the internal per-principal scope prefix "<user>\x1f") so the
        # client's staleness check (safeguard 4) sees the id it submitted, not the server-internal scoped key.
        if isinstance(out.get("operation_id"), str) and "\x1f" in out["operation_id"]:
            out["operation_id"] = out["operation_id"].split("\x1f", 1)[1]
        if job.get("status") == "completed":
            out["result"] = job.get("result")
        return out

    @app.post("/v1/story-coverage/v2/jobs/{job_id}/cancel")
    def cancel_coverage_job(job_id: str, principal: Principal = Depends(optional_user)):
        if not _dev_access_ok():
            raise HTTPException(status_code=404, detail="not found")
        store = _job_store()
        job = store.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="job not found")
        _require_owned(job, principal)  # cross-user -> 404
        if job.get("operation_type", _jobs.OP_EDIT_PLAN) != _jobs.OP_COVERAGE_V2:
            raise HTTPException(status_code=409, detail="job is not a coverage_v2 job")
        return {"job_id": job_id, "status": store.request_cancel(job_id)}

    @app.post("/v1/music-plan", response_model=MusicPlanContract, status_code=200)
    def music_plan(
        body: MusicPlanRequest,
        engine: MusicPlanEngine = Depends(get_music_plan_engine),
        principal: Principal = Depends(optional_user),
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
        principal: Principal = Depends(optional_user),
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
    def music_candidates(body: MusicCandidatesRequest, principal: Principal = Depends(optional_user)):
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
    def music_search(body: MusicSearchRequest, principal: Principal = Depends(optional_user)):
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
    def music_analysis(body: MusicTrackRequest, principal: Principal = Depends(optional_user)):
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
    def music_soundtrack(body: MusicTrackRequest, principal: Principal = Depends(optional_user)):
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
        principal: Principal = Depends(optional_user),
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
        principal: Principal = Depends(optional_user),
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
        principal: Principal = Depends(optional_user),
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
        principal: Principal = Depends(optional_user),
        story_engine: StoryEngine = Depends(get_story_engine),
    ) -> StoryDTO:
        """Derive a CreativeIntent from raw_text and create a Story.

        P0 Beta Security Phase 1: now carries the shared auth dependency — previously it had NONE and accepted
        anonymous writes. `optional_user` means dev keeps the legacy window (req 9) while beta/gamma/prod FAIL
        CLOSED at the central boundary regardless of flag (req 8). iOS does NOT call POST /v1/stories (it
        persists via PUT /v1/stories/{id}); this is a legacy demo route over the in-memory store. Ownership is
        the verified story_user_id — never a client-supplied owner."""
        intent = story_engine.derive_creative_intent(body.raw_text)
        story = story_engine.create_story(body.title, intent)
        store.put(story)
        log.info(
            "story_created",
            extra={"operation": "create_story", "story_id": str(story.id),
                   "owner": principal.story_user_id},
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
