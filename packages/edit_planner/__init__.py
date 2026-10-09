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

PROMPT_VERSION = "edit_plan/3"  # R-c executability correction (v2 preserved for reproducibility)
TASK = "edit_plan.generate"
MODEL_ID = "us.anthropic.claude-opus-4-6-v1"
DURATION_TOLERANCE = 0.20  # ±20% hard feasibility tolerance (frozen)

# v3 adds an explicit EXECUTABILITY INVARIANTS section to the frozen v2 creative body (owner-approved,
# narrowly scoped). The previous frozen prompt stays on disk at prompts/edit_plan/2/system.md for
# reproducibility; switch _PROMPT_PATH back to "2" to reproduce the pre-R-c behavior exactly.
_PROMPT_PATH = Path(__file__).resolve().parent.parent.parent / "prompts" / "edit_plan" / "3" / "system.md"

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


class MalformedPlanError(ValueError):
    """The plan or its inputs are structurally malformed (wrong shapes/types) rather than merely
    non-executable. Distinct from a validator error-string: this is a CLIENT/input fault that must
    surface as a clean 422, never an unhandled 500. Carries a human-readable reason."""


# ---------------------------------------------------------------------------
# Shared timeline arithmetic — the SINGLE source of truth used by BOTH the
# executability validator and the repair/normalization layer, so the two can
# never disagree about what a plan's timeline is. Pure, deterministic, no model.
# ---------------------------------------------------------------------------

# How far a segment's declared output_duration may sit from (span / speed) before it is an
# executability ERROR. Mirrors the validator's historical gate: max(0.5s, 25% of expected).
SPEED_CONSISTENCY_ABS = 0.5
SPEED_CONSISTENCY_REL = 0.25
# A declared output within THIS of the exact (span/speed) is a harmless rounding artefact the
# normalizer may snap to the exact value (preserves source range + speed; changes only the
# redundant derived field). Deliberately far tighter than the error gate above.
ROUND_SNAP_ABS = 0.15


def _useful_ranges(moment: dict) -> list[tuple[float, float]]:
    """Read a Moment's useful_segments into [(start, end), ...] number pairs.

    The frozen wire shape the iOS client sends is [[a, b], ...] number pairs (RenderSupport maps the
    MomentUnderstanding observed.useful_segments [{start_time,end_time}] into pairs before sending).
    This reader ALSO accepts the {start,end} / {start_time,end_time} dict shape defensively so a
    malformed/legacy input yields a clean MalformedPlanError (-> 422) instead of an unhandled
    KeyError/IndexError (-> 500). Returns [] when the field is absent/empty (the validator then
    skips the useful-overlap check, exactly as before)."""
    raw = moment.get("useful_segments")
    if not raw:
        return []
    out: list[tuple[float, float]] = []
    for u in raw:
        if isinstance(u, dict):
            lo = u.get("start", u.get("start_time"))
            hi = u.get("end", u.get("end_time"))
        elif isinstance(u, (list, tuple)) and len(u) >= 2:
            lo, hi = u[0], u[1]
        else:
            raise MalformedPlanError(
                f"useful_segments entry has unsupported shape: {u!r} "
                "(expected [start, end] or {start, end})")
        try:
            out.append((float(lo), float(hi)))
        except (TypeError, ValueError) as e:
            raise MalformedPlanError(
                f"useful_segments entry has non-numeric bounds: {u!r}") from e
    return out


