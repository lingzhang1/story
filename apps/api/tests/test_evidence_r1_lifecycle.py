"""P1-F R1 — end-to-end AU-evidence lifecycle through the REAL endpoints.

Exercises /v1/asset-understanding (provisional persistence from accepted frames) + /v1/evidence/{moment}
(claim->authority retrieval) with REAL RS256 auth (throwaway keypair, JWKS injected) and in-memory fake
S3/DynamoDB for both the media store and the evidence store. No AWS, no model. Mirrors test_media_api.py +
test_asset_understanding_endpoint.py conventions.

Covers §8 ordering scenarios: AU-before-upload, upload-before-AU, SHA mismatch, no-upload, anonymous AU,
cross-account, repeat idempotency, hash absent (legacy caller), extractor-version mismatch.
"""
from __future__ import annotations

import base64
import io
import json
import time

import jwt  # PyJWT
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from PIL import Image

from app.main import create_app
from app.auth import CognitoConfig, CognitoJwtVerifier, IdentityStore
from app.deps import get_asset_understanding_engine
from asset_engine import RealAssetUnderstandingEngine, DEFAULT_AU_MODEL
from model_gateway import FakeModelGateway
import media_store as _media
import evidence_store as _evidence

REGION = "us-east-1"
POOL = "us-east-1_TESTPOOL"
CLIENT_ID = "testclientid123"
ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{POOL}"


def _make_key(kid):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    import jwt.algorithms
    pub = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    pub.update({"kid": kid, "alg": "RS256", "use": "sig"})
    return key, pub


KEY_A, JWK_A = _make_key("kidA")


