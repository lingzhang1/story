"""P1-E — /v1/music/favorites endpoint tests (saved catalog-track references).

Real RS256 tokens (throwaway keypair; JWKS injected, no network). The favorites store is backed by an
in-memory fake UnderstandingStore (the sentinel-key reuse) so account isolation + optimistic concurrency are
exercised without AWS. Mirrors test_media_api.py's auth harness.
"""
from __future__ import annotations

import json
import time

import jwt  # PyJWT
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.main import create_app
from app.auth import CognitoConfig, CognitoJwtVerifier, IdentityStore
from understanding_store.music_favorites import MusicFavoritesStore, FAVORITES_SENTINEL

REGION = "us-east-1"
POOL = "us-east-1_TESTPOOL"
CLIENT_ID = "testclientid123"
ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{POOL}"


def _make_key(kid: str):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    import jwt.algorithms
    pub = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    pub["kid"] = kid
    pub.setdefault("alg", "RS256")
    pub.setdefault("use", "sig")
    return key, pub


KEY_A, JWK_A = _make_key("kidA")


def _token(sub, *, exp_delta=3600):
    now = int(time.time())
    return jwt.encode({"sub": sub, "iss": ISSUER, "token_use": "access", "client_id": CLIENT_ID,
                       "iat": now, "exp": now + exp_delta}, KEY_A, algorithm="RS256", headers={"kid": "kidA"})


def _auth(sub):
    return {"Authorization": f"Bearer {_token(sub)}"}


class FakeVerifier(CognitoJwtVerifier):
    def __init__(self):
        super().__init__(CognitoConfig(region=REGION, user_pool_id=POOL, app_client_id=CLIENT_ID))

    def _fetch_jwks(self):
        return {"keys": [JWK_A]}


class FakeIdentityStore(IdentityStore):
    def __init__(self):
        super().__init__(ddb=object(), claims_table="c", users_table="u", region=REGION)
        self.claims = {}

    def resolve(self, cognito_sub, *, verified_email=None):
        return self.claims.setdefault(f"cognito#{cognito_sub}", f"story-{cognito_sub}")


class FakeUnderstandingStore:
    """In-memory stand-in for UnderstandingStore: composite (owner, moment_id) with a monotonic revision."""
    def __init__(self):
        self.rows = {}

    def get(self, owner, moment_id):
        return self.rows.get((owner, moment_id))

    def put(self, *, owner, moment_id, understanding_json, schema_version, prompt_version,
            frame_policy, content_sha256, model_id=""):
        prev = self.rows.get((owner, moment_id))
        rev = (prev["revision"] + 1) if prev else 1
        self.rows[(owner, moment_id)] = {
            "moment_id": moment_id, "understanding_json": understanding_json,
            "schema_version": schema_version, "revision": rev, "updated_at": int(time.time())}
        return {"moment_id": moment_id, "revision": rev, "updated_at": int(time.time())}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("STORY_ENVIRONMENT", "development")
    monkeypatch.setenv("STORY_REQUIRE_AUTH", "0")
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier()
    app.state._identity_store_override = FakeIdentityStore()
    us = FakeUnderstandingStore()
    app.state._music_favorites_store_override = MusicFavoritesStore(us)
    return TestClient(app), us


def test_get_empty_is_revision_zero_not_error(client):
    c, _ = client
    r = c.get("/v1/music/favorites", headers=_auth("alice"))
    assert r.status_code == 200
    assert r.json() == {"favorites": [], "revision": 0}


def test_unauthenticated_rejected(client):
    c, _ = client
    assert c.get("/v1/music/favorites").status_code == 401
    assert c.put("/v1/music/favorites", json={"base_revision": 0, "favorites": []}).status_code == 401


def test_put_then_get_roundtrip(client):
    c, _ = client
    body = {"base_revision": 0, "favorites": [
        {"track_id": "t1", "title": "Song One", "duration_seconds": 30.0, "saved_at": 100}]}
    r = c.put("/v1/music/favorites", json=body, headers=_auth("alice"))
    assert r.status_code == 200 and r.json()["revision"] == 1
    g = c.get("/v1/music/favorites", headers=_auth("alice")).json()
    assert g["revision"] == 1 and len(g["favorites"]) == 1 and g["favorites"][0]["track_id"] == "t1"


def test_stale_base_revision_conflicts_with_current(client):
    c, _ = client
    c.put("/v1/music/favorites", json={"base_revision": 0, "favorites": [{"track_id": "t1"}]}, headers=_auth("alice"))
    # A second writer still on base 0 must 409 and receive the server's current set (merge, never overwrite).
    r = c.put("/v1/music/favorites", json={"base_revision": 0, "favorites": []}, headers=_auth("alice"))
    assert r.status_code == 409
    cur = r.json()["detail"]["current"]
    assert cur["revision"] == 1 and len(cur["favorites"]) == 1


def test_correct_base_revision_advances(client):
    c, _ = client
    c.put("/v1/music/favorites", json={"base_revision": 0, "favorites": [{"track_id": "t1"}]}, headers=_auth("alice"))
    r = c.put("/v1/music/favorites",
              json={"base_revision": 1, "favorites": [{"track_id": "t1"}, {"track_id": "t2"}]},
              headers=_auth("alice"))
    assert r.status_code == 200 and r.json()["revision"] == 2 and len(r.json()["favorites"]) == 2


def test_account_isolation(client):
    c, _ = client
    c.put("/v1/music/favorites", json={"base_revision": 0, "favorites": [{"track_id": "t1"}]}, headers=_auth("alice"))
    # Bob never wrote — sees an empty library, never alice's.
    g = c.get("/v1/music/favorites", headers=_auth("bob")).json()
    assert g == {"favorites": [], "revision": 0}


def test_unsave_propagates_with_correct_base(client):
    c, _ = client
    c.put("/v1/music/favorites",
          json={"base_revision": 0, "favorites": [{"track_id": "t1"}, {"track_id": "t2"}]}, headers=_auth("alice"))
    # Explicit unsave of t2 from the device that holds the library (correct base) removes it.
    r = c.put("/v1/music/favorites", json={"base_revision": 1, "favorites": [{"track_id": "t1"}]}, headers=_auth("alice"))
    assert r.status_code == 200
    g = c.get("/v1/music/favorites", headers=_auth("alice")).json()
    assert [f["track_id"] for f in g["favorites"]] == ["t1"]


def test_sentinel_row_not_confused_with_a_moment(client):
    c, us = client
    c.put("/v1/music/favorites", json={"base_revision": 0, "favorites": [{"track_id": "t1"}]}, headers=_auth("alice"))
    # The favorites doc is stored under the reserved sentinel key, never a real moment id.
    assert ("story-alice", FAVORITES_SENTINEL) in us.rows
