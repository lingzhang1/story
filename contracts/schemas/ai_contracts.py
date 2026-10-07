"""Story — frozen AI structured-output + cross-boundary contracts (Milestone B).

This is the FOURTH model layer (03-system-architecture.md §2 principle 4):
strict, model-facing representations used to VALIDATE AI output and to cross
the Swift <-> Python boundary. It is distinct from:

  - domain model      (contracts/schemas/domain.py)      — what a concept means
  - API DTO           (contracts/schemas/dto.py)          — the Story-aggregate wire shapes
  - SwiftData models  (apps/ios/.../Persistence/Models)   — device storage

These models are the canonical contracts the upcoming engines (Milestone C+)
must produce and consume. NO real AI is implemented here — this file only
defines and validates the shapes. The engines stay mock until Milestone C.

Conventions (frozen in Milestone B, see milestone-b-reconciliation.md §6):
  - Pydantic v2, every model `extra="forbid"` (strict — reject unknown fields).
  - JSON is snake_case end-to-end (matches existing dto.py).
  - Timestamps are ISO-8601 UTC; ids are opaque UUIDs.
  - No provider/model-specific fields (03 §15), no AWS types (04 §2 #11),
    no persistence/transport fields (03 §7) leak in here.

Design rule enforced by the component-boundary review (task §8):
  Creative input          -> CreativeIntent
  scene scan              -> SceneUnderstanding
  CreativeIntent + SceneUnderstanding + CaptureConstraints
                          -> StoryConcept + StoryPlan   (Director)
  captured shot + Shot    -> ValidationResult
  Moments/assets          -> AssetUnderstanding
  CreativeIntent + AssetUnderstanding[] + MusicDirection
                          -> EditPlan
"""

from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class _Strict(BaseModel):
    """Base: forbid unknown fields so AI output cannot silently add keys."""

    model_config = ConfigDict(extra="forbid")


# ---------------------------------------------------------------------------
# Enums (frozen vocabularies)
# ---------------------------------------------------------------------------


class OutputFormat(str, Enum):
    VERTICAL = "vertical"
    SQUARE = "square"
    LANDSCAPE = "landscape"


