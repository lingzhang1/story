"""P0 Beta Security Phase 1 — central deny-by-default authentication boundary.

Verifies the ONE auth boundary (app.auth.auth_boundary middleware) so that:
  * every non-allowlisted route is protected regardless of its per-route dependency (req 1, 7, 10);
  * beta/gamma/production fail closed regardless of STORY_REQUIRE_AUTH (req 8);
  * development may retain the optional-auth window (req 9);
  * the two previously-unauthenticated routes (POST /v1/stories, POST /v1/music-direction) are closed (req 5);
  * the JWT rejection matrix holds: missing / malformed / expired / wrong-issuer / wrong-client (req 11);
  * a valid request resolves identity exactly once — no duplicate verify/lookup (req 12);
  * docs are public only in development (req 4).

Uses the injected verifier + identity store (no network, no crypto service).
"""

from __future__ import annotations

import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.main import create_app
from app.auth import CognitoConfig, CognitoJwtVerifier, IdentityStore, is_public_path

REGION = "us-east-1"
POOL = "us-east-1_TESTPOOL"
CLIENT_ID = "testclientid123"
ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{POOL}"

ALWAYS_PUBLIC = {"/health"}
DOCS = {"/docs", "/redoc", "/openapi.json", "/docs/oauth2-redirect"}


def _make_key(kid):
    import json
    import jwt.algorithms
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    jwk.update({"kid": kid, "alg": "RS256", "use": "sig"})
    return key, jwk


KEY, JWK = _make_key("kidA")


def _tok(**kw):
    now = int(time.time())
    claims = {"sub": kw.get("sub", "u1"), "iss": kw.get("iss", ISSUER),
              "token_use": kw.get("token_use", "access"), "client_id": kw.get("client_id", CLIENT_ID),
              "iat": now, "exp": now + kw.get("exp_delta", 3600)}
    return jwt.encode(claims, KEY, algorithm="RS256", headers={"kid": kw.get("kid", "kidA")})


class FakeVerifier(CognitoJwtVerifier):
    def __init__(self):
        super().__init__(CognitoConfig(region=REGION, user_pool_id=POOL, app_client_id=CLIENT_ID))
        self._static = {"kidA": JWK}

    def _fetch_jwks(self):
        return {"keys": list(self._static.values())}


class CountingIdentityStore(IdentityStore):
    """Resolves cognito_sub -> deterministic story_user_id, counting resolve() calls (verify-once check)."""
    def __init__(self):
        super().__init__(claims_table="t", users_table="u")
        self.calls = 0

    def resolve(self, cognito_sub: str, *, verified_email=None) -> str:
        self.calls += 1
        return f"story-{cognito_sub}"


def _app(env="beta", require="0"):
    import os
    os.environ["STORY_JOBS_API_ENABLED"] = "1"
    os.environ["STORY_ENVIRONMENT"] = env
    os.environ["STORY_REQUIRE_AUTH"] = require
    os.environ["STORY_EPIDEMIC_MODE"] = "prototyping"
    os.environ["STORY_COGNITO_USER_POOL_ID"] = POOL
    os.environ["STORY_COGNITO_APP_CLIENT_ID"] = CLIENT_ID
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier()
    app.state._identity_store_override = CountingIdentityStore()
    return app


@pytest.fixture(autouse=True)
def _restore_env():
    """Snapshot/restore the env vars these tests mutate so running this module does not leak
    STORY_ENVIRONMENT=beta (etc.) into sibling test modules (order-independent suite)."""
    import os
    keys = ["STORY_ENVIRONMENT", "STORY_REQUIRE_AUTH", "STORY_JOBS_API_ENABLED",
            "STORY_EPIDEMIC_MODE", "STORY_COGNITO_USER_POOL_ID", "STORY_COGNITO_APP_CLIENT_ID",
            "STORY_DOCS_PUBLIC"]
    saved = {k: os.environ.get(k) for k in keys}
    try:
        yield
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


# --- req 10: route-introspection — every non-public route is protected by the boundary -------------------

def test_every_non_public_route_is_denied_without_a_token_in_beta():
    import re
    app = _app(env="beta")
    client = TestClient(app)
    offenders = []
    for r in app.routes:
        if not hasattr(r, "methods") or not r.methods:
            continue
        path = r.path
        if path in ALWAYS_PUBLIC or path in DOCS:
            continue
        concrete = re.sub(r"\{[^}]+\}", "x", path) if "{" in path else path
        for method in (r.methods - {"HEAD", "OPTIONS"}):
            resp = client.request(method, concrete, json={})
            if resp.status_code != 401:
                offenders.append(f"{method} {path} -> {resp.status_code}")
    assert not offenders, f"non-public routes NOT denied unauthenticated in beta: {offenders}"


# --- req 5: the two previously-unauthenticated routes are now closed -------------------------------------

@pytest.mark.parametrize("path", ["/v1/stories", "/v1/music-direction"])
def test_previously_unauthenticated_routes_now_require_auth(path):
    c = TestClient(_app(env="beta"))
    r = c.post(path, json={"title": "x", "raw_text": "x", "creative_intent": {}})
    assert r.status_code == 401


# --- req 8/9: fail-closed regardless of flag for real envs; dev keeps optional window --------------------

