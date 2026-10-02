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
    """A creative idea proposed by the Director Engine (02 §16)."""

    id: UUID
    title: str
    summary: str
    rationale: str | None = None
    preview_asset_id: UUID | None = None
    target_narrative_need_id: str | None = None


class ShotContract(_Strict):
    """One directed shot. Frozen product name is `Shot` (the element of
    StoryPlan.shots[]); 02 §18 called this ShotPlan — see reconciliation §4.2.
    """

    id: UUID
    order: int = Field(ge=0)
    instruction: str
    target_duration_seconds: float | None = Field(default=None, gt=0)
    framing: str | None = None
    camera_motion: str | None = None
    subject_action: str | None = None
    example_asset_id: UUID | None = None


class StoryPlanContract(_Strict):
    """The directed capture for one concept. MVP: generally 1-3 shots (02 §17)."""

    id: UUID
    concept_id: UUID
    shots: list[ShotContract] = Field(default_factory=list)
    estimated_duration_seconds: float | None = Field(default=None, gt=0)


# ---------------------------------------------------------------------------
# ValidationResult (02 §20) — "did we get a usable version?" only
# ---------------------------------------------------------------------------


class ValidationResultContract(_Strict):
    """Usability verdict for a captured shot. NEVER an aesthetic score (02 §20)."""

    usable: bool
    recommendation: ValidationRecommendation
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    issues: list[ValidationIssue] = Field(default_factory=list)


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
    """Machine-generated description of an Asset (02 §13). MVP fields optional."""

    asset_id: UUID
    semantic_description: str | None = None
    scene_tags: list[str] = Field(default_factory=list)
    people_count: int | None = Field(default=None, ge=0)
    actions: list[str] = Field(default_factory=list)
    quality: AssetQuality | None = None
    usable_segments: list[TimeRange] = Field(default_factory=list)


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
    "ShotContract",
    "StoryPlanContract",
    # validation + capture session
    "ValidationResultContract",
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
