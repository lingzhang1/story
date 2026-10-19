"""Endpoint integration tests for the async Story Coverage/2 job API
(/v1/story-coverage/v2/jobs). Uses an in-memory fake JobStore injected via
app.state._job_store_override — no AWS. Verifies: 202 submit + enqueue, idempotent
duplicate (no second enqueue — no duplicate inference), 409 on conflicting payload
for the same operation_id, status-read shape (result under `result`, carries
operation_id for client-side staleness), cancel, dispatch isolation (an edit-plan
job is NOT served through the coverage routes), and invalid-body 422.
"""
import json
from uuid import uuid4

from fastapi.testclient import TestClient

from app.main import create_app
import edit_plan_jobs as _jobs


class FakeStore:
    def __init__(self):
        self.jobs = {}
        self.enqueued = []
        self.staged = {}

    def stage_request(self, job_id, body_json, sheets):
        prefix = f"jobs/{job_id}/"
        self.staged[prefix] = (body_json, list(sheets))
        return prefix

    def create_or_get_coverage(self, *, operation_id, owner, body_json, payload_fingerprint,
                               staging_prefix=""):
        jid = _jobs.job_id_for(operation_id)
        if jid in self.jobs:
            if self.jobs[jid]["fp"] != payload_fingerprint:
                raise _jobs.PayloadConflict("different payload for same operation_id")
            return jid, False
        self.jobs[jid] = {"job_id": jid, "status": "queued", "operation_id": operation_id, "owner": owner,
                          "operation_type": _jobs.OP_COVERAGE_V2, "fp": payload_fingerprint,
                          "request_ref": {"inline": not staging_prefix, "body_json": body_json}}
        return jid, True

    def create_or_get(self, *, operation_id, owner, approach, critique_requested,
                      staging_prefix, sheet_order, payload_fingerprint, has_body=True):
        jid = _jobs.job_id_for(operation_id)
        self.jobs[jid] = {"job_id": jid, "status": "queued", "approach": approach, "owner": owner,
                          "operation_type": _jobs.OP_EDIT_PLAN, "fp": payload_fingerprint,
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


def _body(moments=1, pending=0):
    return json.dumps({
        "story_id": str(uuid4()),
        "story_guide": {"dimensions": [{"id": "d1", "label": "x", "purpose": "p",
                                        "capture_possibilities": [{"id": "p1", "label": "y"}]}]},
        "story_guide_version": "story_guide/1",
        "creative_intent": {"target_duration_seconds": 30.0},
        "scope": {},
        "moment_understandings": [{"moment_id": str(uuid4()),
                                   "observed": {"summary": "s", "subjects": [], "events": [],
                                                "useful_segments": []}} for _ in range(moments)],
        "pending_count": pending})


def test_coverage_submit_202_and_enqueues():
    s = FakeStore(); c = _client(s)
    r = c.post("/v1/story-coverage/v2/jobs",
               data={"operation_id": "cov1", "owner": "dev", "body": _body()})
    assert r.status_code == 202, r.text
    j = r.json()
    assert j["status"] == "queued" and j["created"] is True
    assert s.enqueued == [j["job_id"]], "exactly one enqueue"


def test_coverage_duplicate_same_payload_idempotent_no_second_enqueue():
    s = FakeStore(); c = _client(s)
    body = _body()
    data = {"operation_id": "cov2", "owner": "dev", "body": body}
    r1 = c.post("/v1/story-coverage/v2/jobs", data=data)
    r2 = c.post("/v1/story-coverage/v2/jobs", data=dict(data))
    assert r1.json()["job_id"] == r2.json()["job_id"]
    assert r2.json()["created"] is False
    assert len(s.enqueued) == 1, "duplicate submit must NOT enqueue again (no duplicate inference)"


def test_coverage_conflicting_payload_same_op_is_409():
    s = FakeStore(); c = _client(s)
    c.post("/v1/story-coverage/v2/jobs", data={"operation_id": "cov3", "owner": "dev", "body": _body()})
    r = c.post("/v1/story-coverage/v2/jobs",
               data={"operation_id": "cov3", "owner": "dev", "body": _body(moments=2)})
    assert r.status_code == 409, r.text


def test_coverage_status_shape_and_result_under_result_key():
    s = FakeStore(); c = _client(s)
    jid = c.post("/v1/story-coverage/v2/jobs",
                 data={"operation_id": "cov4", "owner": "dev", "body": _body()}).json()["job_id"]
    g = c.get(f"/v1/story-coverage/v2/jobs/{jid}")
    assert g.status_code == 200
    out = g.json()
    assert out["status"] == "queued" and out["operation_id"] == "cov4"
    s.jobs[jid]["status"] = "completed"
    s.jobs[jid]["result"] = {"dimension_coverage": [{"story_guide_dimension_id": "d1", "state": "strong"}]}
    g2 = c.get(f"/v1/story-coverage/v2/jobs/{jid}").json()
    assert g2["result"]["dimension_coverage"][0]["state"] == "strong"
    assert g2["operation_id"] == "cov4", "status carries op-id for client-side staleness check (safeguard 4)"


def test_coverage_cancel():
    s = FakeStore(); c = _client(s)
    jid = c.post("/v1/story-coverage/v2/jobs",
                 data={"operation_id": "cov5", "owner": "dev", "body": _body()}).json()["job_id"]
    cc = c.post(f"/v1/story-coverage/v2/jobs/{jid}/cancel")
    assert cc.status_code == 200 and cc.json()["status"] == "cancel_requested"
    assert c.get("/v1/story-coverage/v2/jobs/does-not-exist").status_code == 404


def test_coverage_routes_reject_an_edit_plan_job():
    """Dispatch isolation: a job created as edit_plan must NOT be readable/cancelable via coverage routes."""
    s = FakeStore(); c = _client(s)
    jid, _ = s.create_or_get(operation_id="ep1", owner="dev", approach="storytelling",
                             critique_requested=False, staging_prefix="jobs/ep1/",
                             sheet_order=[], payload_fingerprint="x")
    assert c.get(f"/v1/story-coverage/v2/jobs/{jid}").status_code == 409
    assert c.post(f"/v1/story-coverage/v2/jobs/{jid}/cancel").status_code == 409


def test_coverage_invalid_body_is_422():
    s = FakeStore(); c = _client(s)
    r = c.post("/v1/story-coverage/v2/jobs",
               data={"operation_id": "cov6", "owner": "dev", "body": '{"not":"valid"}'})
    assert r.status_code == 422, r.text