class MusicEnergy(str, Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    DYNAMIC = "dynamic"


class Pace(str, Enum):
    """Broad temporal energy of the desired output (04-creative-intent.md §7.3).

    Categorical, NOT continuous and NOT exact edit timing — shot rhythm and
    cut points belong to StoryPlan / EditPlan, not CreativeIntent.
    """

    SLOW = "slow"
    MODERATE = "moderate"
    FAST = "fast"


class SubjectProminence(str, Enum):
    """How visually prominent a scene subject is (04-scene-understanding.md §13).

    Visual prominence, NOT semantic importance.
    """

    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


class OperatorSpace(str, Enum):
    """Visually apparent room for the camera operator (04-scene-understanding.md §18).

    An observation of visible space — NOT a safety guarantee. Director still
    applies conservative capture rules regardless of this value.
    """

    VERY_LIMITED = "very_limited"
    LIMITED = "limited"
    MODERATE = "moderate"
    OPEN = "open"
    UNKNOWN = "unknown"


class CaptureEntryPoint(str, Enum):
    """Where a CaptureSession originated (02 §14)."""

    CREATE_NOW = "create_now"
    SHOOT_MOMENT = "shoot_moment"
    STORY_IDEA = "story_idea"


class CreativeIntentSourceType(str, Enum):
    TEXT = "text"
    TEMPLATE = "template"
    REFERENCE_ASSET = "reference_asset"


class ValidationRecommendation(str, Enum):
    ACCEPT = "accept"
    RETAKE = "retake"


class ValidationIssue(str, Enum):
    """Gross-failure categories only — never aesthetic (02 §20)."""

    TOO_SHORT = "too_short"
    SEVERE_SHAKE = "severe_shake"
    SUBJECT_MISSING = "subject_missing"
    SEVERE_UNDEREXPOSURE = "severe_underexposure"
    SEVERE_OVEREXPOSURE = "severe_overexposure"
    INSTRUCTION_NOT_FOLLOWED = "instruction_not_followed"


class DirectorActionType(str, Enum):
    """The Director's next action in the DIRECT decision loop
    (05-story-director.md §7, §20). One strongest recommendation at a time.

    PINNED SEMANTICS (do not blur):
      capture_shot = capture a NEW Director-selected shot, even if it serves the
                     SAME still-`partial` beat (e.g. a different composition that
                     expresses the purpose more strongly).
      retry_shot   = recapture SUBSTANTIALLY THE SAME requested shot because
                     EXECUTION/validation failed (blocked subject, too short,
                     severe shake). NOT "Director wasn't satisfied".
    """

    CAPTURE_SHOT = "capture_shot"
    CREATE_NOW = "create_now"
    RESCAN_SCENE = "rescan_scene"
    RETRY_SHOT = "retry_shot"


class BeatStatus(str, Enum):
    """How much a StoryBeat has been fulfilled — DIRECTOR state, not planning
    and not ValidationResult (05-story-director.md §7). Categorical, no numeric
    percentage.
    """

    UNFULFILLED = "unfulfilled"
    PARTIAL = "partial"
    FULFILLED = "fulfilled"


class NarrativeCoverage(str, Enum):
    """Advisory, internal only — never rendered as a progress bar (02 §8)."""

    UNKNOWN = "unknown"
    COULD_USE_MORE = "could_use_more"
    LOOKING_GOOD = "looking_good"
    STRONG = "strong"


class TransitionType(str, Enum):
    CUT = "cut"
    FADE = "fade"
    DISSOLVE = "dissolve"


class MusicSectionType(str, Enum):
    INTRO = "intro"
    BUILD = "build"
    PEAK = "peak"
    BREAK = "break"
    OUTRO = "outro"
    OTHER = "other"


class StoryUtility(str, Enum):
    """How useful this Moment is to the broader Story (06-asset-understanding.md §1,
    FROZEN). Story-context interpretation, NOT an observed fact."""

    NONE = "none"
    USEFUL_ELSEWHERE = "useful_elsewhere"
    STRONG_ELSEWHERE = "strong_elsewhere"


# ---------------------------------------------------------------------------
# CreativeIntent (full frozen shape; 02 §4-5)
# ---------------------------------------------------------------------------


class CreativeIntentSource(_Strict):
    """One contributing input to a CreativeIntent."""

    type: CreativeIntentSourceType
    # Exactly one of the following is set depending on `type`.
    value: str | None = Field(default=None, description="text value, when type=text")
    template_id: str | None = Field(default=None, description="when type=template")
    asset_id: UUID | None = Field(default=None, description="when type=reference_asset")


class CreativeIntentContract(_Strict):
    """Normalized, structured representation of what the user wants to create.

    Frozen full shape (02 §4, refined by 04-creative-intent.md Milestone C).
    The Milestone-A code carried a flattened {raw_text, theme, tone, summary};
    map `raw_text`->`raw_user_description`, `summary`->`summary`, and seed
    `style_tags`/`desired_feeling` from the mock `theme`/`tone` until the real
    resolver populates them (reconciliation §3.1).

    Describes the desired OUTCOME only — never physical-scene facts, shot
    instructions, edit decisions, or provider/model metadata (04 §8).
    """

    id: UUID
    source_inputs: list[CreativeIntentSource] = Field(default_factory=list)
    summary: str
    subject: str | None = Field(
        default=None, description="What the Story is broadly about (semantic, not detected objects)"
    )
    # Emotional / creative character. `desired_feeling` is the small-vocabulary
    # tone (energetic/calm/cinematic/...); `style_tags` holds visual-character
    # tags. Together they are the spec's `tone` (04 §7.2), split so Director and
    # Music can consume feeling and visual style independently.
    desired_feeling: list[str] = Field(default_factory=list)
    style_tags: list[str] = Field(default_factory=list)
    pace: Pace | None = Field(
        default=None, description="Broad temporal energy (04 §7.3). Categorical only."
    )
    emphasis: list[str] = Field(
        default_factory=list,
        description="What should receive creative attention (04 §7.5): person/environment/scale/...",
    )
    # Important positive OR negative creative preferences that do not fit the
    # structured fields, e.g. 'authentic, not staged', 'epic but not cheesy',
    # 'focus more on the environment than me' (04 §7.6). Keep concise — not a
    # dumping ground for model reasoning. Supersedes the earlier `avoid`-only
    # field (reconciliation / 04 review): holds both positive and negative.
    creative_constraints: list[str] = Field(default_factory=list)
    target_duration_seconds: float | None = Field(default=None, gt=0)
    target_format: OutputFormat | None = None
    raw_user_description: str | None = None
    created_at: datetime = Field(default_factory=_utcnow)


# ---------------------------------------------------------------------------
# MusicDirection (02 §6)
# ---------------------------------------------------------------------------


class MusicDirectionContract(_Strict):
    """How the soundtrack should FEEL — not the selected song."""

    summary: str
    mood_tags: list[str] = Field(default_factory=list)
    energy: MusicEnergy | None = None
    progression: str | None = None
    raw_user_description: str | None = None


# ---------------------------------------------------------------------------
# SceneUnderstanding (02 §15) — Director input
# ---------------------------------------------------------------------------


class SceneSubject(_Strict):
    """A subject detected in the scene."""

    label: str
    note: str | None = None
    prominence: SubjectProminence | None = Field(
        default=None, description="Visual prominence (04 §13). Not semantic importance."
    )


class SceneUnderstandingContract(_Strict):
    """What Story understands about the user's current environment.

    Describes WHAT IS THERE — not the directing decision (02 §15, 04-scene-
    understanding.md §3). Opportunities are OBSERVATIONS; the Director decides
    what to shoot.
    """

    id: UUID
    summary: str
    environment_tags: list[str] = Field(default_factory=list)
    subjects: list[SceneSubject] = Field(default_factory=list)
    lighting: str | None = Field(
        default=None, description="Concise lighting description (scalar, 04 §19)."
    )
    operator_space: OperatorSpace | None = Field(
        default=None, description="Visibly apparent operator room (04 §18). Not a safety guarantee."
    )
    motion_opportunities: list[str] = Field(default_factory=list)
    composition_opportunities: list[str] = Field(default_factory=list)
    constraints: list[str] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=_utcnow)


