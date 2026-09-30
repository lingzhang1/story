"""Asset Engine — media understanding.

Milestone A does NOT need real asset understanding for the vertical
slice (the mock EditEngine includes all Moments without analysis). This
package therefore provides only a Protocol stub and a minimal mock so the
interface exists and can be swapped for a real AIAssetEngine later.

Do NOT over-build: full AssetUnderstanding (semantic tags, quality,
usable segments, embeddings) is Milestone H, not A.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable
from uuid import UUID


@dataclass(frozen=True)
class AssetUnderstandingStub:
    """Minimal placeholder for the future AssetUnderstanding contract."""

    asset_id: UUID
    semantic_description: str = "unanalyzed (mock)"
    scene_tags: list[str] = field(default_factory=list)


@runtime_checkable
class AssetEngine(Protocol):
    """Media-understanding interface (stub for Milestone A)."""

    def analyze(self, asset_id: UUID) -> AssetUnderstandingStub:
        """Return minimal understanding for one asset."""
        ...


class MockAssetEngine:
    """Minimal deterministic mock. Returns an unanalyzed stub."""

    def analyze(self, asset_id: UUID) -> AssetUnderstandingStub:
        return AssetUnderstandingStub(asset_id=asset_id)
