"""In-memory Story store — NON-PERSISTENT demo state.

⚠️  MVP has NO server database. Persistent Story ownership is LOCAL-FIRST
on the iOS device (SwiftData). This dict exists only so the walking
skeleton's HTTP endpoints have somewhere to hold a Story between the
create call and the create-output call within a single process lifetime.

Everything here is lost on restart — by design. Do NOT grow this into a
backend Story database (see 04-aws-infrastructure.md §45).
"""

from __future__ import annotations

from uuid import UUID

from contracts.schemas.domain import Story


class InMemoryStoryStore:
    """Process-local dict of Story aggregates. Not thread-safe; adequate
    for the single-worker walking skeleton and tests."""

    def __init__(self) -> None:
        self._stories: dict[UUID, Story] = {}

    def put(self, story: Story) -> None:
        self._stories[story.id] = story

    def get(self, story_id: UUID) -> Story | None:
        return self._stories.get(story_id)

    def clear(self) -> None:
        self._stories.clear()
