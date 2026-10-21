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


# 9 interruption + whole-file retry (re-initiate recovers same record; still completable after re-upload).
#   NOTE: this is WHOLE-FILE retry, not part-level multipart resume (that is R4).
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


# --- R4-B multipart API ------------------------------------------------------
import hashlib as _hl


def _psha(data: bytes) -> str:
    return base64.b64encode(_hl.sha256(data).digest()).decode()


class MPUFakeS3(FakeS3):
    def __init__(self):
        super().__init__()
        self.mpus = {}
        self._n = 0
    def create_multipart_upload(self, Bucket, Key, ContentType=None, ChecksumAlgorithm=None):
        self._n += 1; uid = f"mpu-{self._n}"; self.mpus[uid] = {"key": Key, "parts": {}}; return {"UploadId": uid}
    def put_part(self, uid, pn, data, csum):
        self.mpus[uid]["parts"][pn] = {"etag": f"e{pn}", "csum": csum, "data": data}
    def get_paginator(self, _n):
        s3 = self
        class _P:
            def paginate(self, Bucket, Key, UploadId):
                parts = s3.mpus.get(UploadId, {}).get("parts", {})
                yield {"Parts": [{"PartNumber": pn, "ETag": p["etag"], "ChecksumSHA256": p["csum"],
                                  "Size": len(p["data"])} for pn, p in sorted(parts.items())]}
        return _P()
    def complete_multipart_upload(self, Bucket, Key, UploadId, MultipartUpload):
        mpu = self.mpus[UploadId]
        data = b"".join(mpu["parts"][p["PartNumber"]]["data"] for p in MultipartUpload["Parts"])
        shas = [mpu["parts"][p["PartNumber"]]["csum"] for p in MultipartUpload["Parts"]]
        concat = b"".join(base64.b64decode(s) for s in shas)
        comp = base64.b64encode(_hl.sha256(concat).digest()).decode() + f"-{len(shas)}"
        self.objects[Key] = {"size": len(data), "sha_b64": comp}
        return {"ETag": "final"}


@pytest.fixture
def mpuctx(monkeypatch):
    monkeypatch.setenv("STORY_ENVIRONMENT", "development")
    monkeypatch.setenv("STORY_REQUIRE_AUTH", "0")
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier()
    app.state._identity_store_override = FakeIdentityStore()
    s3 = MPUFakeS3(); ddb = FakeDDB()
    store = _media.MediaStore(_media.MediaStoreConfig(table="t", bucket="b", region=REGION), ddb=ddb, s3=s3)
    app.state._media_store_override = store
    return TestClient(app), s3, store


def test_mp_01_initiate_requires_auth(mpuctx):
    client, _, _ = mpuctx
    r = client.post("/v1/media/multipart/initiate",
                    json={"content_sha256": "a"*64, "size_bytes": 100, "part_shas": ["x"]})
    assert r.status_code == 401


def test_mp_02_happy_path(mpuctx):
    client, s3, store = mpuctx
    p1, p2 = b"X"*1000, b"Y"*500
    shas = [_psha(p1), _psha(p2)]
    r = client.post("/v1/media/multipart/initiate", headers=_auth("alice"),
                    json={"content_sha256": "a"*64, "size_bytes": 1500, "part_shas": shas})
    assert r.status_code == 200
    cmid = r.json()["cloud_media_id"]; uid = r.json()["upload_id"]
    # presign parts (owner-scoped)
    pr = client.post(f"/v1/media/{cmid}/parts", headers=_auth("alice"), json={"part_numbers": [1, 2]})
    assert pr.status_code == 200 and set(pr.json()["parts"].keys()) == {"1", "2"}
    # simulate the device PUTting both parts to S3
    s3.put_part(uid, 1, p1, shas[0]); s3.put_part(uid, 2, p2, shas[1])
    c = client.post(f"/v1/media/{cmid}/multipart/complete", headers=_auth("alice"))
    assert c.status_code == 200 and c.json()["state"] == "cloud_verified"


