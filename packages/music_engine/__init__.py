"""Music Engine — MusicDirection interpretation & track recommendation.

Milestone A does NOT need real music intelligence for the vertical slice.
This package provides only a Protocol stub and a minimal mock returning a
single placeholder track from a tiny catalog, so the interface exists and
can be swapped for a real MusicEngine later.

Do NOT over-build: BPM/beat/section analysis is Milestone I, not A.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable


@dataclass(frozen=True)
class MusicTrackStub:
    """Minimal placeholder for the future MusicAsset contract."""

    id: str
    title: str
    mood_tags: list[str] = field(default_factory=list)


# Tiny licensing-safe placeholder catalog (mock only).
_CATALOG = (
    MusicTrackStub(id="mock-cinematic", title="Wide Horizons", mood_tags=["cinematic", "emotional"]),
    MusicTrackStub(id="mock-playful", title="Bright Steps", mood_tags=["playful", "energetic"]),
    MusicTrackStub(id="mock-calm", title="Still Water", mood_tags=["calm", "atmospheric"]),
)


@runtime_checkable
class MusicEngine(Protocol):
    """Music recommendation interface (stub for Milestone A)."""

    def recommend(self, direction_summary: str) -> MusicTrackStub:
        """Return one recommended track for the given music direction."""
        ...


class MockMusicEngine:
    """Minimal deterministic mock. Picks a catalog track by hash."""

    def recommend(self, direction_summary: str) -> MusicTrackStub:
        h = int(hashlib.sha256(direction_summary.encode("utf-8")).hexdigest(), 16)
        return _CATALOG[h % len(_CATALOG)]
