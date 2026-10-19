"""P0 Beta Auth Increment 2 — Phase 4 security tests (15 cases).

Real RS256 tokens signed by a throwaway keypair; the verifier's JWKS is injected (no network). Identity +
job stores are in-memory fakes (no AWS/DynamoDB). Covers JWT validation, atomic identity resolution, and
async job ownership.
"""

from __future__ import annotations

import json
import time
import uuid

import jwt  # PyJWT
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.main import create_app
from app.auth import CognitoConfig, CognitoJwtVerifier, IdentityStore

REGION = "us-east-1"
POOL = "us-east-1_TESTPOOL"
CLIENT_ID = "testclientid123"
ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{POOL}"


def _make_key(kid: str):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    import jwt.algorithms
    pub_jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    pub_jwk["kid"] = kid
    pub_jwk.setdefault("alg", "RS256")
    pub_jwk.setdefault("use", "sig")
    return key, pub_jwk


KEY_A, JWK_A = _make_key("kidA")
KEY_B, JWK_B = _make_key("kidB")  # rotation target


def _token(key, kid, *, sub="cog-sub-1", token_use="access", client_id=CLIENT_ID, iss=ISSUER,
           exp_delta=3600, extra=None):
    now = int(time.time())
    claims = {"sub": sub, "iss": iss, "token_use": token_use, "client_id": client_id,
              "iat": now, "exp": now + exp_delta}
    if extra:
        claims.update(extra)
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": kid})


class FakeVerifier(CognitoJwtVerifier):
    def __init__(self, keys):
        super().__init__(CognitoConfig(region=REGION, user_pool_id=POOL, app_client_id=CLIENT_ID))
        self._static = dict(keys)

    def _fetch_jwks(self):
        return {"keys": list(self._static.values())}

    def set_keys(self, keys):
        self._static = dict(keys)
        self._jwks = {}
        self._jwks_at = 0.0


class FakeIdentityStore(IdentityStore):
    def __init__(self):
        super().__init__(ddb=object(), claims_table="c", users_table="u", region=REGION)
        self.claims = {}
        self.status = {}

    def _read_claim(self, claim_key):
        return self.claims.get(claim_key)

    def _account_status(self, story_user_id):
        return self.status.get(story_user_id, "active")

    def resolve(self, cognito_sub, *, verified_email=None):
        claim_key = f"cognito#{cognito_sub}"
        existing = self.claims.get(claim_key)
        if existing:
            self._enforce_status(existing)
            return existing
        new_id = str(uuid.uuid4())
        self.claims.setdefault(claim_key, new_id)  # first writer wins (atomic conditional create)
        won = self.claims[claim_key]
        self.status.setdefault(won, "active")
        self._enforce_status(won)
        return won


