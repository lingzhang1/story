"""Story contracts — schema package.

Re-exports the DOMAIN model (domain.py) and the API DTOs (dto.py) so
callers can `from contracts.schemas import Story, StoryDTO, ...`.

Keep the three concepts distinct (03-system-architecture.md §7):
  domain model  = what a concept means      (domain.py)
  API DTO       = what crosses the network   (dto.py)
  persistence   = how it is stored (SwiftData, iOS side — not here)
"""

from __future__ import annotations

from contracts.schemas.domain import (
    Asset,
    CreativeIntent,
    GeneratedOutput,
    Moment,
    MomentSource,
    Story,
    StoryStatus,
    new_id,
)
from contracts.schemas.dto import (
    AssetDTO,
    CreateStoryRequest,
    CreativeIntentDTO,
    GeneratedOutputDTO,
    MomentDTO,
    StoryDTO,
    to_dto,
)
from contracts.schemas.dto import StoryStatus as StoryStatusDTO

__all__ = [
    # domain
    "Asset",
    "CreativeIntent",
    "GeneratedOutput",
    "Moment",
    "MomentSource",
    "Story",
    "StoryStatus",
    "new_id",
    # dto
    "AssetDTO",
    "CreateStoryRequest",
    "CreativeIntentDTO",
    "GeneratedOutputDTO",
    "MomentDTO",
    "StoryDTO",
    "StoryStatusDTO",
    "to_dto",
]
