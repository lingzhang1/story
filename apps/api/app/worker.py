"""Async Edit Planning — Lambda worker (owner-approved 2026-10-13, dev only).

SQS-triggered. Reuses the EXACT production Edit Planner execution core (frozen v5.2, A1 evidence, multimodal
images, creative brief, optional critique/revision, Opus->Sonnet fallback, EditPlan/2 validator) — NO creative
behavior change. It only moves that execution off the App Runner request path so a >120s plan can finish.

Lifecycle per message (contract async-edit-planning-CONTRACT.md):
  1. parse {job_id}; load the job row.
  2. If terminal already -> ack (idempotent; a redelivery of a finished job is a no-op).
  3. If cancel_requested while queued -> mark cancelled + clean staging + ack (no model call).
  4. claim_lease -> running (+ lease_token). None => a live lease is held (another worker) -> drop/ack.
  5. load staged body+sheets from S3; build EditPlanInputs (images, brief, critique flag).
  6. run engine.generate under the SAME exception ladder as _execute_edit_plan -> classify failures.
  7. cancel re-check BEFORE publish (adjustment 3): if cancel_requested, finalize cancelled, do NOT complete.
  8. complete(plan, diagnostics, lease_token) — conditional on running + matching token (no stale publish).
  9. ALWAYS delete staging on terminal (privacy); lifecycle 24h + sweep are the backstop.

Execution deadline 840s (< Lambda 900s). Daily-token exhaustion is classified provider_exhausted, NOT retried
as transient (the gateway's Opus->Sonnet fallback already applied first).
"""
from __future__ import annotations

import json
import os
import sys
import time

# The Lambda package bundles packages/ (edit_planner, model_gateway, edit_plan_jobs, contracts) + prompts/.
for _p in ("/var/task", "/var/task/packages", "/opt", "/opt/packages"):
    if _p not in sys.path:
        sys.path.append(_p)

import edit_plan_jobs as _jobs
from edit_planner import (
    EditPlanInputs, RealEditPlannerEngine,
    MalformedPlanError, EditPlanInfeasibleError,
)
from model_gateway import StructuredOutputError, ProviderError

EXEC_DEADLINE_S = int(os.environ.get("STORY_WORKER_DEADLINE_S", "840"))

# P0 Beta Observability — AI usage/cost metrics from the worker. Import is best-effort so a packaging gap in
# the Lambda bundle never breaks plan execution (the worker predates observability wiring).
try:
    from observability import (emit_metrics as _emit_metrics, estimated_cost_usd as _estimated_cost_usd,
                               price_lookup as _price_lookup, scrub_log_fields as _scrub,
                               get_logger as _get_logger, PRICING_VERSION as _PRICING_VERSION)
except Exception:  # noqa: BLE001
    _emit_metrics = None
    _estimated_cost_usd = None
    _price_lookup = None
    _scrub = None
    _get_logger = None
    _PRICING_VERSION = "unknown"

_ENV = os.environ.get("STORY_ENVIRONMENT", "development")

# P0 Beta Security Phase 4 — worker-side AI quota settlement. Import is best-effort (the worker predates
# quota wiring and a packaging gap must never break plan execution). user_quota is a bundled package; the
# worker CANNOT import app.* (FastAPI not bundled), so it uses the pure module directly.
try:
    from user_quota import UserQuota as _UserQuota
except Exception:  # noqa: BLE001
    _UserQuota = None


def _quota_usage_table() -> str:
    return os.environ.get("STORY_USER_USAGE_TABLE", "")


def _served_model_id(diag: dict) -> str:
    """The model that ACTUALLY served this job, from the gateway diagnostics (`calls[].served_by`), so
    cost/metrics/diag report the real provider model (e.g. gpt-5.1 in direct mode) rather than the
    hardcoded Bedrock env. Falls back to the fallback/primary env only when the gateway did not report a
    served model (older gateway, or no call recorded)."""
    calls = diag.get("calls")
    if isinstance(calls, list) and calls:
        served = (calls[-1] or {}).get("served_by")
        if served:
            return str(served)
    return _FALLBACK_MODEL if diag.get("any_fallback") else _PRIMARY_MODEL


