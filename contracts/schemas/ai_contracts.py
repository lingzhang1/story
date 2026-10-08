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

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


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
# StoryCoverage/2 (Milestone E2-b, FROZEN 2026-10-06) — the Guide-relative Story
# Coverage snapshot. PUBLIC composed result of an INTERNAL two-call pipeline:
#   CALL 1 StoryCoverageMapper (prompt story_coverage/mapper-v1, Opus 4.6):
#     StoryGuide + completed MomentUnderstanding[] -> DimensionCoverage[] + strengths
#     + redundancies. NEVER emits sufficiency or story_idea.
#   CALL 2 StoryJudgmentEngine (prompt story_judgment/v2, Opus 4.6):
#     deterministic evidence (CreativeIntent/scope + positive semantic evidence +
#     FACTUAL MaterialScopeEvidence + redundancy + pending_count; NO Guide, NO
#     dimension states, NO candidates, NO completion signals — the J-A/J-B ablation
#     proved candidates reintroduce completion bias) -> {sufficiency, story_idea}.
# The two-call split is an IMPLEMENTATION detail; iOS sees only this composed
# StoryCoverageContractV2. Narrative dimension DEFINITION lives in StoryGuide;
# Coverage/2 owns only STATE keyed by stable Guide dimension id (fixes id drift).
# Material scope is EVIDENCE the Judge reasons over jointly with semantic adequacy —
# NOT a ratio/quota/clip-count formula (G: 2.61x duration but conflicting -> still
# insufficient, proves duration alone cannot decide). sufficiency/story_idea are
# INDEPENDENT: all six {insufficient|workable|sufficient} x {idea|null} states valid;
# never force sufficient -> null.
# ---------------------------------------------------------------------------


class DimensionCoverage(_Strict):
    """STATE of ONE StoryGuide dimension (not its definition — that lives in the
    Guide). Produced by the Mapper. `state` is PURPOSE fulfillment, never literal
    possibility matching. `represented_possibility_ids` is UI-affordance evidence
    ONLY ([x]/Reshoot) — it MUST NOT drive state, sufficiency, idea, or completion;
    a dimension may be strong with an EMPTY list."""

    story_guide_dimension_id: str = Field(description="FK -> frozen StoryGuide dimension (stable id)")
    state: NarrativeCoverage = Field(description="unknown | could_use_more | looking_good | strong (purpose-driven)")
    note: str | None = Field(default=None)
    evidence_moment_ids: list[UUID] = Field(default_factory=list)
    represented_possibility_ids: list[str] = Field(
        default_factory=list, description="UI-only: capture_possibility ids the real material realizes; NON-driving"
    )


class MaterialScopeEvidence(_Strict):
    """FACTUAL material-scope signals derived DETERMINISTICALLY from completed
    MomentUnderstanding useful_segments — the Judge's neutral anchor for 'enough
    material for THIS requested scope?'. NOT a quota, NOT a ratio threshold, NOT a
    clip-count rule: the Judge reasons over it jointly with semantic adequacy and
    redundancy (abundant-but-redundant or abundant-but-conflicting material does not
    create adequacy)."""

    understood_moment_count: int = Field(ge=0)
    useful_moment_count: int = Field(ge=0, description="understood Moments with at least one useful segment")
    total_useful_segment_duration_seconds: float = Field(ge=0.0)
    target_output_duration_seconds: float | None = Field(default=None, gt=0)


class StoryJudgment(_Strict):
    """INTERNAL Call-2 output: the independent Story-level judgment. Composed into
    StoryCoverageContractV2; not a separate public product concept."""

    sufficiency: CoverageSufficiency
    story_idea: "CoverageStoryIdeaV2 | None" = Field(default=None)


class CoverageStoryIdeaV2(_Strict):
    """ONE optional, high-level, scene-independent opportunity offering a MATERIALLY
    NEW contribution (not a redundant variation of an already well-represented
    quality). Independent of sufficiency — a `sufficient` Story may still carry one.
    Shape: title ~3-7 words; description ONE concise sentence (~20-30w, card copy);
    rationale rich/internal (not default Home copy). target set when it serves one
    Guide dimension, else null."""

    title: str
    description: str
    rationale: str | None = None
    target_story_guide_dimension_id: str | None = None


class CoverageMapping(_Strict):
    """INTERNAL Call-1 output: how understood material serves the frozen Guide.
    Composed into StoryCoverageContractV2; never emits sufficiency/story_idea."""

    dimension_coverage: list[DimensionCoverage] = Field(default_factory=list)
    strengths: list[str] = Field(default_factory=list, description="positive actual Story evidence (incl. unexpected material)")
    redundancies: list[str] = Field(default_factory=list)


