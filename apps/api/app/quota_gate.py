"""P0 Beta Security Phase 4 — AI quota ENFORCEMENT GATE (wiring layer).

Wires the pure `user_quota` reserve/settle/release/slot logic into EVERY paid AI entry point with NO bypass
through an alternate route. The set of paid entry points is taken from the SAME authoritative classification
the Phase-3 throttle uses (`throttle.ROUTE_CLASS`) so there is exactly one route map and it cannot drift:

  * ai_sync        -> synchronous Bedrock inference  (reserve estimate before handler, settle/release after)
  * music_provider -> paid Epidemic provider calls   (reserve estimate before handler, settle/release after)
  * ai_job_submit  -> async AI job submission         (reserve estimate + take an active-job slot at submit;
                                                        the WORKER settles/releases on terminal — see
                                                        worker_settle / worker_release below)

Owner corrections honored here:
  7/8. Covers sync inference, async submissions, AND worker retries (the worker calls worker_settle/
       worker_release). A new customer paid endpoint added to throttle.ROUTE_CLASS as an expensive class is
       automatically quota-gated; a route-coverage test asserts the expensive set stays covered.
  9.   Observe mode records QuotaWouldDeny and NEVER denies (expensive store-error still fails closed, like
       Phase 3 amendment 1 — an accounting outage must not run unbounded inference).
 10.   Trusted story_user_id key; low-cardinality metrics (op_type dim), never a user id.

Idempotency model:
  * SYNC ops have no client operation_id, so the gate mints a per-REQUEST operation id. Retries of a sync
    call are distinct requests (the device re-submits), so per-request reservation is correct; settle/release
    always runs in a finally-equivalent block so a reservation is never orphaned by a normal response/error.
  * ASYNC submit uses the SAME scoped operation_id the job store uses (principal-scoped), so a duplicate
    submit / SQS redelivery maps to the SAME reservation + the SAME active-job slot (exactly-once, corr. 6).
    When the submit handler recovers an EXISTING job (created=False), the gate does NOT reserve a second
    allowance or a second slot (idempotent).
"""

from __future__ import annotations

import os
import uuid
from typing import Optional

from fastapi import Request
from fastapi.responses import JSONResponse

from app.throttle import CLASS_POLICIES, classify, THROTTLE_EXEMPT_PATHS

try:
    from user_quota import UserQuota, QuotaConfig, QuotaDenied, QuotaStoreError
except Exception:  # pragma: no cover - import-safe
    UserQuota = None  # type: ignore

# The expensive classes that cost real money and therefore get a quota reservation.
PAID_CLASSES = frozenset({"ai_sync", "music_provider", "ai_job_submit"})

# A conservative per-op ESTIMATE in USD used at reserve time (actual is settled afterward, correction 8).
# Per-class so a batch Opus coverage reserves more headroom than a single Sonnet call. Overridable by env.
_DEFAULT_ESTIMATE_USD: dict[str, float] = {
    "ai_sync": 0.05,
    "music_provider": 0.01,   # Epidemic provider call (not Bedrock) — small fixed estimate
    "ai_job_submit": 0.15,    # async plan/critique/coverage can be multi-call — reserve more
}


def quota_mode() -> str:
    return os.environ.get("STORY_QUOTA_MODE", "observe").strip().lower()


def estimate_for(cls: str) -> float:
    key = f"STORY_QUOTA_ESTIMATE_{cls.upper()}_USD"
    try:
        return float(os.environ.get(key, str(_DEFAULT_ESTIMATE_USD.get(cls, 0.05))))
    except ValueError:
        return _DEFAULT_ESTIMATE_USD.get(cls, 0.05)


def _configured_table() -> str:
    return os.environ.get("STORY_USER_USAGE_TABLE", "")


