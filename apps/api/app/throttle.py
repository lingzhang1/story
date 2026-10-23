"""P0 Beta Security Phase 3 — authenticated per-user API throttling.

A shared, atomic, fixed-window rate limiter keyed by the canonical backend-resolved `story_user_id`
(never a client-supplied id or forwarded IP). Enforcement is identical across App Runner instances because
the counter lives in ONE DynamoDB table and each increment is a single conditional `UpdateItem`.

Owner amendments (2026-10-22) encoded here:
  * Per-class FAILURE POLICY on a limiter-store outage: expensive operations FAIL CLOSED (503 + Retry-After);
    reads, polling, metadata writes, media download and presign issuance FAIL OPEN. Never confuse an
    infrastructure failure with a user exceeding an allowance.
  * ROLLOUT mode: `observe` emits ThrottleAllowed/WouldThrottle and NEVER rejects a rate violation; `enforce`
    returns 429. The fail-closed store-error policy for expensive ops stays active EVEN IN observe mode.
  * NO five-active-job concurrency limit here (recorded as a Phase 4 dependency).
  * Idempotent async submits must not consume a second allowance — the caller passes `consume=False` when a
    duplicate `operation_id` resolved to an existing job (see main.py submit handlers).

Low-cardinality metrics only: dimensioned by `class` (<=6 values), NEVER by story_user_id.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import Optional

from fastapi import Request
from fastapi.responses import JSONResponse

# ---------------------------------------------------------------------------------------------------------
# Route classification (amendment 3). Behavior AUDITED against the handlers:
#   - creative-intent IS model-backed (model_gateway) -> ai_sync
#   - music-direction is DETERMINISTIC (no model, latency 0) -> writes-tier-cheap -> classified 'deterministic'
#   - music candidates/search/analysis/soundtrack call the EPIDEMIC provider (paid) -> ai_sync (expensive)
#   - understanding batch-get is a READ -> poll/read tier
#   - presigned S3 BYTE transfers go direct to S3, NOT through App Runner -> never throttled here
# ---------------------------------------------------------------------------------------------------------

# class -> whether it is an EXPENSIVE op (fail CLOSED on store error) and its default per-minute limit.
@dataclass(frozen=True)
class ClassPolicy:
    expensive: bool          # store-outage => fail closed (503) when True; fail open when False
    default_per_min: int
    env_key: str

CLASS_POLICIES: dict[str, ClassPolicy] = {
    # Expensive: Bedrock inference OR paid Epidemic music. Fail CLOSED on store outage.
    "ai_sync":        ClassPolicy(expensive=True,  default_per_min=20, env_key="STORY_THROTTLE_AI_SYNC_PER_MIN"),
    "ai_job_submit":  ClassPolicy(expensive=True,  default_per_min=10, env_key="STORY_THROTTLE_AI_JOB_SUBMIT_PER_MIN"),
    "music_provider": ClassPolicy(expensive=True,  default_per_min=20, env_key="STORY_THROTTLE_MUSIC_PER_MIN"),
    # Safe: metadata writes/reads/polling/presign/download. Fail OPEN on store outage.
    "writes":         ClassPolicy(expensive=False, default_per_min=60, env_key="STORY_THROTTLE_WRITES_PER_MIN"),
    "presign":        ClassPolicy(expensive=False, default_per_min=30, env_key="STORY_THROTTLE_PRESIGN_PER_MIN"),
    "read":           ClassPolicy(expensive=False, default_per_min=120, env_key="STORY_THROTTLE_READ_PER_MIN"),
}

# (METHOD, exact path) -> class. A path with {param} is matched by its FastAPI route template.
# Deterministic non-expensive endpoints (music-direction, health) are intentionally in 'read' or unlisted.
ROUTE_CLASS: dict[tuple[str, str], str] = {
    # --- ai_sync: Bedrock-backed synchronous inference ---
    ("POST", "/v1/creative-intent"): "ai_sync",
    ("POST", "/v1/interpret-revision"): "ai_sync",
    ("POST", "/v1/scene-understanding"): "ai_sync",
    ("POST", "/v1/asset-understanding"): "ai_sync",
    ("POST", "/v1/story-coverage"): "ai_sync",
    ("POST", "/v1/story-coverage/v2"): "ai_sync",
    ("POST", "/v1/story-guide"): "ai_sync",
    ("POST", "/v1/story-guide-v2"): "ai_sync",
    ("POST", "/v1/edit-plan"): "ai_sync",
    ("POST", "/v1/edit-plan-mm"): "ai_sync",
    ("POST", "/v1/music-plan"): "ai_sync",
    ("POST", "/v1/duration-recommendation"): "ai_sync",
    ("POST", "/v1/director/initialize"): "ai_sync",
    ("POST", "/v1/director/next"): "ai_sync",
    # --- music_provider: paid Epidemic calls ---
    ("POST", "/v1/music/candidates"): "music_provider",
    ("POST", "/v1/music/search"): "music_provider",
    ("POST", "/v1/music/analysis"): "music_provider",
    ("POST", "/v1/music/soundtrack"): "music_provider",
    # --- ai_job_submit: async AI submissions ---
    ("POST", "/v1/edit-plan-jobs"): "ai_job_submit",
    ("POST", "/v1/story-coverage/v2/jobs"): "ai_job_submit",
    # --- writes: metadata writes (fail-open if auth ok) ---
    ("POST", "/v1/stories"): "writes",
    ("PUT", "/v1/stories/{story_id}"): "writes",
    ("PUT", "/v1/understanding"): "writes",
    ("POST", "/v1/stories/{story_id}/outputs/{output_id}/backup"): "writes",
    ("POST", "/v1/stories/{story_id}/outputs"): "writes",
    ("POST", "/v1/music-direction"): "writes",  # DETERMINISTIC, cheap — treated as a cheap write-tier op
    # --- presign: media presign issuance (bytes go direct to S3, not here) ---
    ("POST", "/v1/media/initiate"): "presign",
    ("POST", "/v1/media/multipart/initiate"): "presign",
    ("POST", "/v1/media/{cloud_media_id}/parts"): "presign",
    ("POST", "/v1/media/{cloud_media_id}/complete"): "presign",
    ("POST", "/v1/media/{cloud_media_id}/multipart/complete"): "presign",
    # --- read / poll: reads, polling, media download, batch-get, cancel/reconcile (cheap) ---
    ("GET", "/v1/me"): "read",
    ("GET", "/v1/stories"): "read",
    ("GET", "/v1/stories/{story_id}"): "read",
    ("GET", "/v1/media"): "read",
    ("GET", "/v1/media/{cloud_media_id}"): "read",
    ("GET", "/v1/media/{cloud_media_id}/download"): "read",
    ("GET", "/v1/media/{cloud_media_id}/parts/uploaded"): "read",
    ("POST", "/v1/understanding/batch-get"): "read",   # a READ despite POST (body carries id list)
    ("GET", "/v1/edit-plan-jobs/{job_id}"): "read",
    ("GET", "/v1/story-coverage/v2/jobs/{job_id}"): "read",
    ("POST", "/v1/edit-plan-jobs/{job_id}/cancel"): "read",
    ("POST", "/v1/story-coverage/v2/jobs/{job_id}/cancel"): "read",
    ("POST", "/v1/edit-plan-jobs/_reconcile"): "read",
}

# Public / never-throttled (health; docs handled by auth boundary).
THROTTLE_EXEMPT_PATHS = frozenset({"/health", "/openapi.json", "/docs", "/redoc", "/docs/oauth2-redirect"})


def _env() -> str:
    return os.environ.get("STORY_ENVIRONMENT", "development").strip().lower()


def throttle_mode() -> str:
    """'observe' (default for beta rollout) emits metrics but never 429s; 'enforce' returns 429."""
    return os.environ.get("STORY_THROTTLE_MODE", "observe").strip().lower()


def _limit_for(cls: str) -> int:
    p = CLASS_POLICIES[cls]
    try:
        return int(os.environ.get(p.env_key, str(p.default_per_min)))
    except ValueError:
        return p.default_per_min


def _window_seconds() -> int:
    return int(os.environ.get("STORY_THROTTLE_WINDOW_SECONDS", "60"))


@dataclass
class ThrottleDecision:
    allowed: bool            # whether the request proceeds
    cls: str
    limited: bool = False    # True if the user exceeded the allowance (a real 429 in enforce mode)
    store_error: bool = False
    retry_after: int = 0


class RateLimiter:
    """Atomic fixed-window counter in DynamoDB. One conditional UpdateItem per check. Shared across
    instances. `_ddb` injectable for tests."""

    def __init__(self, *, ddb=None, table: str = "", region: str = "us-east-1"):
        self._ddb = ddb
        self.table = table or os.environ.get("STORY_RATE_LIMIT_TABLE", "")
        self.region = region or os.environ.get("AWS_REGION", "us-east-1")

    def _c(self):
        if self._ddb is None:
            import boto3
            self._ddb = boto3.client("dynamodb", region_name=self.region)
        return self._ddb

    def check_and_consume(self, story_user_id: str, cls: str, *, consume: bool = True) -> ThrottleDecision:
        """Increment the user's counter for this class+window. Returns a decision. Raises on store error
        (the caller maps that to the per-class fail-open/closed policy)."""
        limit = _limit_for(cls)
        win = _window_seconds()
        now = int(time.time())
        window_start = now - (now % win)
        retry_after = (window_start + win) - now
        if not consume:
            # Idempotent duplicate submit: do not consume, always allow.
            return ThrottleDecision(allowed=True, cls=cls, retry_after=retry_after)
        sk = f"rl#{cls}#{window_start}"
        ttl = window_start + win * 3  # self-expire a few windows out
        try:
            self._c().update_item(
                TableName=self.table,
                Key={"story_user_id": {"S": story_user_id}, "rl_key": {"S": sk}},
                UpdateExpression="ADD #c :one SET #t = :ttl",
                ConditionExpression="attribute_not_exists(#c) OR #c < :limit",
                ExpressionAttributeNames={"#c": "count", "#t": "ttl"},
                ExpressionAttributeValues={":one": {"N": "1"}, ":ttl": {"N": str(ttl)},
                                           ":limit": {"N": str(limit)}},
            )
            return ThrottleDecision(allowed=True, cls=cls, retry_after=retry_after)
        except Exception as e:  # noqa: BLE001
            name = type(e).__name__
            if "ConditionalCheckFailed" in name or "ConditionalCheckFailed" in str(e):
                # Over the allowance for this window.
                return ThrottleDecision(allowed=False, cls=cls, limited=True, retry_after=retry_after)
            raise  # genuine store error -> caller applies fail-open/closed policy


def _metric(request: Request, name: str, cls: str) -> None:
    """Best-effort low-cardinality EMF metric via the app's observability hook (dimension: class only)."""
    emit = getattr(request.app.state, "_throttle_metric_hook", None)
    if emit is not None:
        try:
            emit(name, cls)
        except Exception:  # noqa: BLE001
            pass


