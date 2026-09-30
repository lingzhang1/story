"""Director Engine — scene-specific directing (mock for Milestone A).

Owns the "given what the user wants, what should they shoot now?"
question. Milestone A returns a deterministic mock shot suggestion; a
real AIDirectorEngine will implement the same Protocol via the Model
Gateway.

Engines do NOT import each other. The application layer orchestrates.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Protocol, runtime_checkable
from uuid import UUID

from contracts.schemas.domain import Story, new_id

_SHOTS = (
    "Keep the camera still and walk toward the horizon.",
    "Follow your subject from behind as they move through the frame.",
    "Hold steady on the wide landscape; let a person cross the frame.",
    "Track slowly left to right across the scene.",
    "Frame the subject small against the environment for scale.",
)
_CONCEPTS = (
    "Walk Into the Scale",
    "A Moment Together",
    "The Quiet Opening",
    "Movement and Journey",
    "Into the Light",
)


def _digest(text: str) -> int:
    """Stable integer derived from text for deterministic mock selection."""
    return int(hashlib.sha256(text.encode("utf-8")).hexdigest(), 16)


def _now() -> datetime:
    return datetime.now(timezone.utc)


@dataclass(frozen=True)
class ShotSuggestion:
    """Small directing result: one concept + one simple shot instruction.

    A trimmed stand-in for the schema's StoryConcept/StoryPlan pairing,
    sufficient for the Milestone A slice. Duration is in seconds.
    """

    id: UUID
    story_id: UUID
    concept_title: str
    instruction: str
    target_duration_seconds: float = 6.0
    created_at: datetime = field(default_factory=_now)


@runtime_checkable
class DirectorEngine(Protocol):
    """Scene-specific directing interface."""

    def direct_moment(self, story: Story) -> ShotSuggestion:
        """Recommend one strong shot for capturing the next Moment."""
        ...


class MockDirectorEngine:
    """Deterministic mock DirectorEngine.

    Derives its suggestion from the story's creative intent, so the same
    Story always yields the same direction.
    """

    def direct_moment(self, story: Story) -> ShotSuggestion:
        seed = f"{story.id}:{story.creative_intent.raw_text}"
        h = _digest(seed)
        return ShotSuggestion(
            id=new_id(),
            story_id=story.id,
            concept_title=_CONCEPTS[h % len(_CONCEPTS)],
            instruction=_SHOTS[(h // len(_CONCEPTS)) % len(_SHOTS)],
            target_duration_seconds=6.0,
        )
