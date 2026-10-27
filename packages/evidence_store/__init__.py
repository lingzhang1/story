"""P1-F — AU Visual Evidence store (server-side, reuses existing authorized storage).

Persists the EXACT JPEG frames the server accepted for one AU inference as ONE packed blob,
plus a small manifest record, so editing reuses them instead of restoring the source video and
re-extracting. Backend-created (Option B): the frames are already in hand at the AU accept point,
so there is zero extra device egress.

WHY A NEW ADAPTER (P1-F §5, verified against master):
  * `media_store` gives us the IDENTITY + INTEGRITY contract we want — content-addressed id
    (uuid5(owner+sha)), account-scoped S3 key, full-file sha256 verification, account isolation,
    non-public — BUT its WRITE path is a presigned CLIENT PUT (`presign_upload`). There is no
    server-side byte-write method on it.
  * `edit_plan_jobs.JobStore.stage_request` ALREADY does a server-side `s3.put_object(... SSE ...)`
    from the backend. So a server-side write is a proven, in-use pattern — not new capability.
  * This module is the minimal adapter: it reuses media_store's id/key/verify helpers for identity
    and integrity, and does the byte write server-side with put_object, in the SAME media bucket.
    NO new S3 bucket, NO new DynamoDB table, NO new IAM is introduced (P1-F §5/§17).

OWNERSHIP (P1-F §4): `owner` is the TRUSTED, server-derived account (principal.story_user_id) —
never client-supplied. The packed-blob object key is derived server-side under the owner prefix;
a client-supplied key/owner is never honored. `content_sha256` (the SOURCE media sha) is an
identity CLAIM matched against the account's own media record by the caller — not proof here.

CONSISTENCY (P1-F §5): S3 (blob) + DynamoDB (manifest) are NOT one atomic transaction. The write is
ordered + idempotent so a partial write is never presented as complete:
  1. put the packed blob (content-addressed by its OWN sha -> idempotent; a re-put of identical
     bytes is a no-op overwrite of the same key).
  2. ONLY after the blob write returns, put the manifest item (conditional create; a re-put with the
     same blob sha is idempotent).
A reader treats a manifest whose referenced blob is missing/short as a cache MISS (fallback), never a
hit. A failed evidence write NEVER touches the AU understanding record (the caller persists AU first).

DELETION (P1-F §4, revised policy 2026-10-26): delete the manifest + packed blob ONLY on an EXPLICIT
user-initiated permanent deletion — `delete_for_moment` (permanent Moment deletion) and `delete_for_owner`
(account deletion, audit/design only — unwired). There is DELIBERATELY NO automatic expiry, TTL, lifecycle
rule, or orphan sweep (owner-approved retention trade-off §6): an interrupted write (blob without manifest,
or a never-verified provisional package) is simply RETAINED and read as a cache MISS until explicit deletion
or a future separately-approved retention policy. Shared media referenced by other Moments is never deleted
here (the evidence blob is per-(owner, moment, source-sha), so deleting one Moment's evidence cannot strand
another Moment's — they have distinct manifests even when the source bytes are shared).
"""
from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass, field
from typing import Optional

# Reuse the media identity + integrity helpers (NO reimplementation of ownership/key/sha logic).
import media_store as _media

# evidence_package/1 — the frozen manifest schema version this adapter writes.
EVIDENCE_PACKAGE_VERSION = "evidence_package/1"

# The packed-blob storage kind. Reuses media_store's ai_artifact MECHANICS (content-addressed,
# account-scoped, sha-verified, non-deleting retention, same bucket) — we tag the manifest's
# media_kind so a packed-frames blob is never mistaken for a Moment original in the media list.
EVIDENCE_MEDIA_KIND = "au_evidence"


class EvidenceTooLarge(Exception):
    def __init__(self, size: int, limit: int):
        super().__init__(f"packed evidence {size} bytes exceeds {limit}")
        self.size = size
        self.limit = limit


# A packed 24-frame contact-quality blob is ~1-3 MB; cap generously well under any object limit.
MAX_PACKED_BYTES = 12 * 1024 * 1024