# ---------------------------------------------------------------------------
# StoryConcept + StoryPlan + Shot (02 §16-18) — Director output
# ---------------------------------------------------------------------------


class StoryConceptContract(_Strict):
    """A creative idea proposed by the Director Engine (02 §16).

    `summary` IS the Story's creative thesis (05-story-director.md §4) — there
    is deliberately no separate `thesis` field.
    """

    id: UUID
    title: str
    summary: str
    rationale: str | None = None
    preview_asset_id: UUID | None = None
    target_narrative_need_id: str | None = None


class StoryBeat(_Strict):
    """A creative/narrative purpose the resulting Story needs to express
    (05-story-director.md §1-4). PLANNING object — minimal, no mutable
    execution state (fulfillment lives in DirectorState/BeatProgress).
    Every planned Shot serves a Beat; every Beat serves the StoryConcept.
    """

    id: str
    purpose: str


class ShotContract(_Strict):
    """One directed shot. Frozen product name is `Shot` (the element of
    StoryPlan.shots[]); 02 §18 called this ShotPlan — see reconciliation §4.2.

    Two explicit layers (05-story-director.md §12): `purpose` is the INTERNAL
    semantic reason the shot exists (what Validation cares about); `instruction`
    is the simple USER-FACING direction. Keep both distinct.
    """

    id: UUID
    order: int = Field(ge=0)
    instruction: str
    beat_id: str | None = Field(
        default=None, description="The StoryBeat this shot serves (every shot serves a beat)."
    )
    purpose: str | None = Field(
        default=None, description="Internal semantic reason the shot exists (05 §12)."
    )
    target_duration_seconds: float | None = Field(default=None, gt=0)
    framing: str | None = None
    camera_motion: str | None = None
    subject_action: str | None = None
    example_asset_id: UUID | None = None


class StoryPlanContract(_Strict):
    """The directed capture for one concept: WHAT material would create the
    Story. MVP: generally 1-3 shots (02 §17). PLANNING only — it does NOT own
    execution progress (that is DirectorState). Every shot's `beat_id` should
    reference a beat in `beats` (05-story-director.md §2).
    """

    id: UUID
    concept_id: UUID
    beats: list[StoryBeat] = Field(default_factory=list)
    shots: list[ShotContract] = Field(default_factory=list)
    estimated_duration_seconds: float | None = Field(default=None, gt=0)


# ---------------------------------------------------------------------------
# ValidationResult (02 §20) — "did we get a usable version?" only
# ---------------------------------------------------------------------------


