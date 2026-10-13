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


def _run_one(store: _jobs.JobStore, job_id: str) -> str:
    job = store.get(job_id)
    if not job:
        return "missing"
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
            editorial_mode=b.get("editorial_mode"),
            images=images, creative_brief=env.get("creative_brief"), image_moment_order=order,
            critique_revision=bool(env.get("critique_revision")))

        engine = _build_engine()
        plan = engine.generate(inputs)   # SAME core: v5.2 + validator + fallback + bounded critique
        diag = getattr(engine, "last_diagnostics", {}) or {}

        # Adjustment 3: re-check cancel BEFORE publishing. A cancelled job must not be completed.
        if store.is_cancel_requested(job_id):
            store.mark_cancelled(job_id)
            store.delete_staging(prefix)
            return "cancelled_midrun"

        diag_out = {k: diag.get(k) for k in ("model_calls", "used_fallback", "critique_attempted",
                                             "critique_applied", "first_pass_executable")}
        diag_out["planning_mode"] = "multimodal" if images else "text_only"
        diag_out["sheet_count"] = len(images)
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