@dataclass
class EvidenceStoreConfig:
    # Reuse the EXISTING media table + bucket (no new infra). Same env the media store reads.
    table: str = field(default_factory=lambda: os.environ.get("STORY_EVIDENCE_TABLE",
                                                               os.environ.get("STORY_MEDIA_TABLE", "")))
    bucket: str = field(default_factory=lambda: os.environ.get("STORY_EVIDENCE_BUCKET",
                                                               os.environ.get("STORY_MEDIA_BUCKET", "")))
    region: str = field(default_factory=lambda: os.environ.get("AWS_REGION", "us-east-1"))


def _now() -> int:
    return int(time.time())


def packed_sha256(packed: bytes) -> str:
    """Full-file sha256 (hex) of the packed blob — its content address + integrity anchor."""
    return hashlib.sha256(packed).hexdigest()


def evidence_object_key(owner: str, blob_cmid: str) -> str:
    """Account-scoped S3 key for the packed blob. Owner prefix = the account-isolation boundary
    (same shape media_store.object_key uses). Server-derived; never client-supplied."""
    return f"evidence/{owner}/{blob_cmid}/frames.pack"


def evidence_sort_key(moment_id: str) -> str:
    """The manifest row's DynamoDB RANGE key. We reuse the SHARED media table, whose key schema is
    (story_user_id HASH, cloud_media_id RANGE) — so the manifest MUST be keyed on the `cloud_media_id`
    attribute, NOT a separate `evidence_id` (writing a foreign sort-key attribute raises ValidationException,
    the ClientError observed on dev). The `evidence#` prefix namespaces the row so it never collides with a
    real media record's cloud_media_id (a bare uuid5), and media_kind=au_evidence tags it for readers."""
    return f"evidence#{moment_id}"


def pack_frames(frames: list[tuple[int, bytes]]) -> tuple[bytes, list[dict]]:
    """Pack ordered (t_ms, jpeg) frames into ONE concat-jpeg blob + a byte index.
    Returns (packed_bytes, [{index,t_ms,offset,length}, ...]). Deterministic; no model call."""
    buf = bytearray()
    index: list[dict] = []
    for i, (t_ms, jpeg) in enumerate(frames):
        off = len(buf)
        buf.extend(jpeg)
        index.append({"index": i, "t_ms": int(t_ms), "offset": off, "length": len(jpeg)})
    return bytes(buf), index


def unpack_frame(packed: bytes, ref: dict) -> bytes:
    """Slice one frame's JPEG bytes out of the packed blob using its index entry."""
    off = int(ref["offset"]); ln = int(ref["length"])
    return packed[off:off + ln]


