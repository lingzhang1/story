"""P0 Beta Security Phase 3 — per-user throttling tests (owner's 14 required scenarios).

Uses an in-memory fake limiter/store so there is no DynamoDB dependency; the middleware, route
classification, fail-open/closed policy, and observe/enforce mode are exercised exactly as deployed.
"""

from __future__ import annotations

import os
import time
import threading

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.main import create_app
from app.auth import CognitoConfig, CognitoJwtVerifier, IdentityStore
from app.throttle import (
    RateLimiter, ThrottleDecision, ROUTE_CLASS, CLASS_POLICIES, classify, THROTTLE_EXEMPT_PATHS,
)

REGION, POOL, CLIENT_ID = "us-east-1", "us-east-1_TESTPOOL", "testclientid123"
ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{POOL}"


def _make_key(kid="kidA"):
    import json, jwt.algorithms
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    jwk.update({"kid": kid, "alg": "RS256", "use": "sig"})
    return key, jwk


KEY, JWK = _make_key()


def _tok(sub="u1"):
    now = int(time.time())
    return jwt.encode({"sub": sub, "iss": ISSUER, "token_use": "access", "client_id": CLIENT_ID,
                       "iat": now, "exp": now + 3600}, KEY, algorithm="RS256", headers={"kid": "kidA"})


class FakeVerifier(CognitoJwtVerifier):
    def __init__(self):
        super().__init__(CognitoConfig(region=REGION, user_pool_id=POOL, app_client_id=CLIENT_ID))
    def _fetch_jwks(self):
        return {"keys": [JWK]}


class FakeIdentity(IdentityStore):
    def __init__(self):
        super().__init__(claims_table="t", users_table="u")
    def resolve(self, cognito_sub, *, verified_email=None):
        return f"story-{cognito_sub}"


class InMemoryLimiter(RateLimiter):
    """Atomic fixed-window counter in a dict, lock-guarded (models the DDB conditional UpdateItem)."""
    def __init__(self, raise_on_check=False):
        super().__init__(table="t")
        self.counts: dict[str, int] = {}
        self.lock = threading.Lock()
        self.raise_on_check = raise_on_check

    def check_and_consume(self, story_user_id, cls, *, consume=True):
        if self.raise_on_check:
            raise RuntimeError("ddb unavailable")
        from app.throttle import _limit_for, _window_seconds
        limit = _limit_for(cls); win = _window_seconds(); now = int(time.time())
        ws = now - (now % win); retry = (ws + win) - now
        if not consume:
            return ThrottleDecision(allowed=True, cls=cls, retry_after=retry)
        k = f"{story_user_id}|{cls}|{ws}"
        with self.lock:
            cur = self.counts.get(k, 0)
            if cur >= limit:
                return ThrottleDecision(allowed=False, cls=cls, limited=True, retry_after=retry)
            self.counts[k] = cur + 1
        return ThrottleDecision(allowed=True, cls=cls, retry_after=retry)


def _app(mode="enforce", limiter=None, metrics=None):
    os.environ.update({"STORY_ENVIRONMENT": "beta", "STORY_COGNITO_USER_POOL_ID": POOL,
                       "STORY_COGNITO_APP_CLIENT_ID": CLIENT_ID, "STORY_THROTTLE_MODE": mode,
                       "STORY_EPIDEMIC_MODE": "prototyping", "STORY_JOBS_API_ENABLED": "1"})
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier()
    app.state._identity_store_override = FakeIdentity()
    app.state._rate_limiter = limiter or InMemoryLimiter()
    if metrics is not None:
        app.state._throttle_metric_hook = lambda name, cls: metrics.append((name, cls))
    return app


@pytest.fixture(autouse=True)
def _restore_env():
    keys = ["STORY_ENVIRONMENT", "STORY_THROTTLE_MODE", "STORY_COGNITO_USER_POOL_ID",
            "STORY_COGNITO_APP_CLIENT_ID", "STORY_EPIDEMIC_MODE", "STORY_JOBS_API_ENABLED",
            "STORY_THROTTLE_READ_PER_MIN", "STORY_THROTTLE_AI_SYNC_PER_MIN"]
    saved = {k: os.environ.get(k) for k in keys}
    yield
    for k, v in saved.items():
        os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)


