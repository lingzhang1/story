"""Account-owned cloud media storage — the server-authoritative ownership + upload state machine (R2/R3).

Mirrors the well-tested `edit_plan_jobs.JobStore` patterns deliberately:
  * lazy boto3 clients (import-safe without AWS; injectable for tests),
  * CONDITIONAL writes for create/transition (no backward moves, idempotent),
  * ownership is a STORED, server-derived field — never client-supplied.

SCOPE (R2/R3): ownership records + presigned direct-to-S3 upload/download + durable verification. This module
does NOT upload bytes (the client PUTs directly to S3 via presigned URLs — original video never transits App
Runner), does NOT evict local originals, and does NOT delete cloud media (reference-safe deletion is a later
increment).

Identity: a media record is keyed by (story_user_id, cloud_media_id). `cloud_media_id` is deterministic —
uuid5(owner + content_sha256) — so a re-initiate of the SAME content by the SAME owner maps to the SAME record
(idempotent) and never duplicates bytes. Account-scoped S3 keys: media/{story_user_id}/{cloud_media_id}/original.

Verification (owner Phase 4): `cloud_verified` requires object-exists AND expected-size AND a verifiable
FULL-FILE checksum (S3 ChecksumSHA256), checked against the device-computed sha256. A multipart ETag is NEVER
treated as a sha256. An upload RESPONSE alone never authorizes anything — only a server HeadObject check does.
"""
from __future__ import annotations

import os
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional

# Stable namespace so cloud_media_id = uuid5(owner + sha256) is deterministic across App Runner restarts.
_MEDIA_NS = uuid.UUID("b2c4d6e8-1a3c-5e7f-9b1d-2f4a6c8e0b1d")

# Upload lifecycle states (owner Phase 1 state machine; the cloud side only).
STATE_UPLOADING = "uploading"
STATE_CLOUD_VERIFIED = "cloud_verified"
STATE_UPLOAD_FAILED = "upload_failed"
TERMINAL_STATES = {STATE_CLOUD_VERIFIED, STATE_UPLOAD_FAILED}

# A media record lives at least this long without TTL reaping (originals are RETAINED — unlike edit-plan
# staging; there is intentionally NO TTL attribute on the media table). This constant bounds an UNFINISHED
# upload record only, used by the abort/cleanup sweep, not the verified original.
UNFINISHED_UPLOAD_TTL_SECONDS = 7 * 24 * 3600

# Presigned URL expiry (bounded; owner Phase 3). Short for download, longer for a large multipart upload.
DOWNLOAD_URL_TTL_SECONDS = 15 * 60
UPLOAD_URL_TTL_SECONDS = 60 * 60


def cloud_media_id_for(owner: str, content_sha256: str) -> str:
    """Deterministic media id from the trusted owner + content hash — the idempotency guarantee. The owner is
    folded in so two accounts uploading identical bytes get DISTINCT ids (no cross-account dedup / no leak)."""
    return str(uuid.uuid5(_MEDIA_NS, f"{owner.strip()}\x1f{content_sha256.strip()}"))


def object_key(owner: str, cloud_media_id: str) -> str:
    """Account-scoped S3 key. The owner prefix is what makes a presigned URL scopable to one account's media."""
    return f"media/{owner}/{cloud_media_id}/original"


class MediaOwnershipConflict(Exception):
    """An initiate reused a cloud_media_id with a DIFFERENT declared (size/sha) — a client bug, not a retry."""


class MediaNotFound(Exception):
    """No media record for (owner, cloud_media_id) — surfaced as 404 so another account's media is invisible."""


class MediaVerificationError(Exception):
    """Durable verification failed (missing object / size mismatch / checksum mismatch). NOT marked verified."""


@dataclass
class MediaStoreConfig:
    table: str = field(default_factory=lambda: os.environ.get("STORY_MEDIA_TABLE", ""))
    bucket: str = field(default_factory=lambda: os.environ.get("STORY_MEDIA_BUCKET", ""))
    region: str = field(default_factory=lambda: os.environ.get("AWS_REGION", "us-east-1"))


def _now() -> int:
    return int(time.time())