def test_mp_03_resume_reconcile_then_complete(mpuctx):
    client, s3, store = mpuctx
    p1, p2 = b"X"*1000, b"Y"*500
    shas = [_psha(p1), _psha(p2)]
    cmid = client.post("/v1/media/multipart/initiate", headers=_auth("alice"),
                       json={"content_sha256": "a"*64, "size_bytes": 1500, "part_shas": shas}).json()["cloud_media_id"]
    uid = store.get("story-alice", cmid)["upload_id"]
    s3.put_part(uid, 1, p1, shas[0])   # interruption: only part 1
    up = client.get(f"/v1/media/{cmid}/parts/uploaded", headers=_auth("alice")).json()["uploaded_parts"]
    assert [p["part_number"] for p in up] == [1]
    # complete before part 2 -> 422 (missing), record recoverable
    assert client.post(f"/v1/media/{cmid}/multipart/complete", headers=_auth("alice")).status_code == 422
    # upload part 2, then complete
    s3.put_part(uid, 2, p2, shas[1])
    assert client.post(f"/v1/media/{cmid}/multipart/complete", headers=_auth("alice")).json()["state"] == "cloud_verified"


def test_mp_04_cross_account_denied(mpuctx):
    client, s3, store = mpuctx
    shas = [_psha(b"X"*1000)]
    cmid = client.post("/v1/media/multipart/initiate", headers=_auth("alice"),
                       json={"content_sha256": "a"*64, "size_bytes": 1000, "part_shas": shas}).json()["cloud_media_id"]
    # bob cannot presign parts, reconcile, or complete alice's MPU
    assert client.post(f"/v1/media/{cmid}/parts", headers=_auth("bob"), json={"part_numbers": [1]}).status_code == 404
    assert client.get(f"/v1/media/{cmid}/parts/uploaded", headers=_auth("bob")).status_code == 404
    assert client.post(f"/v1/media/{cmid}/multipart/complete", headers=_auth("bob")).status_code == 404


def test_mp_05_idempotent_initiate_recovers_upload(mpuctx):
    client, _, _ = mpuctx
    shas = [_psha(b"X"*1000)]
    body = {"content_sha256": "a"*64, "size_bytes": 1000, "part_shas": shas}
    a = client.post("/v1/media/multipart/initiate", headers=_auth("alice"), json=body).json()
    b = client.post("/v1/media/multipart/initiate", headers=_auth("alice"), json=body).json()
    assert a["cloud_media_id"] == b["cloud_media_id"] and a["upload_id"] == b["upload_id"]
    assert a["created"] is True and b["created"] is False


# ============================================================================================================
# R7-D — GENERATED MP4 backup: the SAME pipeline accepts media_kind="generated" with source_output_id (not
# only source_moment_id). Storage/presign/verify are identical to a moment original; only provenance differs.
# ============================================================================================================

def test_r7d_01_generated_single_initiate_records_kind_and_output_id(ctx):
    client, _, store = ctx
    r = client.post("/v1/media/initiate", headers=_auth("alice"),
                    json={"content_sha256": "c" * 64, "size_bytes": 5000, "content_type": "video/mp4",
                          "media_kind": "generated", "source_output_id": "output-123"})
    assert r.status_code == 200
    cmid = r.json()["cloud_media_id"]
    rec = store.get("story-alice", cmid)
    assert rec["media_kind"] == "generated"
    assert rec["source_output_id"] == "output-123"
    assert rec["content_type"] == "video/mp4"
    # source_moment_id is absent for a generated upload.
    assert rec.get("source_moment_id", "") == ""


def test_r7d_02_default_media_kind_is_moment(ctx):
    client, _, store = ctx
    cmid = _initiate(client, "alice").json()["cloud_media_id"]
    rec = store.get("story-alice", cmid)
    assert rec["media_kind"] == "moment"          # back-compat default
    assert rec["source_output_id"] == ""


def test_r7d_03_generated_appears_in_list_with_provenance(ctx):
    client, _, _ = ctx
    client.post("/v1/media/initiate", headers=_auth("alice"),
                json={"content_sha256": "d" * 64, "size_bytes": 5000, "content_type": "video/mp4",
                      "media_kind": "generated", "source_output_id": "out-xyz"})
    media = client.get("/v1/media", headers=_auth("alice")).json()["media"]
    gen = [m for m in media if m["media_kind"] == "generated"]
    assert len(gen) == 1 and gen[0]["source_output_id"] == "out-xyz"


