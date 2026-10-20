"""R2/R3 — cloud media API security tests.

Real RS256 tokens (throwaway keypair; JWKS injected, no network). MediaStore uses an in-memory fake with a fake
S3 head_object, so verification logic is exercised without AWS. Mirrors test_auth_and_job_ownership.py.
"""
from __future__ import annotations

import base64
import hashlib
import json
import time

import jwt  # PyJWT
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.main import create_app
from app.auth import CognitoConfig, CognitoJwtVerifier, IdentityStore
import media_store as _media

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


def _token(sub, *, token_use="access", client_id=CLIENT_ID, iss=ISSUER, exp_delta=3600):
    now = int(time.time())
    return jwt.encode({"sub": sub, "iss": iss, "token_use": token_use, "client_id": client_id,
                       "iat": now, "exp": now + exp_delta}, KEY_A, algorithm="RS256", headers={"kid": "kidA"})


def _auth(sub):
    return {"Authorization": f"Bearer {_token(sub)}"}


class FakeVerifier(CognitoJwtVerifier):
    def __init__(self):
        super().__init__(CognitoConfig(region=REGION, user_pool_id=POOL, app_client_id=CLIENT_ID))
        self._static = {"kidA": JWK_A}

    def _fetch_jwks(self):
        return {"keys": list(self._static.values())}


class FakeIdentityStore(IdentityStore):
    def __init__(self):
        super().__init__(ddb=object(), claims_table="c", users_table="u", region=REGION)
        self.claims = {}

    def resolve(self, cognito_sub, *, verified_email=None):
        # Deterministic canonical id per sub (distinct from the sub) — mirrors the real atomic claim.
        return self.claims.setdefault(f"cognito#{cognito_sub}", f"story-{cognito_sub}")


class FakeS3:
    """Minimal S3 for MediaStore: an object store keyed by s3 key, with head_object exposing
    ContentLength + ChecksumSHA256, and a presigner that just echoes a URL."""
    def __init__(self):
        self.objects: dict[str, dict] = {}   # key -> {"size": int, "sha_b64": str|None}

    def put(self, key, size, sha_hex=None):
        sha_b64 = base64.b64encode(bytes.fromhex(sha_hex)).decode() if sha_hex else None
        self.objects[key] = {"size": size, "sha_b64": sha_b64}

    def head_object(self, Bucket, Key, ChecksumMode=None):
        o = self.objects.get(Key)
        if o is None:
            raise Exception("404 Not Found")
        out = {"ContentLength": o["size"]}
        if o["sha_b64"] is not None:
            out["ChecksumSHA256"] = o["sha_b64"]
        return out

    def generate_presigned_url(self, op, Params, ExpiresIn):
        return f"https://s3.example/{Params['Key']}?op={op}&exp={ExpiresIn}"


class FakeDDB:
    """Minimal DynamoDB for MediaStore: composite-key item store supporting put_item (conditional),
    get_item, update_item (conditional), query by PK."""
    def __init__(self):
        self.items: dict[tuple, dict] = {}

    @staticmethod
    def _k(key):
        return (key["story_user_id"]["S"], key["cloud_media_id"]["S"])

    def put_item(self, TableName, Item, ConditionExpression=None):
        k = (Item["story_user_id"]["S"], Item["cloud_media_id"]["S"])
        if ConditionExpression and "attribute_not_exists" in ConditionExpression and k in self.items:
            raise Exception("ConditionalCheckFailedException")
        self.items[k] = dict(Item)

    def get_item(self, TableName, Key):
        it = self.items.get(self._k(Key))
        return {"Item": it} if it else {}

    def update_item(self, TableName, Key, UpdateExpression, ConditionExpression=None,
                    ExpressionAttributeNames=None, ExpressionAttributeValues=None):
        k = self._k(Key)
        it = self.items.get(k)
        if it is None:
            raise Exception("ConditionalCheckFailedException")
        # Enforce the #s = :uploading guard.
        if ConditionExpression and ":uploading" in (ExpressionAttributeValues or {}):
            if it.get("state", {}).get("S") != ExpressionAttributeValues[":uploading"]["S"]:
                raise Exception("ConditionalCheckFailedException")
        it["state"] = ExpressionAttributeValues[":v"]
        it["verified_at"] = ExpressionAttributeValues[":t"]
        it["updated_at"] = ExpressionAttributeValues[":t"]

    def query(self, TableName, KeyConditionExpression, ExpressionAttributeValues):
        owner = ExpressionAttributeValues[":o"]["S"]
        return {"Items": [v for (o, _), v in self.items.items() if o == owner]}


