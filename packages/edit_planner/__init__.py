"""Edit Planner Engine — real Opus 4.6 edit planning (Milestone M-d, frozen edit_plan/2).

Owns:
  - the versioned production prompt (prompts/edit_plan/2/system.md), frozen verbatim from the validated
    experimental prompt edit_plan/exp-v3;
  - the structured-output schema (tool-use) for an EditPlan;
  - construction of the planning request from the Story inputs;
  - a DETERMINISTIC executability validator — the hard gate; the model NEVER self-certifies;
  - conversion of model output into the canonical EditPlanV2Contract (server mints ids);
  - task-level failure (never fabricate an EditPlan).

Does NOT: decode/render/mix (Media Engine), select a music provider (adapter), fabricate Moments/footage.

Inputs: CreativeIntent, StoryGuide/1, StoryCoverage/2, completed MomentUnderstanding[], MusicPlan/1, and
OPTIONALLY a selected MusicAsset + MusicAnalysis. Music is OPTIONAL — no-music planning is supported.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol, runtime_checkable
from uuid import uuid4

from contracts.schemas.ai_contracts import (
    EditPlanV2Contract,
    EditSegmentV2Contract,
    MusicAlignment,
    OutputFormat,
)
from model_gateway import ModelGateway, StructuredOutputError, StructuredRequest

PROMPT_VERSION = "edit_plan/2"
TASK = "edit_plan.generate"
MODEL_ID = "us.anthropic.claude-opus-4-6-v1"
DURATION_TOLERANCE = 0.20  # ±20% hard feasibility tolerance (frozen)

_PROMPT_PATH = Path(__file__).resolve().parent.parent.parent / "prompts" / "edit_plan" / "2" / "system.md"

TRANSITION = ["cut", "crossfade", "fade_in", "fade_out", "dip_to_black"]
NATIVE = ["keep", "duck", "mute"]
ANCHOR = ["beat", "downbeat", "highlight", "none"]

# Tool-use schema the model fills (free-string ids; server mints real UUIDs on the canonical contract).
SCHEMA: dict[str, Any] = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "target_duration_seconds": {"type": "number", "exclusiveMinimum": 0},
        "feasible": {"type": "boolean"},
        "infeasible_reason": {"type": "string"},
        "segments": {"type": "array", "minItems": 1, "items": {
            "type": "object", "additionalProperties": False,
            "properties": {
                "order": {"type": "integer", "minimum": 0},
                "asset_id": {"type": "string", "description": "a Moment id present in the input moments[]"},
                "source_start_seconds": {"type": "number", "minimum": 0},
                "source_end_seconds": {"type": "number", "exclusiveMinimum": 0},
                "output_duration_seconds": {"type": "number", "exclusiveMinimum": 0},
                "speed": {"type": "number", "exclusiveMinimum": 0},
                "transition": {"type": "object", "additionalProperties": False, "properties": {
                    "type": {"type": "string", "enum": TRANSITION},
                    "duration_seconds": {"type": "number", "minimum": 0}}, "required": ["type"]},
                "narrative_role": {"type": "string"},
                "native_audio": {"type": "string", "enum": NATIVE},
                "music_alignment": {"type": "object", "additionalProperties": False, "properties": {
                    "anchor": {"type": "string", "enum": ANCHOR}, "note": {"type": "string"}},
                    "required": ["anchor"]},
            },
            "required": ["order", "asset_id", "source_start_seconds", "source_end_seconds",
                         "output_duration_seconds", "native_audio"]}},
    },
    "required": ["target_duration_seconds", "segments"],
}


def _load_system() -> str:
    text = _PROMPT_PATH.read_text()
    # strip the leading HTML provenance comment block, keep the frozen body verbatim
    if text.lstrip().startswith("<!--"):
        text = text.split("-->", 1)[1]
    return text.strip()


class EditPlanInfeasibleError(RuntimeError):
    """Material cannot support a plan; carries the reason. A designed failure, not a crash."""


@dataclass
class EditPlanInputs:
    story_id: str
    creative_intent_id: str
    creative_intent: dict
    story_guide: dict
    story_coverage: dict
    moments: list[dict]  # each: {id, duration_seconds, useful_segments, summary?, events?}
    music_plan: dict
    output_format: str = "vertical"
    music_asset_id: str | None = None
    music_plan_id: str | None = None
    music_analysis: dict | None = None  # frozen music_analysis/1 shape; None => no-music planning


# ---------------------------------------------------------------------------
# Deterministic executability validator — the PRODUCTION hard gate.
# Ported from evals/edit_planner. Returns [] when executable, else error strings.
# ---------------------------------------------------------------------------
def validate_plan(plan: dict, inputs: EditPlanInputs) -> list[str]:
    errs: list[str] = []
    moments = {m["id"]: m for m in inputs.moments}
    has_analysis = inputs.music_analysis is not None
    segs = plan.get("segments", [])
    if not segs:
        errs.append("no segments")
    orders = [s.get("order") for s in segs]
    if orders != sorted(orders):
        errs.append(f"segment order not monotonic: {orders}")
    if len(set(orders)) != len(orders):
        errs.append(f"duplicate order values: {orders}")
    total_out = 0.0
    for i, s in enumerate(segs):
        aid = s.get("asset_id")
        if aid not in moments:
            errs.append(f"seg{i}: asset_id '{aid}' is not a known Moment id")
            continue
        dur = moments[aid]["duration_seconds"]
        a, b = s.get("source_start_seconds"), s.get("source_end_seconds")
        if a is None or b is None:
            errs.append(f"seg{i}: missing source in/out")
        else:
            if a < 0 or b <= a:
                errs.append(f"seg{i}: invalid source range [{a},{b}]")
            if b > dur + 0.05:
                errs.append(f"seg{i}: source_end {b} exceeds Moment duration {dur}")
            us = moments[aid].get("useful_segments") or []
            if us and not any(not (b <= u[0] or a >= u[1]) for u in us):
                errs.append(f"seg{i}: source range [{a},{b}] overlaps NO useful_segment {us}")
        od = s.get("output_duration_seconds", 0)
        if od <= 0:
            errs.append(f"seg{i}: non-positive output_duration {od}")
        total_out += od or 0
        if s.get("native_audio") not in NATIVE:
            errs.append(f"seg{i}: native_audio missing/invalid")
        sp = s.get("speed") or 1.0
        if sp <= 0:
            errs.append(f"seg{i}: non-positive speed {sp}")
        elif a is not None and b is not None and b > a and od > 0:
            expected = (b - a) / sp
            if abs(expected - od) > max(0.5, 0.25 * expected):
                errs.append(f"seg{i}: output {od}s inconsistent with source span {b-a:.1f}s @ speed {sp} "
                            f"(expected ~{expected:.1f}s)")
        tr = s.get("transition")
        if tr and tr.get("type") in ("crossfade", "fade_in", "fade_out", "dip_to_black"):
            td = tr.get("duration_seconds")
            if td is not None and (td < 0 or (od and td > od)):
                errs.append(f"seg{i}: transition {tr.get('type')} duration {td}s infeasible vs segment {od}s")
        if not has_analysis:
            ma = s.get("music_alignment")
            if ma and ma.get("anchor") not in (None, "none"):
                errs.append(f"seg{i}: music_alignment anchor '{ma.get('anchor')}' set without MusicAnalysis")
    target = inputs.creative_intent["target_duration_seconds"]
    declared_infeasible = plan.get("feasible") is False
    if total_out and not declared_infeasible and abs(total_out - target) / target > DURATION_TOLERANCE:
        errs.append(f"total output {total_out:.1f}s is >{int(DURATION_TOLERANCE*100)}% off target {target}s")
    if declared_infeasible and not (plan.get("infeasible_reason") or "").strip():
        errs.append("feasible=false but no infeasible_reason given")
    return errs


@runtime_checkable
class EditPlannerEngine(Protocol):
    def generate(self, inputs: EditPlanInputs) -> EditPlanV2Contract: ...


def _build_user(inputs: EditPlanInputs) -> str:
    import json
    payload = {
        "creative_intent": inputs.creative_intent,
        "story_guide": inputs.story_guide,
        "story_coverage": inputs.story_coverage,
        "moments": inputs.moments,
        "music_plan": inputs.music_plan,
        "target_duration_seconds": inputs.creative_intent["target_duration_seconds"],
    }
    if inputs.music_analysis is not None:
        payload["music_analysis"] = inputs.music_analysis
    return ("Plan the EditPlan for THIS Story from the material below. Use only the given Moment ids and their "
            "real/useful ranges. Plan to the Story target duration. Respect native audio.\n\nINPUT:\n"
            + json.dumps(payload, indent=2) + "\n\nReturn ONLY the EditPlan via the tool.")


def _to_contract(plan: dict, inputs: EditPlanInputs) -> EditPlanV2Contract:
    """Server mints real UUIDs for id fields; model's free-string asset_ids are mapped to the Moment UUIDs."""
    segs = []
    for s in plan.get("segments", []):
        ma = s.get("music_alignment")
        segs.append(EditSegmentV2Contract(
            order=s["order"],
            asset_id=s["asset_id"],  # already a Moment UUID (validated to exist)
            source_start_seconds=s.get("source_start_seconds"),
            source_end_seconds=s.get("source_end_seconds"),
            output_duration_seconds=s["output_duration_seconds"],
            speed=s.get("speed"),
            transition=None,  # Media Engine realizes transitions; keep the frozen minimal contract
            narrative_role=s.get("narrative_role"),
            native_audio=s["native_audio"],
            music_alignment=MusicAlignment(**ma) if ma else None,
        ))
    return EditPlanV2Contract(
        id=uuid4(),
        story_id=inputs.story_id,
        creative_intent_id=inputs.creative_intent_id,
        target_duration_seconds=inputs.creative_intent["target_duration_seconds"],
        output_format=inputs.output_format,
        music_asset_id=inputs.music_asset_id,
        music_plan_id=inputs.music_plan_id,
        music_analysis_ref=None,  # referenced by handle at the API layer; not re-embedded here
        feasible=plan.get("feasible", True),
        infeasible_reason=plan.get("infeasible_reason"),
        segments=segs,
    )


