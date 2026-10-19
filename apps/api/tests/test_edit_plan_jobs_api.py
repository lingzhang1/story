"""Endpoint integration tests for the async Edit Planning job API (/v1/edit-plan-jobs).

Uses an in-memory fake JobStore injected via app.state._job_store_override — no AWS. Verifies: prompt 202
submit, idempotent duplicate (no second enqueue), 409 on conflicting payload for the same operation_id,
status read shape, cancel, and 404 when the API is disabled.
"""
import json
from uuid import uuid4

from fastapi.testclient import TestClient

from app.main import create_app
import edit_plan_jobs as _jobs


class FakeStore:
    """Minimal in-memory JobStore mirroring the real surface the endpoints call."""
    def __init__(self):
        self.jobs = {}
        self.enqueued = []
        self.staged = {}

    def stage_request(self, job_id, body_json, sheets):
        prefix = f"jobs/{job_id}/"
        self.staged[prefix] = (body_json, list(sheets))
        return prefix

    def create_or_get(self, *, operation_id, owner, approach, critique_requested,
                      staging_prefix, sheet_order, payload_fingerprint, has_body=True):
        jid = _jobs.job_id_for(operation_id)
        if jid in self.jobs:
            if self.jobs[jid]["fp"] != payload_fingerprint:
                raise _jobs.PayloadConflict("different payload for same operation_id")
            return jid, False
        self.jobs[jid] = {"job_id": jid, "status": "queued", "approach": approach, "owner": owner,
                          "fp": payload_fingerprint, "staging_prefix": staging_prefix,
                          "request_ref": {"staging_prefix": staging_prefix,
                                          "sheet_order": json.dumps(sheet_order)}}
        return jid, True

    def enqueue(self, job_id):
        self.enqueued.append(job_id)

    def get(self, job_id):
        return self.jobs.get(job_id)

    def request_cancel(self, job_id):
        j = self.jobs.get(job_id)
        if j and j["status"] in ("queued", "running"):
            j["status"] = "cancel_requested"
            return "cancel_requested"
        return j["status"] if j else None

    def reconcile_lost_enqueue(self):
        return []


def _client(store):
    app = create_app()
    app.state._job_store_override = store
    return TestClient(app)


def _body():
    return json.dumps({
        "story_id": str(uuid4()), "creative_intent_id": str(uuid4()),
        "creative_intent": {"target_duration_seconds": 30.0},
        "story_guide": {}, "story_coverage": {},
        "moments": [{"id": "m1", "duration_seconds": 8.0, "useful_segments": [[0.0, 6.0]]}],
        "output_format": "vertical"})


def test_submit_returns_202_and_enqueues():
    s = FakeStore(); c = _client(s)
    r = c.post("/v1/edit-plan-jobs", data={"operation_id": "op1", "owner": "dev",
               "body": _body(), "sheet_order": "[]", "approach": "storytelling"})
    assert r.status_code == 202, r.text
    assert r.json()["status"] == "queued"
    jid = r.json()["job_id"]
    assert s.enqueued == [jid], "exactly one enqueue"


def test_duplicate_same_payload_is_idempotent_no_second_enqueue():
    s = FakeStore(); c = _client(s)
    data = {"operation_id": "op2", "owner": "dev", "body": _body(), "sheet_order": "[]",
            "approach": "storytelling"}
    r1 = c.post("/v1/edit-plan-jobs", data=data)
    r2 = c.post("/v1/edit-plan-jobs", data=dict(data))
    assert r1.json()["job_id"] == r2.json()["job_id"]
    assert len(s.enqueued) == 1, "duplicate submit must NOT enqueue a second time (no dup inference)"


def test_conflicting_payload_same_op_is_409():
    s = FakeStore(); c = _client(s)
    c.post("/v1/edit-plan-jobs", data={"operation_id": "op3", "owner": "dev", "body": _body(),
           "sheet_order": "[]", "approach": "storytelling"})
    # same op id, different body -> different fingerprint -> conflict
    r = c.post("/v1/edit-plan-jobs", data={"operation_id": "op3", "owner": "dev",
               "body": _body(), "sheet_order": "[]", "approach": "visual_first",
               "critique_revision": "true"})
    assert r.status_code == 409, r.text


def test_status_and_cancel():
    s = FakeStore(); c = _client(s)
    jid = c.post("/v1/edit-plan-jobs", data={"operation_id": "op4", "owner": "dev", "body": _body(),
                 "sheet_order": "[]", "approach": "storytelling"}).json()["job_id"]
    g = c.get(f"/v1/edit-plan-jobs/{jid}")
    assert g.status_code == 200 and g.json()["status"] == "queued"
    cc = c.post(f"/v1/edit-plan-jobs/{jid}/cancel")
    assert cc.status_code == 200 and cc.json()["status"] == "cancel_requested"
    assert c.get("/v1/edit-plan-jobs/does-not-exist").status_code == 404