def _evidence_diag(env: dict, plan_dict: dict, order: list) -> dict:
    """Editorial Pipeline v2, P0 — PURE assembly of the durable evidence diagnostics that get persisted onto
    the job item (so they survive the staged-payload TTL). `env` is the staged submit envelope (carries the
    device's reconciling census + build provenance), `plan_dict` the produced EditPlan dict, `order` the
    sheet_order (lowercased sheeted Moment ids). Returns the keys to merge into diag_out. Privacy-safe: counts,
    reason buckets, version strings, and opaque Moment ids only — never raw media/prompts/secrets.

    Stages 1-10 come from the device verbatim (not re-derived). Stages 11-12 are the two the planner alone
    knows: (11) distinct Moments SELECTED into the cut, (12) selected Moments that had NO contact sheet
    (planned blind). `evidence_funnel_consistent` is a backend cross-check: you cannot cut what wasn't sent
    (selected <= eligible) AND the device census reconciled."""
    out: dict = {}
    ev = env.get("evidence_accounting") if isinstance(env.get("evidence_accounting"), dict) else None
    prov = env.get("build_provenance") if isinstance(env.get("build_provenance"), dict) else None
    if ev is not None:
        out["evidence_accounting"] = ev
    if prov is not None:
        out["build_provenance"] = prov
    selected: list[str] = []
    seen: set[str] = set()
    for s in (plan_dict.get("segments") or []):
        aid = str(s.get("asset_id") or "").lower()
        if aid and aid not in seen:
            seen.add(aid); selected.append(aid)
    sheeted = {str(x).lower() for x in (order or [])}
    cut_without_sheet = [a for a in selected if a not in sheeted]
    out["evidence_stage11_selected_distinct"] = len(selected)
    out["evidence_stage12_cut_without_sheet"] = len(cut_without_sheet)
    out["evidence_cut_without_sheet_ids"] = cut_without_sheet
    if ev is not None:
        elig = int(ev.get("eligible") or 0)
        out["evidence_funnel_consistent"] = (len(selected) <= elig) and bool(ev.get("reconciles"))
    return out


def _job_cost_usd(diag: dict) -> float:
    """Actual incurred model spend for this job from its diagnostics tokens (correction 3/8: ALL billable
    attempts — retries, repairs, critiques, fallback — are summed into input/output_tokens by the engine).
    Priced against the ACTUAL served model (direct-provider aware)."""
    if _price_lookup is None:
        return 0.0
    in_tok = int(diag.get("input_tokens") or 0)
    out_tok = int(diag.get("output_tokens") or 0)
    model_id = _served_model_id(diag)
    try:
        cost, _priced = _price_lookup(in_tok, out_tok, model_id)
        return float(cost)
    except Exception:  # noqa: BLE001
        return 0.0


def _quota_settle_job(job: dict, *, actual_usd: float) -> None:
    """A job COMPLETED: settle the actual incurred spend + release the active-job slot, each EXACTLY ONCE
    (idempotent on the reservation + slot markers — safe on an SQS redelivery). No-op when quota is not
    provisioned or the job predates quota (no owner/operation_id)."""
    if _UserQuota is None or not _quota_usage_table():
        return
    uid = job.get("owner")
    scoped_op = job.get("operation_id")
    job_id = job.get("job_id")
    if not uid or not scoped_op or uid == "dev":
        return  # legacy/dev job — never had a reservation
    try:
        q = _UserQuota(usage_table=_quota_usage_table())
        try:
            q.settle(uid, scoped_op, actual_usd=actual_usd)
        finally:
            q.release_slot(uid, job_id)
    except Exception:  # noqa: BLE001 — settlement drift is reconcilable; never break the worker
        pass


def _quota_release_job(job: dict, *, incurred_usd: float = 0.0) -> None:
    """A job FAILED / CANCELLED: refund the user allowance, KEEP any incurred Bedrock spend (correction 3/4),
    release the active-job slot. Idempotent. No-op for legacy/dev or unprovisioned quota."""
    if _UserQuota is None or not _quota_usage_table():
        return
    uid = job.get("owner")
    scoped_op = job.get("operation_id")
    job_id = job.get("job_id")
    if not uid or not scoped_op or uid == "dev":
        return
    try:
        q = _UserQuota(usage_table=_quota_usage_table())
        try:
            q.release_allowance(uid, scoped_op, gens=1, incurred_usd=incurred_usd)
        finally:
            q.release_slot(uid, job_id)
    except Exception:  # noqa: BLE001
        pass
_PRIMARY_MODEL = os.environ.get("STORY_EDIT_PLANNER_MODEL", "us.anthropic.claude-opus-4-6-v1")
_FALLBACK_MODEL = os.environ.get("STORY_LLM_FALLBACK_MODEL", "us.anthropic.claude-sonnet-4-6")


