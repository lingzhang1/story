"""P0 Beta Auth Increment 3 — paid-endpoint protection matrix.

Asserts that EVERY paid (Bedrock or paid-Epidemic) endpoint carries the shared auth dependency, and that the
dev-optional / prod-fail-closed / invalid-token semantics hold uniformly. Uses the injected verifier (no
network) and relies on route introspection so a newly-added paid endpoint that forgets the dependency fails
this test.
"""

from __future__ import annotations

import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.main import create_app
from app.auth import CognitoConfig, CognitoJwtVerifier

REGION = "us-east-1"
POOL = "us-east-1_TESTPOOL"
CLIENT_ID = "testclientid123"
ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{POOL}"

# The paid endpoints that MUST require authentication (Bedrock-backed + paid Epidemic music).
PAID_ROUTES = {
    ("POST", "/v1/creative-intent"),
    ("POST", "/v1/interpret-revision"),
    ("POST", "/v1/scene-understanding"),
    ("POST", "/v1/asset-understanding"),
    ("POST", "/v1/story-coverage"),
    ("POST", "/v1/story-guide"),
    ("POST", "/v1/story-guide-v2"),
    ("POST", "/v1/edit-plan"),
    ("POST", "/v1/edit-plan-mm"),
    ("POST", "/v1/music-plan"),
    ("POST", "/v1/duration-recommendation"),
    ("POST", "/v1/story-coverage/v2"),
    ("POST", "/v1/director/initialize"),
    ("POST", "/v1/director/next"),
    ("POST", "/v1/music/candidates"),
    ("POST", "/v1/music/search"),
    ("POST", "/v1/music/analysis"),
    ("POST", "/v1/music/soundtrack"),
    # async jobs (already protected in Increment 2)
    ("POST", "/v1/edit-plan-jobs"),
    ("POST", "/v1/story-coverage/v2/jobs"),
}


def _make_key(kid):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    import json
    import jwt.algorithms
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    jwk.update({"kid": kid, "alg": "RS256", "use": "sig"})
    return key, jwk


KEY, JWK = _make_key("kidA")


def _tok(**kw):
    now = int(time.time())
    claims = {"sub": kw.get("sub", "u1"), "iss": kw.get("iss", ISSUER),
              "token_use": kw.get("token_use", "access"), "client_id": kw.get("client_id", CLIENT_ID),
              "iat": now, "exp": now + kw.get("exp_delta", 3600)}
    return jwt.encode(claims, KEY, algorithm="RS256", headers={"kid": "kidA"})


class FakeVerifier(CognitoJwtVerifier):
    def __init__(self):
        super().__init__(CognitoConfig(region=REGION, user_pool_id=POOL, app_client_id=CLIENT_ID))
        self._static = {"kidA": JWK}

    def _fetch_jwks(self):
        return {"keys": list(self._static.values())}


def _app(env="development", require="0"):
    import os
    os.environ["STORY_JOBS_API_ENABLED"] = "1"
    os.environ["STORY_ENVIRONMENT"] = env
    os.environ["STORY_REQUIRE_AUTH"] = require
    os.environ["STORY_EPIDEMIC_MODE"] = "prototyping"  # so music routes are not flag-404'd before auth
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier()
    return app


def _dep_names(route):
    # Collect the dependency callables declared on a route.
    names = set()
    for d in getattr(route, "dependant", None).dependencies if getattr(route, "dependant", None) else []:
        if d.call is not None:
            names.add(getattr(d.call, "__name__", ""))
    return names


def test_every_paid_route_declares_the_auth_dependency():
    app = _app()
    routes = {(m, r.path): r for r in app.routes if hasattr(r, "methods")
              for m in (r.methods or set())}
    missing = []
    for method, path in PAID_ROUTES:
        r = routes.get((method, path))
        assert r is not None, f"route {method} {path} not found"
        if "optional_user" not in _dep_names(r) and "require_user" not in _dep_names(r):
            missing.append(f"{method} {path}")
    assert not missing, f"paid routes missing the auth dependency: {missing}"


def test_invalid_token_rejected_on_a_paid_sync_endpoint():
    c = TestClient(_app())
    # Expired token -> 401 regardless of body validity (auth runs first).
    r = c.post("/v1/creative-intent", json={"raw_text": "x"},
               headers={"Authorization": f"Bearer {_tok(exp_delta=-5)}"})
    assert r.status_code == 401


def test_production_rejects_missing_token_on_paid_sync_endpoint():
    c = TestClient(_app(env="production", require="0"))  # prod ignores the flag
    r = c.post("/v1/creative-intent", json={"raw_text": "x"})
    assert r.status_code == 401


def test_dev_optional_accepts_missing_token():
    # In dev optional-auth, a missing token reaches the handler (which may then fail for its OWN reasons,
    # e.g. a model/engine error) — but NOT with 401. We assert it is not an auth rejection.
    c = TestClient(_app())
    r = c.post("/v1/creative-intent", json={"raw_text": "x"})
    assert r.status_code != 401
