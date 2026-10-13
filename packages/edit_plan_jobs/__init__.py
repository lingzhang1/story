"""Async Edit Planning — durable job store + S3 contact-sheet staging.

Owner-approved 2026-10-13 (dev only). Implements the SHARED CONTRACT in
specs/story-specs/spec/implementation-plan/async-edit-planning-CONTRACT.md.

This module is import-safe WITHOUT boto3/AWS (lazy clients) so the backend test
suite and the Lambda worker share it. All AWS resource names come from env:
  STORY_JOBS_TABLE, STORY_JOBS_QUEUE_URL, STORY_STAGING_BUCKET.

Design points enforced here:
  * job_id = UUIDv5(operation_id) -> idempotent submission (a duplicate POST or an
    SQS redelivery maps to the SAME item; a deliberate new version uses a new
    operation_id -> new job).
  * CONDITIONAL state transitions only (no backward moves); terminal states are
    completed|failed|cancelled|expired.
  * A worker LEASE (lease_until) makes at-least-once SQS delivery safe: a redelivery
    while the lease is live and status=running is dropped; after the lease expires a
    re-run is allowed (idempotent — it overwrites the result). We do NOT claim
    exactly-once inference.
  * Staged artifacts are DERIVED JPEG contact sheets + the request body JSON ONLY —
    never original video. Deleted on terminal; 24h S3 lifecycle is the backstop.
"""
from __future__ import annotations

import json
import os
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional

# Stable namespace so UUIDv5(operation_id) is deterministic across App Runner + worker.
_JOB_NS = uuid.UUID("6f1d2c3a-0b7e-5a4d-9c8b-1e2f3a4b5c6d")

TERMINAL = {"completed", "failed", "cancelled", "expired"}

# Retention: staged sheets deleted at terminal; this is the hard backstop (also set as an S3 lifecycle rule).
STAGING_TTL_SECONDS = 24 * 3600
# A job may live this long before TTL reaps it (covers a slow worker + poll window).
JOB_TTL_SECONDS = 6 * 3600
# Worker execution lease — a redelivery within this window does not re-run a live job.
LEASE_SECONDS = 900


def job_id_for(operation_id: str) -> str:
    """Deterministic job id from the client's operation id — the whole idempotency guarantee."""
    return str(uuid.uuid5(_JOB_NS, operation_id.strip()))


def _now() -> int:
    return int(time.time())


@dataclass
class JobStoreConfig:
    table: str = field(default_factory=lambda: os.environ.get("STORY_JOBS_TABLE", ""))
    queue_url: str = field(default_factory=lambda: os.environ.get("STORY_JOBS_QUEUE_URL", ""))
    bucket: str = field(default_factory=lambda: os.environ.get("STORY_STAGING_BUCKET", ""))
    region: str = field(default_factory=lambda: os.environ.get("AWS_REGION", "us-east-1"))