@pytest.fixture
def ctx(monkeypatch):
    monkeypatch.setenv("STORY_ENVIRONMENT", "development")
    monkeypatch.setenv("STORY_REQUIRE_AUTH", "0")
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier()
    app.state._identity_store_override = FakeIdentityStore()
    s3 = FakeS3()
    ddb = FakeDDB()
    store = _media.MediaStore(_media.MediaStoreConfig(table="t", bucket="b", region=REGION), ddb=ddb, s3=s3)
    app.state._media_store_override = store
    return TestClient(app), s3, store


SHA_A = "a" * 64  # 64-hex; the device's declared full-file sha256
SIZE_A = 1234


def _initiate(client, sub, sha=SHA_A, size=SIZE_A):
    return client.post("/v1/media/initiate",
                       json={"content_sha256": sha, "size_bytes": size}, headers=_auth(sub))


# 1 authenticated initiation
def test_01_authenticated_initiate(ctx):
    client, _, _ = ctx
    r = _initiate(client, "alice")
    assert r.status_code == 200
    body = r.json()
    assert body["state"] == "uploading" and body["cloud_media_id"] and body["upload"]["url"]


# 2 missing / invalid token rejected
def test_02_missing_and_invalid_token_rejected(ctx):
    client, _, _ = ctx
    assert client.post("/v1/media/initiate", json={"content_sha256": SHA_A, "size_bytes": SIZE_A}).status_code == 401
    bad = {"Authorization": f"Bearer {_token('x', exp_delta=-10)}"}
    assert client.post("/v1/media/initiate", json={"content_sha256": SHA_A, "size_bytes": SIZE_A},
                       headers=bad).status_code == 401


# 3 cross-user listing isolation
def test_03_cross_user_listing_isolation(ctx):
    client, _, _ = ctx
    _initiate(client, "alice")
    _initiate(client, "bob", sha="b" * 64)
    la = client.get("/v1/media", headers=_auth("alice")).json()["media"]
    lb = client.get("/v1/media", headers=_auth("bob")).json()["media"]
    assert len(la) == 1 and len(lb) == 1
    assert la[0]["cloud_media_id"] != lb[0]["cloud_media_id"]


# 4 cross-user download denied
def test_04_cross_user_download_denied(ctx):
    client, s3, _ = ctx
    cmid = _initiate(client, "alice").json()["cloud_media_id"]
    # alice uploads + verifies
    key = _media.object_key("story-alice", cmid)
    s3.put(key, SIZE_A, SHA_A)
    client.post(f"/v1/media/{cmid}/complete", headers=_auth("alice"))
    # bob cannot download alice's media -> 404 (never reveals it exists)
    assert client.get(f"/v1/media/{cmid}/download", headers=_auth("bob")).status_code == 404


# 5 cross-user completion denied
def test_05_cross_user_completion_denied(ctx):
    client, s3, _ = ctx
    cmid = _initiate(client, "alice").json()["cloud_media_id"]
    s3.put(_media.object_key("story-alice", cmid), SIZE_A, SHA_A)
    assert client.post(f"/v1/media/{cmid}/complete", headers=_auth("bob")).status_code == 404


# 6 presigned URLs scoped to owned objects
def test_06_presigned_scoped_to_owner_key(ctx):
    client, _, _ = ctx
    r = _initiate(client, "alice").json()
    assert f"media/story-alice/{r['cloud_media_id']}/original" in r["upload"]["url"]


# 7 duplicate initiation idempotent
def test_07_duplicate_initiation_idempotent(ctx):
    client, _, _ = ctx
    a = _initiate(client, "alice").json()
    b = _initiate(client, "alice").json()
    assert a["cloud_media_id"] == b["cloud_media_id"]
    assert a["created"] is True and b["created"] is False