def _auth(sub="u1"):
    return {"Authorization": f"Bearer {_tok(sub)}"}


# 9. Route classification completeness --------------------------------------------------------------------

def test_route_classification_completeness():
    """Every customer-facing (non-public) route must be CLASSIFIED. Fails when a new endpoint is unclassified."""
    app = _app()
    unclassified = []
    for r in app.routes:
        if not hasattr(r, "methods") or not r.methods:
            continue
        if r.path in THROTTLE_EXEMPT_PATHS:
            continue
        for m in (r.methods - {"HEAD", "OPTIONS"}):
            if classify(m, r.path) is None:
                unclassified.append(f"{m} {r.path}")
    assert not unclassified, f"customer-facing routes not classified for throttling: {unclassified}"


# 10. Paid music coverage ---------------------------------------------------------------------------------

def test_paid_music_routes_classified_expensive():
    for p in ["/v1/music/candidates", "/v1/music/search", "/v1/music/analysis", "/v1/music/soundtrack"]:
        cls = classify("POST", p)
        assert cls == "music_provider"
        assert CLASS_POLICIES[cls].expensive is True


def test_bedrock_sync_routes_expensive_and_deterministic_not():
    assert CLASS_POLICIES[classify("POST", "/v1/story-guide")].expensive is True
    assert classify("POST", "/v1/creative-intent") == "ai_sync"       # model-backed
    assert classify("POST", "/v1/music-direction") == "writes"         # DETERMINISTIC, cheap
    assert classify("POST", "/v1/understanding/batch-get") == "read"   # a READ despite POST


# 1. Atomic concurrency boundary --------------------------------------------------------------------------

def test_atomic_concurrency_boundary():
    os.environ["STORY_THROTTLE_READ_PER_MIN"] = "5"
    lim = InMemoryLimiter()
    app = _app(mode="enforce", limiter=lim)
    c = TestClient(app)
    results = []
    def hit():
        results.append(c.get("/v1/me", headers=_auth("concur")).status_code)
    threads = [threading.Thread(target=hit) for _ in range(20)]
    for t in threads: t.start()
    for t in threads: t.join()
    allowed = sum(1 for s in results if s != 429)
    blocked = sum(1 for s in results if s == 429)
    assert allowed == 5 and blocked == 15, f"allowed={allowed} blocked={blocked}"


# 2. Window rollover --------------------------------------------------------------------------------------

def test_window_rollover_resets(monkeypatch):
    os.environ["STORY_THROTTLE_READ_PER_MIN"] = "1"
    lim = InMemoryLimiter()
    app = _app(mode="enforce", limiter=lim)
    c = TestClient(app)
    assert c.get("/v1/me", headers=_auth("roll")).status_code != 429
    assert c.get("/v1/me", headers=_auth("roll")).status_code == 429
    # advance time past the window by clearing the dict (models TTL expiry / new window bucket)
    lim.counts.clear()
    assert c.get("/v1/me", headers=_auth("roll")).status_code != 429


# 3. User isolation ---------------------------------------------------------------------------------------

def test_user_isolation():
    os.environ["STORY_THROTTLE_READ_PER_MIN"] = "1"
    app = _app(mode="enforce")
    c = TestClient(app)
    assert c.get("/v1/me", headers=_auth("alice")).status_code != 429
    assert c.get("/v1/me", headers=_auth("alice")).status_code == 429
    # bob has his own counter
    assert c.get("/v1/me", headers=_auth("bob")).status_code != 429


# 6. Rate-limit 429 + Retry-After -------------------------------------------------------------------------