def _emit_ai_metrics(diag: dict, *, op_type: str, stage: str = "edit_plan", story_user_id: str | None = None) -> None:
    """Emit the Phase-2 AI metrics for one logical generation from the worker's diagnostics, via EMF.
    Fire-and-forget: never raises into the worker. `diag` is the engine's last_diagnostics (carries token
    accumulations + fallback + repair counts). The billed model is the FALLBACK model when a fallback fired,
    else the primary — this is the physical attempt the tokens were spent on. Dimensions stay low-cardinality
    (env/service/op_type/stage/model_id); correlation/job id are NEVER passed as dimensions.

    `story_user_id` (the TRUSTED, backend-minted owner from the job row — never client-supplied) is attributed
    via a privacy-safe structured LOG line (`bedrock_usage`), NOT a metric dimension: per-user is high-
    cardinality and the EMF allow-list would drop it anyway. Per-user cost is reconstructed from that log
    stream (Logs Insights), keeping CloudWatch metric cardinality bounded (req 1)."""
    if _emit_metrics is None:
        return
    try:
        in_tok = int(diag.get("input_tokens") or 0)
        out_tok = int(diag.get("output_tokens") or 0)
        any_fallback = bool(diag.get("any_fallback"))
        model_id = _served_model_id(diag)  # ACTUAL served model (direct-provider aware), not hardcoded Bedrock
        dims = {"env": _ENV, "service": "worker", "op_type": op_type, "stage": stage, "model_id": model_id}
        metrics: dict[str, float] = {
            "ModelInvocations": float(diag.get("model_calls") or diag.get("calls") or 0),
            "InputTokens": float(in_tok),
            "OutputTokens": float(out_tok),
            "RepairCount": float(diag.get("executability_repairs_used") or 0),
            "CritiqueCount": float(1 if diag.get("critique_attempted") else 0),
            "ModelFallbacks": float(1 if any_fallback else 0),
        }
        cost = 0.0
        priced = True
        if _price_lookup is not None and (in_tok or out_tok):
            cost, priced = _price_lookup(in_tok, out_tok, model_id)
            metrics["EstimatedModelCostUSD"] = float(cost)
            # req 2: an UNPRICED model is NOT a free call — surface it as its own metric so a $0 cost that is
            # really an accounting gap is visible (and alarmable), distinct from a genuine zero-token attempt.
            metrics["MissingModelPricing"] = float(0 if priced else 1)
        _emit_metrics(metrics, dims)
        # req 1: trusted per-user cost attribution on a PRIVACY-SAFE log line (story_user_id is an opaque
        # backend id, not PII; scrub_log_fields guarantees no instruction/gps/token field rides along).
        if story_user_id and _scrub is not None:
            _log_cost = _get_logger("story.worker.cost") if _get_logger is not None else None
            if _log_cost is not None:
                # NB: 'msg' is a RESERVED LogRecord attribute — putting it in `extra` raises KeyError
                # ("Attempt to overwrite 'msg'"), which the outer except swallows, so the attribution line
                # silently never emits. The event name is already the first positional arg below.
                _log_cost.info("bedrock_usage", extra=_scrub({
                    "story_user_id": story_user_id,
                    "op_type": op_type, "stage": stage, "model_id": model_id,
                    "model_calls": float(diag.get("model_calls") or diag.get("calls") or 0),
                    "input_tokens": in_tok, "output_tokens": out_tok,
                    "repairs": float(diag.get("executability_repairs_used") or 0),
                    "fallback": any_fallback, "estimated_cost_usd": round(cost, 6),
                    "pricing_version": _PRICING_VERSION, "pricing_known": priced,
                }))
    except Exception:  # noqa: BLE001 — observability must never break the worker
        pass


def _build_engine():
    """Mirror apps/api/app/deps.get_edit_planner_engine so the worker runs the IDENTICAL model path
    (direct OpenAI/Gemini in STORY_MODEL_PROVIDER=direct, else Opus primary -> Sonnet fallback)."""
    model = os.environ.get("STORY_EDIT_PLANNER_MODEL", "us.anthropic.claude-opus-4-6-v1")
    if (os.environ.get("STORY_MODEL_PROVIDER", "bedrock") or "bedrock").strip().lower() == "direct":
        from model_gateway.provider import make_gateway
        gw = make_gateway("edit_plan")
    else:
        from model_gateway import BedrockModelGateway, FallbackModelGateway
        fb = os.environ.get("STORY_LLM_FALLBACK_MODEL", "us.anthropic.claude-sonnet-4-6")
        primary = BedrockModelGateway(model_id=model)
        gw = primary if (not fb or fb == model) else FallbackModelGateway(primary, BedrockModelGateway(model_id=fb))
    return RealEditPlannerEngine(gw, executability_repair_attempts=2)


def _build_coverage_engine():
    """Mirror apps/api/app/deps.get_story_coverage_v2_engine so the worker runs the IDENTICAL two-call
    Coverage path (direct OpenAI/Gemini in STORY_MODEL_PROVIDER=direct, else Opus->Sonnet). Frozen
    prompts/contract untouched."""
    from story_coverage_v2 import RealStoryCoverageV2Engine
    model = os.environ.get("STORY_COVERAGE_MODEL", "us.anthropic.claude-opus-4-6-v1")
    if (os.environ.get("STORY_MODEL_PROVIDER", "bedrock") or "bedrock").strip().lower() == "direct":
        from model_gateway.provider import make_gateway
        gw = make_gateway("story_coverage")
    else:
        from model_gateway import BedrockModelGateway, FallbackModelGateway
        fb = os.environ.get("STORY_LLM_FALLBACK_MODEL", "us.anthropic.claude-sonnet-4-6")
        primary = BedrockModelGateway(model_id=model)
        gw = primary if (not fb or fb == model) else FallbackModelGateway(primary, BedrockModelGateway(model_id=fb))
    return RealStoryCoverageV2Engine(gw, model_id=model)


