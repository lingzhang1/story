"""Tests for the P0 Beta Observability EMF metric emitter (packages/observability).

Covers: EMF envelope shape (the `_aws` key CloudWatch requires), the low-cardinality
dimension allow-list (amendment 5 — raw ids/PII dropped), unit inference, and the
estimated-cost helper (amendment 2 — multimodal via reported tokens, unknown model -> 0)."""

from __future__ import annotations

import io
import json
import sys

from observability import (
    emit_metrics,
    estimated_cost_usd,
    _sanitize_dimensions,
    METRIC_NAMESPACE,
)


def _capture_emf(metrics, dims=None, units=None):
    cap = io.StringIO()
    old = sys.stdout
    sys.stdout = cap
    try:
        emit_metrics(metrics, dims, units=units)
    finally:
        sys.stdout = old
    return json.loads(cap.getvalue().strip())


def test_emf_envelope_has_aws_key_and_namespace():
    obj = _capture_emf({"GenerationCompleted": 1}, {"env": "dev"})
    assert "_aws" in obj
    cw = obj["_aws"]["CloudWatchMetrics"][0]
    assert cw["Namespace"] == METRIC_NAMESPACE
    assert obj["GenerationCompleted"] == 1
    assert obj["env"] == "dev"


def test_dimension_allow_list_drops_raw_identifiers():
    d = _sanitize_dimensions({
        "env": "dev", "op_type": "original",
        "owner_sub": "u-123", "job_id": "j-xyz", "correlation_id": "c1",
        "gps": "37.3,-122.0", "prompt": "make it warmer",
    })
    assert d == {"env": "dev", "op_type": "original"}


def test_dimension_oversized_value_dropped():
    d = _sanitize_dimensions({"model_id": "x" * 200, "stage": "edit_plan"})
    assert d == {"stage": "edit_plan"}   # 200-char model_id dropped as high-cardinality/opaque


def test_unit_inference_ms_vs_count():
    obj = _capture_emf({"ModelLatencyMs": 820, "ModelInvocations": 1})
    units = {m["Name"]: m["Unit"] for m in obj["_aws"]["CloudWatchMetrics"][0]["Metrics"]}
    assert units["ModelLatencyMs"] == "Milliseconds"
    assert units["ModelInvocations"] == "Count"


def test_emit_never_raises_on_bad_input():
    # A metric failure must never break the request path (fire-and-forget).
    emit_metrics({"X": 1}, {"env": object()})  # non-stringable-ish dim value still must not raise


def test_estimated_cost_opus_includes_all_billable_tokens():
    c = estimated_cost_usd(20_000, 1_000, "us.anthropic.claude-opus-4-6-v1")
    assert abs(c - (20_000 / 1e6 * 15.0 + 1_000 / 1e6 * 75.0)) < 1e-9


def test_estimated_cost_sonnet():
    c = estimated_cost_usd(20_000, 1_000, "us.anthropic.claude-sonnet-4-6-v1")
    assert abs(c - (20_000 / 1e6 * 3.0 + 1_000 / 1e6 * 15.0)) < 1e-9


def test_estimated_cost_unknown_model_is_zero():
    assert estimated_cost_usd(20_000, 1_000, "some-unmapped-model") == 0.0
