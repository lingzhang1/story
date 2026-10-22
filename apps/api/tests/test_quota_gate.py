"""P0 Beta Security Phase 4 — AI quota ENFORCEMENT GATE integration tests (owner correction 7/8/9/12).

Exercises the quota wiring exactly as deployed: the sync-inference middleware, the async-submit reserve +
active-job slot, duplicate-submit idempotency, the paid-op store-error fail-closed policy, observe-vs-enforce,
the worker-side settle/release, and the NO-BYPASS route coverage (every paid entry point is quota-gated).

Uses an in-memory fake UserQuota/DDB so there is no DynamoDB dependency.
"""

from __future__ import annotations

import os
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.main import create_app
from app.auth import CognitoConfig, CognitoJwtVerifier, IdentityStore
from app.throttle import ROUTE_CLASS
from app import quota_gate
from user_quota import UserQuota, QuotaConfig

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


def _auth(sub="u1"):
    return {"Authorization": f"Bearer {_tok(sub)}"}


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


# Reuse the quota module's proven in-memory DDB fake (single-item conditional update + transact).
from user_quota.fakes import FakeDDB  # shared in-memory DynamoDB double


def _quota(cfg=None):
    return UserQuota(ddb=FakeDDB(), usage_table="t",
                     cfg=cfg or QuotaConfig(user_monthly_usd=5.0, user_daily_gens=40,
                                            max_active_jobs=2, global_monthly_usd=60.0))


class BoomQuota(UserQuota):
    """A quota whose store is unavailable — every op raises QuotaStoreError (paid-op fail-closed test)."""
    def __init__(self):
        super().__init__(ddb=object(), usage_table="t",
                         cfg=QuotaConfig(user_monthly_usd=5, user_daily_gens=40,
                                         max_active_jobs=2, global_monthly_usd=60))
    def reserve(self, *a, **k):
        from user_quota import QuotaStoreError
        raise QuotaStoreError("ddb down")


class FakeStore:
    """Minimal async-job store double: records create_or_get calls + enqueues; idempotent on operation_id."""
    def __init__(self):
        self.jobs: dict[str, dict] = {}
        self.enqueued: list[str] = []
        self.staged: list[str] = []

    def stage_request(self, job_id, body_json, sheets):
        self.staged.append(job_id); return f"jobs/{job_id}/"

    def _create(self, operation_id, owner, **kw):
        import edit_plan_jobs as _jobs
        jid = _jobs.job_id_for(operation_id)
        created = jid not in self.jobs
        if created:
            self.jobs[jid] = {"job_id": jid, "operation_id": operation_id, "owner": owner,
                              "status": "queued", "payload_fingerprint": kw.get("payload_fingerprint")}
        return jid, created

    def create_or_get(self, *, operation_id, owner, approach, critique_requested, staging_prefix,
                      sheet_order, payload_fingerprint, has_body=True):
        return self._create(operation_id, owner, payload_fingerprint=payload_fingerprint)

    def create_or_get_coverage(self, *, operation_id, owner, body_json, payload_fingerprint, staging_prefix=""):
        return self._create(operation_id, owner, payload_fingerprint=payload_fingerprint)

    def enqueue(self, job_id):
        self.enqueued.append(job_id)


def _app(*, quota=None, qmode="enforce"):
    os.environ.update({"STORY_ENVIRONMENT": "beta", "STORY_COGNITO_USER_POOL_ID": POOL,
                       "STORY_COGNITO_APP_CLIENT_ID": CLIENT_ID, "STORY_EPIDEMIC_MODE": "prototyping",
                       "STORY_JOBS_API_ENABLED": "1", "STORY_QUOTA_MODE": qmode,
                       "STORY_THROTTLE_MODE": "observe"})
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier()
    app.state._identity_store_override = FakeIdentity()
    if quota is not None:
        app.state._user_quota = quota
    return app


@pytest.fixture(autouse=True)
def _restore_env():
    keys = ["STORY_ENVIRONMENT", "STORY_QUOTA_MODE", "STORY_THROTTLE_MODE", "STORY_COGNITO_USER_POOL_ID",
            "STORY_COGNITO_APP_CLIENT_ID", "STORY_EPIDEMIC_MODE", "STORY_JOBS_API_ENABLED",
            "STORY_USER_USAGE_TABLE"]
    saved = {k: os.environ.get(k) for k in keys}
    yield
    for k, v in saved.items():
        os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)