def _validator_error_codes(errs: list[str]) -> list[str]:
    """Map validate_plan's human error strings to LOW-CARDINALITY, stable codes for diagnostics/metrics.
    Never echoes a raw id, instruction, path, or model output — only the invariant that failed."""
    codes: set[str] = set()
    for e in errs:
        s = str(e).lower()
        if "not in the eligible source set" in s: codes.add("directive_ref_ineligible")
        elif "appears in no segment" in s: codes.add("directive_include_unplaced")
        elif "must not be used but appears" in s: codes.add("directive_exclude_violated")
        elif "first segment must be" in s: codes.add("directive_opening_unplaced")
        elif "last segment must be" in s: codes.add("directive_ending_unplaced")
        elif "order_after" in s or "order_adjacent" in s: codes.add("directive_order_violated")
        elif "no segments" in s: codes.add("no_segments")
        elif "not a known moment id" in s: codes.add("segment_unknown_asset")
        elif "overlaps no useful_segment" in s: codes.add("source_outside_useful")
        elif "exceeds moment duration" in s: codes.add("source_exceeds_duration")
        elif "invalid source range" in s or "missing source in/out" in s: codes.add("source_range_invalid")
        elif "out of renderer-supported range" in s: codes.add("speed_unrenderable")
        elif "inconsistent with source span" in s: codes.add("output_span_inconsistent")
        elif "upper bound" in s: codes.add("duration_overshoot")
        elif "lower bound" in s: codes.add("duration_undershoot")
        elif "transition" in s and "infeasible" in s: codes.add("transition_infeasible")
        elif "native_audio" in s: codes.add("native_audio_invalid")
        else: codes.add("other")
    return sorted(codes)


def _directive_categories(inputs) -> list[str]:
    """Which hard-directive CATEGORIES the request carried (not the ids/values). Low-cardinality."""
    if inputs is None:
        return []
    ctx = getattr(inputs, "revision_context", None) or {}
    d = ctx.get("directives") or {}
    if not isinstance(d, dict):
        return []
    return sorted(k for k in ("must_include", "exclude", "opening", "ending", "order_after", "order_adjacent")
                  if d.get(k))


def _classify(exc: Exception, inputs: EditPlanInputs) -> tuple[str, str]:
    """Map the engine's exceptions to a contract failure_category + detail."""
    if isinstance(exc, MalformedPlanError):
        return "invalid_after_repair", f"malformed: {exc}"[:400]
    if isinstance(exc, EditPlanInfeasibleError):
        return "material_infeasible", str(exc)[:400]
    if isinstance(exc, StructuredOutputError):
        return "invalid_after_repair", str(exc)[:400]
    if isinstance(exc, ProviderError):
        msg = str(exc)
        if "Too many tokens per day" in msg or "daily" in msg.lower():
            return "provider_exhausted", "daily token quota exhausted (not retried as transient)"
        return "provider_error", msg[:400]
    return "internal", f"{type(exc).__name__}: {exc}"[:400]


def _classify_coverage(exc: Exception) -> tuple[str, str]:
    """Map Coverage engine exceptions to a contract failure_category + detail. CoverageUnavailableError wraps
    both model failures (mapper/judge) and the empty-dimension_coverage guard (truncation). Distinguish daily
    quota exhaustion (not transient — the Opus->Sonnet fallback already applied) from a transient provider error."""
    from story_coverage_v2 import CoverageUnavailableError
    msg = str(exc)
    if isinstance(exc, CoverageUnavailableError):
        low = msg.lower()
        if "empty dimension_coverage" in low or "truncat" in low:
            return "empty_mapping", msg[:400]
        if "too many tokens per day" in low or "daily" in low:
            return "provider_exhausted", "daily token quota exhausted (not retried as transient)"
        if "mapper unavailable" in low:
            return "mapper_unavailable", msg[:400]
        if "judge unavailable" in low:
            return "judge_unavailable", msg[:400]
        return "coverage_unavailable", msg[:400]
    if isinstance(exc, StructuredOutputError):
        return "invalid_output", msg[:400]
    if isinstance(exc, ProviderError):
        if "Too many tokens per day" in msg or "daily" in msg.lower():
            return "provider_exhausted", "daily token quota exhausted (not retried as transient)"
        return "provider_error", msg[:400]
    return "internal", f"{type(exc).__name__}: {exc}"[:400]


def _run_one(store: _jobs.JobStore, job_id: str) -> str:
    """Dispatch on operation_type (owner safeguard 1). Unknown operations fail safe — never guessed, never run."""
    job = store.get(job_id)
    if not job:
        return "missing"
    op = job.get("operation_type", _jobs.OP_EDIT_PLAN)
    if op == _jobs.OP_COVERAGE_V2:
        result = _run_coverage(store, job_id, job)
    elif op == _jobs.OP_EDIT_PLAN:
        result = _run_edit_plan(store, job_id, job)
    else:
        # Unknown operation: fail the job safely (never execute an unrecognized payload against any engine).
        store.fail(job_id, "unknown_operation",
                   f"operation_type={op!r} not in {sorted(_jobs.KNOWN_OPERATIONS)}")
        _quota_release_job(job, incurred_usd=0.0)
        return "failed:unknown_operation"
    # Phase 4: a CANCELLED terminal (any of the several cancel return points in the run paths) refunds the
    # user allowance + releases the active-job slot, each EXACTLY ONCE. Idempotent, so this is safe even if a
    # run path already released — completions settle (with real cost) inside the run path; failures release
    # inside; only the cancel outcomes are finalized here. No incurred spend is recorded for a cancel (the
    # engine did not publish a billed result; any mid-run spend is a reconcilable under-count, not a charge).
    if isinstance(result, str) and result.startswith("cancelled"):
        _quota_release_job(job, incurred_usd=0.0)
    return result