class MediaStore:
    """DynamoDB (ownership records) + S3 (presign + verify). Clients injectable for tests (no AWS needed)."""

    def __init__(self, cfg: MediaStoreConfig | None = None, *, ddb=None, s3=None):
        self.cfg = cfg or MediaStoreConfig()
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

    # --- read -----------------------------------------------------------------------------------------
    def get(self, owner: str, cloud_media_id: str) -> Optional[dict]:
        """Return the record ONLY if it belongs to `owner` (the key is composite, so this is inherently
        account-scoped — a wrong owner simply finds nothing)."""
        resp = self._ddb_c().get_item(TableName=self.cfg.table, Key={
            "story_user_id": {"S": owner}, "cloud_media_id": {"S": cloud_media_id}})
        it = resp.get("Item")
        return self._decode(it) if it else None

    def list_for_owner(self, owner: str) -> list[dict]:
        """All media records owned by `owner` (Query on the PK — never a Scan, so no cross-account leak)."""
        resp = self._ddb_c().query(
            TableName=self.cfg.table,
            KeyConditionExpression="story_user_id = :o",
            ExpressionAttributeValues={":o": {"S": owner}})
        return [self._decode(it) for it in resp.get("Items", [])]

    # --- initiate (idempotent, conditional) ----------------------------------------------------------
    def initiate_upload(self, *, owner: str, content_sha256: str, size_bytes: int,
                        content_type: str = "video/quicktime",
                        device_asset_id: str = "", source_moment_id: str = "") -> tuple[dict, bool]:
        """Create (or idempotently recover) an `uploading` record for (owner, content). Returns (record,
        created). A re-initiate of the SAME content by the SAME owner recovers the existing record (created=
        False). A reuse of the same cloud_media_id with a DIFFERENT size/sha raises MediaOwnershipConflict.
        Ownership (`owner`) is the trusted story_user_id — never client-supplied here."""
        cmid = cloud_media_id_for(owner, content_sha256)
        now = _now()
        key = object_key(owner, cmid)
        item = {
            "story_user_id": {"S": owner}, "cloud_media_id": {"S": cmid},
            "state": {"S": STATE_UPLOADING}, "content_sha256": {"S": content_sha256},
            "size_bytes": {"N": str(int(size_bytes))}, "content_type": {"S": content_type},
            "s3_key": {"S": key}, "created_at": {"N": str(now)}, "updated_at": {"N": str(now)},
            "device_asset_id": {"S": device_asset_id}, "source_moment_id": {"S": source_moment_id},
            "verified_at": {"N": "0"},
        }
        try:
            self._ddb_c().put_item(
                TableName=self.cfg.table, Item=item,
                ConditionExpression="attribute_not_exists(story_user_id) AND attribute_not_exists(cloud_media_id)")
            return self._decode(item), True
        except Exception as e:
            if self._is_conditional(e):
                existing = self.get(owner, cmid)
                if existing is None:
                    raise
                # Same content re-initiate = idempotent. A clashing size/sha under the same id is a conflict.
                if (existing.get("content_sha256") != content_sha256
                        or int(existing.get("size_bytes", -1)) != int(size_bytes)):
                    raise MediaOwnershipConflict(
                        f"cloud_media_id {cmid} already exists with a different content descriptor")
                return existing, False
            raise

    # --- complete + verify ---------------------------------------------------------------------------
    def complete_upload(self, *, owner: str, cloud_media_id: str) -> dict:
        """Durably VERIFY the uploaded object and, only on success, transition uploading -> cloud_verified.
        Verification (owner Phase 4): the object EXISTS, its size matches the declared size, and its FULL-FILE
        sha256 (S3 ChecksumSHA256, base64) matches the declared content_sha256. A multipart ETag is NEVER used
        as a checksum. Idempotent: a record already cloud_verified is returned as-is. Raises MediaNotFound /
        MediaVerificationError (the latter leaves the record `uploading`, recoverable). No client input decides
        verification — only the server HeadObject result does."""
        rec = self.get(owner, cloud_media_id)
        if rec is None:
            raise MediaNotFound(cloud_media_id)
        if rec.get("state") == STATE_CLOUD_VERIFIED:
            return rec  # idempotent completion

        head = self._head_object(rec["s3_key"])
        if head is None:
            raise MediaVerificationError("object not found in S3")
        actual_size = int(head.get("ContentLength", -1))
        if actual_size != int(rec.get("size_bytes", -2)):
            raise MediaVerificationError(f"size mismatch: expected {rec.get('size_bytes')} got {actual_size}")
        actual_sha_b64 = head.get("ChecksumSHA256")  # base64 of the raw sha256 digest; None if not set
        expected_b64 = _sha256_hex_to_b64(rec.get("content_sha256", ""))
        if not actual_sha_b64 or actual_sha_b64 != expected_b64:
            raise MediaVerificationError("checksum mismatch or missing S3 ChecksumSHA256")

        now = _now()
        try:
            self._ddb_c().update_item(
                TableName=self.cfg.table,
                Key={"story_user_id": {"S": owner}, "cloud_media_id": {"S": cloud_media_id}},
                UpdateExpression="SET #s = :v, verified_at = :t, updated_at = :t",
                ConditionExpression="#s = :uploading",   # no backward/forward skip; only uploading -> verified
                ExpressionAttributeNames={"#s": "state"},
                ExpressionAttributeValues={
                    ":v": {"S": STATE_CLOUD_VERIFIED}, ":t": {"N": str(now)},
                    ":uploading": {"S": STATE_UPLOADING}})
        except Exception as e:
            if self._is_conditional(e):
                # Someone else won the race (e.g. a concurrent complete) — re-read; if verified, that's success.
                cur = self.get(owner, cloud_media_id)
                if cur and cur.get("state") == STATE_CLOUD_VERIFIED:
                    return cur
            raise
        return self.get(owner, cloud_media_id) or rec

    # --- presign --------------------------------------------------------------------------------------
    def presign_upload(self, *, owner: str, cloud_media_id: str) -> dict:
        """A bounded presigned PUT for the owner's own object key. Requires the ChecksumSHA256 header so the
        upload itself carries the integrity signal S3 records. Only ever minted for a key under THIS owner's
        prefix (derived server-side from the trusted owner — never a client-supplied key)."""
        rec = self.get(owner, cloud_media_id)
        if rec is None:
            raise MediaNotFound(cloud_media_id)
        url = self._s3_c().generate_presigned_url(
            "put_object",
            Params={"Bucket": self.cfg.bucket, "Key": rec["s3_key"],
                    "ChecksumSHA256": _sha256_hex_to_b64(rec["content_sha256"]),
                    "ContentType": rec.get("content_type", "application/octet-stream")},
            ExpiresIn=UPLOAD_URL_TTL_SECONDS)
        return {"url": url, "s3_key": rec["s3_key"], "expires_in": UPLOAD_URL_TTL_SECONDS}

    def presign_download(self, *, owner: str, cloud_media_id: str) -> dict:
        """A short-lived presigned GET, scoped to the owner's own verified object. MediaNotFound (404) for a
        record that is not this owner's. Not minted before verification (nothing durable to download)."""
        rec = self.get(owner, cloud_media_id)
        if rec is None:
            raise MediaNotFound(cloud_media_id)
        if rec.get("state") != STATE_CLOUD_VERIFIED:
            raise MediaVerificationError("media not yet verified")
        url = self._s3_c().generate_presigned_url(
            "get_object",
            Params={"Bucket": self.cfg.bucket, "Key": rec["s3_key"]},
            ExpiresIn=DOWNLOAD_URL_TTL_SECONDS)
        return {"url": url, "expires_in": DOWNLOAD_URL_TTL_SECONDS}

    # --- helpers --------------------------------------------------------------------------------------
    def _head_object(self, key: str) -> Optional[dict]:
        try:
            return self._s3_c().head_object(Bucket=self.cfg.bucket, Key=key, ChecksumMode="ENABLED")
        except Exception as e:
            if "404" in str(e) or "NotFound" in type(e).__name__ or "NoSuchKey" in str(e):
                return None
            raise

    @staticmethod
    def _is_conditional(e: Exception) -> bool:
        return "ConditionalCheckFailed" in type(e).__name__ or "ConditionalCheckFailed" in str(e)

    @staticmethod
    def _decode(item: dict) -> dict:
        """DynamoDB item -> plain dict (only the attribute shapes this module writes)."""
        out: dict[str, Any] = {}
        for k, v in item.items():
            if "S" in v:
                out[k] = v["S"]
            elif "N" in v:
                out[k] = int(v["N"])
            elif "BOOL" in v:
                out[k] = v["BOOL"]
        return out


def _sha256_hex_to_b64(hex_digest: str) -> str:
    """S3 ChecksumSHA256 is the base64 of the RAW 32-byte sha256 digest. The client/device computes a hex
    sha256; convert so the two are compared in the same encoding. Empty in -> empty out (no false match)."""
    import base64
    h = (hex_digest or "").strip()
    if len(h) != 64:
        return ""
    try:
        return base64.b64encode(bytes.fromhex(h)).decode("ascii")
    except ValueError:
        return ""