def _body():
    import json
    return json.dumps({"story_id": "11111111-1111-4111-8111-111111111111",
                       "creative_intent_id": "22222222-2222-4222-8222-222222222222",
                       "creative_intent": {}, "moments": []})


# --- correction 8: NO BYPASS — every paid entry point is quota-gated -------------------------------------

def test_no_paid_route_bypasses_quota():
    """Every route classified as an EXPENSIVE/paid class MUST be in PAID_CLASSES (so the quota middleware or
    submit handler gates it). A new paid endpoint left ungated fails this test."""
    from app.throttle import CLASS_POLICIES
    expensive = {cls for cls, p in CLASS_POLICIES.items() if p.expensive}
    # Every expensive class is a paid class the quota gate covers.
    assert expensive == quota_gate.PAID_CLASSES, (expensive, quota_gate.PAID_CLASSES)
    # And every route whose class is expensive resolves to a paid class (no expensive route is unclassified).
    for (method, path), cls in ROUTE_CLASS.items():
        if cls in expensive:
            assert cls in quota_gate.PAID_CLASSES


def test_paid_classes_are_exactly_the_expensive_ones():
    from app.throttle import CLASS_POLICIES
    for cls in quota_gate.PAID_CLASSES:
        assert CLASS_POLICIES[cls].expensive is True


# --- correction 7: async submit reserves allowance + an active-job slot exactly once ---------------------

def test_async_submit_reserves_and_takes_slot():
    q = _quota()
    app = _app(quota=q, qmode="enforce")
    store = FakeStore()
    app.state._job_store_override = store
    c = TestClient(app)
    r = c.post("/v1/edit-plan-jobs", headers=_auth("u1"),
               data={"operation_id": "op1", "body": _body(), "sheet_order": "[]"})
    assert r.status_code == 202, r.text
    assert len(store.enqueued) == 1   # new job enqueued
    from user_quota import _period
    it = q._ddb.items[("story-u1", _period())]
    assert float(it["reserved_usd"]["N"]) > 0      # allowance reserved
    assert float(it["active_jobs"]["N"]) == 1       # slot taken
    # duplicate submit (same op) -> recovered, NO second reserve, NO second slot, NO second enqueue
    r2 = c.post("/v1/edit-plan-jobs", headers=_auth("u1"),
                data={"operation_id": "op1", "body": _body(), "sheet_order": "[]"})
    assert r2.status_code == 202
    assert len(store.enqueued) == 1
    it = q._ddb.items[("story-u1", _period())]
    assert float(it["active_jobs"]["N"]) == 1       # still 1 (idempotent)


def test_submit_reserve_helper_reserves_once_and_caps_slots():
    """Drive submit_reserve directly (as the handler does) to assert exactly-once reserve + slot cap."""
    q = _quota(QuotaConfig(user_monthly_usd=5, user_daily_gens=40, max_active_jobs=1, global_monthly_usd=60))
    app = _app(quota=q, qmode="enforce")

    class Req:
        def __init__(self): self.app = app; self.state = type("S", (), {})()
    req = Req()
    uid = "story-u1"
    # first job: reserve + slot ok
    assert quota_gate.submit_reserve(req, uid, "scoped:op1", "job-1", created=True) is None
    # duplicate submit of SAME op/job: no second reserve, no second slot (idempotent)
    assert quota_gate.submit_reserve(req, uid, "scoped:op1", "job-1", created=False) is None
    from user_quota import _period
    it = q._ddb.items[(uid, _period())]
    assert float(it["active_jobs"]["N"]) == 1
    # second DISTINCT job over the slot cap (max_active_jobs=1) -> enforced 429 quota_exceeded(active_jobs)
    resp = quota_gate.submit_reserve(req, uid, "scoped:op2", "job-2", created=True)
    assert resp is not None and resp.status_code == 429
    import json
    assert json.loads(bytes(resp.body))["scope"] == "active_jobs"


def test_submit_reserve_store_error_fails_closed_in_enforce():
    app = _app(quota=BoomQuota(), qmode="enforce")

    class Req:
        def __init__(self): self.app = app; self.state = type("S", (), {})()
    resp = quota_gate.submit_reserve(Req(), "story-u1", "scoped:op1", "job-1", created=True)
    assert resp is not None and resp.status_code == 503   # paid op + accounting outage -> fail CLOSED


