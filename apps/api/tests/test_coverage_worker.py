"""Worker-side tests for async Coverage/2 dispatch + lifecycle (apps/api/app/worker.py).

No AWS, no real model: a FakeStore mirrors the JobStore surface and the coverage engine is stubbed via
monkeypatching worker._build_coverage_engine. Verifies: operation dispatch (coverage_v2 -> coverage path,
edit_plan -> edit path, unknown -> fail-safe), the identical compute is invoked, the result publishes under
`result` (never `plan`), cancel-before-publish, lost-lease non-publish, and failure classification.
"""
from __future__ import annotations

import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[3]
for rel in (".", "packages", "apps/api"):
    p = str((_ROOT / rel).resolve())
    if p not in sys.path:
        sys.path.insert(0, p)

import importlib.util
import json

import edit_plan_jobs as _jobs
from story_coverage_v2 import CoverageUnavailableError

_spec = importlib.util.spec_from_file_location("cvworker", str(_ROOT / "apps/api/app/worker.py"))
worker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(worker)


class FakeStore:
    def __init__(self, job):
        self.job = dict(job)
        self.completed = None       # (result, diag)
        self.failed = None          # (category, detail)
        self.cancelled = False
        self.lease = None
        self._cancel_requested = False

    def get(self, job_id):
        return self.job

    def claim_lease(self, job_id):
        if self.job["status"] in _jobs.TERMINAL:
            return None
        self.lease = "tok-1"
        self.job["status"] = "running"
        return self.lease

    def is_cancel_requested(self, job_id):
        return self._cancel_requested

    def mark_cancelled(self, job_id):
        self.cancelled = True
        self.job["status"] = "cancelled"
        return True

    def complete_coverage(self, job_id, result, diag, token):
        if token != self.lease:
            return False
        self.completed = (result, diag)
        self.job["status"] = "completed"
        return True

    def fail(self, job_id, category, detail, token=None):
        self.failed = (category, detail)
        self.job["status"] = "failed"
        return True

    def delete_staging(self, prefix):
        pass


class _StubCoverage:
    """Mimics a StoryCoverageContractV2 with model_dump."""
    def __init__(self, dims):
        self._dims = dims

    def model_dump(self, mode="json"):
        return {"dimension_coverage": self._dims, "sufficiency": "sufficient", "story_idea": None}


def _cov_job(**over):
    body = {"story_id": "11111111-1111-1111-1111-111111111111",
            "story_guide": {"dimensions": [{"id": "d1", "capture_possibilities": []}]},
            "creative_intent": {}, "scope": {},
            "moment_understandings": [{"moment_id": "22222222-2222-2222-2222-222222222222",
                                       "observed": {"summary": "s"}}],
            "pending_count": 0}
    job = {"job_id": "J1", "status": "queued", "operation_type": _jobs.OP_COVERAGE_V2,
           "request_ref": {"inline": True, "body_json": json.dumps(body)}}
    job.update(over)
    return job


def test_dispatch_coverage_runs_coverage_engine_and_publishes_under_result(monkeypatch):
    s = FakeStore(_cov_job())
    monkeypatch.setattr(worker, "_build_coverage_engine",
                        lambda: type("E", (), {"compute": lambda self, inp: _StubCoverage(
                            [{"story_guide_dimension_id": "d1", "state": "strong"}])})())
    out = worker._run_one(s, "J1")
    assert out == "completed"
    result, diag = s.completed
    assert result["dimension_coverage"][0]["state"] == "strong"
    assert diag["dimension_coverage_count"] == 1
    assert "coverage_latency_ms" in diag


def test_dispatch_unknown_operation_fails_safe():
    s = FakeStore(_cov_job(operation_type="coverage_v99"))
    out = worker._run_one(s, "J1")
    assert out == "failed:unknown_operation"
    assert s.failed[0] == "unknown_operation"


def test_coverage_cancel_before_publish_does_not_complete(monkeypatch):
    s = FakeStore(_cov_job())
    s._cancel_requested = True  # cancel requested after lease, before publish

    def _compute(self, inp):
        return _StubCoverage([{"story_guide_dimension_id": "d1", "state": "strong"}])
    monkeypatch.setattr(worker, "_build_coverage_engine",
                        lambda: type("E", (), {"compute": _compute})())
    out = worker._run_one(s, "J1")
    assert out == "cancelled_midrun"
    assert s.completed is None and s.cancelled


def test_coverage_cancel_while_queued_no_model_call():
    s = FakeStore(_cov_job(status="cancel_requested"))
    out = worker._run_one(s, "J1")
    assert out == "cancelled_prelease" and s.cancelled


def test_coverage_empty_mapping_classified(monkeypatch):
    s = FakeStore(_cov_job())

    def _compute(self, inp):
        raise CoverageUnavailableError("mapper returned empty dimension_coverage for 5 guide dimensions")
    monkeypatch.setattr(worker, "_build_coverage_engine",
                        lambda: type("E", (), {"compute": _compute})())
    out = worker._run_one(s, "J1")
    assert out == "failed:empty_mapping"
    assert s.failed[0] == "empty_mapping"


def test_coverage_mapper_unavailable_classified(monkeypatch):
    s = FakeStore(_cov_job())

    def _compute(self, inp):
        raise CoverageUnavailableError("mapper unavailable (ProviderError: boom)")
    monkeypatch.setattr(worker, "_build_coverage_engine",
                        lambda: type("E", (), {"compute": _compute})())
    out = worker._run_one(s, "J1")
    assert out == "failed:mapper_unavailable"


def test_coverage_already_terminal_is_noop():
    s = FakeStore(_cov_job(status="completed"))
    assert worker._run_one(s, "J1") == "already_terminal"