def _run_coverage(store: _jobs.JobStore, job_id: str, job: dict) -> str:
    """Coverage/2 async execution. Same lifecycle contract as edit-plan (claim-lease -> run -> cancel-recheck
    -> conditional publish) but runs the IDENTICAL RealStoryCoverageV2Engine.compute (Mapper + Judge) off the
    App Runner request path, and reads its compact body INLINE (no S3 sheets). Frozen prompts/contract untouched."""
    if job.get("status") in _jobs.TERMINAL:
        return "already_terminal"
    rref = job.get("request_ref", {})
    if job.get("status") == "cancel_requested":
        store.mark_cancelled(job_id)
        if not rref.get("inline") and rref.get("staging_prefix"):
            store.delete_staging(rref["staging_prefix"])
        return "cancelled_prelease"

    token = store.claim_lease(job_id)
    if not token:
        return "lease_held"

    try:
        # Load the Coverage body: inlined for a compact payload, else staged in S3.
        if rref.get("inline"):
            body_json = rref["body_json"]
        else:
            body_json, _sheets = store.load_request(rref["staging_prefix"], [])
            # staged coverage body is written as body.json; load_request returns (body, sheets)

        b = json.loads(body_json)

        # ACCEPTANCE HOOK (test-only, env-gated): deterministic long-run simulation without model cost.
        if os.environ.get("STORY_WORKER_ALLOW_TEST_DELAY") == "1":
            try:
                delay = int(b.get("_test_delay_s") or 0)
            except Exception:
                delay = 0
            if delay > 0:
                waited = 0
                while waited < min(delay, EXEC_DEADLINE_S - 30):
                    time.sleep(5); waited += 5
                    if store.is_cancel_requested(job_id):
                        store.mark_cancelled(job_id); return "cancelled_during_delay"

        from story_coverage_v2 import CoverageV2Input
        from uuid import UUID as _UUID
        inp = CoverageV2Input(
            story_id=_UUID(str(b["story_id"])),
            story_guide=b.get("story_guide", {}),
            creative_intent=b.get("creative_intent", {}),
            scope=b.get("scope", {}),
            moment_understandings=b.get("moment_understandings", []),
            pending_count=int(b.get("pending_count", 0)))

        t0 = time.monotonic()
        engine = _build_coverage_engine()
        coverage = engine.compute(inp)   # SAME two-call path: Mapper + Judge, frozen prompts, 8192 tokens
        latency_ms = round((time.monotonic() - t0) * 1000)

        if store.is_cancel_requested(job_id):
            store.mark_cancelled(job_id)
            return "cancelled_midrun"

        result = _coverage_to_dict(coverage)
        diag = {
            "coverage_latency_ms": latency_ms,
            "dimension_coverage_count": len(result.get("dimension_coverage", []) or []),
            "mapper_prompt_version": os.environ.get("STORY_COVERAGE_MAPPER_VERSION", "story_coverage/mapper-v1"),
        }
        ok = store.complete_coverage(job_id, result, diag, token)
        if ok:
            # Phase 4: coverage spend is two Opus calls; settle the actual + release the slot (exactly once).
            _quota_settle_job(job, actual_usd=_job_cost_usd({
                "input_tokens": diag.get("input_tokens"), "output_tokens": diag.get("output_tokens"),
                "any_fallback": diag.get("any_fallback")}))
        return "completed" if ok else "publish_lost_lease"
    except Exception as exc:  # noqa: BLE001
        cat, detail = _classify_coverage(exc)
        store.fail(job_id, cat, detail, token)
        _quota_release_job(job, incurred_usd=0.0)
        return f"failed:{cat}"


def _coverage_to_dict(cov) -> dict:
    """StoryCoverageContractV2 -> plain dict for DynamoDB (Pydantic v2 model_dump, else dict())."""
    if hasattr(cov, "model_dump"):
        return cov.model_dump(mode="json")
    if hasattr(cov, "dict"):
        return cov.dict()
    return dict(cov)