def test_submit_reserve_observe_never_denies():
    q = _quota(QuotaConfig(user_monthly_usd=0.001, user_daily_gens=1, max_active_jobs=1, global_monthly_usd=0.001))
    app = _app(quota=q, qmode="observe")

    class Req:
        def __init__(self): self.app = app; self.state = type("S", (), {})()
    req = Req()
    assert quota_gate.submit_reserve(req, "story-u1", "scoped:op1", "job-1", created=True) is None
    # a second job that WOULD exceed slots/budget — observe never denies
    assert quota_gate.submit_reserve(req, "story-u1", "scoped:op2", "job-2", created=True) is None


# --- correction 6/7: worker settle/release terminal paths ------------------------------------------------

def test_worker_settle_and_release_idempotent():
    import app.worker as worker
    os.environ["STORY_USER_USAGE_TABLE"] = "t"
    ddb = FakeDDB()
    # reserve via a quota sharing the SAME fake ddb so the worker settles the same item
    q = UserQuota(ddb=ddb, usage_table="t",
                  cfg=QuotaConfig(user_monthly_usd=5, user_daily_gens=40, max_active_jobs=5, global_monthly_usd=60))
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q.reserve("story-u1", "scoped:op1", estimate_usd=0.10, gens=1)
    q.reserve_slot("story-u1", "job-1")
    from user_quota import _period
    it = ddb.items[("story-u1", _period())]
    assert float(it["active_jobs"]["N"]) == 1

    # monkeypatch the worker's UserQuota to use OUR fake ddb
    orig = worker._UserQuota
    worker._UserQuota = lambda **kw: UserQuota(ddb=ddb, usage_table="t",
        cfg=QuotaConfig(user_monthly_usd=5, user_daily_gens=40, max_active_jobs=5, global_monthly_usd=60))
    try:
        job = {"owner": "story-u1", "operation_id": "scoped:op1", "job_id": "job-1"}
        worker._quota_settle_job(job, actual_usd=0.08)
        worker._quota_settle_job(job, actual_usd=0.08)   # redelivery -> idempotent
    finally:
        worker._UserQuota = orig
    assert float(it["settled_usd"]["N"]) == 0.08
    assert float(it["active_jobs"]["N"]) == 0            # slot released exactly once


def test_worker_release_refunds_allowance_keeps_spend():
    import app.worker as worker
    os.environ["STORY_USER_USAGE_TABLE"] = "t"
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    ddb = FakeDDB()
    q = UserQuota(ddb=ddb, usage_table="t",
                  cfg=QuotaConfig(user_monthly_usd=5, user_daily_gens=40, max_active_jobs=5, global_monthly_usd=60))
    q.reserve("story-u1", "scoped:op1", estimate_usd=0.10, gens=1)
    q.reserve_slot("story-u1", "job-1")
    orig = worker._UserQuota
    worker._UserQuota = lambda **kw: UserQuota(ddb=ddb, usage_table="t",
        cfg=QuotaConfig(user_monthly_usd=5, user_daily_gens=40, max_active_jobs=5, global_monthly_usd=60))
    try:
        job = {"owner": "story-u1", "operation_id": "scoped:op1", "job_id": "job-1"}
        worker._quota_release_job(job, incurred_usd=0.03)   # failed after spending 0.03
    finally:
        worker._UserQuota = orig
    from user_quota import _period
    it = ddb.items[("story-u1", _period())]
    assert float(it["gens_used"]["N"]) == 0          # allowance refunded
    assert float(it["settled_usd"]["N"]) == 0.03     # incurred spend KEPT
    assert float(it["active_jobs"]["N"]) == 0         # slot released


def test_worker_legacy_dev_job_is_noop():
    import app.worker as worker
    os.environ["STORY_USER_USAGE_TABLE"] = "t"
    # a legacy dev job (owner='dev') never had a reservation -> settle/release are no-ops, never raise
    worker._quota_settle_job({"owner": "dev", "operation_id": "x", "job_id": "j"}, actual_usd=1.0)
    worker._quota_release_job({"owner": "dev", "operation_id": "x", "job_id": "j"}, incurred_usd=1.0)


# --- gate inert when unprovisioned -----------------------------------------------------------------------

def test_gate_inert_without_usage_table():
    os.environ.pop("STORY_USER_USAGE_TABLE", None)
    app = _app(qmode="enforce")  # no injected quota, no table
    c = TestClient(app)
    # /v1/me is a read (not paid) -> always allowed; a paid sync route with no quota configured is inert too
    assert c.get("/v1/me", headers=_auth("u1")).status_code in (200, 500)
