"""R7 — Story sync API tests: auth, account isolation, optimistic-concurrency conflict (409), mutation_id
idempotency, and verified-asset dependency gating (C3). Real RS256 tokens; in-memory story + media stores."""
from __future__ import annotations

import json
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.main import create_app
from app.auth import CognitoConfig, CognitoJwtVerifier, IdentityStore
import story_store as _stories

REGION = "us-east-1"
POOL = "us-east-1_TESTPOOL"
CLIENT_ID = "testclientid123"
ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{POOL}"


def _make_key(kid):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    import jwt.algorithms
    pub = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    pub["kid"] = kid; pub.setdefault("alg", "RS256"); pub.setdefault("use", "sig")
    return key, pub


KEY_A, JWK_A = _make_key("kidA")


def _auth(sub):
    now = int(time.time())
    tok = jwt.encode({"sub": sub, "iss": ISSUER, "token_use": "access", "client_id": CLIENT_ID,
                      "iat": now, "exp": now + 3600}, KEY_A, algorithm="RS256", headers={"kid": "kidA"})
    return {"Authorization": f"Bearer {tok}"}


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


class FakeStoryDDB:
    def __init__(self):
        self.items = {}
    @staticmethod
    def _k(key):
        return (key["story_user_id"]["S"], key["story_id"]["S"])
    def put_item(self, TableName, Item, ConditionExpression=None, ExpressionAttributeValues=None):
        k = (Item["story_user_id"]["S"], Item["story_id"]["S"]); cur = self.items.get(k)
        if ConditionExpression == "attribute_not_exists(story_id)" and cur is not None:
            raise Exception("ConditionalCheckFailedException")
        if ConditionExpression == "revision = :base":
            base = ExpressionAttributeValues[":base"]["N"]
            if cur is None or cur.get("revision", {}).get("N") != base:
                raise Exception("ConditionalCheckFailedException")
        self.items[k] = Item
    def get_item(self, TableName, Key):
        it = self.items.get(self._k(Key)); return {"Item": it} if it else {}
    def query(self, TableName, KeyConditionExpression, ExpressionAttributeValues, ProjectionExpression=None):
        o = ExpressionAttributeValues[":o"]["S"]
        return {"Items": [v for (ow, _), v in self.items.items() if ow == o]}


class FakeMedia:
    def __init__(self): self.verified = set()   # {(owner, cmid)}
    def verify(self, owner, cmid): self.verified.add((owner, cmid))
    def get(self, owner, cmid):
        return {"state": "cloud_verified"} if (owner, cmid) in self.verified else None


@pytest.fixture
def ctx(monkeypatch):
    monkeypatch.setenv("STORY_ENVIRONMENT", "development")
    monkeypatch.setenv("STORY_REQUIRE_AUTH", "1")   # enforce auth so unauth paths are exercised
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier()
    app.state._identity_store_override = FakeIdentityStore()
    media = FakeMedia()
    store = _stories.StoryStore(cfg=_stories.StoryStoreConfig(table="t", region=REGION),
                                ddb=FakeStoryDDB(), media=media)
    app.state._story_store_override = store
    return TestClient(app), store, media


def test_requires_auth(ctx):
    client, _, _ = ctx
    assert client.get("/v1/stories").status_code == 401
    assert client.put("/v1/stories/s1", json={"base_revision": 0, "mutation_id": "m", "doc": {}}).status_code == 401


def test_create_get_and_index(ctx):
    client, _, _ = ctx
    r = client.put("/v1/stories/s1", headers=_auth("userA"),
                   json={"base_revision": 0, "mutation_id": "m1", "doc": {"title": "A"}})
    assert r.status_code == 200 and r.json()["revision"] == 1
    g = client.get("/v1/stories/s1", headers=_auth("userA"))
    assert g.status_code == 200 and g.json()["doc"]["title"] == "A"
    idx = client.get("/v1/stories", headers=_auth("userA")).json()["stories"]
    assert [s["story_id"] for s in idx] == ["s1"]