# 8 duplicate completion idempotent
def test_08_duplicate_completion_idempotent(ctx):
    client, s3, _ = ctx
    cmid = _initiate(client, "alice").json()["cloud_media_id"]
    s3.put(_media.object_key("story-alice", cmid), SIZE_A, SHA_A)
    r1 = client.post(f"/v1/media/{cmid}/complete", headers=_auth("alice"))
    r2 = client.post(f"/v1/media/{cmid}/complete", headers=_auth("alice"))
    assert r1.status_code == 200 and r2.status_code == 200
    assert r1.json()["state"] == r2.json()["state"] == "cloud_verified"


# 9 multipart interruption + resume (re-initiate recovers same record; still completable after upload)
def test_09_interruption_resume(ctx):
    client, s3, _ = ctx
    cmid = _initiate(client, "alice").json()["cloud_media_id"]
    # ... "interruption": object not yet in S3 -> complete fails, record stays uploading (recoverable)
    assert client.post(f"/v1/media/{cmid}/complete", headers=_auth("alice")).status_code == 422
    assert client.get(f"/v1/media/{cmid}", headers=_auth("alice")).json()["state"] == "uploading"
    # resume: re-initiate returns the SAME record, then upload completes
    assert _initiate(client, "alice").json()["cloud_media_id"] == cmid
    s3.put(_media.object_key("story-alice", cmid), SIZE_A, SHA_A)
    assert client.post(f"/v1/media/{cmid}/complete", headers=_auth("alice")).json()["state"] == "cloud_verified"


# 10 incorrect checksum
def test_10_incorrect_checksum(ctx):
    client, s3, _ = ctx
    cmid = _initiate(client, "alice").json()["cloud_media_id"]
    s3.put(_media.object_key("story-alice", cmid), SIZE_A, "c" * 64)  # wrong sha
    assert client.post(f"/v1/media/{cmid}/complete", headers=_auth("alice")).status_code == 422


# 11 incorrect size
def test_11_incorrect_size(ctx):
    client, s3, _ = ctx
    cmid = _initiate(client, "alice").json()["cloud_media_id"]
    s3.put(_media.object_key("story-alice", cmid), SIZE_A + 1, SHA_A)  # wrong size
    assert client.post(f"/v1/media/{cmid}/complete", headers=_auth("alice")).status_code == 422


# 12 missing S3 object
def test_12_missing_object(ctx):
    client, _, _ = ctx
    cmid = _initiate(client, "alice").json()["cloud_media_id"]
    assert client.post(f"/v1/media/{cmid}/complete", headers=_auth("alice")).status_code == 422


# 13 ownership-record conflict (same id, different declared content)
def test_13_ownership_record_conflict(ctx):
    client, _, _ = ctx
    _initiate(client, "alice", sha=SHA_A, size=SIZE_A)
    # same owner+sha => same id, but a DIFFERENT size is a conflict
    r = client.post("/v1/media/initiate", json={"content_sha256": SHA_A, "size_bytes": 999},
                    headers=_auth("alice"))
    assert r.status_code == 409


# 14 expired presigned URL (bounded TTL present on the minted URL)
def test_14_presigned_url_bounded_ttl(ctx):
    client, _, _ = ctx
    url = _initiate(client, "alice").json()["upload"]["url"]
    assert f"exp={_media.UPLOAD_URL_TTL_SECONDS}" in url
    assert _media.UPLOAD_URL_TTL_SECONDS <= 3600 and _media.DOWNLOAD_URL_TTL_SECONDS <= 3600


# 16 no destructive deletion endpoint exists
def test_16_no_delete_endpoint(ctx):
    client, _, _ = ctx
    paths = client.app.openapi()["paths"]
    media_methods = {p: list(v.keys()) for p, v in paths.items() if p.startswith("/v1/media")}
    for p, methods in media_methods.items():
        assert "delete" not in methods, f"unexpected DELETE on {p}"


# 17 legacy dev principal cannot access media APIs (require_user, no optional fallback)
def test_17_legacy_dev_cannot_access(ctx):
    client, _, _ = ctx
    # No token at all in dev optional-auth: job API would allow legacy 'dev', but media uses require_user -> 401.
    assert client.post("/v1/media/initiate", json={"content_sha256": SHA_A, "size_bytes": SIZE_A}).status_code == 401
    assert client.get("/v1/media").status_code == 401
    assert client.get("/v1/media/whatever").status_code == 401
    assert client.get("/v1/media/whatever/download").status_code == 401
