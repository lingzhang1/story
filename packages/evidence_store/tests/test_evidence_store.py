from __future__ import annotations

import json
import pytest

import evidence_store as e


# ---- fakes (mirror media_store test conventions) ------------------------------------------------
class _DDB:
    def __init__(self): self.items = {}
    @staticmethod
    def _k(key): return (key["story_user_id"]["S"], key["cloud_media_id"]["S"])
    def put_item(self, TableName, Item, ConditionExpression=None):
        self.items[(Item["story_user_id"]["S"], Item["cloud_media_id"]["S"])] = dict(Item)
    def get_item(self, TableName, Key):
        it = self.items.get(self._k(Key)); return {"Item": it} if it else {}
    def delete_item(self, TableName, Key):
        self.items.pop(self._k(Key), None)
    def query(self, TableName, KeyConditionExpression, ExpressionAttributeValues):
        o = ExpressionAttributeValues[":o"]["S"]
        pfx = ExpressionAttributeValues.get(":pfx", {}).get("S")
        out = []
        for (ow, sk), v in self.items.items():
            if ow != o:
                continue
            if pfx is not None and not sk.startswith(pfx):
                continue
            out.append(v)
        return {"Items": out}


class _S3:
    def __init__(self): self.obj = {}
    def put_object(self, Bucket, Key, Body, ContentType=None, ServerSideEncryption=None):
        self.obj[Key] = bytes(Body)
    def get_object(self, Bucket, Key):
        if Key not in self.obj:
            raise Exception("NoSuchKey")
        import io
        return {"Body": io.BytesIO(self.obj[Key])}
    def delete_object(self, Bucket, Key):
        self.obj.pop(Key, None)


def _store():
    return e.EvidenceStore(e.EvidenceStoreConfig(table="t", bucket="b"), ddb=_DDB(), s3=_S3())


def _frames(n=24, step=1000):
    # (t_ms, jpeg) — distinct bytes per frame so offsets/lengths are meaningful.
    return [(i * step, (f"jpeg-{i}-" + "x" * (10 + i)).encode()) for i in range(n)]


SHA_A = "a" * 64


# ---- pack/unpack ---------------------------------------------------------------------------------
def test_pack_unpack_roundtrip_exact_bytes():
    frames = _frames(5)
    packed, index = e.pack_frames(frames)
    assert len(index) == 5
    for i, (t_ms, jpeg) in enumerate(frames):
        assert index[i]["index"] == i and index[i]["t_ms"] == t_ms
        assert e.unpack_frame(packed, index[i]) == jpeg   # exact bytes preserved


def test_packed_sha_is_content_address():
    p1, _ = e.pack_frames(_frames(3))
    p2, _ = e.pack_frames(_frames(3))
    assert e.packed_sha256(p1) == e.packed_sha256(p2)     # deterministic
    p3, _ = e.pack_frames(_frames(4))
    assert e.packed_sha256(p1) != e.packed_sha256(p3)


# ---- put/get: integrity + timestamps preserved ---------------------------------------------------
def test_put_persists_manifest_with_correct_count_and_timestamps():
    s = _store()
    frames = _frames(24)
    man = s.put(owner="o1", moment_id="m1", content_sha256=SHA_A, frames=frames)
    assert man["frame_count"] == 24
    assert man["sampled_frame_ms"] == [t for t, _ in frames]       # accepted timestamps preserved
    assert man["schema_version"] == "evidence_package/1"
    assert man["frame_extraction_version"] == "au_extract/2"
    assert man["frames_ref"]["layout"] == "concat-jpeg"
    # content hash validation: blob sha matches recomputed
    packed, _ = e.pack_frames(frames)
    assert man["frames_ref"]["sha256"] == e.packed_sha256(packed)
    got = s.get_manifest(owner="o1", moment_id="m1")
    assert got["frames_ref"]["cloud_media_id"] == man["frames_ref"]["cloud_media_id"]


def test_get_packed_returns_exact_frames():
    s = _store()
    frames = _frames(6)
    man = s.put(owner="o1", moment_id="m1", content_sha256=SHA_A, frames=frames)
    packed = s.get_packed(owner="o1", blob_cmid=man["frames_ref"]["cloud_media_id"])
    assert packed is not None
    for i, (_, jpeg) in enumerate(frames):
        assert e.unpack_frame(packed, man["frames"][i]) == jpeg


