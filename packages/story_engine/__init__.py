"""Engine interface protocols and deterministic mock implementations.

Milestone A uses MOCK intelligence only. The API depends on these
Protocols, never on the concrete mock classes, so an AI implementation
can be swapped in later without touching the application layer.

Engines do NOT call each other. The application layer (apps/api)
orchestrates them.
"""

from __future__ import annotations

import hashlib
from typing import Protocol, runtime_checkable
from uuid import UUID

from contracts.schemas.domain import (
    CreativeIntent,
    Story,
    StoryStatus,
    new_id,
)

# Deterministic vocabulary the mock draws from, indexed by a hash of the
# input. No randomness: identical raw_text always yields identical output.
_THEMES = ("journey", "celebration", "discovery", "reunion", "everyday-magic")
_TONES = ("cinematic", "emotional", "playful", "calm", "epic")


def _digest(text: str) -> int:
    """Stable non-cryptographic-purpose integer derived from text.

    Used only to pick deterministic mock output; NOT a security primitive.
    """
    return int(hashlib.sha256(text.encode("utf-8")).hexdigest(), 16)


@runtime_checkable
class StoryEngine(Protocol):
    """Long-horizon Story reasoning interface (Story Engine).

    Owns CreativeIntent derivation and Story creation for the slice. A real
    AIStoryEngine will implement the same surface via the Model Gateway.
    """

    def derive_creative_intent(self, raw_text: str) -> CreativeIntent:
        """Normalize a vague user description into a structured intent."""
        ...

    def create_story(self, title: str, intent: CreativeIntent) -> Story:
        """Create a persistent Story aggregate from a title + intent."""
        ...


class MockStoryEngine:
    """Deterministic mock StoryEngine.

    Output is a pure function of the inputs (hash of raw_text), so the
    walking skeleton behaves identically on every run — a property the
    API tests rely on.
    """

    def derive_creative_intent(self, raw_text: str) -> CreativeIntent:
        h = _digest(raw_text)
        theme = _THEMES[h % len(_THEMES)]
        tone = _TONES[(h // len(_THEMES)) % len(_TONES)]
        summary = f"A {tone} {theme} story derived from the user's direction."
        return CreativeIntent(
            id=new_id(),
            raw_text=raw_text,
            theme=theme,
            tone=tone,
            summary=summary,
        )

    def create_story(self, title: str, intent: CreativeIntent) -> Story:
        return Story(
            id=new_id(),
            title=title,
            creative_intent=intent,
            status=StoryStatus.ACTIVE,
        )
