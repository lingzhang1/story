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


def _build_engine():
    """Mirror apps/api/app/deps.get_edit_planner_engine so the worker runs the IDENTICAL model path
    (Opus primary -> Sonnet fallback, 2 executability repairs)."""
    from model_gateway import BedrockModelGateway, FallbackModelGateway
    model = os.environ.get("STORY_EDIT_PLANNER_MODEL", "us.anthropic.claude-opus-4-6-v1")
    fb = os.environ.get("STORY_LLM_FALLBACK_MODEL", "us.anthropic.claude-sonnet-4-6")
    primary = BedrockModelGateway(model_id=model)
    gw = primary if (not fb or fb == model) else FallbackModelGateway(primary, BedrockModelGateway(model_id=fb))
    return RealEditPlannerEngine(gw, executability_repair_attempts=2)


def _build_coverage_engine():
    """Mirror apps/api/app/deps.get_story_coverage_v2_engine so the worker runs the IDENTICAL two-call
    Coverage path (Mapper + Judge, Opus primary -> Sonnet fallback). Frozen prompts/contract untouched."""
    from model_gateway import BedrockModelGateway, FallbackModelGateway
    from story_coverage_v2 import RealStoryCoverageV2Engine
    model = os.environ.get("STORY_COVERAGE_MODEL", "us.anthropic.claude-opus-4-6-v1")
    fb = os.environ.get("STORY_LLM_FALLBACK_MODEL", "us.anthropic.claude-sonnet-4-6")
    primary = BedrockModelGateway(model_id=model)
    gw = primary if (not fb or fb == model) else FallbackModelGateway(primary, BedrockModelGateway(model_id=fb))
    return RealStoryCoverageV2Engine(gw, model_id=model)


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
        return _run_coverage(store, job_id, job)
    if op == _jobs.OP_EDIT_PLAN:
        return _run_edit_plan(store, job_id, job)
    # Unknown operation: fail the job safely (never execute an unrecognized payload against any engine).
    store.fail(job_id, "unknown_operation", f"operation_type={op!r} not in {sorted(_jobs.KNOWN_OPERATIONS)}")
    return f"failed:unknown_operation"


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
        return "completed" if ok else "publish_lost_lease"
    except Exception as exc:  # noqa: BLE001
        cat, detail = _classify_coverage(exc)
        store.fail(job_id, cat, detail, token)
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
                                             "calls", "executability_repairs_used")}
        diag_out["planning_mode"] = "multimodal" if images else "text_only"
        diag_out["sheet_count"] = len(images)
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
                          "repairs": diag_out.get("executability_repairs_used")})[:1500])
        # complete is conditional on running + our lease_token -> a stale worker can't publish over us.
        ok = store.complete(job_id, _plan_to_dict(plan), diag_out, token)
        store.delete_staging(prefix)
        return "completed" if ok else "publish_lost_lease"
    except Exception as exc:  # noqa: BLE001 — classify everything into a terminal failure
        cat, detail = _classify(exc, locals().get("inputs"))
        store.fail(job_id, cat, detail, token)
        store.delete_staging(prefix)
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
        print(json.dumps({"msg": "worker_reconcile", "reenqueued": reenq}))
        return {"reenqueued": reenq}
    failures = []
    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
            jid = body["job_id"]
            outcome = _run_one(store, jid)
            print(json.dumps({"msg": "worker_outcome", "job_id": jid, "outcome": outcome}))
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"msg": "worker_record_error", "error": f"{type(e).__name__}: {e}"[:300]}))
            failures.append({"itemIdentifier": record.get("messageId", "")})
    return {"batchItemFailures": failures}