class ValidationResultContract(_Strict):
    """Usability verdict for a captured shot. NEVER an aesthetic score (02 §20).

    Shot-level ONLY (05-story-director.md §6): it answers "did the captured
    asset sufficiently satisfy the requested Shot, and is it usable?". It does
    NOT determine StoryBeat fulfillment — that is Director state (BeatProgress).
    May reference the shot/capture it judged.
    """

    usable: bool
    recommendation: ValidationRecommendation
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    issues: list[ValidationIssue] = Field(default_factory=list)
    shot_id: UUID | None = Field(default=None, description="The Shot this judged.")
    capture_asset_id: UUID | None = Field(default=None, description="The captured asset judged.")


# ---------------------------------------------------------------------------
# Director decision loop (05-story-director.md §5, §7, §19) — DIRECT is a
# decision loop, not only a static plan generator.
# ---------------------------------------------------------------------------


class DirectorDecision(_Strict):
    """The Director's single strongest next recommendation (05 §5, §9).

    Separate from StoryPlan: StoryPlan = WHAT material would create the Story;
    DirectorDecision = what the user/system should DO next. Never exposes
    multiple creative choices to the user by default.
    """

    action: DirectorActionType
    # For capture_shot / retry_shot: the shot to (re)capture. Omitted for
    # create_now / rescan_scene.
    shot: ShotContract | None = None
    reason: str | None = Field(
        default=None, description="Internal rationale for this decision (not necessarily user-facing)."
    )


class BeatProgress(_Strict):
    """How far one StoryBeat has been fulfilled — DIRECTOR state, not planning
    and not ValidationResult (05 §7). Categorical, no numeric percentage.
    `supporting_asset_ids` is OPTIONAL (its necessity is an open experiment).
    """

    beat_id: str
    status: BeatStatus = BeatStatus.UNFULFILLED
    supporting_asset_ids: list[UUID] = Field(default_factory=list)


class DirectorState(_Strict):
    """Mutable DIRECT execution state, owned by the CaptureSession (05 §8).

    Separated from StoryPlan (the intent) so the plan stays a stable record of
    what we meant to capture while this tracks what actually happened.
    """

    current_beat_id: str | None = None
    beat_progress: list[BeatProgress] = Field(default_factory=list)
    last_decision: DirectorDecision | None = None


# ---------------------------------------------------------------------------
# CaptureSession (02 §14) — the reusable DIRECT primitive
# ---------------------------------------------------------------------------


class CaptureSessionContract(_Strict):
    """One directed shooting interaction. May belong to a Story (02 §14).

    If `story_id` is absent, this is a standalone Create Now session.
    Holds the scene/directing/capture state DIRECT needs.
    """

    id: UUID
    entry_point: CaptureEntryPoint
    creative_intent: CreativeIntentContract
    story_id: UUID | None = None
    scene_understanding: SceneUnderstandingContract | None = None
    selected_concept: StoryConceptContract | None = None
    story_plan: StoryPlanContract | None = None
    director_state: DirectorState | None = Field(
        default=None, description="Mutable DIRECT loop state (05 §8). Plan stays stable; this changes."
    )
    capture_asset_ids: list[UUID] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=_utcnow)


# ---------------------------------------------------------------------------
# AssetUnderstanding (02 §13) — preserved for Milestone H
# ---------------------------------------------------------------------------


class AssetQuality(_Strict):
    sharpness: float | None = Field(default=None, ge=0.0, le=1.0)
    stability: float | None = Field(default=None, ge=0.0, le=1.0)
    exposure: float | None = Field(default=None, ge=0.0, le=1.0)
    motion_quality: float | None = Field(default=None, ge=0.0, le=1.0)


class TimeRange(_Strict):
    start_seconds: float = Field(ge=0.0)
    end_seconds: float = Field(gt=0.0)


class AssetUnderstandingContract(_Strict):
    """LEGACY (pre-experiment, 02 §13). Superseded for MVP by MomentUnderstandingContract
    (06-asset-understanding.md, FROZEN 2026-10-05). Kept only for the Milestone-B contract
    tests / schema registry; NOT produced by the MVP AssetUnderstandingEngine."""

    asset_id: UUID
    semantic_description: str | None = None
    scene_tags: list[str] = Field(default_factory=list)
    people_count: int | None = Field(default=None, ge=0)
    actions: list[str] = Field(default_factory=list)
    quality: AssetQuality | None = None
    usable_segments: list[TimeRange] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# MomentUnderstanding (06-asset-understanding.md, FROZEN 2026-10-05)