@dataclass
class SegmentTimeline:
    """Deterministic timeline arithmetic for ONE segment. All derived here so validator and
    normalizer agree by construction."""
    source_start: float | None
    source_end: float | None
    speed: float
    declared_output: float
    transition_type: str | None
    transition_duration: float | None

    @property
    def span(self) -> float | None:
        if self.source_start is None or self.source_end is None:
            return None
        return self.source_end - self.source_start

    @property
    def expected_output(self) -> float | None:
        """Playback-speed-consistent output duration: span / speed."""
        sp = self.span
        if sp is None or sp <= 0 or self.speed <= 0:
            return None
        return sp / self.speed

    def output_consistency_error(self) -> float | None:
        """abs(declared_output - expected_output); None when not computable."""
        exp = self.expected_output
        if exp is None or self.declared_output <= 0:
            return None
        return abs(self.declared_output - exp)

    def is_output_inconsistent(self) -> bool:
        """True when the declared output is an EXECUTABILITY error (beyond the error gate)."""
        exp = self.expected_output
        err = self.output_consistency_error()
        if exp is None or err is None:
            return False
        return err > max(SPEED_CONSISTENCY_ABS, SPEED_CONSISTENCY_REL * exp)

    def is_output_snappable(self) -> bool:
        """True when the declared output differs from exact (span/speed) only by a harmless
        rounding artefact the normalizer may safely snap. A mismatch like 7.5s span vs 2.5s
        output is NOT snappable (far outside the snap window) and must go to model repair."""
        err = self.output_consistency_error()
        return err is not None and err <= ROUND_SNAP_ABS and err > 0


def _segment_timeline(seg: dict) -> SegmentTimeline:
    tr = seg.get("transition") or None
    return SegmentTimeline(
        source_start=seg.get("source_start_seconds"),
        source_end=seg.get("source_end_seconds"),
        speed=seg.get("speed") or 1.0,
        declared_output=seg.get("output_duration_seconds") or 0.0,
        transition_type=(tr or {}).get("type"),
        transition_duration=(tr or {}).get("duration_seconds"),
    )


def _overlapping_transition_seconds(segs: list[dict]) -> float:
    """Total seconds the timeline is SHORTENED by overlapping transitions. The Media Engine realizes
    a crossfade as a two-clip OVERLAP (the frozen crossfade boundary-sweep: outgoing clip overlaps the
    incoming by the transition duration), so a crossfade on segment i pulls the wall-clock timeline in
    by its duration. fade_in / fade_out / dip_to_black are IN-PLACE (no overlap) and do not shorten it.
    Used so total-timeline arithmetic matches what the renderer actually produces."""
    overlap = 0.0
    for s in segs:
        tr = s.get("transition") or {}
        if tr.get("type") == "crossfade":
            td = tr.get("duration_seconds")
            if isinstance(td, (int, float)) and td > 0:
                overlap += float(td)
    return overlap


def timeline_total_seconds(segs: list[dict]) -> float:
    """Deterministic wall-clock duration of the whole plan: sum of segment output durations minus
    the seconds removed by overlapping (crossfade) transitions. SINGLE implementation shared by the
    validator and the normalizer."""
    raw = sum((s.get("output_duration_seconds") or 0.0) for s in segs)
    return raw - _overlapping_transition_seconds(segs)