def test_cross_account_isolation(ctx):
    client, _, _ = ctx
    client.put("/v1/stories/s1", headers=_auth("userA"),
               json={"base_revision": 0, "mutation_id": "m1", "doc": {"t": 1}})
    # B cannot see A's story.
    assert client.get("/v1/stories/s1", headers=_auth("userB")).status_code == 404
    assert client.get("/v1/stories", headers=_auth("userB")).json()["stories"] == []


def test_conflict_returns_409_with_server_doc(ctx):
    client, _, _ = ctx
    client.put("/v1/stories/s1", headers=_auth("userA"),
               json={"base_revision": 0, "mutation_id": "m1", "doc": {"t": 1}})
    client.put("/v1/stories/s1", headers=_auth("userA"),
               json={"base_revision": 1, "mutation_id": "m2", "doc": {"t": 2}})  # rev 2
    # A stale write (base 1) with a DIFFERENT mutation -> 409 with the server's current doc.
    r = client.put("/v1/stories/s1", headers=_auth("userA"),
                   json={"base_revision": 1, "mutation_id": "m3", "doc": {"t": 99}})
    assert r.status_code == 409
    cur = r.json()["detail"]["current"]
    assert cur["revision"] == 2 and cur["doc"]["t"] == 2


def test_idempotent_retry_not_a_conflict(ctx):
    client, _, _ = ctx
    client.put("/v1/stories/s1", headers=_auth("userA"),
               json={"base_revision": 0, "mutation_id": "m1", "doc": {"t": 1}})
    client.put("/v1/stories/s1", headers=_auth("userA"),
               json={"base_revision": 1, "mutation_id": "m2", "doc": {"t": 2}})  # rev 2, last m2
    # Lost-response retry: SAME mutation at the SAME base -> 200 success, revision unchanged.
    r = client.put("/v1/stories/s1", headers=_auth("userA"),
                   json={"base_revision": 1, "mutation_id": "m2", "doc": {"t": 2}})
    assert r.status_code == 200 and r.json()["revision"] == 2


def test_incomplete_deps_marked_when_asset_unverified(ctx):
    client, store, media = ctx
    # Reference a cloud asset that is NOT verified for this account -> doc accepted but incomplete_deps True.
    r = client.put("/v1/stories/s1", headers=_auth("userA"),
                   json={"base_revision": 0, "mutation_id": "m1", "doc": {"t": 1},
                         "referenced_cloud_media_ids": ["cm-unverified"]})
    assert r.status_code == 200 and r.json()["incomplete_deps"] is True
    # Now verify it (owner is the resolved canonical id story-userA) and re-sync -> complete.
    media.verify("story-userA", "cm-ok")
    r2 = client.put("/v1/stories/s1", headers=_auth("userA"),
                    json={"base_revision": 1, "mutation_id": "m2", "doc": {"t": 2},
                          "referenced_cloud_media_ids": ["cm-ok"]})
    assert r2.status_code == 200 and r2.json()["incomplete_deps"] is False


def test_output_backup_refuses_unverified_asset(ctx):
    client, store, media = ctx
    client.put("/v1/stories/s1", headers=_auth("userA"),
               json={"base_revision": 0, "mutation_id": "m1", "doc": {}})
    # cloud_media_id not verified for this account -> 409 refusal (cloud id is not authorization).
    r = client.post("/v1/stories/s1/outputs/o1/backup", headers=_auth("userA"),
                    json={"cloud_media_id": "cm-x"})
    assert r.status_code == 409
    media.verify("story-userA", "cm-x")
    r2 = client.post("/v1/stories/s1/outputs/o1/backup", headers=_auth("userA"),
                     json={"cloud_media_id": "cm-x"})
    assert r2.status_code == 200 and r2.json()["backed_up"] is True