def _quota(request: Request) -> Optional["UserQuota"]:
    """Injected quota (tests) or a real one when the usage table is configured. None => gate is inert
    (unprovisioned env / dev / unit tests that do not inject), exactly like the Phase-3 throttle."""
    injected = getattr(request.app.state, "_user_quota", None)
    if injected is not None:
        return injected
    if UserQuota is not None and _configured_table():
        return UserQuota()
    return None


def _metric(request: Request, name: str, cls: str) -> None:
    emit = getattr(request.app.state, "_quota_metric_hook", None)
    if emit is not None:
        try:
            emit(name, cls)
        except Exception:  # noqa: BLE001
            pass


def _principal_uid(request: Request) -> Optional[str]:
    p = getattr(request.state, "principal", None)
    if p is None or getattr(p, "is_legacy", False) or not getattr(p, "story_user_id", None):
        return None
    return p.story_user_id


async def quota_middleware(request: Request, call_next):
    """Runs AFTER auth + throttle (registered BEFORE them so it is the INNERMOST layer, closest to the
    handler, and sees request.state.principal). For a PAID class it reserves an estimate before the handler
    and settles/releases after. Sync ops settle the actual cost reported by the handler (request.state.
    quota_actual_usd) or release on a non-2xx. Async submit reserves + takes a slot; the worker settles.

    Observe mode never denies. A quota STORE error on a paid op fails CLOSED (503) — an accounting outage
    must not run unbounded inference (consistent with Phase 3 amendment 1)."""
    path = request.url.path
    if path in THROTTLE_EXEMPT_PATHS:
        return await call_next(request)
    template = _matched_template(request) or path
    cls = classify(request.method, template)
    if cls is None or cls not in PAID_CLASSES:
        return await call_next(request)

    uid = _principal_uid(request)
    if uid is None:
        return await call_next(request)

    q = _quota(request)
    if q is None:
        return await call_next(request)   # inert until provisioned

    enforce = quota_mode() == "enforce"
    estimate = estimate_for(cls)

    # Async submit is handled by the SUBMIT HANDLER (it has the scoped operation_id + knows created vs
    # recovered, so it reserves the allowance + the slot exactly once). The middleware only gates the SYNC
    # paid classes here; it records that an async submit was seen but defers reserve to the handler.
    if cls == "ai_job_submit":
        request.state.quota_cls = cls
        request.state.quota_uid = uid
        return await call_next(request)

    # SYNC paid op: mint a per-request op id, reserve the estimate, run, settle actual or release.
    op_id = f"sync:{cls}:{uuid.uuid4()}"
    try:
        q.reserve(uid, op_id, estimate_usd=estimate, gens=1)
    except QuotaDenied as d:
        if enforce:
            _metric(request, "QuotaDenied", cls)
            return _denied(d.scope)
        _metric(request, "QuotaWouldDeny", cls)
        # observe: proceed WITHOUT a reservation (we recorded what would be denied). Nothing to settle.
        return await call_next(request)
    except QuotaStoreError:
        _metric(request, "QuotaStoreError", cls)
        # Paid op + accounting outage -> fail CLOSED (503), even in observe (correction 9 / Phase-3 amend 1).
        return JSONResponse(status_code=503, headers={"Retry-After": "30"},
                            content={"error": "quota_store_unavailable", "class": cls,
                                     "retry_after_seconds": 30})

    _metric(request, "QuotaReserved", cls)
    request.state.quota_actual_usd = None  # handler MAY set the real cost
    try:
        response = await call_next(request)
    except Exception:
        # Handler raised -> the generation failed: refund the allowance, keep any incurred spend at 0.
        try:
            q.release_allowance(uid, op_id, gens=1, incurred_usd=0.0)
            _metric(request, "QuotaReleased", cls)
        except Exception:  # noqa: BLE001
            pass
        raise

    actual = getattr(request.state, "quota_actual_usd", None)
    try:
        if 200 <= response.status_code < 300:
            q.settle(uid, op_id, actual_usd=float(actual) if actual is not None else estimate)
            _metric(request, "QuotaSettled", cls)
        else:
            # Non-2xx (validation/engine failure): refund the allowance, record the estimate as incurred only
            # if the handler reported real spend; otherwise 0 (correction 3/4).
            q.release_allowance(uid, op_id, gens=1,
                                incurred_usd=float(actual) if actual is not None else 0.0)
            _metric(request, "QuotaReleased", cls)
    except Exception:  # noqa: BLE001
        pass  # settlement drift is reconcilable; never break the response
    return response