class EvidenceStore:
    """DynamoDB (manifest) + S3 (packed blob). Clients injectable for tests (no AWS needed)."""

    def __init__(self, cfg: EvidenceStoreConfig | None = None, *, ddb=None, s3=None):
        self.cfg = cfg or EvidenceStoreConfig()
        self._ddb = ddb
        self._s3 = s3

    # --- lazy AWS clients ---------------------------------------------------------------------------
    def _ddb_c(self):
        if self._ddb is None:
            import boto3
            self._ddb = boto3.client("dynamodb", region_name=self.cfg.region)
        return self._ddb

    def _s3_c(self):
        if self._s3 is None:
            import boto3
            self._s3 = boto3.client("s3", region_name=self.cfg.region)
        return self._s3

    # --- write (ordered, idempotent; NOT atomic — see module docstring) -----------------------------
    def put(self, *, owner: str, moment_id: str, content_sha256: str,
            frames: list[tuple[int, bytes]], frame_extraction_version: str = "au_extract/2",
            frame_longest_edge: int = 768) -> dict:
        """Persist the accepted frames as evidence_package/1. Returns the manifest dict.

        Steps (recoverable, idempotent): pack -> put blob (content-addressed) -> put manifest. A
        partial write (blob written, manifest not) is simply RETAINED and read as a MISS (no sweep; §6).

        P1-F §4/§5: `owner` is the trusted account; an empty owner is REFUSED (anonymous AU persists
        no account-scoped cache). The blob id is content-addressed by its OWN sha so a repeat AU of the
        SAME pixels reuses the SAME blob (idempotent, no duplicate bytes)."""
        if not owner:
            raise ValueError("evidence packages require a durable account owner (anonymous AU does not persist)")
        if not frames:
            raise ValueError("no frames to persist")
        packed, index = pack_frames(frames)
        if len(packed) > MAX_PACKED_BYTES:
            raise EvidenceTooLarge(len(packed), MAX_PACKED_BYTES)
        blob_sha = packed_sha256(packed)
        blob_cmid = _media.cloud_media_id_for(owner, blob_sha)   # reuse content-addressed identity
        key = evidence_object_key(owner, blob_cmid)

        # 1) packed blob first (SSE; content-addressed key -> idempotent overwrite of identical bytes).
        self._s3_c().put_object(Bucket=self.cfg.bucket, Key=key, Body=packed,
                                ContentType="application/octet-stream", ServerSideEncryption="AES256")

        # 2) manifest item (only after the blob write returns). Keyed (owner, moment_id) — one current
        #    package per Moment (a re-analysis of the SAME source overwrites with an identical manifest).
        sampled = [int(t) for t, _ in frames]
        now = _now()
        manifest = {
            "schema_version": EVIDENCE_PACKAGE_VERSION,
            "moment_id": moment_id, "owner": owner,
            "content_sha256": content_sha256,
            "frame_extraction_version": frame_extraction_version,
            "frame_count": len(frames), "frame_encoding": "jpeg",
            "frame_longest_edge": int(frame_longest_edge),
            "sampled_frame_ms": sampled,
            "frames": index,
            "frames_ref": {"cloud_media_id": blob_cmid, "bytes": len(packed),
                           "sha256": blob_sha, "layout": "concat-jpeg"},
            "created_at": now, "retention": "tied-to-source-media",
            "media_kind": EVIDENCE_MEDIA_KIND,
        }
        item = {
            "story_user_id": {"S": owner}, "cloud_media_id": {"S": evidence_sort_key(moment_id)},
            "manifest_json": {"S": json.dumps(manifest)},
            "content_sha256": {"S": content_sha256},
            "frame_extraction_version": {"S": frame_extraction_version},
            "blob_cmid": {"S": blob_cmid}, "blob_key": {"S": key},
            "media_kind": {"S": EVIDENCE_MEDIA_KIND},
            "updated_at": {"N": str(now)},
        }
        self._ddb_c().put_item(TableName=self.cfg.table, Item=item)
        return manifest

    # --- read ---------------------------------------------------------------------------------------
    def get_manifest(self, *, owner: str, moment_id: str) -> Optional[dict]:
        """The current manifest for (owner, moment_id), or None. Account-scoped composite key, so a
        wrong owner simply finds nothing (no cross-account leak, P1-F §9/§10)."""
        resp = self._ddb_c().get_item(
            TableName=self.cfg.table,
            Key={"story_user_id": {"S": owner}, "cloud_media_id": {"S": evidence_sort_key(moment_id)}})
        it = resp.get("Item")
        if not it:
            return None
        try:
            return json.loads(it.get("manifest_json", {}).get("S", ""))
        except Exception:
            return None

    def get_packed(self, *, owner: str, blob_cmid: str) -> Optional[bytes]:
        """Fetch the packed blob bytes for a manifest's frames_ref. Account-scoped key; None if absent
        (a reader treats absent/short as a cache MISS -> fallback, never a hit)."""
        key = evidence_object_key(owner, blob_cmid)
        try:
            obj = self._s3_c().get_object(Bucket=self.cfg.bucket, Key=key)
            return obj["Body"].read()
        except Exception as e:
            if "NoSuchKey" in str(e) or "404" in str(e) or "NotFound" in type(e).__name__:
                return None
            raise

    # Short-lived presigned GET TTL for the packed blob (device-side Option 8-i download). Mirrors
    # media_store.DOWNLOAD_URL_TTL_SECONDS — bounded, never a public/long-lived URL (P1-F §9).
    PRESIGN_GET_TTL_SECONDS = 15 * 60

    def presign_packed(self, *, owner: str, blob_cmid: str) -> Optional[dict]:
        """A short-lived presigned GET for the owner's own packed-frames blob. The key is SERVER-DERIVED
        under the owner prefix (never client-supplied), so a URL can only ever point at this account's own
        object. Returns None (a cache MISS) when the object does not exist, so an interrupted/lost write
        falls back to restore+extract rather than handing out a dead URL. No public access, no arbitrary key."""
        key = evidence_object_key(owner, blob_cmid)
        try:
            # HEAD first so a missing blob is a clean MISS rather than a presigned URL to nothing.
            self._s3_c().head_object(Bucket=self.cfg.bucket, Key=key)
        except Exception as e:
            if "NoSuchKey" in str(e) or "404" in str(e) or "NotFound" in type(e).__name__:
                return None
            raise
        url = self._s3_c().generate_presigned_url(
            "get_object", Params={"Bucket": self.cfg.bucket, "Key": key},
            ExpiresIn=self.PRESIGN_GET_TTL_SECONDS)
        return {"url": url, "expires_in": self.PRESIGN_GET_TTL_SECONDS}

    def is_valid_for_source(self, manifest: dict, *, content_sha256: str,
                            frame_extraction_version: str) -> bool:
        """P1-F §6 invalidation: the cached pixels are reusable iff the SOURCE fingerprint AND the
        extractor policy match. The AU PROMPT version is deliberately NOT consulted — a prompt bump
        re-interprets text, it does not change the pixels, so it must not invalidate this cache."""
        if not manifest:
            return False
        return (manifest.get("content_sha256") == content_sha256
                and manifest.get("frame_extraction_version") == frame_extraction_version)

    # --- deletion / orphan cleanup (P1-F §10) -------------------------------------------------------
    def delete_for_moment(self, *, owner: str, moment_id: str) -> bool:
        """Delete the manifest + packed blob for one Moment (called on source-Moment deletion). Blob
        first-or-manifest-first is irrelevant for correctness (a dangling blob is swept; a dangling
        manifest reads as a miss), but we delete the MANIFEST first so the package stops resolving
        immediately, then best-effort delete the blob. Idempotent. Never deletes shared SOURCE media
        (that is media_store's domain) — only this per-Moment evidence blob."""
        man = self.get_manifest(owner=owner, moment_id=moment_id)
        try:
            self._ddb_c().delete_item(
                TableName=self.cfg.table,
                Key={"story_user_id": {"S": owner}, "cloud_media_id": {"S": evidence_sort_key(moment_id)}})
        except Exception:
            return False
        if man:
            blob_cmid = (man.get("frames_ref") or {}).get("cloud_media_id")
            if blob_cmid:
                try:
                    self._s3_c().delete_object(Bucket=self.cfg.bucket,
                                               Key=evidence_object_key(owner, blob_cmid))
                except Exception:
                    pass  # best-effort (no sweep; a dangling blob is simply unreferenced per the retention policy)
        return True

    def delete_for_owner(self, *, owner: str) -> int:
        """Delete all evidence for an account (account deletion). Returns how many were removed.
        Scoped to EVIDENCE rows only (cloud_media_id begins_with 'evidence#') so it never deletes the owner's
        media / music / ai_artifact records that share this table. Query on the PK + RANGE prefix (never a
        Scan) so it is inherently account-scoped."""
        resp = self._ddb_c().query(
            TableName=self.cfg.table,
            KeyConditionExpression="story_user_id = :o AND begins_with(cloud_media_id, :pfx)",
            ExpressionAttributeValues={":o": {"S": owner}, ":pfx": {"S": "evidence#"}})
        n = 0
        for it in resp.get("Items", []):
            sk = it.get("cloud_media_id", {}).get("S", "")
            mid = sk[len("evidence#"):] if sk.startswith("evidence#") else ""
            if mid and self.delete_for_moment(owner=owner, moment_id=mid):
                n += 1
        return n