class JobStore:
    """Thin, well-tested wrapper over DynamoDB + SQS + S3. Clients are injectable for tests."""

    def __init__(self, cfg: JobStoreConfig | None = None, *, ddb=None, sqs=None, s3=None):
        self.cfg = cfg or JobStoreConfig()
        self._ddb = ddb
        self._sqs = sqs
        self._s3 = s3

    # --- lazy AWS clients (never imported at module load) --------------------------------------------
    def _ddb_c(self):
        if self._ddb is None:
            import boto3
            self._ddb = boto3.client("dynamodb", region_name=self.cfg.region)
        return self._ddb

    def _sqs_c(self):
        if self._sqs is None:
            import boto3
            self._sqs = boto3.client("sqs", region_name=self.cfg.region)
        return self._sqs

    def _s3_c(self):
        if self._s3 is None:
            import boto3
            self._s3 = boto3.client("s3", region_name=self.cfg.region)
        return self._s3

    # --- staging (derived sheets + body JSON only; NEVER source video) -------------------------------
    def stage_request(self, job_id: str, body_json: str, sheets: list[tuple[str, bytes]]) -> str:
        """Write the body JSON + each contact-sheet JPEG under a per-job prefix. Returns the prefix.
        sheets = [(moment_id, jpeg_bytes), ...]. SSE enforced; no image bytes logged by the caller."""
        prefix = f"jobs/{job_id}/"
        s3 = self._s3_c()
        s3.put_object(Bucket=self.cfg.bucket, Key=prefix + "body.json",
                      Body=body_json.encode("utf-8"), ContentType="application/json",
                      ServerSideEncryption="AES256")
        for mid, data in sheets:
            s3.put_object(Bucket=self.cfg.bucket, Key=prefix + f"sheets/{mid}.jpg",
                          Body=data, ContentType="image/jpeg", ServerSideEncryption="AES256")
        return prefix

    def load_request(self, prefix: str, sheet_order: list[str]) -> tuple[str, list[tuple[str, bytes]]]:
        """Worker-side: read back the body JSON + sheets in sheet_order."""
        s3 = self._s3_c()
        body = s3.get_object(Bucket=self.cfg.bucket, Key=prefix + "body.json")["Body"].read().decode("utf-8")
        sheets: list[tuple[str, bytes]] = []
        for mid in sheet_order:
            obj = s3.get_object(Bucket=self.cfg.bucket, Key=prefix + f"sheets/{mid}.jpg")
            sheets.append((mid, obj["Body"].read()))
        return body, sheets

    def delete_staging(self, prefix: str) -> None:
        """Explicit privacy delete on terminal. Best-effort (lifecycle is the backstop)."""
        s3 = self._s3_c()
        try:
            resp = s3.list_objects_v2(Bucket=self.cfg.bucket, Prefix=prefix)
            keys = [{"Key": o["Key"]} for o in resp.get("Contents", [])]
            if keys:
                s3.delete_objects(Bucket=self.cfg.bucket, Delete={"Objects": keys})
        except Exception:
            pass  # terminal cleanup is best-effort; lifecycle + sweep are the backstop

    # --- job lifecycle (conditional writes) ----------------------------------------------------------
    def create_or_get(self, *, operation_id: str, owner: str, approach: str,
                      critique_requested: bool, staging_prefix: str, sheet_order: list[str],
                      has_body: bool = True) -> tuple[str, bool]:
        """Idempotent create. Returns (job_id, created). created=False => an existing job was recovered
        (duplicate submission with the same operation_id). No duplicate expensive execution is ever queued."""
        jid = job_id_for(operation_id)
        now = _now()
        item = {
            "job_id": {"S": jid}, "operation_id": {"S": operation_id}, "owner": {"S": owner},
            "status": {"S": "queued"}, "created_at": {"N": str(now)}, "updated_at": {"N": str(now)},
            "expires_at": {"N": str(now + JOB_TTL_SECONDS)}, "attempt_count": {"N": "0"},
            "lease_until": {"N": "0"}, "approach": {"S": approach},
            "critique_requested": {"BOOL": bool(critique_requested)},
            "request_ref": {"M": {
                "staging_prefix": {"S": staging_prefix},
                "sheet_order": {"S": json.dumps(sheet_order)},
                "has_body": {"BOOL": bool(has_body)},
            }},
        }
        try:
            self._ddb_c().put_item(
                TableName=self.cfg.table, Item=item,
                ConditionExpression="attribute_not_exists(job_id)")
            return jid, True
        except Exception as e:
            if "ConditionalCheckFailed" in type(e).__name__ or "ConditionalCheckFailed" in str(e):
                return jid, False   # idempotent recovery of the existing job
            raise

    def enqueue(self, job_id: str) -> None:
        self._sqs_c().send_message(QueueUrl=self.cfg.queue_url, MessageBody=json.dumps({"job_id": job_id}))

    def get(self, job_id: str) -> Optional[dict]:
        resp = self._ddb_c().get_item(TableName=self.cfg.table, Key={"job_id": {"S": job_id}})
        it = resp.get("Item")
        return _deser(it) if it else None

    def _set_status(self, job_id: str, new: str, *, require: Optional[list[str]] = None,
                    extra: Optional[dict] = None) -> bool:
        """Conditional status transition. `require` = allowed current statuses. Returns True if applied."""
        now = _now()
        names = {"#s": "status", "#u": "updated_at"}
        vals: dict[str, Any] = {":new": {"S": new}, ":u": {"N": str(now)}}
        set_expr = "#s = :new, #u = :u"
        if extra:
            for i, (k, v) in enumerate(extra.items()):
                names[f"#e{i}"] = k
                vals[f":e{i}"] = v
                set_expr += f", #e{i} = :e{i}"
        cond = None
        if require:
            cond_parts = []
            for i, st in enumerate(require):
                vals[f":r{i}"] = {"S": st}
                cond_parts.append(f"#s = :r{i}")
            cond = "(" + " OR ".join(cond_parts) + ")"
        try:
            self._ddb_c().update_item(
                TableName=self.cfg.table, Key={"job_id": {"S": job_id}},
                UpdateExpression="SET " + set_expr,
                ExpressionAttributeNames=names, ExpressionAttributeValues=vals,
                **({"ConditionExpression": cond} if cond else {}))
            return True
        except Exception as e:
            if "ConditionalCheckFailed" in type(e).__name__ or "ConditionalCheckFailed" in str(e):
                return False
            raise

    def claim_lease(self, job_id: str) -> bool:
        """Worker claims the job: queued|running-with-expired-lease -> running + fresh lease. A redelivery
        while a live lease is held returns False (drop it). At-least-once safe without exactly-once claims."""
        now = _now()
        try:
            self._ddb_c().update_item(
                TableName=self.cfg.table, Key={"job_id": {"S": job_id}},
                UpdateExpression="SET #s = :run, lease_until = :lu, updated_at = :u ADD attempt_count :one",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={
                    ":run": {"S": "running"}, ":lu": {"N": str(now + LEASE_SECONDS)},
                    ":u": {"N": str(now)}, ":one": {"N": "1"},
                    ":q": {"S": "queued"}, ":r": {"S": "running"}, ":now": {"N": str(now)},
                    ":cr": {"S": "cancel_requested"}},
                ConditionExpression="(#s = :q) OR (#s = :r AND lease_until < :now)")
            return True
        except Exception as e:
            if "ConditionalCheckFailed" in type(e).__name__ or "ConditionalCheckFailed" in str(e):
                return False
            raise

    def complete(self, job_id: str, plan: dict, diagnostics: dict) -> bool:
        return self._set_status(job_id, "completed", require=["running"],
                                extra={"plan": {"M": _ser(plan)}, "diagnostics": {"M": _ser(diagnostics)}})

    def fail(self, job_id: str, category: str, detail: str) -> bool:
        return self._set_status(job_id, "failed", require=["running", "queued"],
                                extra={"failure_category": {"S": category},
                                       "failure_detail": {"S": detail[:400]}})

    def request_cancel(self, job_id: str) -> Optional[str]:
        """User cancel. queued|running -> cancel_requested. Terminal -> no-op. Returns resulting status."""
        if self._set_status(job_id, "cancel_requested", require=["queued", "running"]):
            return "cancel_requested"
        cur = self.get(job_id)
        return cur.get("status") if cur else None

    def is_cancel_requested(self, job_id: str) -> bool:
        cur = self.get(job_id)
        return bool(cur and cur.get("status") == "cancel_requested")

    def mark_cancelled(self, job_id: str) -> bool:
        return self._set_status(job_id, "cancelled", require=["cancel_requested", "running", "queued"])