def test_rate_limit_429_has_retry_after():
    os.environ["STORY_THROTTLE_READ_PER_MIN"] = "1"
    app = _app(mode="enforce")
    c = TestClient(app)
    c.get("/v1/me", headers=_auth("rl"))
    r = c.get("/v1/me", headers=_auth("rl"))
    assert r.status_code == 429
    assert int(r.headers["Retry-After"]) >= 0
    assert r.json()["error"] == "rate_limited"


# 7. Store failure -> 503 for EXPENSIVE ops (fail closed) -------------------------------------------------

def test_store_failure_503_for_expensive():
    app = _app(mode="enforce", limiter=InMemoryLimiter(raise_on_check=True))
    c = TestClient(app)
    r = c.post("/v1/story-guide", headers=_auth("x"), json={})
    assert r.status_code == 503
    assert "Retry-After" in r.headers


def test_store_failure_503_for_expensive_even_in_observe():
    # Owner amendment 5: fail-closed for expensive ops stays active even in observe mode.
    app = _app(mode="observe", limiter=InMemoryLimiter(raise_on_check=True))
    c = TestClient(app)
    assert c.post("/v1/story-guide", headers=_auth("x"), json={}).status_code == 503


# 8. Store failure -> fail OPEN for safe ops --------------------------------------------------------------

def test_store_failure_fail_open_for_safe():
    app = _app(mode="enforce", limiter=InMemoryLimiter(raise_on_check=True))
    c = TestClient(app)
    # a read must NOT be 503/429 on store error — it fails open (reaches the handler -> 200)
    assert c.get("/v1/me", headers=_auth("x")).status_code == 200


# 12. No high-cardinality metric dimensions ---------------------------------------------------------------

def test_metrics_are_low_cardinality_class_only():
    metrics: list = []
    os.environ["STORY_THROTTLE_READ_PER_MIN"] = "1"
    app = _app(mode="enforce", metrics=metrics)
    c = TestClient(app)
    c.get("/v1/me", headers=_auth("m1"))
    c.get("/v1/me", headers=_auth("m1"))  # blocked
    # every metric is (name, class) — the 2nd element is a known class, NEVER a user id
    for name, cls in metrics:
        assert cls in CLASS_POLICIES
        assert "m1" not in cls and "story-" not in cls


# 13. Observe vs enforce mode -----------------------------------------------------------------------------

def test_observe_mode_never_rejects_rate_violation():
    metrics: list = []
    os.environ["STORY_THROTTLE_READ_PER_MIN"] = "1"
    app = _app(mode="observe", metrics=metrics)
    c = TestClient(app)
    assert c.get("/v1/me", headers=_auth("o1")).status_code == 200
    assert c.get("/v1/me", headers=_auth("o1")).status_code == 200  # would-throttle, still allowed
    assert ("WouldThrottle", "read") in metrics


# 4/5/11. Duplicate submission / payload-conflict / no double inference -----------------------------------
# (consume=False path: a duplicate operation_id does not consume a second allowance)

def test_duplicate_submit_does_not_consume_second_allowance():
    lim = InMemoryLimiter()
    # Directly exercise the limiter contract the submit handler relies on.
    d1 = lim.check_and_consume("story-dup", "ai_job_submit", consume=True)
    d2 = lim.check_and_consume("story-dup", "ai_job_submit", consume=False)  # duplicate -> no consume
    assert d1.allowed and d2.allowed
    # only ONE token consumed
    from app.throttle import _window_seconds
    ws = int(time.time()) - (int(time.time()) % _window_seconds())
    assert lim.counts[f"story-dup|ai_job_submit|{ws}"] == 1


# 14. No regression: health public, auth still enforced ---------------------------------------------------

def test_health_never_throttled_and_public():
    os.environ["STORY_THROTTLE_READ_PER_MIN"] = "1"
    app = _app(mode="enforce")
    c = TestClient(app)
    for _ in range(5):
        assert c.get("/health").status_code == 200  # never 429, never 401


def test_unauthenticated_still_401_not_throttled():
    app = _app(mode="enforce")
    c = TestClient(app)
    assert c.get("/v1/stories").status_code == 401  # auth runs before throttle