def normalize_plan(plan: dict, inputs: EditPlanInputs) -> tuple[dict, list[str]]:
    """Apply ONLY mechanically-unambiguous corrections that preserve the model's intended source
    ranges, speed, transition and ordering choices. Returns (possibly-mutated copy, notes).

    The ONLY normalization performed: snap a segment's redundant output_duration_seconds to the exact
    (span / speed) when it is already within ROUND_SNAP_ABS of it — a harmless rounding artefact. This
    changes a DERIVED field only; it never truncates a source range, changes speed, drops/reorders a
    segment, or alters narrative emphasis. Anything outside the snap window is left untouched for model
    repair. Deterministic; no model call."""
    import copy
    out = copy.deepcopy(plan)
    notes: list[str] = []
    for i, s in enumerate(out.get("segments", [])):
        tl = _segment_timeline(s)
        if tl.is_output_snappable():
            exact = round(tl.expected_output, 2)
            before = s.get("output_duration_seconds")
            s["output_duration_seconds"] = exact
            notes.append(f"seg{i}: snapped output_duration {before}->{exact}s "
                         f"(exact span/speed; |delta|<= {ROUND_SNAP_ABS}s)")
    return out, notes


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
    for i, s in enumerate(segs):
        aid = s.get("asset_id")
        if aid not in moments:
            errs.append(f"seg{i}: asset_id '{aid}' is not a known Moment id")
            continue
        dur = moments[aid]["duration_seconds"]
        tl = _segment_timeline(s)
        a, b = tl.source_start, tl.source_end
        if a is None or b is None:
            errs.append(f"seg{i}: missing source in/out")
        else:
            if a < 0 or b <= a:
                errs.append(f"seg{i}: invalid source range [{a},{b}]")
            if b > dur + 0.05:
                errs.append(f"seg{i}: source_end {b} exceeds Moment duration {dur}")
            us = _useful_ranges(moments[aid])  # robust: pairs OR dicts; MalformedPlanError on junk
            if us and not any(not (b <= u[0] or a >= u[1]) for u in us):
                errs.append(f"seg{i}: source range [{a},{b}] overlaps NO useful_segment {us}")
        od = tl.declared_output
        if od <= 0:
            errs.append(f"seg{i}: non-positive output_duration {od}")
        if s.get("native_audio") not in NATIVE:
            errs.append(f"seg{i}: native_audio missing/invalid")
        sp = tl.speed
        if sp <= 0:
            errs.append(f"seg{i}: non-positive speed {sp}")
        elif tl.is_output_inconsistent():
            expected = tl.expected_output
            errs.append(f"seg{i}: output {od}s inconsistent with source span {tl.span:.1f}s @ speed {sp} "
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
    total_out = timeline_total_seconds(segs)  # shared arithmetic (accounts for crossfade overlap)
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


def _build_repair(inputs: EditPlanInputs, bad_plan: dict, errs: list[str]) -> str:
    """Repair turn: hand the model back ITS OWN schema-valid plan plus the deterministic validator's
    exact complaints, and ask it to correct ONLY those inconsistencies while preserving its narrative
    intent (segment selection, order, speed and transition choices). The model does NOT self-certify —
    the deterministic validator re-checks the result and remains authoritative."""
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
    return (
        "Your previous EditPlan was schema-valid but FAILED the deterministic executability check. Fix ONLY "
        "the specific problems listed below. PRESERVE your narrative intent — keep the same Moment selection, "
        "segment ORDER, speeds, native-audio and transition choices wherever possible; change the smallest set "
        "of numbers needed to make the plan executable.\n\n"
        "EXECUTABILITY RULES you must satisfy:\n"
        "- For every segment: output_duration_seconds MUST equal (source_end_seconds - source_start_seconds) / "
        "speed (speed defaults to 1.0). If you want a segment SHORTER, shorten its source range or raise its "
        "speed; if LONGER, extend the source range (staying within the Moment's real duration and useful "
        "segments) or lower its speed. Never leave output_duration inconsistent with the source span and speed.\n"
        "- The total timeline duration (sum of output durations, minus any crossfade overlap) MUST be within "
        f"±{int(DURATION_TOLERANCE*100)}% of target_duration_seconds. Aim AT the target, not the edge. If the "
        "usable material genuinely cannot reach the target, return feasible=false with a one-line "
        "infeasible_reason and your best shorter plan — do NOT invent footage.\n"
        "- source ranges stay within each Moment's real duration and useful segments; asset_id stays a given "
        "Moment id.\n\n"
        "VALIDATOR ERRORS to fix:\n" + "\n".join(f"- {e}" for e in errs) + "\n\n"
        "YOUR PREVIOUS PLAN (correct it):\n" + json.dumps(bad_plan, indent=2) + "\n\n"
        "INPUT (unchanged):\n" + json.dumps(payload, indent=2) + "\n\n"
        "Return ONLY the corrected EditPlan via the tool.")


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
    """Opus 4.6 via the generic ModelGateway. Validates deterministically; never fabricates.

    Executability-repair policy (MVP, bounded):
      1. one Opus call (gateway handles SCHEMA repair internally);
      2. apply only SAFE deterministic normalization (redundant-field rounding snaps);
      3. validate executability;
      4. if still invalid, ONE additional model-repair turn carrying the EXACT validator errors,
         asking Opus to fix only those inconsistencies while preserving narrative intent;
      5. re-normalize + re-validate;
      6. if still invalid, fail honestly (StructuredOutputError -> 503). The deterministic validator
         is ALWAYS authoritative; the model never self-certifies.
    `last_diagnostics` records what happened for the reliability measurement / server logs."""

    def __init__(self, gateway: ModelGateway, *, max_tokens: int = 2600, executability_repair_attempts: int = 1):
        self._gw = gateway
        self._system = _load_system()
        self._max_tokens = max_tokens
        self._exec_repairs = max(0, executability_repair_attempts)
        self.last_diagnostics: dict[str, Any] = {}

    def generate(self, inputs: EditPlanInputs) -> EditPlanV2Contract:
        diag: dict[str, Any] = {
            "model_calls": 0, "executability_repairs_used": 0,
            "first_pass_executable": False, "normalized": False,
            "normalize_notes": [], "repaired": False,
            "input_tokens": 0, "output_tokens": 0, "final": "pending",
        }

        def _call(user_content: str) -> dict:
            req = StructuredRequest(
                task=TASK, schema=SCHEMA, prompt_version=PROMPT_VERSION, system=self._system,
                user_content=user_content, max_repair_attempts=2,
                max_tokens=self._max_tokens, temperature=0.0)
            result = self._gw.generate_structured(req)  # raises StructuredOutputError/ProviderError
            diag["model_calls"] += 1
            u = result.usage
            if u:
                diag["input_tokens"] += (u.input_tokens or 0)
                diag["output_tokens"] += (u.output_tokens or 0)
            return result.data

        # 1-3: initial generation, safe normalization, executability validation.
        plan = _call(_build_user(inputs))
        raw_errs = validate_plan(plan, inputs)
        diag["first_pass_executable"] = not raw_errs
        plan, notes = normalize_plan(plan, inputs)
        if notes:
            diag["normalized"] = True
            diag["normalize_notes"] = notes
        errs = validate_plan(plan, inputs)

        # 4-5: bounded model repair carrying the exact errors.
        for _ in range(self._exec_repairs):
            if not errs:
                break
            diag["executability_repairs_used"] += 1
            diag["repaired"] = True
            plan = _call(_build_repair(inputs, plan, errs))
            plan, notes = normalize_plan(plan, inputs)
            if notes:
                diag["normalized"] = True
                diag["normalize_notes"] = diag["normalize_notes"] + notes
            errs = validate_plan(plan, inputs)

        # 6: authoritative verdict.
        if errs:
            diag["final"] = "invalid_after_repair"
            diag["final_errors"] = errs
            self.last_diagnostics = diag
            # schema-valid but NON-executable even after repair. Never pass it on.
            raise StructuredOutputError(f"EditPlan failed deterministic validation after repair: {errs}")
        if plan.get("feasible") is False:
            diag["final"] = "infeasible"
            self.last_diagnostics = diag
            raise EditPlanInfeasibleError(plan.get("infeasible_reason") or "material cannot support a plan")
        diag["final"] = "executable"
        self.last_diagnostics = diag
        return _to_contract(plan, inputs)


class MockEditPlannerEngine:
    """Deterministic mock for tests/preview: one keep segment per Moment, scaled to target."""

    def generate(self, inputs: EditPlanInputs) -> EditPlanV2Contract:
        target = inputs.creative_intent["target_duration_seconds"]
        moments = inputs.moments
        per = max(0.5, target / max(1, len(moments)))
        segs = []
        for i, m in enumerate(moments):
            ranges = _useful_ranges(m)
            us = ranges[0] if ranges else (0.0, min(m["duration_seconds"], per))
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
    "SPEED_CONSISTENCY_ABS", "SPEED_CONSISTENCY_REL", "ROUND_SNAP_ABS",
    "EditPlanInputs", "EditPlanInfeasibleError", "MalformedPlanError",
    "SegmentTimeline", "validate_plan", "normalize_plan", "timeline_total_seconds",
    "EditPlannerEngine", "RealEditPlannerEngine", "MockEditPlannerEngine",
]