#   The MVP Asset Understanding contract. Minimum, consumer-justified. A hard
#   split separates OBSERVED REALITY (request-independent) from STORY-CONTEXT
#   INTERPRETATION (depends on the request). Produced by AssetUnderstandingEngine
#   from a 24-frame timeline via Sonnet 4.6. Dropped vs the experiment schema:
#   environment, dead_or_setup_segments (no consumer).
# ---------------------------------------------------------------------------


class MomentEvent(_Strict):
    """One ordered, factual observed event. OBSERVED REALITY."""

    start_time: float = Field(ge=0.0, description="event start, seconds from clip start")
    end_time: float | None = Field(default=None, ge=0.0, description="event end, seconds (optional)")
    description: str = Field(description="what factually happened — no interpretation")


class MomentUsefulSegment(_Strict):
    """A coherent candidate region worth considering for editing. ASSET-GROUNDED —
    NOT a final cut. 'complete action of X', not 'perfect opening for the Story'."""

    start_time: float = Field(ge=0.0)
    end_time: float = Field(gt=0.0)
    why_useful: str = Field(description="why this region is coherent candidate material")


class MomentObserved(_Strict):
    """OBSERVED REALITY — request-independent. The same media yields the same
    observed block under any Story context."""

    summary: str = Field(description="concise whole-Moment summary")
    subjects: list[str] = Field(default_factory=list, description="who/what matters")
    events: list[MomentEvent] = Field(default_factory=list, description="ordered factual events")
    temporal_order_note: str = Field(
        default="",
        description="first/then/last; departure vs arrival, reveal direction, progression, contradiction",
    )
    useful_segments: list[MomentUsefulSegment] = Field(default_factory=list)


class MomentStoryContext(_Strict):
    """STORY-CONTEXT INTERPRETATION — depends on the request. requested_shot/beat
    contribution are NULLABLE: null when no capture context exists (spontaneous /
    imported Moments) — never fabricate a requested contribution without context."""

    story_utility: StoryUtility = Field(description="broader-Story usefulness")
    requested_shot_contribution: str | None = Field(
        default=None,
        description="does the footage serve the requested Shot purpose? null if no capture context",
    )
    requested_beat_contribution: str | None = Field(
        default=None,
        description="how the Moment contributes to the requested Beat; null if no capture context",
    )


class MomentUnderstandingContract(_Strict):
    """Canonical MVP Asset Understanding output (06-asset-understanding.md §1, FROZEN).
    One current record per Moment (upsert by moment_id). Provenance/version fields are
    server-assigned, not model-produced."""

    moment_id: UUID
    source_capture_id: UUID | None = Field(
        default=None, description="CaptureSession id when DIRECT; null for spontaneous/imported"
    )
    schema_version: str = Field(default="moment_understanding/1")
    frame_policy: str = Field(default="au_frames/1")
    prompt_version: str = Field(default="au_prompt/1")
    model_id: str | None = Field(default=None, description="provenance: which model produced this")
    n_frames: int | None = Field(default=None, ge=1, description="evidence frame count (24 for au_frames/1)")

    observed: MomentObserved
    story_context: MomentStoryContext
    created_at: datetime = Field(default_factory=_utcnow)


# ---------------------------------------------------------------------------
# StoryCoverage (Milestone E, FROZEN 2026-10-06) — "what the collection of
#   understood Moments MEANS for the Story". DERIVED, RECOMPUTABLE, ADVISORY —
#   NOT user-authored truth, NOT a checklist. One recomputed snapshot per Story.
#   HYBRID dimensions (stable structure + intent-derived labels); dimension `id`
#   is a within-snapshot handle ONLY, never durable identity. No numeric scores.
# ---------------------------------------------------------------------------


class SufficiencyStatus(str, Enum):
    """Can a Story meeting the user's intent be made from the understood material?
    Relative to CreativeIntent + scope + complementarity + redundancy + pending
    uncertainty — NEVER derived from Moment count."""

    INSUFFICIENT = "insufficient"
    WORKABLE = "workable"
    SUFFICIENT = "sufficient"