# --- minimal DynamoDB (de)serialization for the nested maps we store ---------------------------------
def _ser(obj: Any) -> Any:
    if isinstance(obj, dict):
        return {k: _ser_val(v) for k, v in obj.items()}
    return {}


def _ser_val(v: Any) -> dict:
    if v is None:
        return {"NULL": True}
    if isinstance(v, bool):
        return {"BOOL": v}
    if isinstance(v, (int, float)):
        return {"N": str(v)}
    if isinstance(v, str):
        return {"S": v}
    if isinstance(v, list):
        return {"L": [_ser_val(x) for x in v]}
    if isinstance(v, dict):
        return {"M": {k: _ser_val(x) for k, x in v.items()}}
    return {"S": json.dumps(v, default=str)}


def _deser(item: dict) -> dict:
    return {k: _deser_val(v) for k, v in item.items()}


def _deser_val(v: dict) -> Any:
    if "S" in v:
        return v["S"]
    if "N" in v:
        n = v["N"]
        return int(n) if n.lstrip("-").isdigit() else float(n)
    if "BOOL" in v:
        return v["BOOL"]
    if "NULL" in v:
        return None
    if "L" in v:
        return [_deser_val(x) for x in v["L"]]
    if "M" in v:
        return {k: _deser_val(x) for k, x in v["M"].items()}
    return None
