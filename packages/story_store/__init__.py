"""R7 — account-owned Story metadata sync store (DynamoDB).

Mirrors media_store's discipline: lazy boto3, conditional writes, account-scoped keys, no cross-account leak.

One item = one Story document for one account:
    PK story_user_id (S)   -- canonical account; every op scoped to the trusted principal (never client-supplied)
    SK story_id      (S)   -- the Story's UUID (SAME id cross-device; no remap)
    revision         (N)   -- SERVER monotonic revision. create -> 1; each accepted update -> +1.
    last_mutation_id (S)   -- idempotency key of the last applied write (C5: a lost-response retry is NOT a conflict)
    deleted          (BOOL)-- soft-delete tombstone (syncs a delete without touching cloud media)
    incomplete_deps  (BOOL)-- true if any referenced cloud asset is not this account's AND cloud_verified
    updated_at       (N)
    doc              (S)   -- JSON body, schema_version "story_doc/1"

OPTIMISTIC CONCURRENCY (owner decision 1 + C5): a PUT carries (base_revision, mutation_id, doc). The
conditional write accepts iff the item does not exist (create, base 0) OR its revision == base_revision. On a
revision mismatch we DISTINGUISH an idempotent retry (same mutation_id already applied -> return committed as
success) from a genuine concurrent modification (different mutation_id -> StoryConflict with the server doc).

A cloud_media_id is NEVER authorization (C3): the caller passes the referenced asset ids and we verify, via the
media store, that each belongs to THIS account AND is cloud_verified before marking a dependency satisfied.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass, field
from typing import Optional

STORY_DOC_SCHEMA = "story_doc/1"

# Phase-1 #5: bound the Story document. DynamoDB's hard item limit is 400 KB; we fail EXPLICITLY well under it
# (a doc at/over this limit must externalize large edit-plan snapshots to S3 — design §C2 — not be truncated).
MAX_DOC_BYTES = 350_000


class StoryNotFound(Exception):
    """No Story document for (owner, story_id) — surfaced as 404 so another account's doc is invisible."""


class StoryDocumentTooLarge(Exception):
    """The serialized Story document exceeds MAX_DOC_BYTES. Explicit failure — never silently truncated."""

    def __init__(self, size: int):
        super().__init__(f"story document {size} bytes exceeds {MAX_DOC_BYTES}")
        self.size = size


class StoryMutationConflict(Exception):
    """The SAME mutation_id was reused with a DIFFERENT payload (Phase-1 #4). A lost-response retry MUST carry
    an identical payload; a different payload under a reused id is a client bug, not an idempotent retry, and
    is rejected rather than returning a false success."""


class StoryConflict(Exception):
    """A genuine optimistic-concurrency conflict: caller's base_revision is stale and the committed write was a
    DIFFERENT mutation. Carries the server's current {revision, doc, deleted} so the client runs Keep Both /
    Use Cloud Version."""

    def __init__(self, current: dict):
        super().__init__("story revision conflict")
        self.current = current


@dataclass
class StoryStoreConfig:
    table: str = field(default_factory=lambda: os.environ.get("STORY_STORIES_TABLE", ""))
    region: str = field(default_factory=lambda: os.environ.get("AWS_REGION", "us-east-1"))


def _now() -> int:
    return int(time.time())


def _mutation_digest(*, base_revision: int, doc_json: str, deleted: bool, incomplete_deps: bool) -> str:
    """Stable sha256 over the mutation's effective payload, so a reused mutation_id with a DIFFERENT payload is
    detected (Phase-1 #4). Canonical: base_revision + flags + the already-canonicalized doc JSON."""
    canon = f"{base_revision}\x1f{int(bool(deleted))}\x1f{int(bool(incomplete_deps))}\x1f{doc_json}"
    return hashlib.sha256(canon.encode('utf-8')).hexdigest()


