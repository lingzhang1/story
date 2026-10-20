"""R7-E — understanding_store unit tests. Fake DynamoDB exercises batch get/put + account scoping + oversized."""
import pytest
import understanding_store as u


class _FakeDDB:
    def __init__(self):
        self.items = {}
    @staticmethod
    def _k(key):
        return (key["story_user_id"]["S"], key["moment_id"]["S"])
    def put_item(self, TableName, Item):
        self.items[(Item["story_user_id"]["S"], Item["moment_id"]["S"])] = Item
    def get_item(self, TableName, Key):
        it = self.items.get(self._k(Key)); return {"Item": it} if it else {}
    def batch_get_item(self, RequestItems):
        table = list(RequestItems.keys())[0]
        keys = RequestItems[table]["Keys"]
        got = [self.items[self._k(k)] for k in keys if self._k(k) in self.items]
        return {"Responses": {table: got}}


def _store():
    return u.UnderstandingStore(cfg=u.UnderstandingStoreConfig(table="t"), ddb=_FakeDDB())


def test_put_then_batch_get_owner_scoped():
    s = _store()
    s.put(owner="A", moment_id="m1", understanding_json='{"x":1}', schema_version="mu/1",
          prompt_version="p", frame_policy="f", content_sha256="sha-a")
    s.put(owner="A", moment_id="m2", understanding_json='{"x":2}', schema_version="mu/1",
          prompt_version="p", frame_policy="f", content_sha256="sha-b")
    s.put(owner="B", moment_id="m3", understanding_json='{"x":3}', schema_version="mu/1",
          prompt_version="p", frame_policy="f", content_sha256="sha-c")
    got = s.get_many("A", ["m1", "m2", "m3"])   # m3 is B's -> not returned for A
    ids = {r["moment_id"] for r in got}
    assert ids == {"m1", "m2"}
    assert s.get("B", "m1") is None             # cross-account get -> None


def test_put_is_idempotent_and_carries_provenance():
    s = _store()
    s.put(owner="A", moment_id="m1", understanding_json='{"x":1}', schema_version="mu/1",
          prompt_version="p2", frame_policy="f3", content_sha256="sha-a", model_id="opus")
    rec = s.get("A", "m1")
    assert rec["content_sha256"] == "sha-a" and rec["schema_version"] == "mu/1"
    assert rec["prompt_version"] == "p2" and rec["frame_policy"] == "f3" and rec["model_id"] == "opus"
    assert rec["revision"] == 1
    s.put(owner="A", moment_id="m1", understanding_json='{"x":1}', schema_version="mu/1",
          prompt_version="p2", frame_policy="f3", content_sha256="sha-a")
    assert s.get("A", "m1")["revision"] == 2    # monotonic


def test_oversized_understanding_rejected():
    s = _store()
    big = "x" * (u.MAX_UNDERSTANDING_BYTES + 10)
    with pytest.raises(u.UnderstandingTooLarge):
        s.put(owner="A", moment_id="m1", understanding_json=big, schema_version="mu/1",
              prompt_version="p", frame_policy="f", content_sha256="sha")