class StoryCoverageContractV2(_Strict):
    """FROZEN public StoryCoverage/2 (Milestone E2-b). Composed from the internal
    Mapper (dimension_coverage/strengths/redundancies) + Judge (sufficiency/
    story_idea) + server provenance. iOS consumes THIS; the two-call pipeline is
    hidden. Narrative definition lives in StoryGuide; this owns Guide-relative STATE
    plus the independent sufficiency + optional single idea."""

    schema_version: str = Field(default="story_coverage/2")
    story_id: UUID
    story_guide_id: str = Field(description="which frozen StoryGuide this maps onto")
    story_guide_version: str = Field(default="story_guide/1", description="Guide schema/version (staleness vs Guide)")
    moment_count: int = Field(ge=0)
    pending_count: int = Field(default=0, ge=0, description="Moments with AU not yet complete (UNKNOWN, not absent)")
    source_understanding_ids: list[UUID] = Field(default_factory=list)

    dimension_coverage: list[DimensionCoverage] = Field(default_factory=list)
    strengths: list[str] = Field(default_factory=list)
    redundancies: list[str] = Field(default_factory=list)
    sufficiency: CoverageSufficiency
    story_idea: CoverageStoryIdeaV2 | None = Field(
        default=None, description="ONE optional opportunity, or null — INDEPENDENT of sufficiency"
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
# MusicAnalysis/1 — FROZEN (Milestone M-d, 2026-10-07). Minimum provider-aligned
# OBSERVED track structure the Edit Planner aligns to. Evidence: live Epidemic
# Partner API validation (milestone-md-epidemic-live-validation-results.md).
# Every field has an Edit-Planner consumer. NO labelled sections (deferred, our-
# analysis), NO time-ranged vocal_regions (deferred), NO numeric emotional
# intensity, NO fabricated section boundaries. Normalizers live in the provider
# adapter; this contract VALIDATES the normalized result.
# ---------------------------------------------------------------------------


class HighlightWindow(_Strict):
    """A candidate engaging region (e.g. Epidemic 'highlights'), in SECONDS. A
    candidate, NOT a guaranteed emotional climax."""

    start_seconds: float = Field(ge=0.0)
    end_seconds: float = Field(gt=0.0)


class MusicAnalysisV1Contract(_Strict):
    """FROZEN music_analysis/1. duration required+positive; bpm nullable (<=0 ->
    null upstream — unreliable/absent tempo); beats/downbeats in real seconds;
    energy_curve a COARSE normalized amplitude envelope (signal amplitude, NOT
    perceived emotion); vocal_type a provider category. tempo_reliable gates
    beat-synchronizability — a beat grid alone does NOT make a track beat-synced."""

    schema_version: str = Field(default="music_analysis/1")
    duration_seconds: float = Field(gt=0.0)
    bpm: float | None = Field(default=None, description="null when unknown/unreliable (provider 0 -> null)")
    tempo_reliable: bool = Field(default=False, description="true only when bpm is present AND trustworthy")
    beats: list[float] = Field(default_factory=list, description="beat times in seconds")
    downbeats: list[float] = Field(default_factory=list, description="derived from provider value==1, seconds")
    highlight_window: HighlightWindow | None = None
    energy_curve: list[float] = Field(
        default_factory=list, description="coarse 0..1 normalized amplitude samples (bounded resolution)")
    vocal_type: str | None = Field(default=None, description="NONE | PRESENCE | LEAD (provider category)")

    @field_validator("bpm")
    @classmethod
    def _bpm_positive_or_null(cls, v: float | None) -> float | None:
        if v is not None and v <= 0:
            raise ValueError("bpm must be >0 or null (normalize provider 0 -> null before constructing)")
        return v

    @field_validator("beats", "downbeats")
    @classmethod
    def _times_sorted_nonneg(cls, v: list[float]) -> list[float]:
        if any(t < 0 for t in v):
            raise ValueError("beat/downbeat times must be nonnegative")
        if v != sorted(v):
            raise ValueError("beat/downbeat times must be chronological")
        return v

    @field_validator("energy_curve")
    @classmethod
    def _energy_bounded(cls, v: list[float]) -> list[float]:
        if any(not (0.0 <= x <= 1.0) for x in v):
            raise ValueError("energy_curve samples must be normalized to 0..1")
        return v

    @model_validator(mode="after")
    def _consistency(self) -> "MusicAnalysisV1Contract":
        dur = self.duration_seconds
        if self.beats and self.beats[-1] > dur + 0.1:
            raise ValueError("beat time exceeds duration")
        if self.downbeats and self.downbeats[-1] > dur + 0.1:
            raise ValueError("downbeat time exceeds duration")
        if self.highlight_window:
            h = self.highlight_window
            if h.end_seconds <= h.start_seconds:
                raise ValueError("highlight_window end must exceed start")
            if h.end_seconds > dur + 0.1:
                raise ValueError("highlight_window exceeds duration")
        if self.tempo_reliable and self.bpm is None:
            raise ValueError("tempo_reliable=true requires a non-null bpm")
        return self


# ---------------------------------------------------------------------------
# MusicPlan (Milestone M-b — FROZEN music_plan/1, Opus 4.6, prompt music_plan/1)
#
# Story-level SOUNDTRACK SHAPE a future Edit Planner consumes for pacing. NOT a
# song, NOT cut points, NOT Moment selection, NOT an audio mix. Generated at /
# immediately before Create My Story from CreativeIntent + MusicDirection +
# StoryGuide + StoryCoverage/2 + target duration. MusicDirection stays
# AUTHORITATIVE for mood/energy; `character` here is a RESOLVED snapshot carried
# for provenance / to seed track selection. key_moments[] was ABLATED OUT in M-b
# (redundant with energy_arc + audio_strategy). Validated: us.anthropic.claude-
# opus-4-6-v1. See milestone-mb-musicplan-experiment.md.
# ---------------------------------------------------------------------------


class EnergyIntensity(str, Enum):
    """Categorical direction of an energy_arc region — NO numeric energy scores."""

    LOW = "low"
    RISING = "rising"
    HIGH = "high"
    FALLING = "falling"


class SoundtrackRole(str, Enum):
    """How much the composed soundtrack carries the Story vs native audio."""

    CONTINUOUS = "continuous"
    SUPPORTIVE = "supportive"
    SPARSE = "sparse"


class NativeAudioPriority(str, Enum):
    """How much room the Story's OWN captured audio needs (a guitar performance,
    singing, laughter, dialogue, wind, waves, crowd)."""

    LOW = "low"
    SELECTIVE = "selective"
    IMPORTANT = "important"


class MusicPlanProvenance(_Strict):
    """How this plan was produced — recorded by the server/engine, not the model."""

    model_id: str = Field(description="e.g. us.anthropic.claude-opus-4-6-v1")
    prompt_version: str = Field(default="music_plan/1")
    inputs: list[str] = Field(
        default_factory=list,
        description="which inputs were actually fed (e.g. creative_intent, music_direction, story_guide, story_coverage)",
    )
    generated_at: datetime = Field(default_factory=_utcnow)


class MusicCharacter(_Strict):
    """RESOLVED snapshot of the intended musical feel. Authority is
    MusicDirection; this is carried for provenance / to seed track selection.
    Do NOT treat as a second source of truth for mood/energy."""

    mood_tags: list[str] = Field(default_factory=list)
    energy: MusicEnergy


class EnergyArcRegion(_Strict):
    """One APPROXIMATE Story-level energy region. Fractions are 0..1 of
    target_duration_seconds — approximate regions, NEVER cut points."""

    label: str = Field(description="short human-readable region name, e.g. 'warm gradual build'")
    start_fraction: float = Field(ge=0.0, le=1.0)
    end_fraction: float = Field(ge=0.0, le=1.0)
    intensity: EnergyIntensity
    note: str | None = Field(default=None, description="optional one-line creative intent for the region")


class AudioStrategy(_Strict):
    """First-class native-audio strategy. Story-level ONLY — NO per-Moment volume
    automation, NO clip ids (those are Edit Planner / audio-mix). Exact ducking,
    fades and mixing belong downstream."""

    soundtrack_role: SoundtrackRole
    native_audio_priority: NativeAudioPriority
    guidance: str | None = Field(
        default=None, description="optional one concise semantic line, e.g. 'step back so the real guitar lands'"
    )


class TrackSelectionCriteria(_Strict):
    """OPTIONAL brief handle for a FUTURE track selector (M-d). The seam between
    music intelligence and track sourcing — carries no catalog/provider assumption."""

    mood_tags: list[str] = Field(default_factory=list)
    energy: MusicEnergy | None = None
    structure_hint: str | None = None


class MusicPlanContract(_Strict):
    """FROZEN Story-level soundtrack shape (Milestone M-b). The intelligence
    bridge from Story understanding to the future Edit Planner. Scope-sensitive:
    an 8s Story = ONE energy region, a rich 60-120s Story may justify 3-4. NO
    mechanical quiet->build->climax. Server/engine mints provenance/version."""

    schema_version: str = Field(default="music_plan/1")
    story_id: UUID
    target_duration_seconds: float = Field(gt=0.0, description="the arc fractions are of THIS duration")
    character: MusicCharacter
    energy_arc: list[EnergyArcRegion] = Field(
        default_factory=list, description="SMALL, scope-sensitive sequence of approximate energy regions"
    )
    audio_strategy: AudioStrategy
    track_selection_criteria: TrackSelectionCriteria | None = Field(
        default=None, description="optional handoff to a FUTURE track selector (M-d)"
    )
    provenance: MusicPlanProvenance | None = Field(
        default=None, description="server-minted: model/prompt/inputs/generated_at"
    )


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


# ---------------------------------------------------------------------------
# EditPlan/2 — FROZEN (Milestone M-d.3, 2026-10-07). Edit Planner PLANS; Media
# Engine EXECUTES. Additive over edit_plan/1: carries the E2/music seam the v1
# shape lacked. Produced by ONE Opus 4.6 call (prompt edit_plan/2) from
# CreativeIntent + StoryGuide/1 + StoryCoverage/2 + MomentUnderstanding[] +
# MusicPlan/1 (+ optional MusicAnalysis). A DETERMINISTIC validator is the hard
# executability gate — the model NEVER self-certifies. See
# milestone-md3-api-validation-edit-planner-experiment.md + ...-editplan2-contract.md.
# ---------------------------------------------------------------------------


class NativeAudioIntent(str, Enum):
    """Per-segment intent for the Moment's OWN CAPTURED audio (NOT the soundtrack).
    keep = preserve the captured sound (it carries the segment); duck = reduce it
    beneath the soundtrack; mute = omit it. Whether the SOUNDTRACK recedes to
    protect a kept native moment is a downstream Media-Engine mix decision driven
    by MusicPlan.audio_strategy + keep — not encoded here."""

    KEEP = "keep"
    DUCK = "duck"
    MUTE = "mute"


class MusicAlignmentAnchor(str, Enum):
    """What real-music structural point a segment's leading cut should land on.
    Only meaningful when a MusicAnalysis is present; default NONE. NO global
    beat_sync boolean — alignment is per-segment and heterogeneous."""

    NONE = "none"
    BEAT = "beat"
    DOWNBEAT = "downbeat"
    HIGHLIGHT = "highlight"


class MusicAlignment(_Strict):
    """Segment-level alignment INTENT. The Media Engine does the exact snapping to
    the MusicAnalysis times; the planner only states intent. Narrative-first —
    set an anchor only when it materially serves pacing/transition/payoff/ending."""

    anchor: MusicAlignmentAnchor = MusicAlignmentAnchor.NONE
    note: str | None = None


class EditSegmentV2Contract(_Strict):
    """One planned segment (edit_plan/2). asset_id MUST be an existing Moment id;
    source range MUST lie within the Moment's real duration and useful_segments."""

    order: int = Field(ge=0)
    asset_id: UUID
    source_start_seconds: float | None = Field(default=None, ge=0.0)
    source_end_seconds: float | None = Field(default=None, gt=0.0)
    output_duration_seconds: float = Field(gt=0.0)
    crop: CropInstruction | None = None
    speed: float | None = Field(default=None, gt=0.0)
    transition: TransitionInstruction | None = None
    narrative_role: str | None = None
    native_audio: NativeAudioIntent
    music_alignment: MusicAlignment | None = None


class EditPlanV2Contract(_Strict):
    """FROZEN edit_plan/2. Output duration tracks the STORY target (CreativeIntent),
    never the music track length; +/-20% is a feasibility tolerance, not a target.
    feasible=False + infeasible_reason instead of inventing footage."""

    schema_version: str = Field(default="edit_plan/2")
    id: UUID
    story_id: UUID
    creative_intent_id: UUID
    target_duration_seconds: float = Field(gt=0.0)
    output_format: OutputFormat
    music_asset_id: str | None = None
    music_plan_id: UUID | None = None
    music_analysis_ref: MusicAnalysisContract | None = None
    feasible: bool = True
    infeasible_reason: str | None = None
    segments: list[EditSegmentV2Contract] = Field(default_factory=list)
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
    # music analysis/1 (M-d, frozen music_analysis/1)
    "HighlightWindow",
    "MusicAnalysisV1Contract",
    # music plan (M-b, frozen music_plan/1)
    "EnergyIntensity",
    "SoundtrackRole",
    "NativeAudioPriority",
    "MusicPlanProvenance",
    "MusicCharacter",
    "EnergyArcRegion",
    "AudioStrategy",
    "TrackSelectionCriteria",
    "MusicPlanContract",
    # edit plan
    "CropInstruction",
    "TransitionInstruction",
    "EditSegmentContract",
    "EditPlanContract",
    # edit plan/2 (M-d.3, frozen edit_plan/2)
    "NativeAudioIntent",
    "MusicAlignmentAnchor",
    "MusicAlignment",
    "EditSegmentV2Contract",
    "EditPlanV2Contract",
]