def classify(method: str, template_path: str) -> Optional[str]:
    return ROUTE_CLASS.get((method.upper(), template_path))


def _matched_template(request: Request) -> Optional[str]:
    """The FastAPI route template (e.g. /v1/stories/{story_id}) for this request, or None."""
    route = request.scope.get("route")
    return getattr(route, "path", None) if route else None


async def throttle_middleware(request: Request, call_next):
    """Runs AFTER the auth boundary. Skips public/unclassified routes. For a classified route it checks the
    per-user counter and applies: observe mode -> never reject (emit WouldThrottle); enforce mode -> 429 on a
    real over-limit. A limiter STORE error applies the per-class policy: expensive -> 503+Retry-After (fail
    closed) even in observe mode; safe -> fail open (allow)."""
    path = request.url.path
    if path in THROTTLE_EXEMPT_PATHS:
        return await call_next(request)

    template = _matched_template(request) or path
    cls = classify(request.method, template)
    if cls is None:
        # Unclassified route: allow, but this is what the route-coverage test forbids for customer endpoints.
        return await call_next(request)

    principal = getattr(request.state, "principal", None)
    # No authenticated user (dev legacy window) -> nothing to key on; skip per-user throttle.
    if principal is None or getattr(principal, "is_legacy", False) or not getattr(principal, "story_user_id", None):
        return await call_next(request)

    # Throttling is a no-op until a rate-limit table is configured (unprovisioned envs, dev, unit tests that
    # do not inject a limiter). This keeps the middleware inert before Phase 3 is deployed — it never breaks
    # a request just by being wired in.
    configured_table = os.environ.get("STORY_RATE_LIMIT_TABLE", "")
    injected = getattr(request.app.state, "_rate_limiter", None)
    if injected is None and not configured_table:
        return await call_next(request)

    limiter: RateLimiter = injected or RateLimiter()
    mode = throttle_mode()
    policy = CLASS_POLICIES[cls]
    try:
        decision = limiter.check_and_consume(principal.story_user_id, cls)
    except Exception:  # noqa: BLE001 — genuine store outage
        _metric(request, "ThrottleStoreError", cls)
        if policy.expensive:
            # Fail CLOSED for expensive ops — even in observe mode (owner amendment 1 + 5). 503, not 429:
            # this is an infrastructure failure, not the user exceeding an allowance.
            retry = _window_seconds()
            return JSONResponse(status_code=503,
                                headers={"Retry-After": str(retry)},
                                content={"error": "rate_limiter_unavailable", "class": cls,
                                         "retry_after_seconds": retry})
        # Fail OPEN for safe ops (reads, polling, metadata writes, presign, download).
        return await call_next(request)

    if decision.limited:
        if mode == "enforce":
            _metric(request, "ThrottleBlocked", cls)
            return JSONResponse(status_code=429,
                                headers={"Retry-After": str(decision.retry_after)},
                                content={"error": "rate_limited", "class": cls,
                                         "retry_after_seconds": decision.retry_after})
        # Observe mode: record what WOULD have been blocked, but let it through.
        _metric(request, "WouldThrottle", cls)
        return await call_next(request)

    _metric(request, "ThrottleAllowed", cls)
    return await call_next(request)