# ---- idempotency: same pixels -> same blob id, repeat write safe ---------------------------------
def test_repeat_write_idempotent_same_blob_id():
    s = _store()
    frames = _frames(8)
    a = s.put(owner="o1", moment_id="m1", content_sha256=SHA_A, frames=frames)
    b = s.put(owner="o1", moment_id="m1", content_sha256=SHA_A, frames=frames)
    assert a["frames_ref"]["cloud_media_id"] == b["frames_ref"]["cloud_media_id"]  # same content address
    assert a["frames_ref"]["sha256"] == b["frames_ref"]["sha256"]


# ---- anonymous / no-owner refused ----------------------------------------------------------------
def test_anonymous_owner_refused():
    s = _store()
    with pytest.raises(ValueError):
        s.put(owner="", moment_id="m1", content_sha256=SHA_A, frames=_frames(4))


# ---- oversized refused (never truncate) ----------------------------------------------------------
def test_oversized_packed_refused():
    s = _store()
    big = [(0, b"x" * (e.MAX_PACKED_BYTES + 1))]
    with pytest.raises(e.EvidenceTooLarge):
        s.put(owner="o1", moment_id="m1", content_sha256=SHA_A, frames=big)


# ---- invalidation: source sha + extractor version, NOT prompt version ----------------------------
def test_is_valid_for_source_matches_sha_and_extractor():
    s = _store()
    man = s.put(owner="o1", moment_id="m1", content_sha256=SHA_A, frames=_frames(4),
                frame_extraction_version="au_extract/2")
    assert s.is_valid_for_source(man, content_sha256=SHA_A, frame_extraction_version="au_extract/2")
    # changed SOURCE fingerprint -> invalid
    assert not s.is_valid_for_source(man, content_sha256="b" * 64, frame_extraction_version="au_extract/2")
    # changed EXTRACTOR policy -> invalid
    assert not s.is_valid_for_source(man, content_sha256=SHA_A, frame_extraction_version="au_extract/3")


def test_prompt_change_does_NOT_invalidate_frames():
    # The mapper/invalidation path never consults an AU prompt version; the manifest doesn't store one.
    s = _store()
    man = s.put(owner="o1", moment_id="m1", content_sha256=SHA_A, frames=_frames(4))
    assert "prompt_version" not in man                      # pixels are prompt-agnostic
    # Same source + extractor still valid regardless of any prompt bump elsewhere.
    assert s.is_valid_for_source(man, content_sha256=SHA_A, frame_extraction_version="au_extract/2")


# ---- account isolation ---------------------------------------------------------------------------
def test_cross_account_get_returns_none():
    s = _store()
    s.put(owner="o1", moment_id="m1", content_sha256=SHA_A, frames=_frames(4))
    assert s.get_manifest(owner="o2", moment_id="m1") is None   # wrong owner finds nothing


# ---- missing / corrupt object -> cache miss (fallback) -------------------------------------------
def test_missing_blob_reads_as_miss():
    s = _store()
    man = s.put(owner="o1", moment_id="m1", content_sha256=SHA_A, frames=_frames(4))
    # Simulate an interrupted/lost blob: manifest present, blob gone.
    s._s3.obj.clear()
    assert s.get_packed(owner="o1", blob_cmid=man["frames_ref"]["cloud_media_id"]) is None


# ---- deletion: moment + account; orphan safety ---------------------------------------------------
def test_delete_for_moment_removes_manifest_and_blob():
    s = _store()
    man = s.put(owner="o1", moment_id="m1", content_sha256=SHA_A, frames=_frames(4))
    cmid = man["frames_ref"]["cloud_media_id"]
    assert s.delete_for_moment(owner="o1", moment_id="m1")
    assert s.get_manifest(owner="o1", moment_id="m1") is None
    assert s.get_packed(owner="o1", blob_cmid=cmid) is None
    # idempotent second delete
    assert s.delete_for_moment(owner="o1", moment_id="m1")


def test_delete_for_owner_removes_all_and_is_account_scoped():
    s = _store()
    s.put(owner="o1", moment_id="m1", content_sha256=SHA_A, frames=_frames(4))
    s.put(owner="o1", moment_id="m2", content_sha256="c" * 64, frames=_frames(5))
    s.put(owner="o2", moment_id="m1", content_sha256=SHA_A, frames=_frames(4))
    n = s.delete_for_owner(owner="o1")
    assert n == 2
    assert s.get_manifest(owner="o1", moment_id="m1") is None
    assert s.get_manifest(owner="o2", moment_id="m1") is not None   # other account untouched