# ---------------------------------------------------------------------------
# StoryGuide (Milestone E2-a, FROZEN 2026-10-06) — the persistent, long-horizon
# creative map generated ONCE from CreativeIntent at Story creation, BEFORE any
# Moment exists. Model: us.anthropic.claude-opus-4-6-v1 (task-specific selection:
# StoryGuide benefits from restraint + concise framing; NOT a general "use Opus"
# rule — Sonnet 4.6 remains a valid future cost-optimized alternative, not rejected
# for capability/safety). Prompt: story_guide/v1. Design: milestone-e2-story-guide-
# reconciliation.md + milestone-e2a-story-guide-experiment.md.
#
# Dimension + capture-possibility `id`s are SERVER/DOMAIN-MINTED stable Story-local
# identity (the model emits ordinal handles d1/d1p1 which the engine coerces into
# canonical ids — model ids are NEVER canonical identity). StoryCoverage (E2-b) will
# reference these stable ids. NO required flags, NO numeric weights, NO completion
# percentages, NO fixed narrative vocabulary, NO camera/framing direction.
# ---------------------------------------------------------------------------


class CapturePossibility(_Strict):
    """ONE example way a StoryGuideDimension's purpose COULD be expressed — an
    illustration/inspiration, NEVER a required shot and NEVER camera/framing
    direction. A dimension may have zero of these. `id` is server-minted stable
    identity (drives the Figma represented/Shoot/Reshoot affordance in E2-b);
    purpose fulfillment — NOT literal possibility matching — determines a
    dimension's coverage, so these are not sub-requirements."""

    id: str = Field(description="server/domain-minted stable id; model ordinal is coerced, never canonical")
    label: str = Field(description="short example expression, e.g. 'person beneath huge mountains'")
    semantic_purpose: str | None = Field(
        default=None, description="what this example expresses (optional; used by Director handoff)"
    )


class StoryGuideDimension(_Strict):
    """One Story-specific narrative dimension of the creative map. `id` is
    server-minted STABLE Story-local identity (StoryCoverage references it by id,
    which is the fix for per-recompute dimension drift). label/purpose derive from
    CreativeIntent — never a fixed vocabulary. NOT a required shot, beat, or task."""

    id: str = Field(description="server/domain-minted STABLE id; model ordinal is coerced, never canonical")
    label: str = Field(description="intent-derived, Story-specific dimension name (domain vocabulary)")
    purpose: str = Field(description="what this dimension expresses for THIS Story")
    capture_possibilities: list[CapturePossibility] = Field(
        default_factory=list, description="a FEW (prefer 1-3) illustrative expressions; examples, not requirements"
    )


class StoryGuideContract(_Strict):
    """The frozen persistent Story creative map (Milestone E2-a). Generated ONCE
    from CreativeIntent at Story creation; stable while StoryCoverage recomputes
    as Moments arrive. One active Guide version per Story for MVP; a future
    Guide evolution MUST create a NEW version, never silently mutate meaning old
    Coverage was computed against (versioning per reconciliation §20/§28)."""

    schema_version: str = Field(default="story_guide/1")
    story_id: UUID
    source_creative_intent_version: str | None = Field(
        default=None, description="provenance: which resolved CreativeIntent this Guide was built from"
    )
    framing_summary: str = Field(
        description="ONE short human-readable statement of what this Story is trying to capture (app's calm voice)"
    )
    dimensions: list[StoryGuideDimension] = Field(
        default_factory=list, description="SMALL, scope-sensitive set of Story-specific dimensions"
    )
    generated_at: datetime = Field(default_factory=_utcnow)


class CoverageDimension(_Strict):
    """One narrative dimension (HYBRID). label/purpose are CreativeIntent-derived
    and Story-specific; `coverage` is categorical. `id` is a handle WITHIN THIS
    snapshot only — do NOT key persistent state on it, do NOT expect it stable
    across recomputes (semantic drift is expected)."""

    id: str = Field(description="within-snapshot handle ONLY; not durable identity")
    label: str = Field(description="intent-derived, Story-specific dimension name")
    purpose: str | None = Field(default=None, description="what this dimension expresses for the Story")
    coverage: NarrativeCoverage = Field(description="unknown | could_use_more | looking_good | strong")
    note: str | None = Field(default=None)
    evidence_moment_ids: list[UUID] = Field(default_factory=list)


class CoverageSufficiency(_Strict):
    status: SufficiencyStatus
    reason: str | None = None


class CoverageStoryIdea(_Strict):
    """ONE optional high-level narrative opportunity. NOT scene-specific, NOT
    camera direction. The whole object is nullable at StoryCoverage.story_idea —
    null is a first-class correct result (no interruption)."""

    title: str
    description: str
    rationale: str | None = None


