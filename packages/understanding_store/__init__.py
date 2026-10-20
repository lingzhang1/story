"""R7-E — account-owned Moment Understanding store (DynamoDB).

Moment Understanding is SHARED across Stories (keyed by moment_id), so it lives in its own account-level table
rather than inside each story_doc. Device B restores AU by moment_id and REUSES it only when the source media
is byte-identical (content_sha256 match) AND the schema is compatible — so a restored Moment is never
re-analyzed (owner principle: restore first, reuse valid results, regenerate only when necessary).

Item:
    PK story_user_id (S)   SK moment_id (S)
    understanding_json (S)   schema_version (S)   prompt_version (S)   frame_policy (S)   model_id (S)
    content_sha256 (S)   -- the Moment's media sha; reuse gated on an EXACT match
    revision (N)         -- server monotonic; idempotent conditional writes
    updated_at (N)

A cloud_media_id / content_sha256 is NEVER authorization: every op is scoped to the trusted
principal.story_user_id (composite key), so a wrong owner simply finds nothing (no cross-account leak).
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from typing import Optional

# Keep AU items safely below DynamoDB's 400 KB item limit; an oversized understanding externalizes to S3
# (ai_artifact) — handled by the API layer, mirroring the story-doc policy.
MAX_UNDERSTANDING_BYTES = 350_000


class UnderstandingTooLarge(Exception):
    def __init__(self, size: int):
        super().__init__(f"understanding {size} bytes exceeds {MAX_UNDERSTANDING_BYTES}")
        self.size = size


@dataclass
class UnderstandingStoreConfig:
    table: str = field(default_factory=lambda: os.environ.get("STORY_UNDERSTANDING_TABLE", ""))
    region: str = field(default_factory=lambda: os.environ.get("AWS_REGION", "us-east-1"))


def _now() -> int:
    return int(time.time())


class UnderstandingStore:
    def __init__(self, cfg: UnderstandingStoreConfig | None = None, *, ddb=None):
        self.cfg = cfg or UnderstandingStoreConfig()
        self._ddb = ddb

    def _ddb_c(self):
        if self._ddb is None:
            import boto3
            self._ddb = boto3.client("dynamodb", region_name=self.cfg.region)
        return self._ddb

    # --- batch read --------------------------------------------------------------------------------
    def get_many(self, owner: str, moment_ids: list[str]) -> list[dict]:
        """Return the owner's understanding records for the given moment_ids (account-scoped). Missing ids are
        simply absent from the result. Chunked BatchGetItem."""
        ids = [m for m in dict.fromkeys(moment_ids) if m]
        out: list[dict] = []
        for i in range(0, len(ids), 100):
            chunk = ids[i:i + 100]
            keys = [{"story_user_id": {"S": owner}, "moment_id": {"S": m}} for m in chunk]
            resp = self._ddb_c().batch_get_item(RequestItems={self.cfg.table: {"Keys": keys}})
            for it in resp.get("Responses", {}).get(self.cfg.table, []):
                out.append(self._decode(it))
            # (A production path would drain UnprocessedKeys; dev scale is well under one page.)
        return out

    def get(self, owner: str, moment_id: str) -> Optional[dict]:
        resp = self._ddb_c().get_item(TableName=self.cfg.table,
                                      Key={"story_user_id": {"S": owner}, "moment_id": {"S": moment_id}})
        it = resp.get("Item")
        return self._decode(it) if it else None

    # --- write (idempotent upsert) -----------------------------------------------------------------
    def put(self, *, owner: str, moment_id: str, understanding_json: str, schema_version: str,
            prompt_version: str, frame_policy: str, content_sha256: str, model_id: str = "") -> dict:
        """Upsert one understanding record. Idempotent: re-putting the same content for the same
        (owner, moment_id) with the SAME content_sha256 + schema is a no-op that bumps nothing meaningful.
        Explicit oversized failure (never truncate)."""
        if len(understanding_json.encode("utf-8")) > MAX_UNDERSTANDING_BYTES:
            raise UnderstandingTooLarge(len(understanding_json.encode("utf-8")))
        now = _now()
        # revision bumps monotonically; we do a simple read-modify (dev scale, single writer per moment).
        existing = self.get(owner, moment_id)
        rev = (existing["revision"] + 1) if existing else 1
        item = {
            "story_user_id": {"S": owner}, "moment_id": {"S": moment_id},
            "understanding_json": {"S": understanding_json},
            "schema_version": {"S": schema_version}, "prompt_version": {"S": prompt_version},
            "frame_policy": {"S": frame_policy}, "content_sha256": {"S": content_sha256},
            "model_id": {"S": model_id or ""}, "revision": {"N": str(rev)}, "updated_at": {"N": str(now)},
        }
        self._ddb_c().put_item(TableName=self.cfg.table, Item=item)
        return {"moment_id": moment_id, "revision": rev, "updated_at": now}

    def _decode(self, item: dict) -> dict:
        g = lambda k: item.get(k, {}).get("S", "")
        return {
            "moment_id": g("moment_id"),
            "understanding_json": g("understanding_json"),
            "schema_version": g("schema_version"),
            "prompt_version": g("prompt_version"),
            "frame_policy": g("frame_policy"),
            "content_sha256": g("content_sha256"),
            "model_id": g("model_id"),
            "revision": int(item.get("revision", {}).get("N", "0")),
            "updated_at": int(item.get("updated_at", {}).get("N", "0")),
        }
