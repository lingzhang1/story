"""Account-owned cloud media storage — the server-authoritative ownership + upload state machine (R2/R3).

Mirrors the well-tested `edit_plan_jobs.JobStore` patterns deliberately:
  * lazy boto3 clients (import-safe without AWS; injectable for tests),
  * CONDITIONAL writes for create/transition (no backward moves, idempotent),
  * ownership is a STORED, server-derived field — never client-supplied.

SCOPE (R2/R3): ownership records + presigned direct-to-S3 upload/download + durable verification. This module
does NOT upload bytes (the client PUTs directly to S3 via presigned URLs — original video never transits App
Runner), does NOT evict local originals, and does NOT delete cloud media (reference-safe deletion is a later
increment).

UPLOAD STRATEGY (honest, owner clarification): a SINGLE presigned PUT of the whole file. Interruption recovery
is WHOLE-FILE: an interrupted PUT leaves the record `uploading`, and the client re-initiates (idempotent — same
record) and re-PUTs the entire file. PART-LEVEL resumable multipart transfer (continue from the last uploaded
part) is NOT implemented here — it is deferred to R4. Do not read `AbortIncompleteMultipartUpload` on the bucket
as proof of part-level resume; it is only a cost-hygiene backstop for any future multipart.

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
import json
from dataclasses import dataclass, field
from typing import Any, Optional

# Stable namespace so cloud_media_id = uuid5(owner + sha256) is deterministic across App Runner restarts.
_MEDIA_NS = uuid.UUID("b2c4d6e8-1a3c-5e7f-9b1d-2f4a6c8e0b1d")

# Upload lifecycle states (owner Phase 1 state machine; the cloud side only).
STATE_UPLOADING = "uploading"
STATE_CLOUD_VERIFIED = "cloud_verified"
STATE_UPLOAD_FAILED = "upload_failed"
TERMINAL_STATES = {STATE_CLOUD_VERIFIED, STATE_UPLOAD_FAILED}

# R7-D — media kind. A record is either a captured ORIGINAL ("moment", the R2/R3/R4 default) or a RENDERED
# generated video ("generated"). The storage key, presign, upload and verification paths are IDENTICAL for
# both — only the provenance fields differ (source_moment_id vs source_output_id) — so the R4 pipeline backs
# up a generated MP4 with no second uploader. An unknown/blank kind normalizes to "moment" (back-compat: a
# pre-R7-D record with no media_kind attribute reads as a moment).
MEDIA_KIND_MOMENT = "moment"
MEDIA_KIND_GENERATED = "generated"
# R7 Phase 4 — ai_artifact. An IMMUTABLE, content-addressed AI blob (an oversized validated EditPlan, or a
# large Moment Understanding) externalized out of the 350 KB Story/Understanding document so version history is
# NEVER silently capped or truncated. The storage key, presign, upload and verification paths are IDENTICAL to
# a media original — content-addressed by uuid5(owner + sha256), account-scoped key, full-file SHA256 verified,
# non-deleting retention — so no second artifact store, bucket, or table is introduced. The Story document then
# carries a durable {cloud_media_id, sha256, bytes, schema_version} reference in place of the inline JSON; the
# client resolves it by the normal verified download. Provenance uses source_output_id (for an EditPlan) and is
# otherwise metadata-only.
MEDIA_KIND_AI_ARTIFACT = "ai_artifact"
_MEDIA_KINDS = {MEDIA_KIND_MOMENT, MEDIA_KIND_GENERATED, MEDIA_KIND_AI_ARTIFACT}


def _normalize_media_kind(kind: str) -> str:
    k = (kind or "").strip().lower()
    return k if k in _MEDIA_KINDS else MEDIA_KIND_MOMENT

# A media record lives at least this long without TTL reaping (originals are RETAINED — unlike edit-plan
# staging; there is intentionally NO TTL attribute on the media table). This constant bounds an UNFINISHED
# upload record only, used by the abort/cleanup sweep, not the verified original.
UNFINISHED_UPLOAD_TTL_SECONDS = 7 * 24 * 3600

# Presigned URL expiry (bounded; owner Phase 3). Short for download, longer for a whole-file upload PUT (R4 will
# add part-level multipart; this increment is a single presigned PUT with whole-file retry).
DOWNLOAD_URL_TTL_SECONDS = 15 * 60
UPLOAD_URL_TTL_SECONDS = 60 * 60

# R4-B multipart. S3 requires every part except the last to be >= 5 MiB. We use 8 MiB parts and switch to
# multipart only above a threshold so small files keep the single-PUT path unchanged.
MIN_S3_PART_SIZE = 5 * 1024 * 1024
MULTIPART_PART_SIZE = 8 * 1024 * 1024
MULTIPART_THRESHOLD = 16 * 1024 * 1024   # <= this -> single PUT; above -> multipart
#
# CHECKSUM STRATEGY (owner Phase 2 — documented, equivalent integrity; no bytes through App Runner):
#   • The device declares the FULL-FILE sha256 (hex) at initiate (provenance + the single-PUT guarantee).
#   • SINGLE PUT (small files): S3 validates the whole object's ChecksumSHA256 against the declared digest at
#     PUT, and complete re-checks it via HeadObject. Unchanged, strongest guarantee.
#   • MULTIPART (large files): each PART uploads with its OWN ChecksumSHA256, which S3 validates on arrival — a
#     corrupt part is REJECTED at PUT (the same per-byte guarantee as single-PUT, applied per part). The device
#     sends each part's sha256 (base64) to initiate, so the server records the EXPECTED per-part digests.
#     CompleteMultipartUpload passes those per-part checksums in order; S3 validates the assembly and returns a
#     COMPOSITE checksum ("<base64>-N"). A multipart ETag/composite is NOT a full-file sha256 and is NEVER
#     treated as one. Verification before cloud_verified = (object exists) ∧ (ContentLength == declared size) ∧
#     (S3's returned composite ChecksumSHA256 == the composite the SERVER recomputes from the recorded per-part
#     digests). Every part is sha256-validated by S3 at upload AND the composite + size match the server's
#     independent computation, so the object is integrity-assured end to end without re-downloading the bytes.


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
            from botocore.config import Config
            # Presigned PUT/upload_part URLs are consumed by a client that STREAMS the body (iOS URLSession /
            # urllib), so the presign must use UNSIGNED-PAYLOAD SigV4 — otherwise S3 computes a body-hash the
            # streaming client did not sign and returns SignatureDoesNotMatch (403). Applies to both the
            # single-PUT and multipart part URLs.
            self._s3 = boto3.client("s3", region_name=self.cfg.region,
                                    config=Config(signature_version="s3v4",
                                                  s3={"payload_signing_enabled": False}))
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
                        device_asset_id: str = "", source_moment_id: str = "",
                        media_kind: str = MEDIA_KIND_MOMENT, source_output_id: str = "") -> tuple[dict, bool]:
        """Create (or idempotently recover) an `uploading` record for (owner, content). Returns (record,
        created). A re-initiate of the SAME content by the SAME owner recovers the existing record (created=
        False). A reuse of the same cloud_media_id with a DIFFERENT size/sha raises MediaOwnershipConflict.
        Ownership (`owner`) is the trusted story_user_id — never client-supplied here.

        R7-D: `media_kind` distinguishes a captured-original backup (MEDIA_KIND_MOMENT, default) from a
        RENDERED generated-video backup (MEDIA_KIND_GENERATED); a generated record carries `source_output_id`
        (the GeneratedOutput id) instead of a `source_moment_id`. The storage path/verification are IDENTICAL —
        only the provenance fields differ, so the R4 upload pipeline is reused unchanged (no second uploader)."""
        media_kind = _normalize_media_kind(media_kind)
        cmid = cloud_media_id_for(owner, content_sha256)
        now = _now()
        key = object_key(owner, cmid)
        item = {
            "story_user_id": {"S": owner}, "cloud_media_id": {"S": cmid},
            "state": {"S": STATE_UPLOADING}, "content_sha256": {"S": content_sha256},
            "size_bytes": {"N": str(int(size_bytes))}, "content_type": {"S": content_type},
            "s3_key": {"S": key}, "created_at": {"N": str(now)}, "updated_at": {"N": str(now)},
            "device_asset_id": {"S": device_asset_id}, "source_moment_id": {"S": source_moment_id},
            "media_kind": {"S": media_kind}, "source_output_id": {"S": source_output_id},
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
                UpdateExpression=("SET #s = :v, verified_at = :t, updated_at = :t, "
                                  "checksum_sha256 = :ck, checksum_kind = :kind"),
                ConditionExpression="#s = :uploading",   # no backward/forward skip; only uploading -> verified
                ExpressionAttributeNames={"#s": "state"},
                ExpressionAttributeValues={
                    ":v": {"S": STATE_CLOUD_VERIFIED}, ":t": {"N": str(now)},
                    # Persist the checksum that was ACTUALLY verified (durable audit). Single-PUT -> the
                    # full-file sha256, base64. checksum_kind tells a reader this is a whole-file digest,
                    # so a composite is never mistaken for one.
                    ":ck": {"S": actual_sha_b64}, ":kind": {"S": "sha256"},
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
        # R6: return the SERVER-AUTHORITATIVE expectation so a device that never held the upload job (a fresh
        # install, or Device B after R7 sync) can still verify the download. content_sha256 is the FULL-FILE
        # sha256 (hex) recorded at initiate — the authoritative whole-file check for a downloaded original; the
        # multipart composite checksum is an upload-time artifact and is NOT used to verify a download.
        return {"url": url, "expires_in": DOWNLOAD_URL_TTL_SECONDS,
                "size_bytes": int(rec.get("size_bytes", 0)),
                "content_sha256": rec.get("content_sha256", ""),
                "content_type": rec.get("content_type", "application/octet-stream")}

    # --- MULTIPART (R4-B; large files) ---------------------------------------------------------------
    def initiate_multipart(self, *, owner: str, content_sha256: str, size_bytes: int,
                           part_shas_b64: list[str], content_type: str = "video/quicktime",
                           device_asset_id: str = "", source_moment_id: str = "",
                           media_kind: str = MEDIA_KIND_MOMENT, source_output_id: str = "") -> tuple[dict, bool]:
        """Create (or idempotently recover) a MULTIPART upload for (owner, content). `part_shas_b64` is the
        device's per-part sha256 (base64), in order — recorded as the EXPECTED digests for composite
        verification. Returns (record, created). A re-initiate of the SAME content recovers the existing
        record + its S3 upload_id (never a second MPU, never a duplicate object). Owner is the trusted
        story_user_id. Conflict on a different size/sha.

        R7-D: `media_kind`/`source_output_id` carry generated-video provenance exactly as in initiate_upload —
        a large rendered MP4 takes this multipart path unchanged."""
        media_kind = _normalize_media_kind(media_kind)
        cmid = cloud_media_id_for(owner, content_sha256)
        existing = self.get(owner, cmid)
        if existing is not None:
            if (existing.get("content_sha256") != content_sha256
                    or int(existing.get("size_bytes", -1)) != int(size_bytes)):
                raise MediaOwnershipConflict(f"cloud_media_id {cmid} exists with a different content descriptor")
            if existing.get("state") == STATE_CLOUD_VERIFIED:
                return existing, False
            if existing.get("upload_id"):
                return existing, False   # resume the SAME multipart upload
            # record exists (e.g. from a prior single-PUT initiate) but no MPU yet — fall through to create one.

        key = object_key(owner, cmid)
        mpu = self._s3_c().create_multipart_upload(
            Bucket=self.cfg.bucket, Key=key, ContentType=content_type, ChecksumAlgorithm="SHA256")
        upload_id = mpu["UploadId"]
        now = _now()
        item = {
            "story_user_id": {"S": owner}, "cloud_media_id": {"S": cmid},
            "state": {"S": STATE_UPLOADING}, "upload_mode": {"S": "multipart"},
            "content_sha256": {"S": content_sha256}, "size_bytes": {"N": str(int(size_bytes))},
            "content_type": {"S": content_type}, "s3_key": {"S": key}, "upload_id": {"S": upload_id},
            "part_shas": {"S": json.dumps(part_shas_b64)}, "part_count": {"N": str(len(part_shas_b64))},
            "created_at": {"N": str(now)}, "updated_at": {"N": str(now)},
            "device_asset_id": {"S": device_asset_id}, "source_moment_id": {"S": source_moment_id},
            "media_kind": {"S": media_kind}, "source_output_id": {"S": source_output_id},
            "verified_at": {"N": "0"},
        }
        # Overwrite any prior single-PUT record for this cmid (same owner) with the multipart record.
        self._ddb_c().put_item(TableName=self.cfg.table, Item=item)
        return self._decode(item), True

    def presign_parts(self, *, owner: str, cloud_media_id: str, part_numbers: list[int]) -> dict:
        """Bounded presigned upload-part URLs for the requested 1-based part numbers of the owner's own MPU.
        Each URL requires the part's ChecksumSHA256 header (recorded at initiate) so S3 validates the part on
        arrival. 404 if not the caller's; conflict if not a multipart record."""
        rec = self.get(owner, cloud_media_id)
        if rec is None:
            raise MediaNotFound(cloud_media_id)
        upload_id = rec.get("upload_id")
        if not upload_id:
            raise MediaVerificationError("not a multipart upload")
        part_shas = json.loads(rec.get("part_shas", "[]"))
        urls: dict[int, dict] = {}
        for pn in part_numbers:
            if pn < 1 or pn > len(part_shas):
                continue
            params = {"Bucket": self.cfg.bucket, "Key": rec["s3_key"], "UploadId": upload_id,
                      "PartNumber": pn, "ChecksumSHA256": part_shas[pn - 1]}
            urls[pn] = {"url": self._s3_c().generate_presigned_url(
                "upload_part", Params=params, ExpiresIn=UPLOAD_URL_TTL_SECONDS),
                "checksum_sha256": part_shas[pn - 1]}
        return {"parts": urls, "expires_in": UPLOAD_URL_TTL_SECONDS}

    def list_uploaded_parts(self, *, owner: str, cloud_media_id: str) -> list[dict]:
        """Reconcile: the parts S3 has already received for this MPU (so the client re-uploads only what's
        missing after an interruption). Returns [{part_number, etag, checksum_sha256, size}]."""
        rec = self.get(owner, cloud_media_id)
        if rec is None:
            raise MediaNotFound(cloud_media_id)
        upload_id = rec.get("upload_id")
        if not upload_id:
            raise MediaVerificationError("not a multipart upload")
        out: list[dict] = []
        paginator = self._s3_c().get_paginator("list_parts")
        for page in paginator.paginate(Bucket=self.cfg.bucket, Key=rec["s3_key"], UploadId=upload_id):
            for p in page.get("Parts", []):
                out.append({"part_number": p["PartNumber"], "etag": p["ETag"],
                            "checksum_sha256": p.get("ChecksumSHA256", ""), "size": p.get("Size", 0)})
        return out

    def complete_multipart(self, *, owner: str, cloud_media_id: str) -> dict:
        """Complete the MPU (passing the recorded per-part checksums), then VERIFY: object exists ∧ size matches
        ∧ the COMPOSITE ChecksumSHA256 S3 returns == the composite the SERVER recomputes from the recorded
        per-part digests. Only then uploading -> cloud_verified. A multipart completion SUCCEEDING is NOT
        sufficient — the composite + size must match. Idempotent. Never marks verified on client say-so."""
        rec = self.get(owner, cloud_media_id)
        if rec is None:
            raise MediaNotFound(cloud_media_id)
        if rec.get("state") == STATE_CLOUD_VERIFIED:
            return rec
        upload_id = rec.get("upload_id")
        if not upload_id:
            raise MediaVerificationError("not a multipart upload")
        part_shas = json.loads(rec.get("part_shas", "[]"))

        # Reconcile the actually-uploaded parts; every expected part must be present.
        uploaded = {p["part_number"]: p for p in self.list_uploaded_parts(owner=owner, cloud_media_id=cloud_media_id)}
        parts_payload = []
        for pn in range(1, len(part_shas) + 1):
            got = uploaded.get(pn)
            if got is None:
                raise MediaVerificationError(f"missing part {pn}")
            if got.get("checksum_sha256") and got["checksum_sha256"] != part_shas[pn - 1]:
                raise MediaVerificationError(f"part {pn} checksum mismatch")
            parts_payload.append({"ETag": got["etag"], "PartNumber": pn,
                                  "ChecksumSHA256": part_shas[pn - 1]})

        try:
            self._s3_c().complete_multipart_upload(
                Bucket=self.cfg.bucket, Key=rec["s3_key"], UploadId=upload_id,
                MultipartUpload={"Parts": parts_payload})
        except Exception as e:
            # A duplicate completion after S3 already assembled the object is tolerable — fall through to verify.
            if "NoSuchUpload" not in str(e):
                raise

        head = self._head_object(rec["s3_key"])
        if head is None:
            raise MediaVerificationError("object not found after complete")
        actual_size = int(head.get("ContentLength", -1))
        if actual_size != int(rec.get("size_bytes", -2)):
            raise MediaVerificationError(f"size mismatch: expected {rec.get('size_bytes')} got {actual_size}")
        expected_composite = _composite_checksum(part_shas)
        actual_composite = head.get("ChecksumSHA256", "")
        if not actual_composite or actual_composite != expected_composite:
            raise MediaVerificationError("composite checksum mismatch")

        now = _now()
        try:
            self._ddb_c().update_item(
                TableName=self.cfg.table,
                Key={"story_user_id": {"S": owner}, "cloud_media_id": {"S": cloud_media_id}},
                UpdateExpression=("SET #s = :v, verified_at = :t, updated_at = :t, "
                                  "checksum_sha256 = :ck, checksum_kind = :kind"),
                ConditionExpression="#s = :uploading",
                ExpressionAttributeNames={"#s": "state"},
                ExpressionAttributeValues={
                    ":v": {"S": STATE_CLOUD_VERIFIED}, ":t": {"N": str(now)},
                    # Persist the COMPOSITE checksum that was verified. checksum_kind marks it 'sha256-composite'
                    # (base64(sha256(concat(part digests)))-N), so a reader NEVER treats it as a full-file sha256.
                    ":ck": {"S": actual_composite}, ":kind": {"S": "sha256-composite"},
                    ":uploading": {"S": STATE_UPLOADING}})
        except Exception as e:
            if self._is_conditional(e):
                cur = self.get(owner, cloud_media_id)
                if cur and cur.get("state") == STATE_CLOUD_VERIFIED:
                    return cur
            raise
        return self.get(owner, cloud_media_id) or rec

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
        # R7-D back-compat: a record written before media_kind existed reads as a captured moment with no
        # output provenance. Normalize so every reader sees the keys regardless of record vintage.
        out["media_kind"] = _normalize_media_kind(out.get("media_kind", ""))
        out.setdefault("source_output_id", "")
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


def _composite_checksum(part_shas_b64: list[str]) -> str:
    """Recompute S3's multipart COMPOSITE ChecksumSHA256 from the ordered per-part sha256 digests (base64):
    sha256( concat(raw_part_digests) ), base64-encoded, suffixed '-<N>'. This is how S3 derives the object's
    composite checksum for a multipart upload whose parts each carry a ChecksumSHA256 — so matching it against
    S3's returned value (plus the size check and S3's own per-part validation) assures end-to-end integrity
    WITHOUT re-downloading the object. It is deliberately NOT a full-file sha256, and never treated as one."""
    import base64
    import hashlib
    if not part_shas_b64:
        return ""
    concat = b"".join(base64.b64decode(p) for p in part_shas_b64)
    digest = hashlib.sha256(concat).digest()
    return f"{base64.b64encode(digest).decode('ascii')}-{len(part_shas_b64)}"