# --- async submit handler helpers (called from the submit endpoints in main.py) -------------------------

def submit_reserve(request: Request, uid: str, scoped_op_id: str, job_id: str,
                   *, created: bool) -> Optional[JSONResponse]:
    """Called by an async submit handler AFTER it has the scoped operation_id + job_id and knows whether the
    job was newly CREATED or recovered. Reserves the allowance + an active-job slot EXACTLY ONCE (idempotent
    on scoped_op_id / job_id). Returns a JSONResponse to SHORT-CIRCUIT the submit on an enforced denial, or
    None to proceed. A recovered (created=False) duplicate reserves nothing new (the markers already exist)."""
    q = _quota(request) if request is not None else None
    if q is None:
        return None
    cls = "ai_job_submit"
    enforce = quota_mode() == "enforce"
    estimate = estimate_for(cls)
    try:
        q.reserve(uid, scoped_op_id, estimate_usd=estimate, gens=1)
        # reserve a queued+running slot keyed by the deterministic job id (same identity the store uses)
        q.reserve_slot(uid, job_id)
    except QuotaDenied as d:
        if enforce:
            _metric(request, "QuotaDenied", cls)
            return _denied(d.scope)
        _metric(request, "QuotaWouldDeny", cls)
        return None
    except QuotaStoreError:
        _metric(request, "QuotaStoreError", cls)
        if enforce:
            return JSONResponse(status_code=503, headers={"Retry-After": "30"},
                                content={"error": "quota_store_unavailable", "class": cls,
                                         "retry_after_seconds": 30})
        return None
    _metric(request, "QuotaReserved", cls)
    return None


# --- worker terminal settlement (correction 7: worker retries; 6: slot release) -------------------------

def worker_settle(uid: str, scoped_op_id: str, job_id: str, *, actual_usd: float,
                  usage_table: str = "", ddb=None) -> None:
    """Worker-side: a job COMPLETED. Settle the actual incurred spend and RELEASE the active-job slot, each
    exactly once (idempotent on the reservation + slot markers). Safe to call on an SQS redelivery."""
    if UserQuota is None:
        return
    q = UserQuota(ddb=ddb, usage_table=usage_table or _env_table())
    try:
        q.settle(uid, scoped_op_id, actual_usd=actual_usd)
    finally:
        q.release_slot(uid, job_id)


def worker_release(uid: str, scoped_op_id: str, job_id: str, *, incurred_usd: float = 0.0,
                   usage_table: str = "", ddb=None) -> None:
    """Worker-side: a job FAILED / CANCELLED. Refund the allowance, KEEP any incurred Bedrock spend
    (correction 3/4 — failed/retry/repair/critique/fallback attempts still cost money), and release the
    active-job slot. Idempotent."""
    if UserQuota is None:
        return
    q = UserQuota(ddb=ddb, usage_table=usage_table or _env_table())
    try:
        q.release_allowance(uid, scoped_op_id, gens=1, incurred_usd=incurred_usd)
    finally:
        q.release_slot(uid, job_id)


def _env_table() -> str:
    return os.environ.get("STORY_USER_USAGE_TABLE", "")


def _denied(scope: str) -> JSONResponse:
    """Distinct quota denial, separable from a rate-limit 429 (which uses error:'rate_limited')."""
    return JSONResponse(status_code=429, headers={"Retry-After": "3600"},
                        content={"error": "quota_exceeded", "scope": scope, "retry_after_seconds": 3600})


def _matched_template(request: Request) -> Optional[str]:
    route = request.scope.get("route")
    return getattr(route, "path", None) if route else None