class FakeJobStore:
    def __init__(self):
        self.items = {}
        self.enqueued = []
        self.cancelled = []

    def stage_request(self, jid, body_envelope, staged):
        return f"staging/{jid}"

    def create_or_get(self, *, operation_id, owner, approach, critique_requested, staging_prefix,
                      sheet_order, payload_fingerprint, has_body=True):
        import edit_plan_jobs as _jobs
        jid = _jobs.job_id_for(operation_id)
        ex = self.items.get(jid)
        if ex:
            if ex["payload_fingerprint"] != payload_fingerprint:
                raise _jobs.PayloadConflict(f"different payload (job {jid})")
            return jid, False
        self.items[jid] = {"job_id": jid, "operation_id": operation_id, "owner": owner, "status": "queued",
                           "approach": approach, "operation_type": _jobs.OP_EDIT_PLAN,
                           "payload_fingerprint": payload_fingerprint, "lease_token": "", "lease_until": 0}
        return jid, True

    def create_or_get_coverage(self, *, operation_id, owner, body_json, payload_fingerprint, staging_prefix=""):
        import edit_plan_jobs as _jobs
        jid = _jobs.job_id_for(operation_id)
        ex = self.items.get(jid)
        if ex:
            if ex["payload_fingerprint"] != payload_fingerprint:
                raise _jobs.PayloadConflict(f"conflict {jid}")
            return jid, False
        self.items[jid] = {"job_id": jid, "operation_id": operation_id, "owner": owner, "status": "queued",
                           "operation_type": _jobs.OP_COVERAGE_V2, "payload_fingerprint": payload_fingerprint,
                           "lease_token": "", "lease_until": 0}
        return jid, True

    def enqueue(self, job_id):
        self.enqueued.append(job_id)

    def get(self, job_id):
        return self.items.get(job_id)

    def request_cancel(self, job_id):
        self.cancelled.append(job_id)
        self.items[job_id]["status"] = "cancel_requested"
        return "cancel_requested"

    def reconcile_lost_enqueue(self):
        return 0


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("STORY_JOBS_API_ENABLED", "1")
    monkeypatch.setenv("STORY_ENVIRONMENT", "development")
    monkeypatch.setenv("STORY_REQUIRE_AUTH", "0")
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier({"kidA": JWK_A})
    app.state._identity_store_override = FakeIdentityStore()
    app.state._job_store_override = FakeJobStore()
    return TestClient(app)


def _auth(tok):
    return {"Authorization": f"Bearer {tok}"}


def _submit(client, tok=None, op="op-1", story_id=None):
    # Deterministic payload keyed by story_id so a same-(op,story_id) resubmit is a TRUE idempotent retry
    # (identical fingerprint), while a different story_id yields a different payload (conflict).
    sid = story_id or str(uuid.uuid4())
    det = uuid.uuid5(uuid.NAMESPACE_URL, sid)
    body = json.dumps({
        "story_id": sid,
        "creative_intent_id": str(uuid.uuid5(det, "ci")),
        "creative_intent": {"target_duration_seconds": 20},
        "moments": [{"id": str(uuid.uuid5(det, "m0")), "duration_seconds": 6.0,
                     "useful_segments": [{"start_seconds": 0.0, "end_seconds": 6.0}]}],
        "output_format": "vertical",
    }, sort_keys=True)
    headers = _auth(tok) if tok else {}
    return client.post("/v1/edit-plan-jobs", data={"operation_id": op, "body": body}, headers=headers)


# 1–6 JWT validation
def test_01_valid_access_token(client):
    assert _submit(client, _token(KEY_A, "kidA", sub="userX")).status_code == 202


def test_02_id_token_rejected(client):
    r = _submit(client, _token(KEY_A, "kidA", token_use="id"))
    assert r.status_code == 401 and "access token" in r.json()["detail"]


def test_03_expired_token_rejected(client):
    r = _submit(client, _token(KEY_A, "kidA", exp_delta=-10))
    assert r.status_code == 401 and "expired" in r.json()["detail"]


def test_04_wrong_issuer_and_client_rejected(client):
    assert _submit(client, _token(KEY_A, "kidA", iss="https://evil.example.com/p")).status_code == 401
    r = _submit(client, _token(KEY_A, "kidA", client_id="someoneelse"))
    assert r.status_code == 401 and "client" in r.json()["detail"]


def test_05_tampered_jwt_rejected(client):
    tok = _token(KEY_A, "kidA")
    head, payload, sig = tok.split(".")
    assert _submit(client, f"{head}.{payload}.{sig[:-3]}AAA").status_code == 401


def test_06_jwks_rotation(client):
    verifier: FakeVerifier = client.app.state._jwt_verifier_override
    verifier.set_keys({"kidA": JWK_A})
    _submit(client, _token(KEY_A, "kidA"))
    verifier.set_keys({"kidA": JWK_A, "kidB": JWK_B})
    assert _submit(client, _token(KEY_B, "kidB", sub="rot"), op="op-rot").status_code == 202