@pytest.mark.parametrize("env", ["beta", "gamma", "production"])
def test_real_envs_fail_closed_even_with_require_auth_0(env):
    c = TestClient(_app(env=env, require="0"))
    assert c.post("/v1/stories", json={"title": "x", "raw_text": "x"}).status_code == 401
    assert c.get("/v1/stories").status_code == 401


def test_development_optional_window_allows_missing_token():
    c = TestClient(_app(env="development", require="0"))
    r = c.post("/v1/creative-intent", json={"raw_text": "x"})
    assert r.status_code != 401


def test_development_require_auth_1_fails_closed():
    c = TestClient(_app(env="development", require="1"))
    assert c.post("/v1/stories", json={"title": "x", "raw_text": "x"}).status_code == 401


# --- req 11: JWT rejection matrix -----------------------------------------------------------------------

def test_valid_token_is_accepted_on_a_protected_route():
    c = TestClient(_app(env="beta"))
    r = c.get("/v1/me", headers={"Authorization": f"Bearer {_tok(sub='alice')}"})
    assert r.status_code == 200
    assert r.json()["story_user_id"] == "story-alice"


@pytest.mark.parametrize("hdr,expect", [
    (None, 401),
    ("Bearer not.a.jwt", 401),
])
def test_missing_or_malformed_token_rejected(hdr, expect):
    c = TestClient(_app(env="beta"))
    headers = {"Authorization": hdr} if hdr else {}
    assert c.get("/v1/me", headers=headers).status_code == expect


def test_expired_token_rejected():
    c = TestClient(_app(env="beta"))
    assert c.get("/v1/me", headers={"Authorization": f"Bearer {_tok(exp_delta=-5)}"}).status_code == 401


def test_wrong_issuer_rejected():
    c = TestClient(_app(env="beta"))
    bad = _tok(iss="https://cognito-idp.us-east-1.amazonaws.com/us-east-1_WRONGPOOL")
    assert c.get("/v1/me", headers={"Authorization": f"Bearer {bad}"}).status_code == 401


def test_wrong_client_rejected():
    c = TestClient(_app(env="beta"))
    bad = _tok(client_id="someotherclient")
    assert c.get("/v1/me", headers={"Authorization": f"Bearer {bad}"}).status_code == 401


def test_id_token_rejected_only_access_tokens():
    c = TestClient(_app(env="beta"))
    bad = _tok(token_use="id")
    assert c.get("/v1/me", headers={"Authorization": f"Bearer {bad}"}).status_code == 401


# --- req 12: verify-once — a valid request resolves identity exactly once --------------------------------

def test_valid_request_resolves_identity_exactly_once():
    app = _app(env="beta")
    c = TestClient(app)
    store = app.state._identity_store_override
    before = store.calls
    r = c.get("/v1/me", headers={"Authorization": f"Bearer {_tok(sub='once')}"})
    assert r.status_code == 200
    assert store.calls - before == 1


# --- req 2: account status + beta eligibility enforced beyond JWT validity ------------------------------

class StatusIdentityStore(IdentityStore):
    """Resolves to a fixed id but runs the REAL _enforce_status against injected account/beta status."""
    def __init__(self, account_status="active", beta_status="eligible"):
        super().__init__(claims_table="t", users_table="u")
        self._as = account_status
        self._bs = beta_status

    def _read_claim(self, claim_key):
        return "story-fixed"  # account already exists -> resolve() takes the _enforce_status path

    def _account_status(self, story_user_id):
        return self._as, self._bs


def _app_with_store(store, env="beta"):
    import os
    os.environ["STORY_ENVIRONMENT"] = env
    os.environ["STORY_REQUIRE_AUTH"] = "0"
    os.environ["STORY_COGNITO_USER_POOL_ID"] = POOL
    os.environ["STORY_COGNITO_APP_CLIENT_ID"] = CLIENT_ID
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier()
    app.state._identity_store_override = store
    return app


def test_valid_jwt_but_suspended_account_rejected():
    c = TestClient(_app_with_store(StatusIdentityStore(account_status="suspended")))
    r = c.get("/v1/me", headers={"Authorization": f"Bearer {_tok(sub='sus')}"})
    assert r.status_code == 403


def test_valid_jwt_but_beta_ineligible_rejected_in_beta():
    c = TestClient(_app_with_store(StatusIdentityStore(beta_status="revoked")))
    r = c.get("/v1/me", headers={"Authorization": f"Bearer {_tok(sub='rev')}"})
    assert r.status_code == 403


def test_invited_beta_user_allowed():
    c = TestClient(_app_with_store(StatusIdentityStore(beta_status="invited")))
    r = c.get("/v1/me", headers={"Authorization": f"Bearer {_tok(sub='inv')}"})
    assert r.status_code == 200


# --- req 4: docs gating ----------------------------------------------------------------------------------

def test_docs_disabled_in_beta():
    c = TestClient(_app(env="beta"))
    assert c.get("/openapi.json").status_code in (404, 401)
    assert c.get("/docs").status_code in (404, 401)


def test_docs_public_in_development():
    c = TestClient(_app(env="development"))
    assert c.get("/openapi.json").status_code == 200
    assert c.get("/health").status_code == 200
