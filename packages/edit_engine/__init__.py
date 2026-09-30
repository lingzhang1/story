"""Edit Engine — turns a Story's Moments into a GeneratedOutput (mock).

For Milestone A this produces mock GeneratedOutput METADATA only — no
real render. It deterministically derives the output title and duration
from the Story and uses the ids of the Story's existing Moments.

CRITICAL invariant (enforced by the domain model, respected here):
creating a GeneratedOutput does NOT change Story.status.

Engines do NOT import each other. The application layer orchestrates.
"""

from __future__ import annotations

import hashlib
from typing import Protocol, runtime_checkable

from contracts.schemas.domain import GeneratedOutput, Story, new_id


def _digest(text: str) -> int:
    """Stable integer derived from text for deterministic mock selection."""
    return int(hashlib.sha256(text.encode("utf-8")).hexdigest(), 16)


@runtime_checkable
class EditEngine(Protocol):
    """Edit planning / output creation interface."""

    def create_generated_output(self, story: Story) -> GeneratedOutput:
        """Create mock GeneratedOutput metadata from the Story's Moments."""
        ...


class MockEditEngine:
    """Deterministic mock EditEngine.

    Duration is derived from the Story so repeated runs are identical.
    moment_ids are taken from the Story's current Moments — a real
    EditEngine would select a subset; the mock includes them all.
    """

    def create_generated_output(self, story: Story) -> GeneratedOutput:
        moment_ids = [m.id for m in story.moments]
        # Deterministic mock duration in the 8-20s range typical of a short.
        duration = 8.0 + float(_digest(str(story.id)) % 13)
        return GeneratedOutput(
            id=new_id(),
            story_id=story.id,
            title=f"{story.title} — cut",
            duration_seconds=duration,
            moment_ids=moment_ids,
        )
