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


def test_bedrock_usage_attribution_log_emits_with_trusted_user():
    """req 1: a privacy-safe bedrock_usage line carrying the trusted story_user_id MUST emit.

    Regression: 'msg' is a reserved LogRecord attribute — passing it in `extra` raised KeyError, which the
    helper's outer except swallowed, so the attribution line silently never appeared even though the EMF
    metrics did. Capture ALL stdout lines and assert the bedrock_usage line is present with the user id.
    """
    cap = io.StringIO()
    old = sys.stdout
    sys.stdout = cap
    try:
        W._emit_ai_metrics({"input_tokens": 15_164, "output_tokens": 1_273, "model_calls": 1,
                            "any_fallback": False}, op_type="original",
                           story_user_id="61310227-0e51-4755-8f2d-5f1ac9f7a103")
    finally:
        sys.stdout = old
    lines = [json.loads(l) for l in cap.getvalue().strip().splitlines() if l.strip().startswith("{")]
    usage = [o for o in lines if o.get("msg") == "bedrock_usage" or o.get("message") == "bedrock_usage"
             or "story_user_id" in o]
    assert usage, f"expected a bedrock_usage attribution line; got {[o.get('msg') or o.get('message') for o in lines]}"
    u = usage[-1]
    assert u.get("story_user_id") == "61310227-0e51-4755-8f2d-5f1ac9f7a103"
    assert u.get("input_tokens") == 15_164 and u.get("output_tokens") == 1_273
    assert u.get("pricing_known") is True and u.get("estimated_cost_usd") > 0
    # privacy: no raw instruction / gps / credential field rode along.
    for banned in ("soft_direction", "instruction", "gps", "prompt", "token"):
        assert banned not in u


# --- Editorial Pipeline v2, P0: durable evidence diagnostics (pure helper) ---------------------------------

def test_evidence_diag_persists_census_provenance_and_adds_stages_11_12():
    env = {
        "evidence_accounting": {"linked": 35, "eligible": 25, "sheeted": 19, "missing_sheet": 6,
                                "reconciles": True},
        "build_provenance": {"commit_sha": "19f9640", "extraction_policy": "au_extract/2"},
    }
    plan = {"segments": [{"asset_id": "A", "order": 0}, {"asset_id": "B", "order": 1},
                         {"asset_id": "A", "order": 2}, {"asset_id": "C", "order": 3}]}
    order = ["a", "b"]   # sheeted ids are lowercased; C had no sheet
    out = W._evidence_diag(env, plan, order)
    # Stages 1-10 persisted verbatim from the device (survive staged-payload TTL on the item).
    assert out["evidence_accounting"]["linked"] == 35
    assert out["build_provenance"]["commit_sha"] == "19f9640"
    # Stage 11: distinct selected = {a,b,c} (A de-duped). Stage 12: c was cut but had no sheet.
    assert out["evidence_stage11_selected_distinct"] == 3
    assert out["evidence_stage12_cut_without_sheet"] == 1
    assert out["evidence_cut_without_sheet_ids"] == ["c"]
    # Backend cross-check: selected(3) <= eligible(25) AND device reconciled.
    assert out["evidence_funnel_consistent"] is True


def test_evidence_diag_flags_inconsistent_when_selected_exceeds_eligible():
    # Impossible funnel: plan cut 2 distinct Moments but device said only 1 eligible -> cannot have happened.
    env = {"evidence_accounting": {"eligible": 1, "reconciles": True}}
    plan = {"segments": [{"asset_id": "x", "order": 0}, {"asset_id": "y", "order": 1}]}
    out = W._evidence_diag(env, plan, [])
    assert out["evidence_funnel_consistent"] is False


def test_evidence_diag_safe_without_device_fields():
    # A run from an older build (no evidence fields) still gets stages 11-12 and never crashes.
    plan = {"segments": [{"asset_id": "m1", "order": 0}]}
    out = W._evidence_diag({}, plan, ["m1"])
    assert "evidence_accounting" not in out and "build_provenance" not in out
    assert out["evidence_stage11_selected_distinct"] == 1
    assert out["evidence_stage12_cut_without_sheet"] == 0
    assert "evidence_funnel_consistent" not in out   # no device census -> no cross-check