class StoryStore:
    """DynamoDB-backed Story documents. Client injectable for tests (no AWS needed)."""

    def __init__(self, cfg: StoryStoreConfig | None = None, *, ddb=None, media=None):
        self.cfg = cfg or StoryStoreConfig()
        self._ddb = ddb
        self._media = media   # a media_store.MediaStore for asset-ownership verification (C3); optional

    def _ddb_c(self):
        if self._ddb is None:
            import boto3
            self._ddb = boto3.client("dynamodb", region_name=self.cfg.region)
        return self._ddb

    # --- read ---------------------------------------------------------------------------------------
    def get(self, owner: str, story_id: str) -> Optional[dict]:
        """The Story document for THIS owner, or None. Account-scoped by the composite key — a wrong owner
        simply finds nothing (no cross-account leak)."""
        resp = self._ddb_c().get_item(TableName=self.cfg.table, Key={
            "story_user_id": {"S": owner}, "story_id": {"S": story_id}})
        it = resp.get("Item")
        return self._decode(it) if it else None

    def index(self, owner: str) -> list[dict]:
        """The account's Story INDEX (no bodies): one row per Story with revision/updated_at/deleted/
        incomplete_deps. A Query on the PK — never a cross-account Scan."""
        out: list[dict] = []
        kwargs = {"TableName": self.cfg.table,
                  "KeyConditionExpression": "story_user_id = :o",
                  "ExpressionAttributeValues": {":o": {"S": owner}},
                  "ProjectionExpression": "story_id, revision, updated_at, deleted, incomplete_deps"}
        while True:
            resp = self._ddb_c().query(**kwargs)
            for it in resp.get("Items", []):
                out.append({
                    "story_id": it["story_id"]["S"],
                    "revision": int(it.get("revision", {}).get("N", "0")),
                    "updated_at": int(it.get("updated_at", {}).get("N", "0")),
                    "deleted": it.get("deleted", {}).get("BOOL", False),
                    "incomplete_deps": it.get("incomplete_deps", {}).get("BOOL", False),
                })
            lek = resp.get("LastEvaluatedKey")
            if not lek:
                break
            kwargs["ExclusiveStartKey"] = lek
        return out

    # --- write (optimistic concurrency + idempotency) ----------------------------------------------
    def put(self, *, owner: str, story_id: str, base_revision: int, mutation_id: str,
            doc: dict, deleted: bool = False, incomplete_deps: bool = False) -> dict:
        """Create (base_revision 0) or update (base_revision == current) the Story document.

        Conditional write: accept iff the item is absent OR its revision == base_revision. On the condition
        failing we re-read and DISTINGUISH:
          * same `mutation_id` already applied  -> idempotent success (return committed) — a lost-response retry
          * different mutation                  -> StoryConflict(current) — a genuine concurrent modification
        Returns {story_id, revision, updated_at, deleted, incomplete_deps}."""
        now = _now()
        new_rev = base_revision + 1
        doc_json = json.dumps(doc, separators=(",", ":"))
        # Phase-1 #5: explicit size failure (never truncate). Guard the serialized doc BEFORE any write.
        if len(doc_json.encode("utf-8")) > MAX_DOC_BYTES:
            raise StoryDocumentTooLarge(len(doc_json.encode("utf-8")))
        # Phase-1 #4: bind mutation_id to the EXACT payload. A lost-response retry carries the identical payload
        # and so the identical digest; a reused id with a changed payload must NOT be treated as idempotent.
        mutation_digest = _mutation_digest(base_revision=base_revision, doc_json=doc_json,
                                           deleted=deleted, incomplete_deps=incomplete_deps)
        item = {
            "story_user_id": {"S": owner}, "story_id": {"S": story_id},
            "revision": {"N": str(new_rev)}, "last_mutation_id": {"S": mutation_id},
            "last_mutation_digest": {"S": mutation_digest},
            "deleted": {"BOOL": bool(deleted)}, "incomplete_deps": {"BOOL": bool(incomplete_deps)},
            "updated_at": {"N": str(now)},
            "doc": {"S": doc_json},
        }
        try:
            if base_revision <= 0:
                # CREATE — must not already exist.
                self._ddb_c().put_item(
                    TableName=self.cfg.table, Item=item,
                    ConditionExpression="attribute_not_exists(story_id)")
            else:
                # UPDATE — only if the server revision matches what the client last saw.
                self._ddb_c().put_item(
                    TableName=self.cfg.table, Item=item,
                    ConditionExpression="revision = :base",
                    ExpressionAttributeValues={":base": {"N": str(base_revision)}})
        except Exception as e:
            if not self._is_conditional(e):
                raise
            # Condition failed — resolve retry-vs-conflict from the CURRENT item.
            cur = self.get(owner, story_id)
            if cur is not None and cur.get("last_mutation_id") == mutation_id:
                # Same id. ONLY idempotent if the payload digest also matches (Phase-1 #4).
                if cur.get("last_mutation_digest") == mutation_digest:
                    return self._summary(cur)             # C5: this exact write already committed
                raise StoryMutationConflict()             # reused id, different payload -> reject (no false success)
            raise StoryConflict(cur or {})                # C1/C5: genuine concurrent modification
        return {"story_id": story_id, "revision": new_rev, "updated_at": now,
                "deleted": bool(deleted), "incomplete_deps": bool(incomplete_deps)}

    # --- C3: verify referenced cloud assets belong to this account AND are cloud_verified ----------
    def verify_dependencies(self, owner: str, cloud_media_ids: list[str]) -> tuple[bool, list[str]]:
        """A cloud_media_id is NEVER authorization. For each referenced id, confirm via the media store that
        the record is THIS owner's AND cloud_verified. Returns (all_satisfied, unverified_ids). With no media
        store injected (unit tests of pure doc logic) this is a no-op that trusts nothing -> treats all as
        unverified so the caller marks incomplete_deps rather than falsely reporting complete."""
        ids = [i for i in dict.fromkeys(cloud_media_ids) if i]
        if not ids:
            return True, []
        if self._media is None:
            return False, ids
        unverified: list[str] = []
        for cmid in ids:
            rec = self._media.get(owner, cmid)             # account-scoped by the media composite key
            if rec is None or rec.get("state") != "cloud_verified":
                unverified.append(cmid)
        return (len(unverified) == 0), unverified

    # --- helpers ------------------------------------------------------------------------------------
    def _summary(self, rec: dict) -> dict:
        return {"story_id": rec["story_id"], "revision": rec["revision"],
                "updated_at": rec.get("updated_at", 0), "deleted": rec.get("deleted", False),
                "incomplete_deps": rec.get("incomplete_deps", False)}

    def _decode(self, item: dict) -> dict:
        return {
            "story_id": item["story_id"]["S"],
            "revision": int(item.get("revision", {}).get("N", "0")),
            "last_mutation_id": item.get("last_mutation_id", {}).get("S", ""),
            "last_mutation_digest": item.get("last_mutation_digest", {}).get("S", ""),
            "deleted": item.get("deleted", {}).get("BOOL", False),
            "incomplete_deps": item.get("incomplete_deps", {}).get("BOOL", False),
            "updated_at": int(item.get("updated_at", {}).get("N", "0")),
            "doc": json.loads(item["doc"]["S"]) if item.get("doc", {}).get("S") else {},
        }

    @staticmethod
    def _is_conditional(e: Exception) -> bool:
        return e.__class__.__name__ == "ConditionalCheckFailedException" \
            or "ConditionalCheckFailed" in str(e)