def _run_edit_plan(store: _jobs.JobStore, job_id: str, job: dict) -> str:
    if job.get("status") in _jobs.TERMINAL:
        return "already_terminal"
    # cancel while queued -> cancelled, no model call
    if job.get("status") == "cancel_requested":
        store.mark_cancelled(job_id)
        store.delete_staging(job["request_ref"]["staging_prefix"])
        return "cancelled_prelease"

    token = store.claim_lease(job_id)
    if not token:
        return "lease_held"   # another worker owns it; drop this delivery

    prefix = job["request_ref"]["staging_prefix"]
    order = json.loads(job["request_ref"]["sheet_order"])
    try:
        envelope_raw, sheets = store.load_request(prefix, order)
        env = json.loads(envelope_raw)
        from model_gateway import ImageInput
        images = [ImageInput(data=data, media_type="image/jpeg") for _mid, data in sheets]
        # The body was already validated at submit time by the endpoint's EditPlanRequest model. The worker
        # parses the raw dict directly — it must NOT import app.main (that pulls FastAPI/uvicorn, not bundled).
        b = json.loads(env["body"])
        inputs = EditPlanInputs(
            story_id=str(b["story_id"]), creative_intent_id=str(b["creative_intent_id"]),
            creative_intent=b["creative_intent"], story_guide=b.get("story_guide", {}),
            story_coverage=b.get("story_coverage", {}), moments=b["moments"],
            music_plan=b.get("music_plan", {}), output_format=b.get("output_format", "vertical"),
            music_asset_id=b.get("music_asset_id"),
            music_plan_id=str(b["music_plan_id"]) if b.get("music_plan_id") else None,
            music_analysis=b.get("music_analysis"), sound_preference=b.get("sound_preference"),
            editorial_mode=b.get("editorial_mode"), revision_context=b.get("revision_context"),
            images=images, creative_brief=env.get("creative_brief"), image_moment_order=order,
            critique_revision=bool(env.get("critique_revision")))

        # ACCEPTANCE HOOK (test-only): a per-job artificial delay carried in the envelope (_test_delay_s), used
        # to deterministically simulate a long (>120s / 180s / 300s) plan WITHOUT real model cost — proving the
        # async path is decoupled from the old App Runner request ceiling. ONLY honored when the worker env
        # STORY_WORKER_ALLOW_TEST_DELAY=1 (off in any real use). Bounded by the deadline; checks cancel while waiting.
        import os as _os
        delay = 0
        if _os.environ.get("STORY_WORKER_ALLOW_TEST_DELAY") == "1":
            try:
                delay = int(env.get("_test_delay_s") or 0)
            except Exception:
                delay = 0
        if delay > 0:
            waited = 0
            while waited < min(delay, EXEC_DEADLINE_S - 30):
                time.sleep(5); waited += 5
                if store.is_cancel_requested(job_id):
                    store.mark_cancelled(job_id); store.delete_staging(prefix); return "cancelled_during_delay"

        engine = _build_engine()
        plan = engine.generate(inputs)   # SAME core: v5.2 + validator + fallback + bounded critique
        diag = getattr(engine, "last_diagnostics", {}) or {}

        # Adjustment 3: re-check cancel BEFORE publishing. A cancelled job must not be completed.
        if store.is_cancel_requested(job_id):
            store.mark_cancelled(job_id)
            store.delete_staging(prefix)
            return "cancelled_midrun"

        diag_out = {k: diag.get(k) for k in ("model_calls", "used_fallback", "critique_attempted",
                                             "critique_applied", "first_pass_executable",
                                             "first_pass_errors", "any_fallback", "first_fallback_error",
                                             "calls", "executability_repairs_used", "revision_path",
                                             "retime_reject_errors",
                                             # v2 creative-freedom: completion state + honest partial disclosure
                                             # so the device renders a SUCCESS-with-note, never the Adjust error.
                                             "completion", "partial_disclosure", "material_unmet",
                                             "creative_satisfaction", "creative_objective_count",
                                             "shipped_retained_candidate", "best_valid_from_attempt",
                                             "structural_repair", "repair_budget")}
        diag_out["planning_mode"] = "multimodal" if images else "text_only"
        diag_out["sheet_count"] = len(images)
        # P0 EVIDENCE ACCOUNTING (Editorial Pipeline v2). Persist the device's reconciling funnel census (stages
        # 1-10) + build provenance ONTO the job item (diag_out), so they survive the staged-payload TTL (the
        # staged request is deleted at job-terminal, but the item's diagnostics are durable), and add the two
        # stages only the planner knows (11 selected-distinct, 12 cut-without-sheet). Pure helper, unit-tested.
        try:
            diag_out.update(_evidence_diag(env, _plan_to_dict(plan), order))
        except Exception:
            pass   # diagnostics must never break a job
        # P0 Beta Observability: surface TOKENS + the physical model into the diag (they live in the engine's
        # last_diagnostics but were never forwarded) so EstimatedModelCost has an input and the log line is
        # cost-legible. input_tokens/output_tokens are the SUMMED billable tokens across all attempts.
        diag_out["input_tokens"] = int(diag.get("input_tokens") or 0)
        diag_out["output_tokens"] = int(diag.get("output_tokens") or 0)
        diag_out["model_id"] = _served_model_id(diag)
        # DIRECTIVE visibility: what revision_context the worker ACTUALLY received, the resolved opening id,
        # and whether the produced plan's first segment honored it. This is the only way to tell apart "the app
        # sent no/stale directive" from "the directive was sent but not enforced" from "Moment N resolved to an
        # unexpected id" — all three present as a byte-identical plan from the outside.
        _rc = (b.get("revision_context") or {}) if isinstance(b.get("revision_context"), dict) else {}
        _dir = _rc.get("directives") or {}
        _moment_ids = {str(m.get("id")).lower() for m in b.get("moments", []) if isinstance(m, dict)}
        _plan_segs = sorted(_plan_to_dict(plan).get("segments", []), key=lambda s: s.get("order", 0))
        _seg0 = (str(_plan_segs[0].get("asset_id")).lower() if _plan_segs else None)
        _open = _dir.get("opening")
        _open_l = (str(_open).lower() if isinstance(_open, str) else None)
        rev_diag = {
            "mode": _rc.get("mode"),
            "directive_keys": sorted(k for k in _dir.keys() if _dir.get(k)) if isinstance(_dir, dict) else None,
            "opening": _open_l,
            "opening_in_moments": (_open_l in _moment_ids) if _open_l else None,
            "seg0": _seg0,
            "opening_honored": (_open_l == _seg0) if _open_l else None,
            "soft": (str(_rc.get("soft_direction"))[:80] if _rc.get("soft_direction") else None),
            "dur_src": _rc.get("duration_target_source"),
        }
        diag_out["rev_diag"] = rev_diag
        # Greppable diagnostics line (CloudWatch): which model served each call, first-pass validator errors,
        # and WHY the primary failed over — so Opus-vs-Sonnet reject behavior is analyzable without DynamoDB.
        print(json.dumps({"msg": "worker_plan_diag", "job_id": job_id,
                          "model_calls": diag_out.get("model_calls"),
                          "first_pass_executable": diag_out.get("first_pass_executable"),
                          "first_pass_errors": diag_out.get("first_pass_errors"),
                          "any_fallback": diag_out.get("any_fallback"),
                          "first_fallback_error": diag_out.get("first_fallback_error"),
                          "calls": diag_out.get("calls"),
                          "rev_diag": rev_diag,
                          "revision_path": diag_out.get("revision_path"),
                          "retime_reject_errors": diag_out.get("retime_reject_errors"),
                          "input_tokens": diag_out.get("input_tokens"),
                          "output_tokens": diag_out.get("output_tokens"),
                          "model_id": diag_out.get("model_id"),
                          "pricing_version": _PRICING_VERSION,
                          "repairs": diag_out.get("executability_repairs_used")})[:1500])
        # P0 Beta Observability: emit AI usage/cost + a GenerationCompleted count (EMF, fire-and-forget). The
        # op_type is the revision mode (original|another_version|revision) from the request body.
        _op = (b.get("revision_context") or {}).get("mode", "original") if isinstance(b.get("revision_context"), dict) else "original"
        _emit_ai_metrics(diag_out, op_type=_op, story_user_id=job.get("owner"))
        if _emit_metrics is not None:
            try: _emit_metrics({"GenerationCompleted": 1.0}, {"env": _ENV, "service": "worker", "op_type": _op})
            except Exception: pass
        # complete is conditional on running + our lease_token -> a stale worker can't publish over us.
        ok = store.complete(job_id, _plan_to_dict(plan), diag_out, token)
        store.delete_staging(prefix)
        if ok:
            # Phase 4: settle the ACTUAL incurred Bedrock spend + release the active-job slot (exactly once).
            _quota_settle_job(job, actual_usd=_job_cost_usd(diag_out))
        return "completed" if ok else "publish_lost_lease"
    except Exception as exc:  # noqa: BLE001 — classify everything into a terminal failure
        cat, detail = _classify(exc, locals().get("inputs"))
        # Phase 5: an unsupported-operation refusal is an EditPlanInfeasibleError, but it is a CAPABILITY limit,
        # not a material-insufficiency one — surface it under its own category so the app can explain the real
        # reason (and keep the selected version) instead of the generic "not enough footage" copy.
        _eng = locals().get("engine")
        if cat == "material_infeasible" and getattr(_eng, "last_diagnostics", {}).get("final") == "unsupported_operation":
            cat = "unsupported_operation"
        # Phase 2 (revision messaging): a PRESERVATION VIOLATION is also raised as an EditPlanInfeasibleError
        # (classified material_infeasible), but it is NOT a material-insufficiency — the revise WOULD change
        # clips the user did not ask to change. Surface it under its own category so the app shows the correct
        # reason (the current version was kept) instead of prepending the generic "material can't fill the
        # target" duration copy. Mirrors the unsupported_operation promotion above.
        if cat == "material_infeasible" and getattr(_eng, "last_diagnostics", {}).get("final") == "preservation_violation":
            cat = "preservation_violation"
        # Phase 1 — privacy-safe validator diagnostics. Emit LOW-CARDINALITY error codes (never raw user
        # instructions, media paths, GPS, images, or raw model output) so invalid_after_repair is debuggable in
        # CloudWatch and future metrics. Correlation id (job_id) stays in the log, never a metric dimension.
        _diag = getattr(_eng, "last_diagnostics", {}) or {}
        if cat in ("invalid_after_repair", "material_infeasible", "unsupported_operation", "preservation_violation"):
            _inp = locals().get("inputs")
            print(json.dumps({
                "msg": "worker_validation_diag",
                "job_id": job_id,
                "operation_type": (getattr(_inp, "revision_context", None) or {}).get("mode", "original") if _inp else "unknown",
                "terminal": _diag.get("final", cat),
                "repairs_used": _diag.get("executability_repairs_used", 0),
                "final_error_codes": _validator_error_codes(_diag.get("final_errors") or []),
                "usable_moment_count": len(getattr(_inp, "moments", []) or []) if _inp else None,
                "target_seconds": (getattr(_inp, "creative_intent", None) or {}).get("target_duration_seconds") if _inp else None,
                "directive_categories": _directive_categories(_inp),
            })[:1500])
        # P0 Beta Observability: GenerationFailed count keyed by a LOW-CARDINALITY error_category (the design's
        # throttle|quota|validation|provider|transport|none enum), mapped from the worker's failure category.
        if _emit_metrics is not None:
            try:
                _ec = {
                    "invalid_after_repair": "validation", "material_infeasible": "validation",
                    "unsupported_operation": "validation", "preservation_violation": "validation",
                    "provider_exhausted": "quota", "provider_throttled": "throttle",
                    "provider_error": "provider", "transport": "transport",
                }.get(cat, "provider")
                _op = (getattr(locals().get("inputs"), "revision_context", None) or {}).get("mode", "original")
                _emit_metrics({"GenerationFailed": 1.0},
                              {"env": _ENV, "service": "worker", "op_type": _op, "error_category": _ec})
                if _ec == "throttle":
                    _emit_metrics({"BedrockThrottles": 1.0},
                                  {"env": _ENV, "service": "worker", "model_id": _PRIMARY_MODEL})
            except Exception:  # noqa: BLE001
                pass
        store.fail(job_id, cat, detail, token)
        store.delete_staging(prefix)
        # Phase 4: FAILED generation refunds the user allowance but KEEPS incurred Bedrock spend (correction
        # 3/4). Release the active-job slot (exactly once).
        _incurred = 0.0
        try:
            _incurred = _job_cost_usd(getattr(_eng, "last_diagnostics", {}) or {})
        except Exception:  # noqa: BLE001
            _incurred = 0.0
        _quota_release_job(job, incurred_usd=_incurred)
        return f"failed:{cat}"


