"""R7 — story_store unit tests (CI-collected). A fake DynamoDB exercises the REAL conditional-write + mutation
idempotency + conflict logic; a fake media store exercises C3 dependency verification. No AWS needed."""
import pytest
import story_store as s


class _FakeDDB:
    """Minimal DynamoDB with put_item ConditionExpression + get_item + query, enough for StoryStore."""

    def __init__(self):
        self.items: dict[tuple[str, str], dict] = {}

    @staticmethod
    def _k(key):
        return (key["story_user_id"]["S"], key["story_id"]["S"])

    def put_item(self, TableName, Item, ConditionExpression=None, ExpressionAttributeValues=None):
        k = (Item["story_user_id"]["S"], Item["story_id"]["S"])
        cur = self.items.get(k)
        if ConditionExpression == "attribute_not_exists(story_id)":
            if cur is not None:
                raise Exception("ConditionalCheckFailedException")
        elif ConditionExpression == "revision = :base":
            base = ExpressionAttributeValues[":base"]["N"]
            if cur is None or cur.get("revision", {}).get("N") != base:
                raise Exception("ConditionalCheckFailedException")
        self.items[k] = Item

    def get_item(self, TableName, Key):
        it = self.items.get(self._k(Key))
        return {"Item": it} if it else {}

    def query(self, TableName, KeyConditionExpression, ExpressionAttributeValues, ProjectionExpression=None):
        o = ExpressionAttributeValues[":o"]["S"]
        return {"Items": [v for (ow, _), v in self.items.items() if ow == o]}


class _FakeMedia:
    """Media store stub: a set of (owner, cloud_media_id) that are cloud_verified."""

    def __init__(self, verified):
        self.verified = set(verified)   # {(owner, cmid)}

    def get(self, owner, cmid):
        return {"state": "cloud_verified"} if (owner, cmid) in self.verified else None


def _store(media=None):
    return s.StoryStore(cfg=s.StoryStoreConfig(table="t"), ddb=_FakeDDB(), media=media)


def test_create_then_get_is_owner_scoped():
    st = _store()
    out = st.put(owner="A", story_id="s1", base_revision=0, mutation_id="m1", doc={"title": "Hi"})
    assert out["revision"] == 1
    got = st.get("A", "s1")
    assert got["doc"]["title"] == "Hi" and got["revision"] == 1
    assert st.get("B", "s1") is None            # cross-account get -> None


def test_update_bumps_revision_on_matching_base():
    st = _store()
    st.put(owner="A", story_id="s1", base_revision=0, mutation_id="m1", doc={"t": 1})
    out = st.put(owner="A", story_id="s1", base_revision=1, mutation_id="m2", doc={"t": 2})
    assert out["revision"] == 2
    assert st.get("A", "s1")["doc"]["t"] == 2


def test_stale_base_different_mutation_raises_conflict():
    st = _store()
    st.put(owner="A", story_id="s1", base_revision=0, mutation_id="m1", doc={"t": 1})
    st.put(owner="A", story_id="s1", base_revision=1, mutation_id="m2", doc={"t": 2})  # now rev 2
    with pytest.raises(s.StoryConflict) as ei:
        st.put(owner="A", story_id="s1", base_revision=1, mutation_id="m3", doc={"t": 99})  # stale base
    assert ei.value.current["revision"] == 2 and ei.value.current["doc"]["t"] == 2


def test_idempotent_retry_same_mutation_is_success_not_conflict():
    st = _store()
    st.put(owner="A", story_id="s1", base_revision=0, mutation_id="m1", doc={"t": 1})
    st.put(owner="A", story_id="s1", base_revision=1, mutation_id="m2", doc={"t": 2})  # rev 2, last_mutation m2
    # Client lost the response and retries the SAME mutation at the SAME stale base -> idempotent success.
    out = st.put(owner="A", story_id="s1", base_revision=1, mutation_id="m2", doc={"t": 2})
    assert out["revision"] == 2            # no inflation, no conflict
    assert st.get("A", "s1")["revision"] == 2


def test_index_is_owner_scoped():
    st = _store()
    st.put(owner="A", story_id="s1", base_revision=0, mutation_id="m1", doc={})
    st.put(owner="A", story_id="s2", base_revision=0, mutation_id="m2", doc={})
    st.put(owner="B", story_id="s3", base_revision=0, mutation_id="m3", doc={})
    assert {r["story_id"] for r in st.index("A")} == {"s1", "s2"}
    assert {r["story_id"] for r in st.index("B")} == {"s3"}


def test_verify_dependencies_cloud_id_is_not_authorization():
    # A references cm-A (verified, A's) and cm-X (not A's). cm-X must be reported unverified (C3).
    media = _FakeMedia(verified={("A", "cm-A")})
    st = _store(media=media)
    ok, unver = st.verify_dependencies("A", ["cm-A", "cm-X"])
    assert ok is False and unver == ["cm-X"]
    ok2, unver2 = st.verify_dependencies("A", ["cm-A"])
    assert ok2 is True and unver2 == []
    # No ids -> satisfied.
    assert st.verify_dependencies("A", []) == (True, [])


def test_soft_delete_syncs_as_tombstone():
    st = _store()
    st.put(owner="A", story_id="s1", base_revision=0, mutation_id="m1", doc={"t": 1})
    out = st.put(owner="A", story_id="s1", base_revision=1, mutation_id="m2", doc={}, deleted=True)
    assert out["deleted"] is True
    assert st.get("A", "s1")["deleted"] is True
