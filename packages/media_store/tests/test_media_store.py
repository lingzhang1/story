"""Unit tests for the media_store package (CI-collected via `pytest packages`). No AWS — fake ddb/s3."""
from __future__ import annotations

import base64
import pytest

import media_store as m


def test_cloud_media_id_is_deterministic_and_owner_scoped():
    a = m.cloud_media_id_for("owner-1", "d" * 64)
    assert a == m.cloud_media_id_for("owner-1", "d" * 64)          # deterministic
    assert a != m.cloud_media_id_for("owner-2", "d" * 64)          # owner-scoped (no cross-account dedup)
    assert a != m.cloud_media_id_for("owner-1", "e" * 64)          # content-scoped


def test_object_key_is_account_scoped():
    key = m.object_key("owner-1", "cmid-9")
    assert key == "media/owner-1/cmid-9/original"


def test_sha256_hex_to_b64_matches_s3_contract():
    hex_digest = "00" * 32  # 32 zero bytes
    assert m._sha256_hex_to_b64(hex_digest) == base64.b64encode(bytes(32)).decode()
    assert m._sha256_hex_to_b64("") == ""            # empty in -> empty out (never a false match)
    assert m._sha256_hex_to_b64("zz") == ""          # malformed -> empty


class _DDB:
    def __init__(self): self.items = {}
    @staticmethod
    def _k(key): return (key["story_user_id"]["S"], key["cloud_media_id"]["S"])
    def put_item(self, TableName, Item, ConditionExpression=None):
        k = (Item["story_user_id"]["S"], Item["cloud_media_id"]["S"])
        if ConditionExpression and "attribute_not_exists" in ConditionExpression and k in self.items:
            raise Exception("ConditionalCheckFailedException")
        self.items[k] = dict(Item)
    def get_item(self, TableName, Key):
        it = self.items.get(self._k(Key)); return {"Item": it} if it else {}
    def update_item(self, TableName, Key, UpdateExpression, ConditionExpression=None,
                    ExpressionAttributeNames=None, ExpressionAttributeValues=None):
        it = self.items[self._k(Key)]
        if ConditionExpression and it.get("state", {}).get("S") != ExpressionAttributeValues[":uploading"]["S"]:
            raise Exception("ConditionalCheckFailedException")
        it["state"] = ExpressionAttributeValues[":v"]; it["verified_at"] = ExpressionAttributeValues[":t"]
    def query(self, TableName, KeyConditionExpression, ExpressionAttributeValues):
        o = ExpressionAttributeValues[":o"]["S"]
        return {"Items": [v for (ow, _), v in self.items.items() if ow == o]}


class _S3:
    def __init__(self): self.obj = {}
    def put(self, key, size, sha_hex=None):
        self.obj[key] = {"size": size, "sha": base64.b64encode(bytes.fromhex(sha_hex)).decode() if sha_hex else None}
    def head_object(self, Bucket, Key, ChecksumMode=None):
        o = self.obj.get(Key)
        if o is None: raise Exception("404")
        d = {"ContentLength": o["size"]}
        if o["sha"]: d["ChecksumSHA256"] = o["sha"]
        return d
    def generate_presigned_url(self, op, Params, ExpiresIn):
        return f"url:{Params['Key']}:{ExpiresIn}"


def _store():
    return m.MediaStore(m.MediaStoreConfig(table="t", bucket="b"), ddb=_DDB(), s3=_S3())


def test_initiate_then_verify_happy_path():
    s = _store()
    sha = "a" * 64
    rec, created = s.initiate_upload(owner="o1", content_sha256=sha, size_bytes=10)
    assert created and rec["state"] == m.STATE_UPLOADING
    s._s3.put(rec["s3_key"], 10, sha)       # device uploaded the correct bytes
    out = s.complete_upload(owner="o1", cloud_media_id=rec["cloud_media_id"])
    assert out["state"] == m.STATE_CLOUD_VERIFIED and out["verified_at"] > 0


def test_verify_rejects_bad_checksum_and_size_and_missing():
    s = _store()
    sha = "a" * 64
    rec, _ = s.initiate_upload(owner="o1", content_sha256=sha, size_bytes=10)
    cmid = rec["cloud_media_id"]
    with pytest.raises(m.MediaVerificationError):            # missing object
        s.complete_upload(owner="o1", cloud_media_id=cmid)
    s._s3.put(rec["s3_key"], 11, sha)                        # wrong size
    with pytest.raises(m.MediaVerificationError):
        s.complete_upload(owner="o1", cloud_media_id=cmid)
    s._s3.put(rec["s3_key"], 10, "b" * 64)                   # wrong checksum
    with pytest.raises(m.MediaVerificationError):
        s.complete_upload(owner="o1", cloud_media_id=cmid)
    # record is still recoverable (uploading), never falsely verified
    assert s.get("o1", cmid)["state"] == m.STATE_UPLOADING


def test_initiate_idempotent_and_conflict():
    s = _store()
    sha = "a" * 64
    r1, c1 = s.initiate_upload(owner="o1", content_sha256=sha, size_bytes=10)
    r2, c2 = s.initiate_upload(owner="o1", content_sha256=sha, size_bytes=10)
    assert c1 and not c2 and r1["cloud_media_id"] == r2["cloud_media_id"]
    with pytest.raises(m.MediaOwnershipConflict):
        s.initiate_upload(owner="o1", content_sha256=sha, size_bytes=999)   # same id, different size


def test_download_requires_verified():
    s = _store()
    rec, _ = s.initiate_upload(owner="o1", content_sha256="a" * 64, size_bytes=10)
    with pytest.raises(m.MediaVerificationError):
        s.presign_download(owner="o1", cloud_media_id=rec["cloud_media_id"])


def test_list_is_owner_scoped():
    s = _store()
    s.initiate_upload(owner="o1", content_sha256="a" * 64, size_bytes=1)
    s.initiate_upload(owner="o2", content_sha256="b" * 64, size_bytes=1)
    assert len(s.list_for_owner("o1")) == 1 and len(s.list_for_owner("o2")) == 1
    assert s.get("o2", s.list_for_owner("o1")[0]["cloud_media_id"]) is None   # cross-account get -> None