def _plan_to_dict(plan) -> dict:
    """EditPlanV2Contract -> plain dict for DynamoDB. Pydantic v2 model_dump, else dict()."""
    if hasattr(plan, "model_dump"):
        return plan.model_dump(mode="json")
    if hasattr(plan, "dict"):
        return plan.dict()
    return dict(plan)


def handler(event, context):
    """SQS batch handler. Returns partial-batch failures so a single bad message doesn't re-drive the batch.
    Also handles the EventBridge reconcile sentinel {reconcile:true} (concern 6: lost-enqueue recovery)."""
    store = _jobs.JobStore()
    if isinstance(event, dict) and event.get("reconcile") is True:
        reenq = store.reconcile_lost_enqueue()
        # P0 Beta Security Phase 4 crash-recovery: release AI-quota reservations + active-job slots leaked by a
        # worker that crashed mid-run or died between the store terminal-transition and the quota settle/release.
        # sweep_quota_orphans stamps each row quota_released=1 (exactly-once); we release conservatively (refund
        # allowance, free the slot, record 0 incurred — a crashed attempt's cost is an accepted under-count, per
        # the design's failure-window table, never an over-charge).
        orphans = []
        try:
            orphans = store.sweep_quota_orphans()
            for o in orphans:
                _quota_release_job({"owner": o["owner"], "operation_id": o["operation_id"],
                                    "job_id": o["job_id"]}, incurred_usd=0.0)
        except Exception as e:  # noqa: BLE001 — sweep is best-effort; never break the reconcile tick
            print(json.dumps({"msg": "worker_quota_sweep_error", "error": f"{type(e).__name__}: {e}"[:300]}))
        print(json.dumps({"msg": "worker_reconcile", "reenqueued": reenq,
                          "quota_orphans_released": len(orphans)}))
        return {"reenqueued": reenq, "quota_orphans_released": len(orphans)}
    failures = []
    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
            jid = body["job_id"]
            # P0 Beta Observability: QueueWaitMs = how long this message sat in SQS before the worker picked it
            # up. Derived from the FREE SQS-provided SentTimestamp attribute (ms since epoch) — no enqueue-ts
            # change to the API send path, no custom timestamp on the body. Worker-execution time is measured
            # separately (WorkerProcessingMs below), so queue wait is never conflated with inference time.
            if _emit_metrics is not None:
                try:
                    _op = (body.get("revision_context") or {}).get("mode", "original") \
                        if isinstance(body.get("revision_context"), dict) else "original"
                    _emit_metrics({"GenerationStarted": 1.0},
                                  {"env": _ENV, "service": "worker", "op_type": _op})
                    _sent = (record.get("attributes") or {}).get("SentTimestamp")
                    if _sent:
                        _wait = max(0.0, time.time() * 1000.0 - float(_sent))
                        _emit_metrics({"QueueWaitMs": _wait}, {"env": _ENV, "service": "worker", "op_type": _op})
                except Exception:  # noqa: BLE001 — telemetry must never break the batch
                    pass
            _t0 = time.time()
            outcome = _run_one(store, jid)
            if _emit_metrics is not None:
                try:
                    _emit_metrics({"WorkerProcessingMs": (time.time() - _t0) * 1000.0},
                                  {"env": _ENV, "service": "worker"})
                except Exception:  # noqa: BLE001
                    pass
            print(json.dumps({"msg": "worker_outcome", "job_id": jid, "outcome": outcome}))
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"msg": "worker_record_error", "error": f"{type(e).__name__}: {e}"[:300]}))
            failures.append({"itemIdentifier": record.get("messageId", "")})
    return {"batchItemFailures": failures}
