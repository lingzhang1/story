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


class PayloadConflict(Exception):
    """Same operation_id submitted with a DIFFERENT payload — a client bug, not a legitimate retry (concern 2)."""

# Retention: staged sheets deleted at terminal; this is the hard backstop (also set as an S3 lifecycle rule).
STAGING_TTL_SECONDS = 24 * 3600
# A job may live this long before TTL reaps it (covers a slow worker + poll window).
JOB_TTL_SECONDS = 6 * 3600
# Worker execution lease — a redelivery within this window does not re-run a live job.
LEASE_SECONDS = 900


def job_id_for(operation_id: str) -> str:
    """Deterministic job id from the client's operation id — the whole idempotency guarantee."""
    return str(uuid.uuid5(_JOB_NS, operation_id.strip()))


def payload_fingerprint(body_json: str, sheet_order: list[str], critique: bool, approach: str) -> str:
    """Stable hash of the request payload so the SAME operation_id with a DIFFERENT payload is a conflict,
    not a silent idempotent recovery (concern 2)."""
    import hashlib
    h = hashlib.sha256()
    h.update(body_json.encode("utf-8"))
    h.update(b"\x00" + json.dumps(sheet_order, sort_keys=True).encode("utf-8"))
    h.update(b"\x00" + (b"1" if critique else b"0"))
    h.update(b"\x00" + approach.encode("utf-8"))
    return h.hexdigest()