class RealEditPlannerEngine:
    """Opus 4.6 via the generic ModelGateway. Validates deterministically; never fabricates."""

    def __init__(self, gateway: ModelGateway, *, max_tokens: int = 2600):
        self._gw = gateway
        self._system = _load_system()
        self._max_tokens = max_tokens

    def generate(self, inputs: EditPlanInputs) -> EditPlanV2Contract:
        req = StructuredRequest(
            task=TASK, schema=SCHEMA, prompt_version=PROMPT_VERSION, system=self._system,
            user_content=_build_user(inputs), max_repair_attempts=2, max_tokens=self._max_tokens, temperature=0.0)
        result = self._gw.generate_structured(req)  # raises StructuredOutputError on model failure
        plan = result.data
        errs = validate_plan(plan, inputs)
        if errs:
            # The model produced schema-valid JSON but a NON-executable plan. Never pass it on.
            raise StructuredOutputError(f"EditPlan failed deterministic validation: {errs}")
        if plan.get("feasible") is False:
            raise EditPlanInfeasibleError(plan.get("infeasible_reason") or "material cannot support a plan")
        return _to_contract(plan, inputs)


class MockEditPlannerEngine:
    """Deterministic mock for tests/preview: one keep segment per Moment, scaled to target."""

    def generate(self, inputs: EditPlanInputs) -> EditPlanV2Contract:
        target = inputs.creative_intent["target_duration_seconds"]
        moments = inputs.moments
        per = max(0.5, target / max(1, len(moments)))
        segs = []
        for i, m in enumerate(moments):
            us = (m.get("useful_segments") or [[0.0, min(m["duration_seconds"], per)]])[0]
            a, b = us[0], min(us[1], us[0] + per)
            segs.append(EditSegmentV2Contract(
                order=i, asset_id=m["id"], source_start_seconds=a, source_end_seconds=b,
                output_duration_seconds=round(b - a, 2), native_audio="keep"))
        return EditPlanV2Contract(
            id=uuid4(), story_id=inputs.story_id, creative_intent_id=inputs.creative_intent_id,
            target_duration_seconds=target, output_format=inputs.output_format,
            music_asset_id=inputs.music_asset_id, music_plan_id=inputs.music_plan_id, segments=segs)


__all__ = [
    "PROMPT_VERSION", "TASK", "MODEL_ID", "DURATION_TOLERANCE", "SCHEMA",
    "EditPlanInputs", "EditPlanInfeasibleError", "validate_plan",
    "EditPlannerEngine", "RealEditPlannerEngine", "MockEditPlannerEngine",
]