def _token(sub, exp_delta=3600):
    now = int(time.time())
    return jwt.encode({"sub": sub, "iss": ISSUER, "token_use": "access", "client_id": CLIENT_ID,
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
        return self.claims.setdefault(f"cognito#{cognito_sub}", f"story-{cognito_sub}")


# ---- shared in-memory S3/DDB usable by BOTH media and evidence stores ----------------------------
class FakeS3:
    def __init__(self): self.objects = {}
    def put_object(self, Bucket, Key, Body, ContentType=None, ServerSideEncryption=None):
        self.objects[Key] = bytes(Body)
    def put(self, key, size, sha_hex=None):   # media-store verify helper
        self.objects[key] = {"size": size, "sha_b64": base64.b64encode(bytes.fromhex(sha_hex)).decode() if sha_hex else None}
    def get_object(self, Bucket, Key):
        v = self.objects.get(Key)
        if v is None: raise Exception("NoSuchKey")
        return {"Body": io.BytesIO(v if isinstance(v, bytes) else b"")}
    def head_object(self, Bucket, Key, ChecksumMode=None):
        o = self.objects.get(Key)
        if o is None: raise Exception("404 Not Found")
        if isinstance(o, bytes): return {"ContentLength": len(o)}
        out = {"ContentLength": o["size"]}
        if o.get("sha_b64"): out["ChecksumSHA256"] = o["sha_b64"]
        return out
    def delete_object(self, Bucket, Key): self.objects.pop(Key, None)
    def generate_presigned_url(self, op, Params, ExpiresIn):
        return f"https://s3.example/{Params['Key']}?op={op}&exp={ExpiresIn}"


class FakeDDB:
    """Composite-key store; the key attr name differs per table (cloud_media_id vs evidence_id), so detect it."""
    def __init__(self): self.items = {}
    @staticmethod
    def _skey(d):
        for name in ("cloud_media_id", "evidence_id"):
            if name in d: return (d["story_user_id"]["S"], d[name]["S"])
        raise KeyError("no sort key")
    def put_item(self, TableName, Item, ConditionExpression=None):
        k = self._skey(Item)
        if ConditionExpression and "attribute_not_exists" in ConditionExpression and k in self.items:
            raise Exception("ConditionalCheckFailedException")
        self.items[k] = dict(Item)
    def get_item(self, TableName, Key):
        it = self.items.get(self._skey(Key)); return {"Item": it} if it else {}
    def delete_item(self, TableName, Key): self.items.pop(self._skey(Key), None)
    def update_item(self, TableName, Key, UpdateExpression, ConditionExpression=None,
                    ExpressionAttributeNames=None, ExpressionAttributeValues=None):
        it = self.items[self._skey(Key)]
        if ConditionExpression and ":uploading" in (ExpressionAttributeValues or {}):
            if it.get("state", {}).get("S") != ExpressionAttributeValues[":uploading"]["S"]:
                raise Exception("ConditionalCheckFailedException")
        it["state"] = ExpressionAttributeValues[":v"]
        it["verified_at"] = ExpressionAttributeValues[":t"]; it["updated_at"] = ExpressionAttributeValues[":t"]
    def query(self, TableName, KeyConditionExpression, ExpressionAttributeValues):
        owner = ExpressionAttributeValues[":o"]["S"]
        return {"Items": [v for (o, _), v in self.items.items() if o == owner]}


_GOOD = {
    "observed": {"summary": "s", "subjects": ["a"],
                 "events": [{"start_time": 0.0, "end_time": 5.0, "description": "e"}],
                 "temporal_order_note": "n",
                 "useful_segments": [{"start_time": 0.0, "end_time": 5.0, "why_useful": "u"}]},
    "story_context": {"story_utility": "strong_elsewhere",
                      "requested_shot_contribution": "fulfilled", "requested_beat_contribution": "b"},
}


def _jpeg():
    b = io.BytesIO(); Image.new("RGB", (16, 16), (90, 110, 130)).save(b, format="JPEG"); return b.getvalue()


def _frames(n=24, step=100):
    jpegs = [_jpeg() for _ in range(n)]
    files = [("frames", (f"f{i}.jpg", jpegs[i], "image/jpeg")) for i in range(n)]
    fmeta = json.dumps([{"t_ms": i * step} for i in range(n)])
    return files, fmeta, jpegs


MID = "11111111-1111-1111-1111-111111111111"
# the sha of the packed accepted frames is computed by the store; the SOURCE sha is the device claim:
SRC_SHA = "a" * 64
SRC_SIZE = 4096


@pytest.fixture
def ctx(monkeypatch):
    monkeypatch.setenv("STORY_ENVIRONMENT", "development")
    monkeypatch.setenv("STORY_REQUIRE_AUTH", "0")
    monkeypatch.setenv("STORY_EVIDENCE_PERSIST_ENABLED", "1")   # P1-F: enable server persistence under test
    app = create_app()
    app.state._jwt_verifier_override = FakeVerifier()
    app.state._identity_store_override = FakeIdentityStore()
    s3, ddb = FakeS3(), FakeDDB()
    media = _media.MediaStore(_media.MediaStoreConfig(table="t", bucket="b", region=REGION), ddb=ddb, s3=s3)
    evid = _evidence.EvidenceStore(_evidence.EvidenceStoreConfig(table="t", bucket="b", region=REGION), ddb=ddb, s3=s3)
    app.state._media_store_override = media
    app.state._evidence_store_override = evid
    app.dependency_overrides[get_asset_understanding_engine] = \
        lambda: RealAssetUnderstandingEngine(FakeModelGateway(response=_GOOD), model_id=DEFAULT_AU_MODEL)
    return TestClient(app), s3, media, evid


def _au(client, sub, moment_id=MID, sha=SRC_SHA, extra_meta=None):
    files, fmeta, _ = _frames()
    meta = {"moment_id": moment_id}
    if sha is not None:
        meta["content_sha256"] = sha
    if extra_meta:
        meta.update(extra_meta)
    return client.post("/v1/asset-understanding",
                       data={"meta": json.dumps(meta), "frames_meta": fmeta}, files=files,
                       headers=_auth(sub) if sub else {})


def _upload_verified(client, media, s3, sub, moment_id=MID, sha=SRC_SHA):
    """Drive a media record to cloud_verified for (sub, moment) with source sha, as the upload path would."""
    owner = f"story-{sub}"
    rec, _ = media.initiate_upload(owner=owner, content_sha256=sha, size_bytes=SRC_SIZE,
                                   source_moment_id=moment_id, media_kind=_media.MEDIA_KIND_MOMENT)
    s3.put(rec["s3_key"], SRC_SIZE, sha)
    media.complete_upload(owner=owner, cloud_media_id=rec["cloud_media_id"])
    return owner


# ---- §8: AU before upload -> provisional -> verified upload -> cache HIT -------------------------
def test_au_before_upload_then_verify_then_hit(ctx):
    client, s3, media, evid = ctx
    assert _au(client, "alice").status_code == 200           # AU persists provisional package
    # retrieval before upload -> not yet usable (source not verified)
    miss = client.get(f"/v1/evidence/{MID}", headers=_auth("alice")).json()
    assert miss["available"] is False and miss["reason"] == "source_not_verified"
    _upload_verified(client, media, s3, "alice")             # upload completes independently
    hit = client.get(f"/v1/evidence/{MID}", headers=_auth("alice")).json()
    assert hit["available"] is True
    assert hit["manifest"]["frame_count"] == 24
    assert hit["download"]["url"].startswith("https://s3.example/")


# ---- §8: upload before AU -> immediately eligible ------------------------------------------------
def test_upload_before_au_immediately_eligible(ctx):
    client, s3, media, evid = ctx
    _upload_verified(client, media, s3, "bob")
    assert _au(client, "bob").status_code == 200
    hit = client.get(f"/v1/evidence/{MID}", headers=_auth("bob")).json()
    assert hit["available"] is True and hit["manifest"]["frame_count"] == 24


# ---- §8: SHA mismatch (uploaded source differs from AU claim) ------------------------------------
def test_sha_mismatch_is_cache_miss(ctx):
    client, s3, media, evid = ctx
    assert _au(client, "carol", sha="a" * 64).status_code == 200     # claim A
    _upload_verified(client, media, s3, "carol", sha="b" * 64)       # uploaded B
    r = client.get(f"/v1/evidence/{MID}", headers=_auth("carol")).json()
    assert r["available"] is False and r["reason"] == "sha_mismatch"


# ---- §8: no upload ever -> never usable ----------------------------------------------------------
def test_no_upload_never_usable(ctx):
    client, s3, media, evid = ctx
    assert _au(client, "dave").status_code == 200
    r = client.get(f"/v1/evidence/{MID}", headers=_auth("dave")).json()
    assert r["available"] is False and r["reason"] == "source_not_verified"


# ---- §8: anonymous AU -> no provisional package --------------------------------------------------
def test_anonymous_au_persists_no_package(ctx):
    client, s3, media, evid = ctx
    # legacy/dev principal (no token) in dev optional-auth: AU still works, but no account cache.
    assert _au(client, None).status_code == 200
    # legacy principal cannot even call retrieval (require_user) -> 401
    assert client.get(f"/v1/evidence/{MID}").status_code == 401


# ---- §8: cross-account retrieval denied ----------------------------------------------------------
def test_cross_account_retrieval_denied(ctx):
    client, s3, media, evid = ctx
    assert _au(client, "alice").status_code == 200
    _upload_verified(client, media, s3, "alice")
    # eve (different account) sees no package for alice's moment
    r = client.get(f"/v1/evidence/{MID}", headers=_auth("eve")).json()
    assert r["available"] is False and r["reason"] == "no_package"


# ---- §8: repeat AU idempotent (same source) ------------------------------------------------------
def test_repeat_au_idempotent(ctx):
    client, s3, media, evid = ctx
    assert _au(client, "alice").status_code == 200
    man1 = evid.get_manifest(owner="story-alice", moment_id=MID)
    assert _au(client, "alice").status_code == 200
    man2 = evid.get_manifest(owner="story-alice", moment_id=MID)
    assert man1["frames_ref"]["cloud_media_id"] == man2["frames_ref"]["cloud_media_id"]


# ---- §8: legacy caller WITHOUT the optional hash still succeeds (no cache) ------------------------
def test_au_without_sha_claim_still_succeeds(ctx):
    client, s3, media, evid = ctx
    r = _au(client, "alice", sha=None)   # omit content_sha256
    assert r.status_code == 200
    assert evid.get_manifest(owner="story-alice", moment_id=MID) is None   # nothing cached, AU fine


# ---- §8: extractor-version mismatch -> cache miss ------------------------------------------------
def test_extractor_version_mismatch_is_miss(ctx):
    client, s3, media, evid = ctx
    assert _au(client, "alice", extra_meta={"frame_extraction_version": "au_extract/2"}).status_code == 200
    _upload_verified(client, media, s3, "alice")
    r = client.get(f"/v1/evidence/{MID}?frame_extraction_version=au_extract/3", headers=_auth("alice")).json()
    assert r["available"] is False and r["reason"] == "extractor_version_mismatch"


# ---- §8: missing blob (interrupted write) -> cache miss, never a dead URL -------------------------
def test_missing_blob_is_miss(ctx):
    client, s3, media, evid = ctx
    assert _au(client, "alice").status_code == 200
    _upload_verified(client, media, s3, "alice")
    man = evid.get_manifest(owner="story-alice", moment_id=MID)
    # simulate a lost blob (manifest row survived, packed object gone)
    key = _evidence.evidence_object_key("story-alice", man["frames_ref"]["cloud_media_id"])
    s3.objects.pop(key, None)
    r = client.get(f"/v1/evidence/{MID}", headers=_auth("alice")).json()
    assert r["available"] is False and r["reason"] == "blob_missing"


# ---- §4 activation safety: server flag OFF -> NO durable package written -----------------------
def test_server_persist_flag_off_writes_nothing(ctx, monkeypatch):
    client, s3, media, evid = ctx
    monkeypatch.setenv("STORY_EVIDENCE_PERSIST_ENABLED", "0")   # authoritative server kill-switch
    assert _au(client, "alice").status_code == 200              # AU still succeeds
    assert evid.get_manifest(owner="story-alice", moment_id=MID) is None   # but NOTHING persisted
def test_moment_delete_removes_evidence(ctx):
    client, s3, media, evid = ctx
    assert _au(client, "alice").status_code == 200
    _upload_verified(client, media, s3, "alice")
    assert client.get(f"/v1/evidence/{MID}", headers=_auth("alice")).json()["available"] is True
    d = client.delete(f"/v1/evidence/{MID}", headers=_auth("alice"))
    assert d.status_code == 200 and d.json()["deleted"] is True
    # gone now -> retrieval is a miss
    assert client.get(f"/v1/evidence/{MID}", headers=_auth("alice")).json()["available"] is False
    assert evid.get_manifest(owner="story-alice", moment_id=MID) is None
    # idempotent second delete
    assert client.delete(f"/v1/evidence/{MID}", headers=_auth("alice")).status_code == 200


def test_cross_account_delete_does_not_touch_others(ctx):
    client, s3, media, evid = ctx
    assert _au(client, "alice").status_code == 200
    # eve deleting alice's moment id only ever touches eve's (empty) scope
    assert client.delete(f"/v1/evidence/{MID}", headers=_auth("eve")).status_code == 200
    assert evid.get_manifest(owner="story-alice", moment_id=MID) is not None   # alice's package intact


def test_account_delete_removes_all_owner_evidence(ctx):
    client, s3, media, evid = ctx
    # alice caches two moments
    assert _au(client, "alice", moment_id=MID).status_code == 200
    other = "22222222-2222-2222-2222-222222222222"
    assert _au(client, "alice", moment_id=other).status_code == 200
    n = evid.delete_for_owner(owner="story-alice")   # the account-deletion primitive (unwired; see milestone doc)
    assert n == 2
    assert evid.get_manifest(owner="story-alice", moment_id=MID) is None
    assert evid.get_manifest(owner="story-alice", moment_id=other) is None