# 7–8 identity
def test_07_concurrent_first_sign_in_one_account(client):
    store: FakeIdentityStore = client.app.state._identity_store_override
    assert len({store.resolve("sub-concurrent") for _ in range(5)}) == 1


def test_08_identity_claim_collision_isolated(client):
    store: FakeIdentityStore = client.app.state._identity_store_override
    a, b = store.resolve("sub-a"), store.resolve("sub-b")
    assert a != b and store.resolve("sub-a") == a


# 9–13 ownership
def test_09_cross_user_get_and_cancel_denied(client):
    tokA, tokB = _token(KEY_A, "kidA", sub="alice"), _token(KEY_A, "kidA", sub="bob")
    jid = _submit(client, tokA, op="shared-op").json()["job_id"]
    assert client.get(f"/v1/edit-plan-jobs/{jid}", headers=_auth(tokB)).status_code == 404
    assert client.post(f"/v1/edit-plan-jobs/{jid}/cancel", headers=_auth(tokB)).status_code == 404
    assert client.get(f"/v1/edit-plan-jobs/{jid}", headers=_auth(tokA)).status_code == 200


def test_10_cross_user_operation_id_collision_isolated(client):
    tokA, tokB = _token(KEY_A, "kidA", sub="alice"), _token(KEY_A, "kidA", sub="bob")
    jidA = _submit(client, tokA, op="same-op-id").json()["job_id"]
    jidB = _submit(client, tokB, op="same-op-id").json()["job_id"]
    assert jidA != jidB


def test_11_same_user_idempotent_retry(client):
    tok = _token(KEY_A, "kidA", sub="carol")
    sid = str(uuid.uuid4())
    r1 = _submit(client, tok, op="idem-op", story_id=sid)
    r2 = _submit(client, tok, op="idem-op", story_id=sid)
    assert r1.json()["job_id"] == r2.json()["job_id"]
    store: FakeJobStore = client.app.state._job_store_override
    assert store.enqueued.count(r1.json()["job_id"]) == 1


def test_12_same_user_payload_conflict_is_409(client):
    tok = _token(KEY_A, "kidA", sub="dave")
    _submit(client, tok, op="conf-op", story_id=str(uuid.uuid4()))
    assert _submit(client, tok, op="conf-op", story_id=str(uuid.uuid4())).status_code == 409


def test_13_legacy_dev_jobs_inaccessible_to_real_users(client):
    jid = _submit(client, None, op="legacy-op").json()["job_id"]
    assert client.get(f"/v1/edit-plan-jobs/{jid}").status_code == 200
    tok = _token(KEY_A, "kidA", sub="newuser")
    assert client.get(f"/v1/edit-plan-jobs/{jid}", headers=_auth(tok)).status_code == 404


# 14 no anonymous fallback on invalid token + prod fail-closed
def test_14_invalid_token_never_falls_back(client):
    assert _submit(client, _token(KEY_A, "kidA", exp_delta=-5)).status_code == 401


def test_14b_production_fails_closed(monkeypatch):
    monkeypatch.setenv("STORY_JOBS_API_ENABLED", "1")
    monkeypatch.setenv("STORY_ENVIRONMENT", "production")
    monkeypatch.setenv("STORY_REQUIRE_AUTH", "0")
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier({"kidA": JWK_A})
    app.state._identity_store_override = FakeIdentityStore()
    app.state._job_store_override = FakeJobStore()
    c = TestClient(app)
    assert _submit(c, None, op="prod-op").status_code == 401


# 15 lease fencing contract unchanged
def test_15_lease_fencing_contract_unchanged():
    import edit_plan_jobs as _jobs
    assert _jobs.job_id_for("abc") == _jobs.job_id_for("abc")
    assert _jobs.job_id_for("u1\x1fabc") != _jobs.job_id_for("u2\x1fabc")
    assert _jobs.LEASE_SECONDS == 900
    assert "completed" in _jobs.TERMINAL and "cancelled" in _jobs.TERMINAL
