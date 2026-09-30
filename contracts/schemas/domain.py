"""Story domain model — the source of truth for the vertical slice.

Derived from spec/implementation-plan/02-core-story-schema.md.

This is the DOMAIN MODEL, not the API DTO and not the persistence model.
- Domain model  : pure business objects (this file)
- API DTO        : contracts/dto.py  (network wire shapes)
- Persistence    : SwiftData models on iOS; the backend is stateless for MVP

Invariants enforced here (subset relevant to Milestone A):
  - Story != GeneratedOutput
  - Create != Complete  (creating a GeneratedOutput never changes StoryStatus)
  - Identifiers are opaque UUIDs
  - A Story may hold multiple GeneratedOutputs
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from uuid import UUID, uuid4


def _now() -> datetime:
    return datetime.now(timezone.utc)


def new_id() -> UUID:
    """Opaque UUID identifier."""
    return uuid4()


class StoryStatus(str, Enum):
    """MVP status model. Only two states exist for Milestone A."""

    ACTIVE = "active"
    COMPLETED = "completed"


class MomentSource(str, Enum):
    DIRECTED = "directed"
    SPONTANEOUS = "spontaneous"
    EXISTING_MEDIA = "existing_media"
    CAMERA_IMPORT = "camera_import"


@dataclass(frozen=True)
class CreativeIntent:
    """Structured interpretation of the user's vague description.

    For the slice this is produced by the mock StoryEngine, deterministically.
    """

    id: UUID
    raw_text: str
    theme: str
    tone: str
    summary: str
    created_at: datetime = field(default_factory=_now)


@dataclass
class Asset:
    """Provenance of a piece of local media.

    LOCAL-FIRST: the original media never leaves the device. `local_uri`
    is a device-local reference (file URL or PhotoKit identifier). The
    backend never receives the bytes and never mints a cloud URL for it.
    """

    id: UUID
    local_uri: str
    duration_seconds: float
    source: MomentSource
    created_at: datetime = field(default_factory=_now)


@dataclass
class Moment:
    """Primary media unit belonging to a Story."""

    id: UUID
    story_id: UUID
    asset: Asset
    source: MomentSource
    caption: str | None = None
    created_at: datetime = field(default_factory=_now)


@dataclass
class GeneratedOutput:
    """A rendered result derived from a Story.

    Invariant: creating a GeneratedOutput does NOT complete the Story.
    For the slice, this is mock metadata only — no real render.
    """

    id: UUID
    story_id: UUID
    title: str
    duration_seconds: float
    moment_ids: list[UUID]
    created_at: datetime = field(default_factory=_now)


@dataclass
class Story:
    """Aggregate root."""

    id: UUID
    title: str
    creative_intent: CreativeIntent
    status: StoryStatus = StoryStatus.ACTIVE
    moments: list[Moment] = field(default_factory=list)
    generated_outputs: list[GeneratedOutput] = field(default_factory=list)
    created_at: datetime = field(default_factory=_now)
    updated_at: datetime = field(default_factory=_now)

    def add_moment(self, moment: Moment) -> None:
        assert moment.story_id == self.id, "Moment must belong to this Story"
        self.moments.append(moment)
        self.updated_at = _now()

    def add_generated_output(self, output: GeneratedOutput) -> None:
        """Create != Complete: status is intentionally left unchanged."""
        assert output.story_id == self.id, "Output must belong to this Story"
        self.generated_outputs.append(output)
        self.updated_at = _now()
        # Deliberately NOT touching self.status. Invariant: Create != Complete.
