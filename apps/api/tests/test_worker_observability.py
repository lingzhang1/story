"""P0 Beta Observability — worker AI-metric emission (token surfacing + EMF).

Unit-tests the pure metric helper wired into the edit-plan worker: tokens surface out of the engine diag,
EstimatedModelCost is computed on the PHYSICAL (fallback-aware) model, and dimensions stay low-cardinality.
No SQS/S3/DynamoDB — the helper is pure over a diag dict + op_type."""

from __future__ import annotations

import io
import json
import sys

from app import worker as W


def _capture(fn) -> dict:
    cap = io.StringIO()
    old = sys.stdout
    sys.stdout = cap
    try:
        fn()
    finally:
        sys.stdout = old
    out = cap.getvalue().strip()
    assert out, "expected an EMF line"
    return json.loads(out.splitlines()[-1])


def test_worker_ai_metrics_surface_tokens_and_cost_on_fallback():
    diag = {"input_tokens": 20_000, "output_tokens": 1_000, "model_calls": 2,
            "any_fallback": True, "executability_repairs_used": 1, "critique_attempted": True}
    obj = _capture(lambda: W._emit_ai_metrics(diag, op_type="revision"))
    assert obj["_aws"]["CloudWatchMetrics"][0]["Namespace"] == "Story/Beta"
    # Fallback fired -> the billed model is the fallback (sonnet), and cost uses sonnet pricing.
    assert obj["model_id"] == W._FALLBACK_MODEL
    assert obj["InputTokens"] == 20_000
    assert obj["OutputTokens"] == 1_000
    assert obj["ModelFallbacks"] == 1
    assert obj["RepairCount"] == 1
    assert obj["CritiqueCount"] == 1
    assert "EstimatedModelCostUSD" in obj and obj["EstimatedModelCostUSD"] > 0
    # Dimensions are the low-cardinality allow-list only — never a job id / correlation id.
    dims = obj["_aws"]["CloudWatchMetrics"][0]["Dimensions"][0]
    assert set(dims) <= {"env", "service", "op_type", "stage", "model_id"}
    assert "job_id" not in dims and "correlation_id" not in dims


def test_worker_ai_metrics_primary_model_when_no_fallback():
    diag = {"input_tokens": 5_000, "output_tokens": 500, "model_calls": 1, "any_fallback": False}
    obj = _capture(lambda: W._emit_ai_metrics(diag, op_type="original"))
    assert obj["model_id"] == W._PRIMARY_MODEL
    assert obj["ModelFallbacks"] == 0


def test_worker_ai_metrics_zero_tokens_omits_cost_but_still_emits():
    diag = {"input_tokens": 0, "output_tokens": 0, "model_calls": 1, "any_fallback": False}
    obj = _capture(lambda: W._emit_ai_metrics(diag, op_type="original"))
    # No token data -> no cost metric, but usage counts still emit (never silently nothing).
    assert "EstimatedModelCostUSD" not in obj
    assert obj["InputTokens"] == 0 and obj["ModelInvocations"] == 1
