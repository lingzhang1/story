"""Observability — structured stdout logging for the Story backend.

App Runner captures stdout/stderr to CloudWatch, so a stdlib logging
logger that emits one JSON object per line to stdout is all Milestone A
needs. No external logging dependencies.

Per 03-system-architecture.md §37: include a correlation/request id where
available; never log raw media bytes or user PII.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import datetime, timezone

_CONFIGURED: set[str] = set()


class _JsonFormatter(logging.Formatter):
    """Format each record as a single-line JSON object (JSON-ish structured
    output to stdout for CloudWatch)."""

    # Standard LogRecord attributes we do NOT copy into the "extra" bag.
    _RESERVED = {
        "name", "msg", "args", "levelname", "levelno", "pathname", "filename",
        "module", "exc_info", "exc_text", "stack_info", "lineno", "funcName",
        "created", "msecs", "relativeCreated", "thread", "threadName",
        "processName", "process", "taskName",
    }

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "ts": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        # Merge any structured fields passed via logger.info(msg, extra={...}).
        for key, value in record.__dict__.items():
            if key not in self._RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def get_logger(name: str = "story", level: int = logging.INFO) -> logging.Logger:
    """Return a stdlib logger emitting structured JSON lines to stdout.

    Idempotent: repeated calls for the same name do not add duplicate
    handlers. Propagation is disabled so records are not double-emitted by
    the root logger.
    """
    logger = logging.getLogger(name)
    if name not in _CONFIGURED:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(_JsonFormatter())
        logger.addHandler(handler)
        logger.setLevel(level)
        logger.propagate = False
        _CONFIGURED.add(name)
    return logger


# ---------------------------------------------------------------------------
# CloudWatch EMF metrics (P0 Beta Observability)
#
# Embedded Metric Format: a specially-shaped JSON line on stdout that CloudWatch
# auto-extracts into metrics — NO PutMetricData API call, NO added request
# latency. App Runner + Lambda both ship stdout to CloudWatch Logs, which parses
# the `_aws` envelope.
#
# Amendment 5 (ENFORCED here, not by convention): dimensions are restricted to a
# low-cardinality ALLOW-LIST. A caller that passes a disallowed dimension
# (owner id, job id, correlation id, GPS, prompt, media) has it DROPPED before
# emission, so a raw identifier can never become a metric dimension or appear in
# the metric line. High-cardinality context belongs in the structured LOG line
# (get_logger), never here.
# ---------------------------------------------------------------------------

METRIC_NAMESPACE = "Story/Beta"

# The ONLY dimensions any metric may carry. Everything else is dropped.
_ALLOWED_DIMENSIONS = {"env", "service", "op_type", "stage", "error_category", "model_id", "reason"}


def _sanitize_dimensions(dims: dict[str, object] | None) -> dict[str, str]:
    """Keep only allow-listed, low-cardinality dimension keys; stringify values.
    Silently drops anything else (defense against a raw id leaking into a dim)."""
    if not dims:
        return {}
    out: dict[str, str] = {}
    for k, v in dims.items():
        if k in _ALLOWED_DIMENSIONS and v is not None:
            s = str(v)
            # A dimension value should be a small enum-like token; guard against an
            # accidental large/opaque value sneaking in as a "reason"/"op_type".
            if len(s) <= 64:
                out[k] = s
    return out


def emit_metrics(
    metrics: dict[str, float],
    dimensions: dict[str, object] | None = None,
    *,
    namespace: str = METRIC_NAMESPACE,
    units: dict[str, str] | None = None,
) -> None:
    """Emit one or more CloudWatch metrics via EMF (one stdout JSON line).

    `metrics`     name -> value (e.g. {"GenerationCompleted": 1, "ModelLatencyMs": 820}).
    `dimensions`  low-cardinality context; NON-allow-listed keys are DROPPED (amendment 5).
    `units`       optional per-metric CloudWatch unit (default: Count; Milliseconds for *Ms).

    Fire-and-forget: never raises into the caller (a metric failure must not break a request).
    """
    try:
        dims = _sanitize_dimensions(dimensions)
        units = units or {}
        metric_defs = []
        for mname in metrics:
            unit = units.get(mname) or ("Milliseconds" if mname.endswith("Ms") else "Count")
            metric_defs.append({"Name": mname, "Unit": unit})
        payload: dict[str, object] = {
            "_aws": {
                "Timestamp": int(datetime.now(tz=timezone.utc).timestamp() * 1000),
                "CloudWatchMetrics": [{
                    "Namespace": namespace,
                    "Dimensions": [list(dims.keys())] if dims else [[]],
                    "Metrics": metric_defs,
                }],
            },
            "emf": True,
        }
        payload.update(dims)
        payload.update(metrics)
        # EMF requires the literal `_aws` key. The structured log formatter drops
        # underscore-prefixed keys, so write the EMF line DIRECTLY to stdout rather
        # than routing through get_logger's formatter.
        sys.stdout.write(json.dumps(payload, default=str) + "\n")
        sys.stdout.flush()
    except Exception:
        # Observability must never take down the request path.
        pass


def estimated_cost_usd(
    input_tokens: float,
    output_tokens: float,
    model_id: str,
    pricing: dict[str, tuple[float, float]] | None = None,
) -> float:
    """ESTIMATED Bedrock cost for one billable attempt: input_tok/1e6 * in_price +
    output_tok/1e6 * out_price. `pricing` maps model_id substring -> (in_usd_per_mtok,
    out_usd_per_mtok); a config table that can drift from real Bedrock prices (amendment 2
    documented limitation). Image/multimodal cost is included via Bedrock's REPORTED input
    tokens (contact-sheet tiles are counted as input tokens, not re-derived). Unknown model
    -> 0.0 (and the caller should still emit the raw token metrics)."""
    cost, priced = price_lookup(input_tokens, output_tokens, model_id, pricing)
    # Backward-compatible: an unpriced model still returns 0.0 here (callers that want to TELL
    # "unpriced" apart from "genuinely free" call price_lookup directly and read `priced`).
    return cost


def price_lookup(
    input_tokens: float,
    output_tokens: float,
    model_id: str,
    pricing: dict[str, tuple[float, float]] | None = None,
) -> tuple[float, bool]:
    """Like estimated_cost_usd but ALSO reports whether the model was actually PRICED (amendment 2 req 2).

    Returns (cost_usd, priced). `priced` is True only when `model_id` matched a pricing-table entry. This
    lets a caller distinguish an UNKNOWN/unpriced model (priced=False -> emit a MissingPricing diagnostic so
    the $0 is visibly an accounting gap, not a free call) from a genuinely zero-cost attempt (priced=True with
    both token counts 0 -> cost legitimately 0.0). Without this, both collapse to 0.0 and a new/renamed model
    silently under-reports spend."""
    table = pricing or _DEFAULT_PRICING
    for key, (in_p, out_p) in table.items():
        if key in model_id:
            cost = (input_tokens / 1_000_000.0) * in_p + (output_tokens / 1_000_000.0) * out_p
            return (cost, True)
    # No pricing entry matched: cost is unknown (reported as 0.0), and priced=False flags the gap.
    return (0.0, False)


# USD per 1M tokens (in, out). ESTIMATE ONLY — keep in sync with each provider's published list price;
# drift is an accepted limitation (amendment 2). Substring match against the full model id, FIRST match
# wins (dict insertion order) — so list the MORE SPECIFIC id before a prefix that would also match it
# (e.g. "gpt-5.1" before any "gpt-5", "gpt-4o" distinct from gpt-5). Direct-provider models (OpenAI/Gemini)
# are the live default under STORY_MODEL_PROVIDER=direct; before they were added here every direct-provider
# generation priced to $0.0 + priced=False (MissingModelPricing) and under-reported real spend.
_DEFAULT_PRICING: dict[str, tuple[float, float]] = {
    # --- Bedrock Anthropic (fallback / legacy) ---
    "opus-4": (15.0, 75.0),
    "sonnet-4": (3.0, 15.0),
    "haiku": (0.80, 4.0),
    # --- OpenAI direct (GPT-5-era; published list price USD/Mtok) ---
    "gpt-5.1": (1.25, 10.0),
    "gpt-5": (1.25, 10.0),          # any other gpt-5.x variant
    "gpt-4o": (2.50, 10.0),         # legacy direct default (still seen as served_by in older jobs)
    # --- Google Gemini direct (published list price USD/Mtok, standard <=200k context tier) ---
    "gemini-3.8-flash": (0.30, 2.50),
    "gemini-3": (0.30, 2.50),       # other gemini-3.x flash variants
    "gemini-1.5-pro": (1.25, 5.0),  # legacy routing default
    "gemini": (0.30, 2.50),         # catch-all flash-class fallback (keep LAST so specific ids win)
}

# Versioned pricing assumptions (Phase 1 requirement "versioned pricing assumptions"). Bump this whenever
# _DEFAULT_PRICING changes so a cost figure in CloudWatch is traceable to the assumption that produced it.
# Emitted on the AI metric line as `pricing_version` (a LOG field, not a metric dimension — it is not
# low-cardinality-bounded the way a dimension must be, and cost is already dimensioned by model_id).
PRICING_VERSION = "beta-pricing/2026-11-01-direct-providers"


# PII / sensitive keys that must NEVER appear in a structured log line (amendment 5 + Phase 2 "do not emit raw
# user instructions, media, GPS, or credentials"). Substring match, case-insensitive, against the field key.
_PII_KEY_MARKERS = (
    "instruction", "soft_direction", "prompt", "brief", "caption", "transcript",
    "gps", "latitude", "longitude", "location", "coordinate",
    "token", "secret", "password", "credential", "authorization", "cookie", "api_key", "apikey",
    "contact_sheet", "image", "frame_jpeg", "media_bytes", "thumbnail",
    "email", "phone",
)
# Keys that LOOK sensitive by substring but are legitimate low-risk telemetry — kept.
_PII_ALLOW = ("input_tokens", "output_tokens", "token_count", "model_id")


def scrub_log_fields(fields: dict[str, object]) -> dict[str, object]:
    """Return a copy of `fields` with any PII/sensitive key REDACTED to '[redacted]'. Used on the structured
    LOG envelope (never the metric line, which already enforces the dimension allow-list). A key is redacted
    when it contains a sensitive marker AND is not on the explicit allow-list (so `input_tokens` survives but
    `authorization` / `soft_direction` / `gps` do not). Value-level scrubbing of free text is out of scope —
    the rule is simpler and safer: those fields are not logged at all."""
    out: dict[str, object] = {}
    for k, v in fields.items():
        kl = str(k).lower()
        if any(a in kl for a in _PII_ALLOW):
            out[k] = v
            continue
        if any(m in kl for m in _PII_KEY_MARKERS):
            out[k] = "[redacted]"
        else:
            out[k] = v
    return out