def test_r7d_04_generated_verify_and_download_roundtrip(ctx):
    client, s3, _ = ctx
    sha = "e" * 64
    r = client.post("/v1/media/initiate", headers=_auth("alice"),
                    json={"content_sha256": sha, "size_bytes": 9000, "content_type": "video/mp4",
                          "media_kind": "generated", "source_output_id": "out-9"})
    cmid = r.json()["cloud_media_id"]
    key = _media.object_key("story-alice", cmid)
    s3.put(key, 9000, sha)                              # device PUT landed
    c = client.post(f"/v1/media/{cmid}/complete", headers=_auth("alice"))
    assert c.status_code == 200 and c.json()["state"] == "cloud_verified"
    # Download presign returns the SERVER-AUTHORITATIVE size + full-file sha so Device B can verify.
    d = client.get(f"/v1/media/{cmid}/download", headers=_auth("alice")).json()
    assert d["size_bytes"] == 9000 and d["content_sha256"] == sha and d["url"]


def test_r7d_05_cross_account_generated_download_denied(ctx):
    client, s3, _ = ctx
    sha = "f" * 64
    cmid = client.post("/v1/media/initiate", headers=_auth("alice"),
                       json={"content_sha256": sha, "size_bytes": 9000, "content_type": "video/mp4",
                             "media_kind": "generated", "source_output_id": "out-1"}).json()["cloud_media_id"]
    key = _media.object_key("story-alice", cmid)
    s3.put(key, 9000, sha)
    client.post(f"/v1/media/{cmid}/complete", headers=_auth("alice"))
    # bob cannot reach alice's generated object.
    assert client.get(f"/v1/media/{cmid}/download", headers=_auth("bob")).status_code == 404
    assert client.get(f"/v1/media/{cmid}", headers=_auth("bob")).status_code == 404


def test_r7d_06_unknown_media_kind_normalizes_to_moment(ctx):
    client, _, store = ctx
    cmid = client.post("/v1/media/initiate", headers=_auth("alice"),
                       json={"content_sha256": "1" * 64, "size_bytes": 10, "media_kind": "bogus"}
                       ).json()["cloud_media_id"]
    assert store.get("story-alice", cmid)["media_kind"] == "moment"


def test_r7d_07_backup_endpoint_registers_verified_generated(ctx):
    client, s3, _ = ctx
    sha = "2" * 64
    cmid = client.post("/v1/media/initiate", headers=_auth("alice"),
                       json={"content_sha256": sha, "size_bytes": 7000, "content_type": "video/mp4",
                             "media_kind": "generated", "source_output_id": "out-b"}).json()["cloud_media_id"]
    key = _media.object_key("story-alice", cmid)
    s3.put(key, 7000, sha)
    client.post(f"/v1/media/{cmid}/complete", headers=_auth("alice"))
    r = client.post("/v1/stories/story-1/outputs/out-b/backup", headers=_auth("alice"),
                    json={"cloud_media_id": cmid})
    assert r.status_code == 200 and r.json()["backed_up"] is True


def test_r7d_08_backup_endpoint_refuses_unverified_generated(ctx):
    client, _, _ = ctx
    cmid = client.post("/v1/media/initiate", headers=_auth("alice"),
                       json={"content_sha256": "3" * 64, "size_bytes": 7000, "content_type": "video/mp4",
                             "media_kind": "generated", "source_output_id": "out-c"}).json()["cloud_media_id"]
    # Not completed/verified -> backup registration is refused (409).
    r = client.post("/v1/stories/story-1/outputs/out-c/backup", headers=_auth("alice"),
                    json={"cloud_media_id": cmid})
    assert r.status_code == 409


def test_r7d_09_generated_multipart_records_kind_and_output_id(mpuctx):
    client, _, store = mpuctx
    shas = [_psha(b"G" * 1000), _psha(b"H" * 600)]
    r = client.post("/v1/media/multipart/initiate", headers=_auth("alice"),
                    json={"content_sha256": "a" * 64, "size_bytes": 1600, "part_shas": shas,
                          "content_type": "video/mp4", "media_kind": "generated",
                          "source_output_id": "out-mp"})
    assert r.status_code == 200
    cmid = r.json()["cloud_media_id"]
    rec = store.get("story-alice", cmid)
    assert rec["media_kind"] == "generated" and rec["source_output_id"] == "out-mp"
    assert rec["upload_mode"] == "multipart"
