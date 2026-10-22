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
    price_lookup,
    scrub_log_fields,
    PRICING_VERSION,
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


def test_scrub_redacts_pii_keys_but_keeps_token_counts():
    scrubbed = scrub_log_fields({
        "op_type": "revision", "model_id": "opus", "input_tokens": 100, "output_tokens": 20,
        "soft_direction": "make it warmer", "instruction": "open with moment 1",
        "gps": "37.3,-122", "authorization": "Bearer abc", "contact_sheet_url": "s3://x",
        "latency_ms": 820,
    })
    # Sensitive keys redacted:
    assert scrubbed["soft_direction"] == "[redacted]"
    assert scrubbed["instruction"] == "[redacted]"
    assert scrubbed["gps"] == "[redacted]"
    assert scrubbed["authorization"] == "[redacted]"
    assert scrubbed["contact_sheet_url"] == "[redacted]"
    # Legitimate low-risk telemetry kept:
    assert scrubbed["op_type"] == "revision"
    assert scrubbed["model_id"] == "opus"
    assert scrubbed["input_tokens"] == 100
    assert scrubbed["output_tokens"] == 20
    assert scrubbed["latency_ms"] == 820


def test_pricing_version_is_set_and_stringlike():
    assert isinstance(PRICING_VERSION, str) and PRICING_VERSION
    assert "/" in PRICING_VERSION   # e.g. "beta-pricing/2026-10-21"


def test_price_lookup_flags_known_vs_unknown_model():
    # req 2: a priced model reports priced=True with a real cost...
    cost, priced = price_lookup(20_000, 1_000, "us.anthropic.claude-opus-4-6-v1")
    assert priced is True and cost > 0
    # ...an UNKNOWN model reports priced=False (cost 0.0 is an accounting GAP, not a free call)...
    cost_u, priced_u = price_lookup(20_000, 1_000, "some-unmapped-model")
    assert priced_u is False and cost_u == 0.0
    # ...and a genuinely zero-token attempt on a KNOWN model is priced=True, cost 0.0 (distinct case).
    cost_z, priced_z = price_lookup(0, 0, "us.anthropic.claude-opus-4-6-v1")
    assert priced_z is True and cost_z == 0.0


def test_estimated_cost_usd_matches_price_lookup_cost():
    # Backward-compatibility: the scalar helper returns exactly price_lookup's cost.
    model = "us.anthropic.claude-sonnet-4-6-v1"
    assert estimated_cost_usd(5_000, 500, model) == price_lookup(5_000, 500, model)[0]


def test_story_user_id_survives_scrub_for_attribution():
    # req 1: the trusted backend-minted story_user_id is an opaque id, NOT PII — it must pass the scrubber so
    # per-user cost attribution works, while any sensitive sibling field is still redacted on the same line.
    scrubbed = scrub_log_fields({
        "story_user_id": "su-9f3a2b", "estimated_cost_usd": 0.0123, "model_id": "opus",
        "input_tokens": 4200, "pricing_known": True, "soft_direction": "warmer",
    })
    assert scrubbed["story_user_id"] == "su-9f3a2b"   # kept — this is the attribution key
    assert scrubbed["estimated_cost_usd"] == 0.0123
    assert scrubbed["soft_direction"] == "[redacted]"  # sensitive sibling still redacted