class StoryCoverageContract(_Strict):
    """The frozen MVP Story Coverage snapshot (Milestone E). Produced by the
    StoryCoverageEngine from CreativeIntent + completed MomentUnderstanding[] +
    pending_count, via Opus. Server/engine mints provenance/version fields."""

    schema_version: str = Field(default="story_coverage/1")
    story_id: UUID
    moment_count: int = Field(ge=0, description="understood Moments considered")
    pending_count: int = Field(default=0, ge=0, description="Moments with AU not yet complete (UNKNOWN, not absent)")
    source_understanding_ids: list[UUID] = Field(
        default_factory=list, description="which MomentUnderstanding records this was computed from (staleness/provenance)"
    )

    dimensions: list[CoverageDimension] = Field(default_factory=list)
    strengths: list[str] = Field(default_factory=list)
    redundancies: list[str] = Field(default_factory=list)
    sufficiency: CoverageSufficiency
    story_idea: CoverageStoryIdea | None = Field(
        default=None, description="ONE optional opportunity, or null (first-class 'no interruption')"
    )

    generated_at: datetime = Field(default_factory=_utcnow)


# ---------------------------------------------------------------------------
# Music assets (02 §22-23) — preserved for Milestone I
# ---------------------------------------------------------------------------


class MusicSection(_Strict):
    type: MusicSectionType
    start_seconds: float = Field(ge=0.0)
    end_seconds: float = Field(gt=0.0)


class MusicAnalysisContract(_Strict):
    bpm: float | None = Field(default=None, gt=0)
    beats: list[float] = Field(default_factory=list)
    sections: list[MusicSection] = Field(default_factory=list)


class MusicAssetContract(_Strict):
    id: str
    title: str
    duration_seconds: float = Field(gt=0)
    mood_tags: list[str] = Field(default_factory=list)
    source: str = Field(description="story_catalog | user_import")
    analysis: MusicAnalysisContract | None = None


# ---------------------------------------------------------------------------
# EditPlan (02 §24) — preserved for Milestone J. AI decides; Media Engine executes.
# ---------------------------------------------------------------------------


class CropInstruction(_Strict):
    x: float = Field(ge=0.0, le=1.0)
    y: float = Field(ge=0.0, le=1.0)
    width: float = Field(gt=0.0, le=1.0)
    height: float = Field(gt=0.0, le=1.0)
    aspect_ratio: str | None = None


class TransitionInstruction(_Strict):
    type: TransitionType
    duration_seconds: float | None = Field(default=None, ge=0.0)


class EditSegmentContract(_Strict):
    order: int = Field(ge=0)
    asset_id: UUID
    source_start_seconds: float | None = Field(default=None, ge=0.0)
    source_end_seconds: float | None = Field(default=None, gt=0.0)
    output_duration_seconds: float = Field(gt=0.0)
    crop: CropInstruction | None = None
    speed: float | None = Field(default=None, gt=0.0)
    transition: TransitionInstruction | None = None
    narrative_role: str | None = None


class EditPlanContract(_Strict):
    """Structured editing specification produced by the Edit Engine (02 §24)."""

    id: UUID
    creative_intent_id: UUID
    target_duration_seconds: float = Field(gt=0.0)
    output_format: OutputFormat
    music_asset_id: str | None = None
    segments: list[EditSegmentContract] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=_utcnow)


__all__ = [
    # enums
    "OutputFormat",
    "MusicEnergy",
    "Pace",
    "SubjectProminence",
    "OperatorSpace",
    "CaptureEntryPoint",
    "CreativeIntentSourceType",
    "ValidationRecommendation",
    "ValidationIssue",
    "DirectorActionType",
    "BeatStatus",
    "NarrativeCoverage",
    "TransitionType",
    "MusicSectionType",
    # creative intent + music direction
    "CreativeIntentSource",
    "CreativeIntentContract",
    "MusicDirectionContract",
    # scene + director
    "SceneSubject",
    "SceneUnderstandingContract",
    "StoryConceptContract",
    "StoryBeat",
    "ShotContract",
    "StoryPlanContract",
    # validation + director loop + capture session
    "ValidationResultContract",
    "DirectorDecision",
    "BeatProgress",
    "DirectorState",
    "CaptureSessionContract",
    # asset understanding
    "AssetQuality",
    "TimeRange",
    "AssetUnderstandingContract",
    # music
    "MusicSection",
    "MusicAnalysisContract",
    "MusicAssetContract",
    # edit plan
    "CropInstruction",
    "TransitionInstruction",
    "EditSegmentContract",
    "EditPlanContract",
]
