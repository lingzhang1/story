"""P1-E — account-owned My Music FAVORITES store (saved catalog-track references).

A saved catalog favorite is a licensing-safe REFERENCE (provider track id + display metadata), never audio
bytes. The durable thing to sync across reinstall is the per-account SET of saved references. This is a small,
mutable, per-account document with optimistic concurrency — exactly the Story-doc shape, but global to the
account rather than per-Story.

NO NEW INFRASTRUCTURE: this reuses the EXISTING R7-E Moment Understanding DynamoDB table
(key = story_user_id, moment_id) under a RESERVED sentinel sort key that can never collide with a real
Moment UUID. So there is no new table, no CDK change, no IAM change — only a new API shape on top of storage
that is already provisioned, granted, and env-wired. (Owner-approved P1-E: new /v1/music/favorites endpoint.)

Item (in the understanding table):
    PK story_user_id (S)   SK moment_id (S) = FAVORITES_SENTINEL
    understanding_json (S) = {"favorites": [...]}   (reuses the existing string column)
    revision (N)           -- server monotonic (managed by the understanding store); optimistic concurrency
    updated_at (N)

Account isolation: every op is scoped to the trusted principal.story_user_id (composite key), so a wrong
owner finds nothing. References only — no bytes, no licensing exposure.
"""
from __future__ import annotations

import json
import time
from typing import Optional

# A sentinel sort key for the per-account favorites doc. NOT a UUID, so it can never collide with a Moment id.
FAVORITES_SENTINEL = "__music_favorites__"

# Keep the favorites doc bounded (references are tiny; this is a generous cap well under the 350 KB item limit).
MAX_FAVORITES = 2000


class FavoritesConflict(Exception):
    """base_revision did not match the server's current revision (another device won)."""
    def __init__(self, current: dict):
        super().__init__("music favorites revision conflict")
        self.current = current


def _now() -> int:
    return int(time.time())


class MusicFavoritesStore:
    """Thin wrapper over the understanding store's table. Accepts the SAME ddb client / table the
    UnderstandingStore uses (injected for tests), so there is one storage dependency, not a new one.

    The authoritative revision is the understanding table's own `revision` column (bumped monotonically by
    UnderstandingStore.put on every write) — this store does NOT embed a second revision in the doc, so the
    two can never drift."""

    def __init__(self, understanding_store):
        # Reuse the already-configured UnderstandingStore (its table + ddb client + test override).
        self._us = understanding_store

    def get(self, owner: str) -> dict:
        """Return {"favorites": [...], "revision": N}. A never-written account reads as an empty doc at
        revision 0 (NOT an error) — so a fresh client shows an empty library, never a failure."""
        rec = self._us.get(owner, FAVORITES_SENTINEL)
        if not rec:
            return {"favorites": [], "revision": 0}
        try:
            doc = json.loads(rec.get("understanding_json") or "{}")
        except Exception:
            doc = {}
        favs = doc.get("favorites") if isinstance(doc, dict) else None
        return {"favorites": favs if isinstance(favs, list) else [],
                "revision": int(rec.get("revision", 0))}

    def put(self, *, owner: str, base_revision: int, favorites: list[dict]) -> dict:
        """Optimistic-concurrency upsert of the whole favorites list. `base_revision` must equal the server's
        current revision (0 to create). On mismatch -> FavoritesConflict carrying the server's current doc, so
        the client can merge (never a silent overwrite). References only; bounded count. The new revision is
        whatever the understanding store assigns to the row (its column is authoritative)."""
        if not isinstance(favorites, list):
            raise ValueError("favorites must be a list")
        if len(favorites) > MAX_FAVORITES:
            favorites = favorites[:MAX_FAVORITES]
        current = self.get(owner)
        if base_revision != current["revision"]:
            raise FavoritesConflict(current=current)
        doc = {"favorites": favorites}
        # Write through the understanding store's own put so the revision/updated_at columns stay consistent
        # with the rest of the table; it returns the authoritative new revision. schema/prompt/frame/sha are
        # not meaningful for this sentinel row.
        out = self._us.put(owner=owner, moment_id=FAVORITES_SENTINEL,
                           understanding_json=json.dumps(doc, separators=(",", ":")),
                           schema_version="music_favorites/1", prompt_version="", frame_policy="",
                           content_sha256="", model_id="")
        return {"favorites": favorites, "revision": int(out["revision"]), "updated_at": int(out["updated_at"])}