# Reconcile: re-enqueue only truly-stranded jobs (concern 6).
RECONCILE_AFTER_SECONDS = 60
MAX_ENQUEUE_ATTEMPTS = 2


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
                      payload_fingerprint: str, has_body: bool = True) -> tuple[str, bool]:
        """Idempotent create. Returns (job_id, created). created=False => an existing job was recovered
        (duplicate submission with the same operation_id AND the same payload). A duplicate operation_id with a
        DIFFERENT payload_fingerprint is a client bug -> raises PayloadConflict (409 at the endpoint). No
        duplicate expensive execution is ever queued."""
        jid = job_id_for(operation_id)
        now = _now()
        item = {
            "job_id": {"S": jid}, "operation_id": {"S": operation_id}, "owner": {"S": owner},
            "status": {"S": "queued"}, "created_at": {"N": str(now)}, "updated_at": {"N": str(now)},
            "expires_at": {"N": str(now + JOB_TTL_SECONDS)}, "attempt_count": {"N": "0"},
            "lease_until": {"N": "0"}, "lease_token": {"S": ""}, "approach": {"S": approach},
            "critique_requested": {"BOOL": bool(critique_requested)},
            "payload_fingerprint": {"S": payload_fingerprint},
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
                existing = self.get(jid)
                if existing and existing.get("payload_fingerprint") not in (None, payload_fingerprint):
                    raise PayloadConflict(
                        f"operation_id already used with a different payload (job {jid})")
                return jid, False   # idempotent recovery of the existing job (same payload)
            raise

    def enqueue(self, job_id: str) -> None:
        self._sqs_c().send_message(QueueUrl=self.cfg.queue_url, MessageBody=json.dumps({"job_id": job_id}))

    def get(self, job_id: str) -> Optional[dict]:
        resp = self._ddb_c().get_item(TableName=self.cfg.table, Key={"job_id": {"S": job_id}})
        it = resp.get("Item")
        if not it:
            return None
        d = _deser(it)
        # Concern 5: DynamoDB TTL is NOT immediate deletion (reaped within ~48h). A non-terminal job past
        # its expires_at is reported as `expired` on READ, so callers never see a stale queued/running row.
        if d.get("status") not in TERMINAL and _now() > int(d.get("expires_at", 0) or 0):
            d["status"] = "expired"
        return d

    def _set_status(self, job_id: str, new: str, *, require: Optional[list[str]] = None,
                    lease_token: Optional[str] = None, extra: Optional[dict] = None) -> bool:
        """Conditional status transition. `require` = allowed current statuses. When `lease_token` is given,
        the write ALSO requires the stored lease_token to match — so a stale worker (whose lease expired and
        whose job was re-claimed with a new token) cannot publish over the fresh run (concern 3). Returns True
        if applied."""
        now = _now()
        names = {"#s": "status", "#u": "updated_at"}
        vals: dict[str, Any] = {":new": {"S": new}, ":u": {"N": str(now)}}
        set_expr = "#s = :new, #u = :u"
        if extra:
            for i, (k, v) in enumerate(extra.items()):
                names[f"#e{i}"] = k
                vals[f":e{i}"] = v
                set_expr += f", #e{i} = :e{i}"
        cond_parts = []
        if require:
            req_parts = []
            for i, st in enumerate(require):
                vals[f":r{i}"] = {"S": st}
                req_parts.append(f"#s = :r{i}")
            cond_parts.append("(" + " OR ".join(req_parts) + ")")
        if lease_token is not None:
            names["#lt"] = "lease_token"
            vals[":lt"] = {"S": lease_token}
            cond_parts.append("#lt = :lt")
        cond = " AND ".join(cond_parts) if cond_parts else None
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

    def claim_lease(self, job_id: str) -> Optional[str]:
        """Worker claims the job: queued|running-with-expired-lease -> running + fresh lease + NEW lease_token.
        Returns the lease_token on success, None if a live lease is held (redelivery -> drop). The token lets
        complete()/fail() reject a STALE worker whose lease expired and whose job was re-claimed (concern 3)."""
        now = _now()
        token = str(uuid.uuid4())
        try:
            self._ddb_c().update_item(
                TableName=self.cfg.table, Key={"job_id": {"S": job_id}},
                UpdateExpression=("SET #s = :run, lease_until = :lu, lease_token = :tok, "
                                  "updated_at = :u ADD attempt_count :one"),
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={
                    ":run": {"S": "running"}, ":lu": {"N": str(now + LEASE_SECONDS)},
                    ":tok": {"S": token}, ":u": {"N": str(now)}, ":one": {"N": "1"},
                    ":q": {"S": "queued"}, ":r": {"S": "running"}, ":now": {"N": str(now)}},
                ConditionExpression="(#s = :q) OR (#s = :r AND lease_until < :now)")
            return token
        except Exception as e:
            if "ConditionalCheckFailed" in type(e).__name__ or "ConditionalCheckFailed" in str(e):
                return None
            raise

    def complete(self, job_id: str, plan: dict, diagnostics: dict, lease_token: str) -> bool:
        return self._set_status(job_id, "completed", require=["running"], lease_token=lease_token,
                                extra={"plan": {"M": _ser(plan)}, "diagnostics": {"M": _ser(diagnostics)}})

    def fail(self, job_id: str, category: str, detail: str, lease_token: str | None = None) -> bool:
        return self._set_status(job_id, "failed", require=["running", "queued"], lease_token=lease_token,
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

    def reconcile_lost_enqueue(self, limit: int = 50) -> list[str]:
        """Concern 6: re-enqueue ONLY genuinely-stranded jobs — status=queued, never leased (attempt_count=0),
        older than RECONCILE_AFTER_SECONDS. A job a worker already claimed (attempt_count>=1 / running) is left
        alone. Re-enqueue is capped: after MAX_ENQUEUE_ATTEMPTS a job is failed(category=enqueue_lost). SQS
        redelivery is still deduped by the lease, so this never doubles inference. Returns re-enqueued job_ids.
        (Scan is fine at dev volume; a GSI on status would replace it at scale.)"""
        now = _now()
        cutoff = now - RECONCILE_AFTER_SECONDS
        resp = self._ddb_c().scan(
            TableName=self.cfg.table,
            FilterExpression="#s = :q AND attempt_count = :z AND created_at < :cut",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":q": {"S": "queued"}, ":z": {"N": "0"},
                                       ":cut": {"N": str(cutoff)}},
            Limit=limit)
        reenq: list[str] = []
        for raw in resp.get("Items", []):
            d = _deser(raw)
            jid = d["job_id"]
            # bump a reconcile counter; cap re-enqueues
            n = int(d.get("reconcile_count", 0) or 0)
            if n >= MAX_ENQUEUE_ATTEMPTS:
                self.fail(jid, "enqueue_lost", "job never dequeued after max reconcile attempts")
                continue
            # best-effort re-enqueue + count bump (not a state change, so no lease needed)
            try:
                self._ddb_c().update_item(
                    TableName=self.cfg.table, Key={"job_id": {"S": jid}},
                    UpdateExpression="SET reconcile_count = :nc, updated_at = :u",
                    ExpressionAttributeValues={":nc": {"N": str(n + 1)}, ":u": {"N": str(now)}})
                self.enqueue(jid)
                reenq.append(jid)
            except Exception:
                pass
        return reenq


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
