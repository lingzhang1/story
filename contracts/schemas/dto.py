"""API WIRE models (DTOs) for the Story backend.

These are the shapes that cross the NETWORK — distinct from:
  - the DOMAIN model (contracts/schemas/domain.py), and
  - the PERSISTENCE model (SwiftData @Model classes on iOS).

Rules (03-system-architecture.md §7):
  - No persistence fields (no SwiftData concerns, no local file paths as
    storage, no relationship graphs) leak into DTOs.
  - Domain -> DTO conversion is explicit via from_domain(); DTOs never
    import persistence code.

Pydantic v2. Timestamps serialize as ISO-8601 strings; ids as UUID.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from contracts.schemas import domain as _domain


class StoryStatus(str, Enum):
    """Wire copy of the domain status enum (network-facing)."""

    ACTIVE = "active"
    COMPLETED = "completed"


class CreativeIntentDTO(BaseModel):
    """Wire shape of a derived CreativeIntent."""

    model_config = ConfigDict(extra="forbid")

    id: UUID
    raw_text: str
    theme: str
    tone: str
    summary: str
    created_at: datetime

    @classmethod
    def from_domain(cls, ci: _domain.CreativeIntent) -> "CreativeIntentDTO":
        return cls(
            id=ci.id,
            raw_text=ci.raw_text,
            theme=ci.theme,
            tone=ci.tone,
            summary=ci.summary,
            created_at=ci.created_at,
        )


class AssetDTO(BaseModel):
    """Wire shape of an Asset.

    LOCAL-FIRST: `local_uri` is a device-local reference the client owns.
    The backend never receives the bytes; this DTO carries the reference
    string only, never a cloud URL and never the media itself.
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID
    local_uri: str
    duration_seconds: float
    source: str
    created_at: datetime

    @classmethod
    def from_domain(cls, asset: _domain.Asset) -> "AssetDTO":
        return cls(
            id=asset.id,
            local_uri=asset.local_uri,
            duration_seconds=asset.duration_seconds,
            source=asset.source.value,
            created_at=asset.created_at,
        )


class MomentDTO(BaseModel):
    """Wire shape of a Moment (embeds its Asset)."""

    model_config = ConfigDict(extra="forbid")

    id: UUID
    story_id: UUID
    asset: AssetDTO
    source: str
    caption: str | None = None
    created_at: datetime

    @classmethod
    def from_domain(cls, moment: _domain.Moment) -> "MomentDTO":
        return cls(
            id=moment.id,
            story_id=moment.story_id,
            asset=AssetDTO.from_domain(moment.asset),
            source=moment.source.value,
            caption=moment.caption,
            created_at=moment.created_at,
        )


class GeneratedOutputDTO(BaseModel):
    """Wire shape of a GeneratedOutput (metadata only — no media)."""

    model_config = ConfigDict(extra="forbid")

    id: UUID
    story_id: UUID
    title: str
    duration_seconds: float
    moment_ids: list[UUID] = Field(default_factory=list)
    created_at: datetime

    @classmethod
    def from_domain(cls, out: _domain.GeneratedOutput) -> "GeneratedOutputDTO":
        return cls(
            id=out.id,
            story_id=out.story_id,
            title=out.title,
            duration_seconds=out.duration_seconds,
            moment_ids=list(out.moment_ids),
            created_at=out.created_at,
        )


class StoryDTO(BaseModel):
    """Wire shape of a Story aggregate."""

    model_config = ConfigDict(extra="forbid")

    id: UUID
    title: str
    status: StoryStatus
    creative_intent: CreativeIntentDTO
    moments: list[MomentDTO] = Field(default_factory=list)
    generated_outputs: list[GeneratedOutputDTO] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime

    @classmethod
    def from_domain(cls, story: _domain.Story) -> "StoryDTO":
        return cls(
            id=story.id,
            title=story.title,
            status=StoryStatus(story.status.value),
            creative_intent=CreativeIntentDTO.from_domain(story.creative_intent),
            moments=[MomentDTO.from_domain(m) for m in story.moments],
            generated_outputs=[
                GeneratedOutputDTO.from_domain(o) for o in story.generated_outputs
            ],
            created_at=story.created_at,
            updated_at=story.updated_at,
        )


# ---- Request bodies (network in-bound) ----------------------------------


class CreateStoryRequest(BaseModel):
    """POST /v1/stories body."""

    model_config = ConfigDict(extra="forbid")

    raw_text: str = Field(min_length=1, description="User's creative direction")
    title: str = Field(min_length=1, description="Human-readable Story title")


def to_dto(story: _domain.Story) -> StoryDTO:
    """Convenience alias: domain Story -> StoryDTO."""
    return StoryDTO.from_domain(story)
