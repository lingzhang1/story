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

import math
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol, runtime_checkable
from uuid import uuid4

from contracts.schemas.ai_contracts import (
    EditPlanV2Contract,
    EditSegmentV2Contract,
    MusicAlignment,
    OutputFormat,
)
from model_gateway import ModelGateway, StructuredOutputError, StructuredRequest, ProviderError

PROMPT_VERSION = "edit_plan/4"  # Editorial Timing significance-weighting amendment (v2/v3 preserved for reproducibility)
TASK = "edit_plan.generate"
MODEL_ID = "us.anthropic.claude-opus-4-6-v1"
DURATION_TOLERANCE = 0.20  # legacy symmetric tolerance — retained for the repair-prompt wording + back-compat
# Asymmetric accept policy (owner decision 2026-10-13): generous on OVERSHOOT (a longer video still ships),
# strict on UNDERSHOOT (a too-short video feels broken). The repair pass still aims at the exact target; these
# only decide ACCEPT vs reject so the user gets a watchable video instead of "couldn't finish your story".
DURATION_OVERSHOOT_TOLERANCE = 0.50   # accept up to +50% longer than the requested duration
DURATION_UNDERSHOOT_TOLERANCE = 0.20  # reject if >20% SHORTER than requested (degenerate / empty-feeling)

# RENDERER CAPABILITY — playback speed. MediaEngineV1 (the on-device renderer) only supports 0.5x–2.0x
# playback (see apps/ios/.../MediaEngineV1.swift SCOPE + StoryCreationCoordinator renderability check), so a
# segment speed outside this window is schema-valid but UNRENDERABLE and crashes the device with
# "segment N speed S out of range [0.5, 2.0]". The planner's schema only requires speed>0, so without this
# gate the model can emit e.g. a 4.0x time-lapse that passes every server check and then fails on-device.
# This is a REJECT bound (routed to bounded repair), NOT an unconditional clamp: a mathematically valid speed
# is not necessarily an editorially valid one, so we let the planner choose an executable alternative
# (shorten the source range / adjust pacing) rather than silently rewriting its numbers. Keep in sync with
# the iOS renderability check and the Phase-4 capability-audit doc.
RENDERER_SPEED_MIN = 0.5
RENDERER_SPEED_MAX = 2.0

# v4 adds ONE "SIGNIFICANCE-WEIGHTED SCREEN TIME" paragraph to the frozen v3 body (which is v2's creative
# body + the EXECUTABILITY INVARIANTS section). Owner-approved via the Editorial Timing Quality Gate: it
# allocates screen time by narrative significance (payoff holds longer; routine footage brief or dropped),
# changing NO duration discipline, native-audio policy, music-alignment, repair behavior, model, or the
# EditPlan/2 schema. The previous frozen prompts stay on disk at prompts/edit_plan/2/system.md and
# prompts/edit_plan/3/system.md; switch _PROMPT_PATH back to "3" (pre-amendment) or "2" (pre-R-c) to reproduce.
#
# v5 (Native-Audio Preservation amendment) is OWNER-ACCEPTED on physical device (TMB keep15/duck6/mute0, mix
# confirmed by listening on build b6c0237) and FROZEN as the approved DEVELOPMENT default. It changes ONLY the
# native-audio clause (preserve-by-default; duck/mute needs an editorial reason; no fixed category list) — no
# schema change. v4 is PRESERVED verbatim on disk and remains reachable (STORY_EDIT_PLAN_VERSION=4), so a
# production surface that has NOT yet approved v5 can still pin v4. Dev-default != production approval.
# Any value other than a directory that exists under prompts/edit_plan/ falls back to the default.
_EDIT_PLAN_DEFAULT = "5"
_EDIT_PLAN_VERSION = os.environ.get("STORY_EDIT_PLAN_VERSION", _EDIT_PLAN_DEFAULT).strip() or _EDIT_PLAN_DEFAULT
_PROMPT_BASE = Path(__file__).resolve().parent.parent.parent / "prompts" / "edit_plan"
if not (_PROMPT_BASE / _EDIT_PLAN_VERSION / "system.md").is_file():
    _EDIT_PLAN_VERSION = _EDIT_PLAN_DEFAULT
PROMPT_VERSION = f"edit_plan/{_EDIT_PLAN_VERSION}"
_PROMPT_PATH = _PROMPT_BASE / _EDIT_PLAN_VERSION / "system.md"

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


# ---------------------------------------------------------------------------
# EDITPLAN CREATIVE-FREEDOM v2 FEATURE FLAGS (owner-approved amendment v2, 2026-10-22).
# Each is INDEPENDENTLY reversible and defaults OFF, so importing/deploying this module is a pure no-op
# until a flag is flipped. The amendment turns imperfectly-satisfied CREATIVE directives from terminal
# validation failures into strong editorial OBJECTIVES: a technically-valid, meaningful plan ships (with an
# honest disclosure of material unmet instructions) instead of burning repeated Opus calls and returning an
# "Adjust instructions" error. Technical/integrity/ownership/renderer-safety/privacy rules stay HARD.
# See specs implementation-plan/milestone-editplan-validation-creative-freedom-amendment-v2.md.
def _flag(name: str) -> bool:
    return (os.environ.get(name, "") or "").strip().lower() in ("1", "true", "yes", "on")


def _objective_directives_on() -> bool:
    # Opening/ending/inclusion/ordering become OBJECTIVES (scored, disclosed) rather than hard errors.
    return _flag("STORY_EDITPLAN_OBJECTIVE_DIRECTIVES")


def _best_valid_retention_on() -> bool:
    # Retain the best technically-valid candidate across the whole attempt chain; ship it rather than fail.
    return _flag("STORY_EDITPLAN_BEST_VALID_RETENTION")


def _approx_duration_soft_on() -> bool:
    # For an APPROXIMATE (not user-exact) target, the duration band is a runaway guard, not a hard reject.
    return _flag("STORY_EDITPLAN_APPROX_DURATION_SOFT")


def _useful_range_soft_on() -> bool:
    # source-range-outside-useful becomes a deterministic nudge target, not a hard reject (real-duration
    # bound stays HARD).
    return _flag("STORY_EDITPLAN_USEFUL_RANGE_SOFT")


# When the approximate-duration band is soft, we still refuse a RUNAWAY plan (a safety/quality guard, not an
# editorial nicety): generous beyond the normal overshoot band so a longer-but-watchable video still ships.
DURATION_RUNAWAY_GUARD = 1.00   # reject only if >+100% of an APPROXIMATE target (degenerate/runaway)

# Stable low-cardinality codes for the creative objectives (surfaced in diag.material_unmet / disclosure).
_OBJECTIVE_CODES = (
    "opening", "ending", "inclusion", "ordering", "adjacency", "exclusion_creative", "approx_duration",
)


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


def _coerce_speed(raw: Any) -> float:
    """Resolve a segment's speed for validation. An ABSENT speed defaults to 1.0 (the schema's documented
    default). A PRESENT speed is validated AS GIVEN — including out-of-range values like 4.0, which the
    renderer-range gate must reject rather than silently normalize. Non-numeric junk (e.g. a string) becomes
    NaN so the validator's finite-number gate rejects it cleanly instead of raising deep in arithmetic.
    Note: a literal present 0 / 0.0 stays 0.0 and is caught by the non-positive gate."""
    if raw is None:
        return 1.0
    try:
        return float(raw)
    except (TypeError, ValueError):
        return float("nan")


def _segment_timeline(seg: dict) -> SegmentTimeline:
    tr = seg.get("transition") or None
    return SegmentTimeline(
        source_start=seg.get("source_start_seconds"),
        source_end=seg.get("source_end_seconds"),
        speed=_coerce_speed(seg.get("speed")),
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


# Error-string prefixes that a DETERMINISTIC reorder can fix (placement only — no content change).
_ORDER_REPAIRABLE_PREFIXES = (
    "directive opening:",            # first segment must be X but is Y
    "directive ending:",             # last segment must be X but is Y
    "directive order_after:",        # A must come after B but is at position ...
    "directive order_adjacent:",     # A must immediately follow B ...
)


def _errors_are_order_only(errs: list[str]) -> bool:
    """True when EVERY error is an opening/ending/order PLACEMENT violation — i.e. fixable by reordering
    segments without touching content, membership, duration, speed or source ranges. An empty list is False
    (nothing to repair). A 'references Moment not in the eligible source set' or 'appears in no segment' error
    is a MEMBERSHIP problem a reorder cannot fix, so it is deliberately NOT in the repairable set."""
    if not errs:
        return False
    return all(any(str(e).startswith(p) for p in _ORDER_REPAIRABLE_PREFIXES) for e in errs)


def repair_directive_placement(plan: dict, inputs: EditPlanInputs) -> dict | None:
    """DETERMINISTIC structural repair: reassign segment `order` so the plan satisfies the hard PLACEMENT
    directives (opening, ending, order_adjacent, order_after) carried in revision_context['directives'].

    Preserves EVERYTHING else exactly — asset_id, source ranges, output_duration, speed, transition,
    native_audio, music_alignment — and never adds, drops, duplicates or reselects a segment. It only changes
    the order in which the SAME segments play. must_include / exclude are membership constraints a reorder
    cannot satisfy, so they are left to the (unchanged) validator + model-repair path.

    Returns a reordered COPY, or None when the placement constraints are unsatisfiable by reordering alone
    (opening/ending Moment absent from the plan, or a cyclic/conflicting order graph) — in which case the
    caller keeps the existing failure path. No model call. No frozen-contract change."""
    import copy as _copy
    ctx = inputs.revision_context or {}
    directives = ctx.get("directives") or {}
    if not isinstance(directives, dict):
        return None
    segs = sorted(plan.get("segments", []), key=lambda s: s.get("order", 0))
    if not segs:
        return None

    def _aid(s):
        return str(s.get("asset_id")).lower() if s.get("asset_id") is not None else None

    def _low(v):
        if isinstance(v, str):
            return v.lower()
        if isinstance(v, list):
            return [_low(x) for x in v]
        return v

    opening = _low(directives.get("opening")) if isinstance(directives.get("opening"), str) else None
    ending = _low(directives.get("ending")) if isinstance(directives.get("ending"), str) else None
    adj = [(a, b) for a, b in (_pairs(directives.get("order_adjacent")) or [])]
    adj = [(a.lower(), b.lower()) for a, b in adj]
    aft = [(a.lower(), b.lower()) for a, b in (_pairs(directives.get("order_after")) or [])]

    present = [_aid(s) for s in segs]
    present_set = set(present)
    # opening/ending must be present to be placeable by reorder; absent => membership issue, not reorderable.
    if opening is not None and opening not in present_set:
        return None
    if ending is not None and ending not in present_set:
        return None

    # Unique assets in current first-occurrence order.
    uniq, seen = [], set()
    for a in present:
        if a not in seen:
            seen.add(a); uniq.append(a)

    # Adjacency chains: B -> A (A glued immediately after B). An asset follows at most one B; guard cycles.
    follow, glued = {}, set()
    for a, b in adj:
        if a in present_set and b in present_set and b not in follow and a not in glued and a != b:
            follow[b] = a; glued.add(a)

    emitted, seq = set(), []
    def _emit_chain(start):
        cur = start
        while cur is not None and cur not in emitted:
            seq.append(cur); emitted.add(cur)
            cur = follow.get(cur)
    if opening is not None:
        _emit_chain(opening)
    for a in uniq:
        if a in emitted or a in glued:
            continue
        _emit_chain(a)
    for a in uniq:                      # defensive: a glued asset whose B was missing
        if a not in emitted:
            seq.append(a); emitted.add(a)

    # order_after[A,B]: A after B (by first-occurrence position). Stable bubble with a cycle bound.
    for _ in range(len(seq) * max(1, len(aft)) + 1):
        pos = {a: i for i, a in enumerate(seq)}; changed = False
        for a, b in aft:
            if a in pos and b in pos and pos[a] < pos[b]:
                seq.remove(a); seq.insert(seq.index(b) + 1, a); changed = True
        if not changed:
            break
    else:
        return None  # could not stabilize -> conflicting/cyclic ordering

    # Placement must hold after after-fixups.
    if opening is not None and (not seq or seq[0] != opening):
        return None
    if ending is not None and (not seq or seq[-1] != ending):
        # ending may conflict with an adjacency chain ending elsewhere -> unrepairable by reorder.
        return None

    # Expand unique order back to full segments (repeats keep original relative order), renumber 0..N-1.
    by_asset = {}
    for s in segs:
        by_asset.setdefault(_aid(s), []).append(s)
    out_segs = []
    for a in seq:
        for s in by_asset.get(a, []):
            out_segs.append(_copy.deepcopy(s))
    placed = set(seq)
    for s in segs:                      # defensive: anything not placed keeps original tail order
        if _aid(s) not in placed:
            out_segs.append(_copy.deepcopy(s))
    for i, s in enumerate(out_segs):
        s["order"] = i
    out = _copy.deepcopy(plan); out["segments"] = out_segs
    return out


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
    sound_preference: str | None = None  # immersive|balanced|music_led; None => infer. Advisory input, no schema change.
    editorial_mode: str | None = None  # highlights|full|custom; None => infer from duration (back-compat). Advisory; no schema change.
    # Creative Revision Foundation (additive, request-only). When present, carries the version-aware context:
    #   {mode: "explore"|"revise", base_version_id, prior_edit_summaries: [...], base_plan?, directives?,
    #    soft_direction?}. Injected into the USER message only (frozen v5.2 system body untouched); None => the
    #   planner behaves exactly as before. For Explore it supplies bounded prior-edit summaries + an explicit
    #   alternative-edit objective; Revise (NL V1, later) will additionally carry the exact base_plan.
    revision_context: dict | None = None
    # MVP multimodal (additive, no schema/contract change): bounded Tier-1 contact-sheet JPEGs (one per Moment,
    # in moments[] order) attached to the SAME request. Empty => text-only A1 planning (the frozen fallback).
    images: list[Any] = field(default_factory=list)  # list[model_gateway.ImageInput]
    # MVP creative direction (additive): a bounded, versioned application-level brief injected into the USER
    # message only — NEVER the frozen v5.2 system body. None => no brief (behavior unchanged).
    creative_brief: str | None = None
    image_moment_order: list[str] = field(default_factory=list)  # Moment ids matching images[], for the map line
    # Phase-6 (experiment Arm D): ONE bounded critique->revision pass AFTER a valid plan. Flag-gated and OFF by
    # default — it costs 2 extra model calls, each re-sending the image payload, so it is the heaviest path and
    # the most quota-fragile. The revised plan is kept ONLY if it also passes the deterministic validator; any
    # failure retains the original valid plan (never blocks the Story). Requires a creative_brief to critique
    # against; a no-brief request skips it.
    critique_revision: bool = False


# ---------------------------------------------------------------------------
# Deterministic executability validator — the PRODUCTION hard gate.
# Ported from evals/edit_planner. Returns [] when executable, else error strings.
# ---------------------------------------------------------------------------
import re as _re


def _parse_target_clip_seconds(soft: str) -> float | None:
    """Extract a PER-CLIP target duration from a pacing instruction, or None when the instruction is not a
    clip-length ask (so 'make it more cinematic' never triggers the timing-only path). Requires BOTH a clip/
    cut/shot/segment word AND an explicit seconds value, e.g. 'shorten each clip to around 5s', 'make the cuts
    about 3 seconds', 'keep shots under 4 sec'. Conservative: anything ambiguous returns None and the request
    takes the normal (model) path."""
    low = (soft or "").lower()
    if not low.strip():
        return None
    if not any(w in low for w in ("clip", "cut", "shot", "segment")):
        return None
    m = _re.search(r"(\d+(?:\.\d+)?)\s*(?:s\b|sec\b|secs\b|second|seconds)", low)
    if not m:
        m = _re.search(r"(?:around|about|under|to|~)\s*(\d+(?:\.\d+)?)", low)
    if not m:
        return None
    try:
        val = float(m.group(1))
    except ValueError:
        return None
    return val if 1.0 <= val <= 30.0 else None


def _errors_are_non_visual(errs: list[str]) -> bool:
    """Phase 3 targeted repair: True when EVERY validator error is numeric/structural — fixable from the plan
    text + the exact errors without the model re-seeing contact sheets (duration, speed, source-range bounds,
    ordering, native-audio, unknown-id, directive placement). KEEP images only when an error implicates what a
    clip CONTAINS — today the single visual-judgement case is a source range overlapping NO useful_segment
    (re-picking a usable range can benefit from frames). Conservative: any useful_segment marker keeps images."""
    visual_markers = ("useful_segment",)
    for e in errs:
        low = str(e).lower()
        if any(m in low for m in visual_markers):
            return False
    return True


def _is_timing_only_revise(inputs: "EditPlanInputs") -> bool:
    """A revise whose ONLY requested change is per-clip pacing/duration — no hard directives (which change
    structure) and a soft_direction that parses as a clip-length target. These are the revises where honoring
    the pacing legitimately changes the TOTAL duration, so the AI-recommended length must not block them."""
    rc = inputs.revision_context or {}
    if rc.get("mode") != "revise":
        return False
    if rc.get("directives"):
        return False
    return _parse_target_clip_seconds(rc.get("soft_direction") or "") is not None


def _duration_target_source(inputs: "EditPlanInputs") -> str:
    """Provenance of the NUMERIC target duration, independent of the editorial mode (Highlights/Full/Custom are
    editorial PREFERENCES; their numeric length may still be AI-recommended). 'user_exact' => the user typed an
    exact length and it is authoritative; 'ai_recommended' => the number came from a recommendation. Absent/
    unknown provenance is treated as user_exact (the safe, strict default — we never weaken a length we are not
    certain is only a recommendation)."""
    rc = inputs.revision_context or {}
    src = (rc.get("duration_target_source") or "").strip().lower()
    return src if src in ("user_exact", "ai_recommended") else "user_exact"


def _has_retime_intent(inputs: "EditPlanInputs") -> bool:
    """A revise whose soft_direction asks for shorter clips / faster pacing / a shorter video — whether or not
    it ALSO carries a structural directive. Phase 5 (owner 2026-10-21): "do not add footage merely to preserve
    an inherited duration the user did not request." A mixed revise like "open with Moment 1 AND shorten each
    clip to ~5s" legitimately produces a SHORTER total, so for an AI-recommended target its undershoot floor is
    relaxed too — not only the pure-timing-only case. Distinct from `_is_timing_only_revise`, which still gates
    the zero-model deterministic retime fast path (that path requires NO directives)."""
    rc = inputs.revision_context or {}
    if rc.get("mode") != "revise":
        return False
    soft = (rc.get("soft_direction") or "").lower()
    if _parse_target_clip_seconds(soft) is not None:
        return True
    return any(p in soft for p in ("shorten", "shorter", "make it short", "condense", "tighten", "faster",
                                   "speed it up", "quicker", "snappier", "less time", "cut it down",
                                   "trim it down", "shorten each", "shorter clip"))


def _undershoot_tolerance_for(inputs: "EditPlanInputs") -> float | None:
    """The effective undershoot floor for THIS operation. Returns the strict default for initial creation and
    for any revise with an explicit user duration; returns None (no lower bound) for a revise that carries a
    retime/shorter-pacing intent whose target length is AI-recommended, so honoring the user's pacing can
    shorten the whole video without being rejected (whether or not a structural directive is also present).
    Never relaxes the overshoot/feasibility checks — this governs the lower bound alone."""
    if _has_retime_intent(inputs) and _duration_target_source(inputs) == "ai_recommended":
        return None
    return DURATION_UNDERSHOOT_TOLERANCE


# Editorial-continuity floor (Phase 4, owner-approved 2026-10-21). A targeted revise whose instruction does NOT
# itself authorize a selection change (no exclude / no shorter-duration drop / no "focus on the best shots")
# must keep at least this fraction of the base plan's clips, else it is treated as a WHOLESALE replacement
# (the model re-cut the whole edit rather than revising it) and rejected. When the instruction DOES authorize a
# selection change, the floor does not apply — a shorter duration or an explicit exclude may legitimately drop
# many clips. Single tunable; NOT a per-keyword rule and NOT a mode classifier.
CONTINUITY_FLOOR = 0.5


def _directive_authorized_ids(directives) -> set[str]:
    """The clip ids a structured-directive object explicitly authorizes adding or removing, lowercased. The
    directive payload is a DICT of id-lists/scalars/pairs — opening, ending, must_include, exclude, and the
    order_after / order_adjacent pair lists — NOT a list of {asset_id} dicts (the previous code iterated it as
    the latter, so the authorized set was ALWAYS EMPTY and a legitimate exclude/add was flagged). This reads the
    real shape. (A list-of-dicts shape is still tolerated for forward-compat.)"""
    out: set[str] = set()
    if not directives:
        return out

    def _add(v):
        if isinstance(v, str) and v.strip():
            out.add(v.lower())

    if isinstance(directives, dict):
        for k in ("opening", "ending"):
            _add(directives.get(k))
        for k in ("must_include", "exclude", "include_moment_ids", "exclude_moment_ids"):
            v = directives.get(k)
            for x in (v if isinstance(v, list) else ([v] if v else [])):
                _add(x)
        for k in ("order_after", "order_adjacent", "order_pins"):
            for pair in (directives.get(k) or []):
                if isinstance(pair, (list, tuple)):
                    for x in pair:
                        _add(x)
                else:
                    _add(pair)
    elif isinstance(directives, list):   # forward-compat: list of {asset_id|id|moment_id|target_id}
        for d in directives:
            if isinstance(d, dict):
                for kk in ("asset_id", "id", "moment_id", "target_id"):
                    _add(d.get(kk))
    return out


def _continuity_assessment(base_plan: dict | None, revised: dict, rc: dict) -> dict | None:
    """Deterministic (no model) editorial-continuity signal for a targeted revise. Compares the base vs revised
    CLIP SET (segment asset_ids, case-insensitive) and returns a graded verdict rather than a terminal
    rejection string. Phase 4, owner-approved 2026-10-21: a technically-valid revise is NOT discarded solely
    because the clip set changed; only a NO-OP or a WHOLESALE replacement (below the continuity floor, when the
    instruction did not authorize a selection change) is rejected.

    Returns None when there is nothing to assess (no base plan / empty base). Otherwise a dict:
      verdict:          "ok" | "noop" | "wholesale"
      removed/added:    counts of UNAUTHORIZED drops/introductions (directive-named ids excluded)
      reordered:        True when the shared clip set's order changed
      continuity_ratio: |base ∩ revised| / |base|  (1.0 = every base clip retained)
      authorized_change: True when the instruction itself authorizes a selection change (exclude / shorter
                         duration / explicit selective-focus) — the floor does not apply then
      reason:           short human string for the caller's limitation message on a reject verdict
    """
    if not isinstance(base_plan, dict):
        return None

    def _ids(p):
        return [str(s.get("asset_id")).lower() for s in (p.get("segments") or []) if s.get("asset_id")]

    base_list, rev_list = _ids(base_plan), _ids(revised)
    base_ids, rev_ids = set(base_list), set(rev_list)
    if not base_ids:
        return None

    authorized = _directive_authorized_ids(rc.get("directives"))
    removed = base_ids - rev_ids - authorized
    added = rev_ids - base_ids - authorized
    retained = len(base_ids & rev_ids)
    continuity_ratio = retained / len(base_ids)

    # Does the latest instruction itself authorize a selection change? (then the floor does not apply)
    directives = rc.get("directives") or {}
    has_exclude = bool(isinstance(directives, dict) and (directives.get("exclude")
                       or directives.get("exclude_moment_ids")))
    soft = (rc.get("soft_direction") or "").lower()
    # Explicit selective-focus language ("focus on the best", "just the highlights", "only the best shots").
    _selective = any(p in soft for p in ("focus on", "best shot", "best clip", "highlight", "only the",
                                         "just the", "pick the", "trim it down", "cut it down"))
    # A shorter total that the user asked for (shorter/retime) legitimately drops clips.
    _shorter = _parse_target_clip_seconds(soft) is not None or any(
        p in soft for p in ("shorten", "shorter", "make it short", "condense", "tighten"))
    authorized_change = bool(has_exclude or _selective or _shorter or authorized)

    # NO-OP: the directed revise produced NO effective change at all (same clip set AND same order). An honest
    # "couldn't apply that", never saved as a successful edit. (Order change alone is a real edit, not a no-op.)
    reordered = base_list != rev_list and base_ids == rev_ids
    if base_ids == rev_ids and not reordered:
        return {"verdict": "noop", "removed": 0, "added": 0, "reordered": False,
                "continuity_ratio": 1.0, "authorized_change": authorized_change,
                "reason": "the requested change produced no effective edit"}

    # WHOLESALE replacement: continuity below the floor AND the instruction did not authorize dropping clips.
    if continuity_ratio < CONTINUITY_FLOOR and not authorized_change:
        dropped = len(base_ids - rev_ids)
        return {"verdict": "wholesale", "removed": len(removed), "added": len(added),
                "reordered": reordered, "continuity_ratio": round(continuity_ratio, 3),
                "authorized_change": authorized_change,
                "reason": (f"it would replace most of your video ({dropped} of {len(base_ids)} clips changed) "
                           "rather than revise it")}

    return {"verdict": "ok", "removed": len(removed), "added": len(added), "reordered": reordered,
            "continuity_ratio": round(continuity_ratio, 3), "authorized_change": authorized_change,
            "reason": ""}


def _classify_unsupported_ops(instruction: str) -> dict:
    """Classify a revise instruction against MediaEngineV1's real capabilities, deterministically (no model).

    Supported editing verbs (the renderer's actual scope): trim/shorten/lengthen, reorder/move, cut,
    crossfade/fade/dissolve transitions, speed up/slow down (0.5-2.0x), native-audio keep/mute/duck, soundtrack
    change, include/exclude/opening/ending a Moment. Unsupported (no renderer support): color grading, filters,
    brightness/contrast/saturation/exposure/tint/warm/cool, glow/vignette/blur/sharpen, zoom/crop/reframe/pan,
    stabilization, text/caption/sticker/overlay, green-screen.

    Returns {verdict: 'supported'|'mixed'|'all_unsupported', unsupported: [matched terms], phrase: human list}.
    'phrase' is a short natural list of what cannot be done, for the user-facing limitation message. The match
    is word-boundary and case-insensitive; an empty/whitespace instruction is 'supported' (nothing to gate)."""
    import re
    text = (instruction or "").lower()
    if not text.strip():
        return {"verdict": "supported", "unsupported": [], "phrase": ""}
    # Unsupported-capability vocabulary -> the human noun shown back to the user.
    UNSUPPORTED = {
        r"color[- ]?correct|colou?r grade|colou?r grading|white balance": "color correction",
        r"\bfilter\b|\bfilters\b|\blut\b|instagram filter": "filters",
        r"\bbright(er|ness)?\b|\bcontrast\b|\bsaturat|\bexposure\b|\bvibran|\btint\b|\bhue\b": "brightness/color adjustments",
        r"\bwarm(er|th)?\b|\bcool(er)?\b|\bteal\b|cinematic colou?r|film look|color (tone|tint)|"
        r"more (blue|green|red|orange|yellow|purple|pink|golden|vivid|colou?rful)|"
        r"(blue|green|red|orange|yellow|purple|golden)r\b|make .*(sky|colou?rs?|grass|water|sunset) ": "color tone changes",
        r"\bglow\b|\bvignette\b|\bbloom\b|light leak": "glow/vignette effects",
        r"\bblur\b|\bsharpen\b|\bgrain\b|\bnoise\b": "blur/sharpen effects",
        r"\bzoom\b|\bcrop\b|\breframe\b|\bpan\b|ken burns|re-?frame|punch in": "zoom/reframe",
        r"\bstabili[sz]e|\bstabili[sz]ation|anti-?shake|smooth(ing)? shake": "stabilization",
        r"\btext\b|\bcaption|\bsubtitle|\bsticker|\boverlay|\btitle card|lower third": "text/overlays",
        r"green ?screen|chroma ?key|remove background|replace background": "background replacement",
    }
    # Supported editing vocabulary — presence of ANY of these alongside an unsupported term => MIXED. These are
    # genuine edit VERBS/targets, not bare nouns like "clip"/"shot" which are commonly the OBJECT of an
    # unsupported verb ("stabilize the clip", "blur the shot") and must not flip such a request to mixed.
    SUPPORTED = (r"shorten|length|trim|\bcut\b|duration|pace|pacing|faster|slow(er)?|"
                 r"\bspeed\b|reorder|rearrange|\bswap\b|opening|ending|move (moment|clip|shot|it)|"
                 r"\binclude\b|\bexclude\b|\bremove\b|add moment|crossfade|\bfade\b|dissolve|transition|"
                 r"\bmusic\b|soundtrack|\btrack\b|\bsong\b|native audio|\bmute\b|\bduck\b")
    matched = []
    for pat, noun in UNSUPPORTED.items():
        if re.search(pat, text):
            matched.append(noun)
    if not matched:
        return {"verdict": "supported", "unsupported": [], "phrase": ""}
    # De-dup nouns, preserve order.
    seen = set(); nouns = [n for n in matched if not (n in seen or seen.add(n))]
    phrase = nouns[0] if len(nouns) == 1 else (", ".join(nouns[:-1]) + " or " + nouns[-1])
    has_supported = bool(re.search(SUPPORTED, text))
    return {"verdict": "mixed" if has_supported else "all_unsupported",
            "unsupported": nouns, "phrase": phrase}


def validate_plan(plan: dict, inputs: EditPlanInputs) -> list[str]:
    errs: list[str] = []
    # Case-INSENSITIVE Moment-id space. Clients disagree on UUID case: the moments[] payload and segment
    # asset_ids arrive lowercased (StoryCreationCoordinator.momentsPayload), but directive ids historically
    # arrived UPPERCASE (UUID.uuidString). A case-sensitive lookup here rejected every segment as "not a known
    # Moment id" on the first pass (forcing a repair call on every job) and let the opening/ending/order
    # directive silently go unenforced. Normalizing the key space to lowercase makes id identity robust to
    # any client's casing. (The iOS fix lowercases directives too; this is defense-in-depth so a future drift
    # can never again break enforcement invisibly.)
    moments = {str(m["id"]).lower(): m for m in inputs.moments}
    has_analysis = inputs.music_analysis is not None
    segs = plan.get("segments", [])
    # A model that HONESTLY declares the Story infeasible (feasible=false + a reason) is ALLOWED to return no
    # segments — that is the "I can't cut this material to this target" answer, not a malformed plan. Only an
    # empty plan WITHOUT a feasible=false declaration is the "no segments" bug. Checking feasibility first lets
    # the engine's feasible=false branch surface the model's real infeasible_reason instead of a false
    # "no segments" -> 503 (observed on crowded 21-Moment libraries at a tight target).
    _declared_infeasible = plan.get("feasible") is False and bool((plan.get("infeasible_reason") or "").strip())
    if not segs and not _declared_infeasible:
        errs.append("no segments")
    orders = [s.get("order") for s in segs]
    if orders != sorted(orders):
        errs.append(f"segment order not monotonic: {orders}")
    if len(set(orders)) != len(orders):
        errs.append(f"duplicate order values: {orders}")
    for i, s in enumerate(segs):
        aid = (str(s.get("asset_id")).lower() if s.get("asset_id") is not None else None)
        if aid not in moments:
            errs.append(f"seg{i}: asset_id '{s.get('asset_id')}' is not a known Moment id")
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
        if sp is None or not math.isfinite(sp):
            errs.append(f"seg{i}: speed must be a finite number (got {sp!r})")
        elif sp <= 0:
            errs.append(f"seg{i}: non-positive speed {sp}")
        elif sp < RENDERER_SPEED_MIN or sp > RENDERER_SPEED_MAX:
            # Schema-valid (speed>0) but UNRENDERABLE: MediaEngineV1 supports only 0.5x–2.0x. Reject so the
            # bounded repair pass can pick an executable alternative (shorten source / adjust pacing) rather
            # than shipping a plan that crashes the device renderer.
            errs.append(f"seg{i}: speed {sp} out of renderer-supported range "
                        f"[{RENDERER_SPEED_MIN}, {RENDERER_SPEED_MAX}]")
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
    # ASYMMETRIC duration policy (owner decision 2026-10-13): ship the user SOMETHING watchable rather than
    # failing when the plan is a bit off the requested length. Overshoot is cheap — a longer video is still a
    # good video — so we tolerate the model running LONG generously (up to +OVERSHOOT). Undershoot is NOT: a
    # video far SHORTER than requested feels broken/empty, so we keep the tight lower bound. A near-zero /
    # degenerate plan (the "model gave up" case) is still rejected by the lower bound. The repair pass still
    # nudges toward the exact target; this only governs when we ACCEPT vs reject.
    #
    # OPERATION-SCOPED duration precedence (owner decision 2026-10-18): the undershoot bound exists to reject a
    # degenerate/empty plan against a length the USER asked for. But when the length was only AI-RECOMMENDED and
    # the user's revise instruction is a timing-only pacing change ("shorten each clip to ~5s"), the user's
    # revise intent OUTRANKS the AI's length guess — honoring the pacing may legitimately make the whole video
    # shorter. In that one case we relax the undershoot floor so a correctly-shortened plan is NOT rejected (and
    # therefore never silently re-planned). We do NOT touch overshoot, feasibility, speed, or source-range
    # checks, and we do NOT relax anything for an EXPLICIT user duration or for initial creation. The policy is
    # derived from the request's revision_context provenance; absent it, behavior is exactly as before.
    undershoot_tol = _undershoot_tolerance_for(inputs)
    if total_out and not declared_infeasible:
        over = (total_out - target) / target     # >0 => longer than asked, <0 => shorter
        # v2: an APPROXIMATE (not user-exact) target is an editorial OBJECTIVE, not a hard reject — honoring
        # pacing/selection may legitimately land a bit long or short. We keep only a RUNAWAY guard (degenerate /
        # absurdly-long) hard; the normal overshoot/undershoot bands move to the creative-intent scorer. An
        # EXPLICIT user-exact duration keeps the hard bands. Flag-gated; default OFF = exactly today's behavior.
        _approx_soft = _approx_duration_soft_on() and _duration_target_source(inputs) != "user_exact"
        if _approx_soft:
            if over > DURATION_RUNAWAY_GUARD:
                errs.append(f"total output {total_out:.1f}s exceeds target {target}s by "
                            f">{int(DURATION_RUNAWAY_GUARD*100)}% (runaway guard)")
            # a degenerate near-empty plan is still caught by 'no segments' / feasibility; no hard lower band here
        else:
            if over > DURATION_OVERSHOOT_TOLERANCE:
                errs.append(f"total output {total_out:.1f}s exceeds target {target}s by "
                            f">{int(DURATION_OVERSHOOT_TOLERANCE*100)}% (upper bound)")
            elif undershoot_tol is not None and over < -undershoot_tol:
                errs.append(f"total output {total_out:.1f}s is >{int(undershoot_tol*100)}% "
                            f"SHORT of target {target}s (lower bound)")
    if declared_infeasible and not (plan.get("infeasible_reason") or "").strip():
        errs.append("feasible=false but no infeasible_reason given")
    # DIRECTIVES. Split into HARD (references to unknown/unowned Moments, safety/privacy excludes, internal
    # contradictions) and OBJECTIVE (opening/ending/inclusion/ordering/adjacency/creative-exclude). HARD always
    # fails validation. OBJECTIVE fails validation ONLY when the objective-directives flag is OFF (legacy); when
    # ON, objective misses are scored + disclosed by assess_creative_intent, never a terminal failure. The model
    # is still never trusted to self-certify — the hard gate is deterministic throughout.
    hard_d, obj_d = _validate_directives_split(plan, inputs, moments)
    errs.extend(hard_d)
    if not _objective_directives_on():
        errs.extend(obj_d)
    return errs


# Canonical hard-directive keys. Each value is a RESOLVED stable Moment id (asset_id), never a display number.
# Ordering keys carry [after, before] PAIRS of resolved ids: order_after = "A appears after B"; order_adjacent
# = "A appears IMMEDIATELY after B". Semantics for a Moment used in multiple segments: the FIRST occurrence of
# each id is the one constrained (documented, deterministic).
_DIRECTIVE_KEYS = ("must_include", "exclude", "opening", "ending", "order_after", "order_adjacent")


def _pairs(raw) -> list[tuple[str, str]]:
    """Read a list of [a, b] pairs defensively; ignore malformed entries (never raise)."""
    out: list[tuple[str, str]] = []
    if isinstance(raw, list):
        for p in raw:
            if isinstance(p, (list, tuple)) and len(p) == 2 and all(isinstance(x, str) for x in p):
                out.append((p[0], p[1]))
    return out


def _exclude_is_safety(directives: dict, mid: str) -> bool:
    """Conservative safety/privacy classification of an exclude (owner principle 3). An exclude is treated as
    a SAFETY/PRIVACY prohibition — HARD, never silently violated — UNLESS it is UNAMBIGUOUSLY marked creative.
    A MISSING marker does NOT mean creative: we fail safe. The client's privacy/face controls set
    exclude_safety:[ids] (or safety_exclude / exclude_reason:{id:'privacy'|'safety'}). Only an id explicitly
    listed as a creative exclude (exclude_creative:[ids] or exclude_reason:{id:'creative'}) is treated as a
    mere editorial drop. When the distinction cannot be resolved for an id, it is SAFETY (fail-safe)."""
    mid = (mid or "").lower()
    def _idset(key):
        v = directives.get(key)
        if isinstance(v, list):
            return {str(x).lower() for x in v}
        if isinstance(v, str):
            return {v.lower()}
        return set()
    if mid in _idset("exclude_safety") or mid in _idset("safety_exclude"):
        return True
    reason = directives.get("exclude_reason")
    if isinstance(reason, dict):
        r = str(reason.get(mid) or reason.get(mid.upper()) or "").strip().lower()
        if r in ("privacy", "safety", "sensitive", "person", "face"):
            return True
        if r == "creative":
            return False
    if mid in _idset("exclude_creative"):
        return False
    # No resolvable marker -> conservative default: SAFETY (fail-safe). Opt into creative handling explicitly.
    return not _flag("STORY_EDITPLAN_EXCLUDE_DEFAULT_CREATIVE")


def _validate_directives(plan: dict, inputs: EditPlanInputs, moments: dict) -> list[str]:
    """Back-compat wrapper: returns HARD + OBJECTIVE errors as one flat list (legacy all-hard behavior).
    New callers use _validate_directives_split to keep objectives out of the hard gate."""
    hard, obj = _validate_directives_split(plan, inputs, moments)
    return hard + obj


def _validate_directives_split(plan: dict, inputs: EditPlanInputs,
                               moments: dict) -> tuple[list[str], list[str]]:
    """Deterministically evaluate the Moment-reference directives in revision_context['directives'], returning
    (HARD errors, OBJECTIVE errors). NEVER silently ignores or substitutes.

    HARD (always block a ship): a reference to a Moment not in the eligible/owned source set; a SAFETY/PRIVACY
    exclude that is violated (conservative — see _exclude_is_safety); any internal directive CONTRADICTION.
    OBJECTIVE (block only in legacy mode; otherwise scored+disclosed): opening, ending, must_include placement,
    order_after, order_adjacent, and a CREATIVE exclude.

    Shape (all ids RESOLVED stable Moment ids — the same values that appear as segment asset_id):
      {"must_include": [id,...], "exclude": [id,...], "opening": id, "ending": id,
       "order_after": [[A,B],...], "order_adjacent": [[A,B],...]}"""
    ctx = inputs.revision_context or {}
    directives = ctx.get("directives") or {}
    if not isinstance(directives, dict) or not any(directives.get(k) for k in _DIRECTIVE_KEYS):
        return [], []

    # Case-INSENSITIVE id comparison (see validate_plan). Directive ids historically arrived UPPERCASE while
    # segment asset_ids / moments ids are lowercase; a raw == never matched, so opening/ending/order went
    # silently unenforced and every "new version" came back as the same default edit. Lowercase both sides.
    def _norm(v):
        if isinstance(v, str):
            return v.lower()
        if isinstance(v, list):
            return [_norm(x) for x in v]
        return v
    _raw_directives = directives
    directives = {k: _norm(val) for k, val in directives.items()}

    hard: list[str] = []
    obj: list[str] = []
    segs = sorted(plan.get("segments", []), key=lambda s: s.get("order", 0))
    used = [(str(s.get("asset_id")).lower() if s.get("asset_id") is not None else None) for s in segs]
    used_set = set(used)

    def _known(mid: str) -> bool:
        return mid in moments

    def _first_index(mid: str) -> int | None:
        for i, a in enumerate(used):
            if a == mid:
                return i
        return None

    # must_include: every named Moment must appear in at least one segment, and must be an eligible Moment.
    inc = directives.get("must_include") or []
    for mid in (inc if isinstance(inc, list) else [inc]):
        if not _known(mid):
            hard.append(f"directive must_include references Moment '{mid}' not in the eligible source set "
                        "(resolve/clarify the reference before submission)")
        elif mid not in used_set:
            obj.append(f"directive must_include: Moment '{mid}' is required but appears in no segment")

    # exclude: no named Moment may appear in any segment. A SAFETY/PRIVACY exclude is HARD (never violated,
    # conservative classification); an ordinary CREATIVE exclude is an objective.
    exc = directives.get("exclude") or []
    for mid in (exc if isinstance(exc, list) else [exc]):
        if mid in used_set:
            if _exclude_is_safety(_raw_directives, mid):
                hard.append(f"directive exclude (safety/privacy): Moment '{mid}' must NOT be used but appears "
                            "in a segment")
            else:
                obj.append(f"directive exclude: Moment '{mid}' must NOT be used but appears in a segment")

    # opening: the first segment (order 0) must be the named Moment.
    opening = directives.get("opening")
    if opening:
        if not _known(opening):
            hard.append(f"directive opening references Moment '{opening}' not in the eligible source set "
                        "(resolve/clarify the reference before submission)")
        elif not segs or used[0] != opening:
            got = used[0] if used else "(none)"
            obj.append(f"directive opening: first segment must be Moment '{opening}' but is '{got}'")

    # ending: the last segment must be the named Moment.
    ending = directives.get("ending")
    if ending:
        if not _known(ending):
            hard.append(f"directive ending references Moment '{ending}' not in the eligible source set "
                        "(resolve/clarify the reference before submission)")
        elif not segs or used[-1] != ending:
            got = used[-1] if used else "(none)"
            obj.append(f"directive ending: last segment must be Moment '{ending}' but is '{got}'")

    after_pairs = _pairs(directives.get("order_after"))
    adj_pairs = _pairs(directives.get("order_adjacent"))

    # order_after[A,B]: A's first segment index must be greater than B's first segment index.
    for a, b in after_pairs:
        if not _known(a) or not _known(b):
            miss = a if not _known(a) else b
            hard.append(f"directive order_after references Moment '{miss}' not in the eligible source set "
                        "(resolve/clarify the reference before submission)")
            continue
        ia, ib = _first_index(a), _first_index(b)
        if ia is None or ib is None:
            missing = a if ia is None else b
            obj.append(f"directive order_after: Moment '{missing}' is required for ordering but appears in no segment")
        elif not (ia > ib):
            obj.append(f"directive order_after: Moment '{a}' must come after '{b}' but is at position {ia} vs {ib}")

    # order_adjacent[A,B]: A's first segment must be exactly one position after B's first segment.
    for a, b in adj_pairs:
        if not _known(a) or not _known(b):
            miss = a if not _known(a) else b
            hard.append(f"directive order_adjacent references Moment '{miss}' not in the eligible source set "
                        "(resolve/clarify the reference before submission)")
            continue
        ia, ib = _first_index(a), _first_index(b)
        if ia is None or ib is None:
            missing = a if ia is None else b
            obj.append(f"directive order_adjacent: Moment '{missing}' is required for adjacency but appears in no segment")
        elif ia != ib + 1:
            obj.append(f"directive order_adjacent: Moment '{a}' must immediately follow '{b}' "
                        f"(expected position {ib + 1}) but is at position {ia}")

    # ---- conflict detection: surface contradictory constraints, never silently ignore (ALWAYS HARD) ----
    # A Moment cannot be both required and excluded.
    inc_set = set(inc if isinstance(inc, list) else [inc])
    exc_set = set(exc if isinstance(exc, list) else [exc])
    for mid in (inc_set & exc_set):
        hard.append(f"directive conflict: Moment '{mid}' is in both must_include and exclude")
    # An excluded Moment cannot be named in an ordering/opening/ending constraint.
    ordered_ids = {x for pair in (after_pairs + adj_pairs) for x in pair}
    if opening:
        ordered_ids.add(opening)
    if ending:
        ordered_ids.add(ending)
    for mid in (exc_set & ordered_ids):
        hard.append(f"directive conflict: Moment '{mid}' is excluded but also named in an ordering/position directive")
    # Contradictory after-ordering: A after B AND B after A.
    after_set = set(after_pairs) | set(adj_pairs)
    for a, b in after_set:
        if (b, a) in after_set:
            hard.append(f"directive conflict: contradictory ordering between '{a}' and '{b}'")
    # Impossible adjacency: two different predecessors required immediately before the same Moment,
    # or one Moment required immediately before two different successors.
    adj_by_a: dict[str, set[str]] = {}
    adj_by_b: dict[str, set[str]] = {}
    for a, b in adj_pairs:
        adj_by_a.setdefault(a, set()).add(b)
        adj_by_b.setdefault(b, set()).add(a)
    for a, bs in adj_by_a.items():
        if len(bs) > 1:
            hard.append(f"directive conflict: Moment '{a}' is required immediately after multiple Moments {sorted(bs)}")
    for b, as_ in adj_by_b.items():
        if len(as_) > 1:
            hard.append(f"directive conflict: multiple Moments {sorted(as_)} are each required immediately after '{b}'")
    # opening cannot also be required to come after something; ending cannot be required before something.
    if opening and any(opening == a for a, _ in after_set):
        hard.append(f"directive conflict: Moment '{opening}' is the opening but is also ordered after another Moment")
    if ending and any(ending == b for _, b in after_set):
        hard.append(f"directive conflict: Moment '{ending}' is the ending but another Moment is ordered after it")
    return hard, obj


def _objective_code(err: str) -> str:
    """Map an objective error string to a stable low-cardinality code for disclosure/diagnostics."""
    e = err
    if e.startswith("directive opening:"):
        return "opening"
    if e.startswith("directive ending:"):
        return "ending"
    if e.startswith("directive must_include:"):
        return "inclusion"
    if e.startswith("directive order_adjacent:"):
        return "adjacency"
    if e.startswith("directive order_after:"):
        return "ordering"
    if e.startswith("directive exclude:"):
        return "exclusion_creative"
    if "SHORT of target" in e or "exceeds target" in e or "runaway guard" in e:
        return "approx_duration"
    return "other"


def assess_creative_intent(plan: dict, inputs: EditPlanInputs) -> dict:
    """Deterministic, model-free scorer of how well a TECHNICALLY-VALID plan satisfies the creative OBJECTIVES
    (opening, ending, inclusion, ordering, adjacency, creative exclude, approximate duration). It emits NO hard
    error and never rejects — its output drives best-candidate selection and the honest partial-success
    disclosure. Call it only AFTER the hard gate (validate_plan) passes.

    Returns:
      satisfied:       True when every present objective is met (fully complete creative request)
      satisfaction:    float in [0,1], fraction of present objectives satisfied (1.0 when none present)
      material_unmet:  list of {code, detail} for each unmet objective the user will notice
      objective_count: number of objectives evaluated
    """
    moments = {str(m["id"]).lower(): m for m in inputs.moments}
    _hard, obj_errs = _validate_directives_split(plan, inputs, moments)
    # Count the objectives actually PRESENT in the request so satisfaction is fraction-of-present, not absolute.
    ctx = inputs.revision_context or {}
    directives = ctx.get("directives") or {}
    present = 0
    if isinstance(directives, dict):
        if directives.get("opening"):
            present += 1
        if directives.get("ending"):
            present += 1
        inc = directives.get("must_include") or []
        present += len(inc if isinstance(inc, list) else [inc])
        exc = directives.get("exclude") or []
        for mid in (exc if isinstance(exc, list) else [exc]):
            if not _exclude_is_safety(directives, str(mid)):
                present += 1
        present += len(_pairs(directives.get("order_after")))
        present += len(_pairs(directives.get("order_adjacent")))
    # Approximate-duration objective counts as present when the band would otherwise bind (soft mode on).
    _approx_present = _approx_duration_soft_on() and _duration_target_source(inputs) != "user_exact"
    if _approx_present:
        present += 1

    material: list[dict] = []
    for e in obj_errs:
        material.append({"code": _objective_code(e), "detail": str(e)[:200]})
    # approx-duration miss appears in obj_errs only in legacy mode; in soft mode the band is relaxed, so a
    # within-runaway long/short plan is considered SATISFIED for the duration objective (the owner's intent:
    # do not treat a modest deviation as unmet). No extra material entry needed.
    unmet = len(material)
    # Satisfaction: present objectives that were met. Clamp so an over-count can't go negative.
    sat = 1.0 if present <= 0 else max(0.0, (present - unmet) / present)
    return {
        "satisfied": unmet == 0,
        "satisfaction": round(sat, 4),
        "material_unmet": material,
        "objective_count": present,
    }


def preflight_directives(directives: dict, eligible_ids: set[str]) -> list[str]:
    """Plan-INDEPENDENT validation of resolved directives BEFORE an expensive revision job (Phase 4). Catches
    what we can know without a plan: references to Moments not in the eligible source set, and internally
    contradictory constraints (include<->exclude, excluded-but-ordered, contradictory ordering, impossible
    adjacency, opening/ending vs ordering). Returns human-readable blocking reasons; empty => safe to submit.
    This does NOT check plan satisfaction (that is validate_plan's job after planning) — it only refuses to
    spend a job on a request that is already known-unsatisfiable or malformed."""
    if not isinstance(directives, dict) or not any(directives.get(k) for k in _DIRECTIVE_KEYS):
        return []
    errs: list[str] = []

    def _as_list(v):
        return v if isinstance(v, list) else ([v] if v else [])

    inc = _as_list(directives.get("must_include"))
    exc = _as_list(directives.get("exclude"))
    opening = directives.get("opening")
    ending = directives.get("ending")
    after_pairs = _pairs(directives.get("order_after"))
    adj_pairs = _pairs(directives.get("order_adjacent"))

    named = set(inc) | set(exc) | set(x for pair in (after_pairs + adj_pairs) for x in pair)
    if opening:
        named.add(opening)
    if ending:
        named.add(ending)
    for mid in named:
        if mid not in eligible_ids:
            errs.append(f"Moment '{mid}' is not in this Story (resolve or remove the reference)")

    inc_set, exc_set = set(inc), set(exc)
    for mid in (inc_set & exc_set):
        errs.append(f"Moment '{mid}' is both required and excluded")

    # Over-exclusion feasibility (Phase 4): an exclude set that leaves too few eligible Moments can never be
    # planned into a watchable edit. The planner would honestly fail 'invalid_after_repair' on it, which is an
    # expensive way to learn a fact we already know here. Blocking it preflight turns a hard failure into an
    # upfront clarify. Threshold: at least 2 Moments must remain (one-clip "edits" are not a Story). Counts the
    # eligible set the client actually sent, so it is exact for this request.
    if exc_set and eligible_ids:
        remaining = len(eligible_ids - exc_set)
        if remaining < 2:
            errs.append(
                f"Excluding those Moments leaves only {remaining} to build from — keep at least 2. "
                "Exclude fewer Moments.")
    ordered_ids = {x for pair in (after_pairs + adj_pairs) for x in pair}
    if opening:
        ordered_ids.add(opening)
    if ending:
        ordered_ids.add(ending)
    for mid in (exc_set & ordered_ids):
        errs.append(f"Moment '{mid}' is excluded but also used in an ordering/position instruction")
    after_set = set(after_pairs) | set(adj_pairs)
    for a, b in after_set:
        if (b, a) in after_set:
            errs.append(f"Contradictory ordering between Moment '{a}' and '{b}'")
    adj_by_a: dict[str, set[str]] = {}
    adj_by_b: dict[str, set[str]] = {}
    for a, b in adj_pairs:
        adj_by_a.setdefault(a, set()).add(b)
        adj_by_b.setdefault(b, set()).add(a)
    for a, bs in adj_by_a.items():
        if len(bs) > 1:
            errs.append(f"Moment '{a}' can't immediately follow more than one Moment")
    for b, as_ in adj_by_b.items():
        if len(as_) > 1:
            errs.append(f"More than one Moment can't each immediately follow Moment '{b}'")
    if opening and any(opening == a for a, _ in after_set):
        errs.append(f"Moment '{opening}' is set as the opening but also ordered after another Moment")
    if ending and any(ending == b for _, b in after_set):
        errs.append(f"Moment '{ending}' is set as the ending but another Moment is ordered after it")
    # de-dupe, stable order
    seen: set[str] = set()
    out: list[str] = []
    for e in errs:
        if e not in seen:
            seen.add(e); out.append(e)
    return out


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
    if inputs.sound_preference:
        payload["sound_preference"] = inputs.sound_preference
    if inputs.editorial_mode:
        payload["editorial_mode"] = inputs.editorial_mode
    # MVP creative direction — injected into the USER message only (frozen v5.2 body untouched).
    brief_block = ""
    if inputs.creative_brief:
        brief_block = ("\n=== CREATIVE DIRECTION ===\n" + inputs.creative_brief.strip()
                       + "\n=== END CREATIVE DIRECTION ===\n")
    # Creative Revision Foundation — version-aware context in the USER message only (frozen v5.2 body untouched).
    revision_block = _revision_context_block(inputs.revision_context)
    # MVP multimodal — tell the model that timestamped contact-sheet frames accompany the text, mapped to
    # Moment ids in this exact order. Present ONLY when images are attached (text-only path omits it entirely).
    image_block = ""
    if inputs.images and inputs.image_moment_order:
        order = "; ".join(inputs.image_moment_order)
        image_block = (
            f"\n(Contact-sheet images, one tiled JPEG per Moment, in this order: {order})\n"
            "VISUAL EVIDENCE: in addition to the text, you receive timestamped contact-sheet frames for each "
            "Moment, labeled with Moment id and source timestamp. Use them to judge visual distinctness, "
            "composition, expressiveness and precise source ranges. Frames are evidence for the SAME Moments "
            "in the JSON — never invent footage not present.\n")
    return ("Plan the EditPlan for THIS Story from the material below. Use only the given Moment ids and their "
            "real/useful ranges. Plan to the Story target duration. Respect native audio.\n"
            + brief_block
            + revision_block
            + image_block
            + _edit_sound_pref_directive(inputs.sound_preference)
            + _edit_mode_directive(inputs.editorial_mode)
            + "\nINPUT:\n"
            + json.dumps(payload, indent=2) + "\n\nReturn ONLY the EditPlan via the tool.")


def _directive_lines(directives: dict | None) -> list[str]:
    """Render resolved hard Moment-reference directives as explicit model instructions. Ids are the SAME
    stable Moment ids used as segment asset_id, so the model can act on them directly. Empty => no lines."""
    if not isinstance(directives, dict):
        return []
    out: list[str] = []
    inc = directives.get("must_include") or []
    inc = inc if isinstance(inc, list) else [inc]
    exc = directives.get("exclude") or []
    exc = exc if isinstance(exc, list) else [exc]
    if inc:
        out.append("HARD REQUIREMENT — you MUST include a segment from each of these Moment ids: "
                   + ", ".join(str(x) for x in inc))
    if exc:
        out.append("HARD REQUIREMENT — you MUST NOT use any of these Moment ids: "
                   + ", ".join(str(x) for x in exc))
    if directives.get("opening"):
        out.append(f"HARD REQUIREMENT — the FIRST segment (order 0) MUST be Moment id {directives['opening']}.")
    if directives.get("ending"):
        out.append(f"HARD REQUIREMENT — the LAST segment MUST be Moment id {directives['ending']}.")
    for pair in (directives.get("order_after") or []):
        if isinstance(pair, (list, tuple)) and len(pair) == 2:
            out.append(f"HARD REQUIREMENT — a segment from Moment id {pair[0]} MUST appear somewhere AFTER "
                       f"a segment from Moment id {pair[1]}.")
    for pair in (directives.get("order_adjacent") or []):
        if isinstance(pair, (list, tuple)) and len(pair) == 2:
            out.append(f"HARD REQUIREMENT — a segment from Moment id {pair[0]} MUST come IMMEDIATELY AFTER "
                       f"a segment from Moment id {pair[1]} (directly next, no segment between).")
    return out


def _revision_context_block(ctx: dict | None) -> str:
    """Render the version-aware context as a BOUNDED USER-message block (never the frozen system body).

    EXPLORE: an explicit alternative-edit objective plus compact summaries of the selected parent version and a
    bounded set of relevant recent versions — selected moment ids, opening/ending moment, ordering, source
    ranges, shot-duration distribution. The objective asks for a MEANINGFULLY DIFFERENT yet valid edit WITHOUT
    dropping required material, padding, or arbitrary fragmentation — never a shuffle or a template.

    REVISE (NL V1, later): carried here too, but Revise additionally supplies the exact base_plan; this block
    states the directive/soft intent. Empty string when ctx is None => behavior unchanged.
    """
    if not ctx:
        return ""
    import json
    mode = (ctx.get("mode") or "explore").strip().lower()
    summaries = ctx.get("prior_edit_summaries") or []
    # Bound the history we inject (defense-in-depth; the client also bounds it).
    MAX_SUMMARIES = 4
    if isinstance(summaries, list) and len(summaries) > MAX_SUMMARIES:
        summaries = summaries[:MAX_SUMMARIES]
    lines = ["\n=== VERSION CONTEXT ==="]
    base_v = ctx.get("base_version_id")
    if base_v:
        lines.append(f"base_version_id: {base_v}")
    if mode == "explore":
        lines.append(
            "OBJECTIVE: produce a MEANINGFULLY DIFFERENT yet fully valid alternative edit from the previous "
            "version(s) below — a different opening, a different ordering, or a different source-range emphasis. "
            "Do NOT merely shuffle, do NOT follow a fixed template, do NOT drop required material or pad, and do "
            "NOT fragment a continuous performance just for novelty. If the material genuinely cannot support a "
            "meaningfully different good edit, return your best valid edit rather than a forced variation.")
    elif mode == "revise":
        # Phase 1/D1 (owner 2026-10-21): Revise is a DIFF against the EXACT base plan — so inject it, plus a
        # preserve-unaffected / latest-intent-wins objective. (Previously the base plan was NEVER put in the
        # USER message, so the model revised with nothing concrete to preserve.) The frozen edit_plan/5.2
        # SYSTEM body is untouched; this is USER-message text only.
        lines.append(
            "OBJECTIVE: this is a REVISE of the user's EXISTING edit (the BASE PLAN below), not a new edit. "
            "Apply the user's latest requested changes to that edit. PRESERVE its footage, order, timing, "
            "native audio and creative decisions wherever they do not need to change; make additional editorial "
            "changes only when reasonably necessary to fulfil the request. Where an earlier creative preference "
            "conflicts with the latest request, the LATEST request wins. Do NOT re-cut the whole video or seek "
            "a different edit for novelty — change the smallest set needed to satisfy the request.")
        soft = (ctx.get("soft_direction") or "").strip()
        if soft:
            lines.append("LATEST REVISE INTENT (soft): " + soft)
        base_plan = ctx.get("base_plan")
        if isinstance(base_plan, dict) and base_plan.get("segments"):
            lines.append("BASE PLAN (the exact current edit to revise — preserve what the request does not change):")
            lines.append(json.dumps(base_plan, indent=2))
    # HARD DIRECTIVES — resolved stable Moment references. Rendered in BOTH modes (a user may pin an opening
    # while exploring). These are REQUIREMENTS the deterministic validator also enforces; the model must obey.
    lines.extend(_directive_lines(ctx.get("directives")))
    if summaries and mode != "revise":   # summaries are an EXPLORE "avoid being identical" reference, not Revise
        lines.append("PREVIOUS VERSION(S) (most recent first):")
        lines.append(json.dumps(summaries, indent=2))
    lines.append("=== END VERSION CONTEXT ===\n")
    return "\n".join(lines)


def diversity_diagnostics(parent_summary: dict, new_plan: dict) -> dict:
    """Deterministic, model-free comparison of a NEW plan against the PARENT version's compact summary.

    Returns metrics used by the eval harness (and optionally logged) to decide whether an Explore alternative is
    MEANINGFULLY different from its parent — NOT to accept/reject automatically (human judgment decides worth):
      - moment_set_jaccard      : |A∩B| / |A∪B| over selected moment ids (1.0 => identical set)
      - opening_changed         : parent's opening moment != new opening moment
      - ending_changed          : parent's ending moment  != new ending moment
      - order_changed           : the ordered shared-moment sequence differs
      - shot_count_delta        : new segment count - parent segment count
      - near_identical          : coarse "basically the same edit" flag (same set, same opening+ending, same order)
    A near_identical=True Explore result is the failure the owner forbids saving as a creative alternative.
    """
    def _moment_seq(summary_or_plan: dict) -> list[str]:
        segs = summary_or_plan.get("segments") or summary_or_plan.get("moment_sequence") or []
        out = []
        for s in segs:
            if isinstance(s, dict):
                out.append(str(s.get("asset_id") or s.get("moment_id") or ""))
            else:
                out.append(str(s))
        return [x for x in out if x]

    pseq = _moment_seq(parent_summary)
    nseq = _moment_seq(new_plan)
    pset, nset = set(pseq), set(nseq)
    union = pset | nset
    jaccard = (len(pset & nset) / len(union)) if union else 1.0
    p_open = pseq[0] if pseq else None
    n_open = nseq[0] if nseq else None
    p_end = pseq[-1] if pseq else None
    n_end = nseq[-1] if nseq else None
    # ordered sequence over the SHARED moments only (ignores pure add/remove, isolates reordering)
    shared = pset & nset
    p_shared = [m for m in pseq if m in shared]
    n_shared = [m for m in nseq if m in shared]
    order_changed = p_shared != n_shared
    opening_changed = p_open != n_open
    ending_changed = p_end != n_end
    near_identical = (jaccard >= 0.999 and not opening_changed and not ending_changed and not order_changed)
    return {
        "moment_set_jaccard": round(jaccard, 4),
        "opening_changed": opening_changed,
        "ending_changed": ending_changed,
        "order_changed": order_changed,
        "shot_count_delta": len(nseq) - len(pseq),
        "near_identical": near_identical,
    }


def _edit_mode_directive(mode: str | None) -> str:
    """One-line editorial-breadth bias from the user's Story-length mode. Advisory REQUEST context; the v5.1
    prompt clause reads editorial_mode. Target duration stays authoritative; no minimum clip count; no forced
    Guide completion. Empty string when unset (older clients) so v5 behavior is unchanged."""
    if mode == "highlights":
        return ("\nEDITORIAL MODE = highlights: favor the STRONGEST material, impact and concision; it is correct "
                "to use fewer, higher-value Moments.")
    if mode == "full":
        return ("\nEDITORIAL MODE = full: seek BROADER distinct, meaningful representation of the experience where "
                "the footage and duration support it — include additional Moments when they add narrative, "
                "atmosphere, character, progression or emotional value; still avoid redundant clips and never pad.")
    if mode == "custom":
        return ("\nEDITORIAL MODE = custom: respect the selected duration and infer appropriate breadth from the "
                "Story's intent and available material.")
    return ""


def _edit_sound_pref_directive(pref: str | None) -> str:
    """One-line native_audio bias from the user's sound preference. Advisory REQUEST context; the frozen
    edit_plan/5 clause already defaults to keep. music_led is NOT music-only."""
    if pref == "immersive":
        return ("SOUND PREFERENCE = immersive: strongly prefer native_audio=keep for usable environmental sound, "
                "speech and atmosphere; duck/mute only for a clear editorial reason.")
    if pref == "balanced":
        return ("SOUND PREFERENCE = balanced: keep meaningful native audio and let music support it; duck minor "
                "sound, mute only noise/unusable audio.")
    if pref == "music_led":
        return ("SOUND PREFERENCE = music_led: the soundtrack leads, so duck is a reasonable default — BUT this is "
                "NOT music-only: still keep genuinely important native audio (a performance, intelligible speech).")
    return ""


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
        f"- PLAYBACK SPEED must stay within {RENDERER_SPEED_MIN}x–{RENDERER_SPEED_MAX}x (the renderer supports "
        "no faster or slower). If a segment currently uses an unsupported speed (e.g. a 4.0x time-lapse), do "
        "NOT merely clamp the number — PREFER to achieve the pacing a different way: SHORTEN the segment's "
        "source range (pick the most expressive stretch) and/or let the cut do the work, keeping speed within "
        f"{RENDERER_SPEED_MIN}x–{RENDERER_SPEED_MAX}x. Only use speed as a last resort, and never outside that "
        "window.\n"
        "- For every segment: output_duration_seconds MUST equal (source_end_seconds - source_start_seconds) / "
        "speed (speed defaults to 1.0). If you want a segment SHORTER, shorten its source range or raise its "
        "speed; if LONGER, extend the source range (staying within the Moment's real duration and useful "
        "segments) or lower its speed. Never leave output_duration inconsistent with the source span and speed.\n"
        "- The total timeline duration (sum of output durations, minus any crossfade overlap) should AIM AT "
        f"target_duration_seconds. Running somewhat LONG is acceptable (up to +{int(DURATION_OVERSHOOT_TOLERANCE*100)}%), "
        f"but do NOT come in more than {int(DURATION_UNDERSHOOT_TOLERANCE*100)}% SHORT of target. Aim at the "
        "target, not the edge. If the "
        "usable material genuinely cannot reach the target, return feasible=false with a one-line "
        "infeasible_reason and your best shorter plan — do NOT invent footage.\n"
        "- source ranges stay within each Moment's real duration and useful segments; asset_id stays a given "
        "Moment id.\n\n"
        "VALIDATOR ERRORS to fix:\n" + "\n".join(f"- {e}" for e in errs) + "\n\n"
        "YOUR PREVIOUS PLAN (correct it):\n" + json.dumps(bad_plan, indent=2) + "\n\n"
        "INPUT (unchanged):\n" + json.dumps(payload, indent=2) + "\n\n"
        "Return ONLY the corrected EditPlan via the tool.")


# ---------------------------------------------------------------------------
# Phase-6 / experiment Arm D: bounded critique -> revision. Faithful to
# evals/multimodal_edit/run_shortform_experiment.py (the arm that produced the
# visible engagement gain): a plain-text self-critique against the creative
# brief, then ONE revise call re-emitting the EditPlan via the SAME schema.
# ---------------------------------------------------------------------------
def _build_critique(inputs: EditPlanInputs, plan: dict) -> str:
    """Self-review the just-produced plan against the creative direction. <=180 words, no tool call — the
    5 specific questions are the ones Arm D used (hook / variation / unjustified holds / ending / expressive
    footage left on the table), citing Moment ids + source times."""
    import json
    brief = (inputs.creative_brief or "").strip()
    return (
        "You produced the EditPlan below for a SHORT-FORM SOCIAL video. Critique it against the creative "
        "direction, in <=180 words, then STOP (no tool call). Judge ONLY: (1) does the first shot hook in the "
        "first 3s? (2) is there genuine visual variation or does footage repeat? (3) does any shot run long "
        "without an action/expression/reveal justifying the hold? (4) is the ending memorable? (5) is anything "
        "expressive left on the table? Be specific and cite Moment ids + source times. Do not rewrite the plan.\n\n"
        "=== CREATIVE DIRECTION ===\n" + brief + "\n=== END ===\n\nEDITPLAN:\n" + json.dumps(plan, indent=2))


def _build_revision(inputs: EditPlanInputs, plan: dict, critique: str) -> str:
    """Revise to address the critique, honoring the SAME creative direction, Moment ids/ranges and native-audio
    rules. Only improvements the critique supports; no clip-count padding. Re-emits via the frozen validator."""
    import json
    brief = (inputs.creative_brief or "").strip()
    inv = [{"id": m.get("id"), "duration_seconds": m.get("duration_seconds"),
            "useful_segments": m.get("useful_segments")} for m in inputs.moments]
    return (
        "Revise the EditPlan to address your critique below, honoring the SAME creative direction and the SAME "
        "Moment ids/ranges and native-audio rules. Make only improvements the critique supports; do not pad "
        "clip count. Return ONLY the revised EditPlan via the tool.\n\n"
        "=== CREATIVE DIRECTION ===\n" + brief + "\n=== END ===\n\nCRITIQUE:\n" + (critique or "") +
        "\n\nCURRENT EDITPLAN:\n" + json.dumps(plan, indent=2) +
        "\n\nMoment inventory (ids + useful ranges):\n" + json.dumps(inv, indent=2))


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

    def __init__(self, gateway: ModelGateway, *, max_tokens: int = 8192, executability_repair_attempts: int = 1,
                 max_tokens_ceiling: int = 16384):
        self._gw = gateway
        self._system = _load_system()
        self._max_tokens = max_tokens
        # Hard ceiling for the on-truncation escalation (see _call). A 24-Moment plan overflowed the old 2600
        # cap (proven: stop_reason=max_tokens, output_tokens=2600); 8192 fits a full ~17-segment plan with
        # headroom, and we escalate once up to this ceiling if a plan still truncates.
        self._max_tokens_ceiling = max(max_tokens, max_tokens_ceiling)
        self._exec_repairs = max(0, executability_repair_attempts)
        self.last_diagnostics: dict[str, Any] = {}

    def generate(self, inputs: EditPlanInputs) -> EditPlanV2Contract:
        diag: dict[str, Any] = {
            "model_calls": 0, "executability_repairs_used": 0,
            "first_pass_executable": False, "normalized": False,
            "normalize_notes": [], "repaired": False,
            "input_tokens": 0, "output_tokens": 0, "final": "pending",
            "last_stop_reason": None, "last_output_tokens": 0, "max_tokens": self._max_tokens,
        }

        def _call(user_content: str, images: list | None = None) -> dict:
            # Escalate the output cap on truncation: if the model stops at max_tokens (a truncated, usually
            # empty plan), retry ONCE at the ceiling before giving up. Proven root cause of the 24-Moment
            # 'no segments' 503. The retry is bounded (one escalation) so a genuinely runaway plan still fails
            # fast rather than looping.
            # `images` defaults to the full payload; a repair may pass a SMALLER set (Phase 3) when the
            # validator errors are purely numeric/structural and re-sending every contact sheet is wasted cost.
            call_images = list(inputs.images) if images is None else images
            caps = [self._max_tokens]
            if self._max_tokens_ceiling > self._max_tokens:
                caps.append(self._max_tokens_ceiling)
            result = None
            for cap in caps:
                req = StructuredRequest(
                    task=TASK, schema=SCHEMA, prompt_version=PROMPT_VERSION, system=self._system,
                    user_content=user_content, max_repair_attempts=2,
                    max_tokens=cap, temperature=0.0,
                    images=call_images)
                result = self._gw.generate_structured(req)  # raises StructuredOutputError/ProviderError
                diag["model_calls"] += 1
                u = result.usage
                if u:
                    diag["input_tokens"] += (u.input_tokens or 0)
                    diag["output_tokens"] += (u.output_tokens or 0)
                    diag["last_output_tokens"] = u.output_tokens or 0
                diag["last_stop_reason"] = result.stop_reason
                diag["last_max_tokens_used"] = cap
                if result.stop_reason != "max_tokens":
                    break   # not truncated — accept this result
                diag["truncation_escalations"] = diag.get("truncation_escalations", 0) + 1
                # else: truncated — loop retries at the higher cap (if any left)
            # Per-call diagnostics: which model actually served this call, and (if the primary failed over)
            # WHY. last_fallback/last_error reflect THIS call; the end-of-generate read only sees the last one,
            # so accumulate here. served_by is the fallback model when a fallback happened, else the primary.
            fb = bool(getattr(self._gw, "last_fallback", False))
            err = getattr(self._gw, "last_error", None)
            served = getattr(self._gw, "fallback_model_id", None) if fb else getattr(self._gw, "primary_model_id", None)
            diag.setdefault("calls", []).append({"fallback": fb, "served_by": served,
                                                 "primary_error": (err if fb else None)})
            if fb:
                diag["any_fallback"] = True
                if err and not diag.get("first_fallback_error"):
                    diag["first_fallback_error"] = err   # WHY Opus failed on the first fail-over
            return result.data

        def _call_text(user_content: str) -> str:
            # The gateway is structured-only, so a plain-text critique is requested via a tiny one-field schema
            # (same approach the experiment used). Bounded: one repair, 600 tokens, images attached so the
            # critique can actually judge the frames. Returns the critique string ("" on anything unusable).
            cs = {"type": "object", "additionalProperties": False,
                  "properties": {"critique": {"type": "string"}}, "required": ["critique"]}
            req = StructuredRequest(
                task="edit_plan.critique", schema=cs, prompt_version=PROMPT_VERSION, system=self._system,
                user_content=user_content, max_repair_attempts=1, max_tokens=600, temperature=0.0,
                images=list(inputs.images))
            result = self._gw.generate_structured(req)
            diag["model_calls"] += 1
            u = result.usage
            if u:
                diag["input_tokens"] += (u.input_tokens or 0)
                diag["output_tokens"] += (u.output_tokens or 0)
            return str((result.data or {}).get("critique", "") or "")

        # 0: DETERMINISTIC REVISION FAST PATH (Phase 5). When this is a revise carrying the exact base_plan and
        # ONLY hard structural directives (exclude / opening / ending / order_*), try to satisfy it by pure
        # reorder+prune of the base plan — ZERO model calls. Adopt the result only if the deterministic
        # validator passes AND there is no soft_direction (a creative request still needs the model). Any miss
        # falls through to normal planning (the targeted single-call path, since critique stays off by default).
        rc = inputs.revision_context or {}

        # Phase 5 — UNSUPPORTED-OPERATION PREFLIGHT (owner 2026-10-18). MediaEngineV1 can only trim, order,
        # set output duration, cut/crossfade/fade, 0.5-2.0x speed, native-audio policy and aspect-fit. It has NO
        # color grading, filters, brightness/contrast/saturation, glow/vignette/blur, zoom/crop/reframe or
        # stabilization. Without this guard an unsupported revise ("make it warmer", "add a glow") has no hard
        # directive and no clip-length target, so it falls to the model, which returns SOME re-cut plan — a
        # silent substitution of a different edit for the edit the user asked for. So, for a REVISE, we classify
        # the instruction deterministically BEFORE planning: if the WHOLE actionable instruction is unsupported
        # we keep the user's version and return a clear limitation (never plan, never claim success); if it is
        # MIXED (some supported, some not) we record which parts cannot be applied so the supported part can run
        # with an honest note. Initial creation is never gated here.
        if rc.get("mode") == "revise":
            _unsup = _classify_unsupported_ops(rc.get("soft_direction") or "")
            if _unsup["verdict"] == "all_unsupported":
                diag["final"] = "unsupported_operation"
                diag["unsupported_ops"] = _unsup["unsupported"]
                self.last_diagnostics = diag
                raise EditPlanInfeasibleError(
                    "That edit isn't something this app can do yet — it only re-cuts, re-times, reorders and "
                    f"sets transitions/soundtrack, not {_unsup['phrase']}. Your current version was kept "
                    "unchanged.")
            if _unsup["verdict"] == "mixed":
                diag["unsupported_ops"] = _unsup["unsupported"]
                diag["partial_support_note"] = (
                    f"Applied the supported part; this app can't yet do {_unsup['phrase']}.")

        # 0a: TIMING-ONLY deterministic fast path (preservation contract). A pure pacing/duration revise
        # ("shorten each clip to ~5s", "make the clips about 3 seconds") must PRESERVE which clips are used,
        # their order, source ranges, soundtrack, native-audio and transitions — only re-timing each segment.
        # When a revise carries the exact base_plan and a parseable target clip length, we re-time
        # deterministically (ZERO model calls) and adopt it only if the frozen validator passes. This is what
        # keeps "shorten the clips" from silently re-picking the whole edit. Requires NO hard directives that
        # would change structure (those take the structural path below); a bare pacing soft_direction is fine.
        if (rc.get("mode") == "revise" and isinstance(rc.get("base_plan"), dict)
                and not rc.get("directives")):
            target = _parse_target_clip_seconds(rc.get("soft_direction") or "")
            if target is not None:
                from .deterministic_revision import apply_deterministic_retime
                # Duration precedence: honor the pacing. Only when the target length is a USER-EXACT requirement
                # do we lift shot durations to keep the total near it; for an AI-RECOMMENDED target we let the
                # video shorten (the relaxed undershoot floor accepts it) rather than uniformly lengthening
                # shots just to satisfy a number the user never fixed.
                _tgt = inputs.creative_intent.get("target_duration_seconds")
                _exact = _duration_target_source(inputs) == "user_exact"
                _min_total = (float(_tgt) * (1.0 - DURATION_UNDERSHOOT_TOLERANCE)
                              if _exact and isinstance(_tgt, (int, float)) and _tgt > 0 else None)
                retimed = apply_deterministic_retime(rc["base_plan"], target, min_total_seconds=_min_total)
                if retimed is not None:
                    retimed, rnotes = normalize_plan(retimed, inputs)
                    rt_errs = validate_plan(retimed, inputs)
                    if not rt_errs and retimed.get("feasible") is not False:
                        diag["final"] = "executable"
                        diag["revision_path"] = "deterministic_retime"
                        diag["model_calls"] = 0
                        diag["first_pass_executable"] = True
                        diag["normalize_notes"] = rnotes
                        self.last_diagnostics = diag
                        return _to_contract(retimed, inputs)
                    diag["retime_reject_errors"] = [str(e)[:120] for e in rt_errs[:5]]
                # Point 7 (owner 2026-10-18): a pure pacing/timing revise must NEVER fall through to
                # unrestricted model replanning on a validation failure — re-timing is a deterministic clip-level
                # transform that the model cannot improve, and a model replan is exactly the silent re-pick we
                # are preventing. So a retime that cannot be made valid is surfaced as a clear limitation and the
                # user's existing version is kept, rather than silently replanned. (In practice the trim-at-
                # normal-speed transform only ever shortens within an already-valid window, so this is a
                # belt-and-braces guard, visible via retime_reject_errors.)
                diag["revision_path"] = "deterministic_retime_infeasible"
                self.last_diagnostics = diag
                raise EditPlanInfeasibleError(
                    "This pacing change could not be applied to your video without re-cutting it. "
                    "Your current version was kept unchanged.")

        if (rc.get("mode") == "revise" and isinstance(rc.get("base_plan"), dict)
                and rc.get("directives") and not (rc.get("soft_direction") or "").strip()):
            from .deterministic_revision import apply_deterministic_revision
            fast = apply_deterministic_revision(rc["base_plan"], rc["directives"])
            if fast is not None:
                fast, fnotes = normalize_plan(fast, inputs)
                if not validate_plan(fast, inputs) and fast.get("feasible") is not False:
                    diag["final"] = "executable"
                    diag["revision_path"] = "deterministic"
                    diag["model_calls"] = 0
                    diag["first_pass_executable"] = True
                    diag["normalize_notes"] = fnotes
                    self.last_diagnostics = diag
                    return _to_contract(fast, inputs)
            diag["revision_path"] = "deterministic_fallthrough"

        # SAFE-FALLBACK BOUNDARY (owner decision 2026-10-18): a TARGETED revise that reached here (both
        # deterministic fast paths missed) must NOT silently become an unrestricted from-scratch replan that is
        # free to re-pick every clip. The only from-scratch replans allowed are: initial creation (no revise
        # context), Explore (mode=explore, which intends a fresh alternative), and a revise that EXPLICITLY
        # authorizes broad redesign (revision_context.allow_broad_replan == True). Every other targeted revise
        # takes the base-plan-carrying call (_build_user already injects the revision block with the base plan +
        # preservation framing) and is then PRESERVATION-CHECKED against the base before we accept it. If the
        # model's revise changed clips it was not asked to change, we reject with a clear limitation rather than
        # ship a silent re-pick. (This increment enforces the boundary + the check; richer bounded repairs are
        # a later increment.)
        _is_targeted_revise = (rc.get("mode") == "revise" and isinstance(rc.get("base_plan"), dict)
                               and not rc.get("allow_broad_replan"))

        # 1-3: initial generation, safe normalization, executability validation.
        plan = _call(_build_user(inputs))
        raw_errs = validate_plan(plan, inputs)
        diag["first_pass_executable"] = not raw_errs
        if raw_errs:
            # WHAT the model's first plan violated (truncated) — so a repair/fallback is explainable instead
            # of guessed. The first 5 error strings are plenty to classify duration vs speed vs directive.
            diag["first_pass_errors"] = [str(e)[:160] for e in raw_errs[:5]]
        plan, notes = normalize_plan(plan, inputs)
        if notes:
            diag["normalized"] = True
            diag["normalize_notes"] = notes
        errs = validate_plan(plan, inputs)

        # --- v2 cost-aware repair policy (owner-approved 2026-10-22; all gated by the v2 flags) -------------
        # best_valid retains the best TECHNICALLY-VALID candidate across the whole chain so a later attempt can
        # never discard an earlier usable one. ship_best() records satisfaction for selection.
        best_valid: dict | None = None
        best_sat: float = -1.0
        best_from = None

        def _consider_best(p: dict, attempt: str) -> None:
            nonlocal best_valid, best_sat, best_from
            if not _best_valid_retention_on():
                return
            if validate_plan(p, inputs) or p.get("feasible") is False:
                return
            sat = assess_creative_intent(p, inputs)["satisfaction"] if _objective_directives_on() else 1.0
            # First valid wins; replace ONLY by a strictly-higher satisfaction (never a worse candidate).
            if best_valid is None or sat > best_sat:
                import copy as _c
                best_valid, best_sat, best_from = _c.deepcopy(p), sat, attempt

        if not errs:
            _consider_best(plan, "initial")

        # 3b: DETERMINISTIC structural directive repair (0 Bedrock). v2: run the reorder whenever the DIRECTIVE
        # PLACEMENT subset is reorder-only — not only when EVERY error is placement (the 47.5s fix: a lone
        # unrelated numeric error used to disqualify the cheap reorder). In objective mode the placement misses
        # are OBJECTIVE (not in errs), so we also pull them from assess_creative_intent and reorder to raise
        # satisfaction before shipping. Content is never changed; full validate_plan re-run gates adoption.
        def _placement_errors() -> list[str]:
            moments_l = {str(m["id"]).lower(): m for m in inputs.moments}
            _h, _o = _validate_directives_split(plan, inputs, moments_l)
            pool = list(errs) + (_o if _objective_directives_on() else [])
            return [e for e in pool if any(str(e).startswith(p) for p in _ORDER_REPAIRABLE_PREFIXES)]

        _place = _placement_errors()
        if _place:
            reordered = repair_directive_placement(plan, inputs)
            if reordered is not None:
                re_errs = validate_plan(reordered, inputs)
                if not re_errs:
                    plan = reordered
                    errs = []
                    diag["structural_repair"] = True
                    diag["structural_repair_kind"] = "directive_placement"
                    _consider_best(plan, "deterministic_reorder")

        # 4-5: STRICT COST-AWARE model repair (owner policy §7). Default ZERO additional model calls. We issue
        # a targeted model repair ONLY when (a) HARD errors remain (never for a purely creative/objective
        # deviation), (b) no technically-valid candidate is already retained (justified expected benefit), and
        # (c) the per-operation budget allows it. Budget: Create/Explore <= 1; Revise = 0, with a single
        # exception of 1 when a HARD technical defect would otherwise leave the result unrenderable. Repairs
        # carry ONLY the HARD errors — the model is never asked to chase editorial objectives.
        def _hard_only(es: list[str]) -> list[str]:
            # In objective mode, `errs` already contains only hard errors (objectives are excluded upstream),
            # so this is the identity; in legacy mode we repair everything as before.
            return list(es)

        _mode = (rc.get("mode") or "").strip().lower()
        _is_revise = _mode == "revise"
        if _objective_directives_on():
            # Create / Create Another Version: at most 1. Revise: 0, exception 1 to recover an unrenderable
            # HARD defect. (errs here are HARD-only by construction.)
            if _is_revise:
                max_repairs = 1 if errs else 0   # the exception: only if a HARD defect remains
            else:
                max_repairs = min(1, self._exec_repairs) if self._exec_repairs else 1
            max_repairs = min(max_repairs, 1)   # never >=2 under v2
        else:
            max_repairs = self._exec_repairs     # legacy behavior unchanged

        diag["repair_budget"] = max_repairs
        _repairs_done = 0
        for _ in range(max_repairs):
            if not errs:
                break
            # Justified-benefit gate: if we already hold a valid candidate, do NOT spend a model call to chase
            # compliance — ship the retained candidate instead (owner §6/§7).
            if best_valid is not None:
                diag["repair_skipped_have_valid"] = True
                break
            diag["executability_repairs_used"] += 1
            _repairs_done += 1
            diag["repaired"] = True
            repair_errs = _hard_only(errs)
            # Phase 3 — targeted repair payload (unchanged): drop contact sheets for non-visual numeric fixes.
            repair_images = [] if _errors_are_non_visual(repair_errs) else list(inputs.images)
            diag["repair_images_sent"] = len(repair_images)
            plan = _call(_build_repair(inputs, plan, repair_errs), images=repair_images)
            plan, notes = normalize_plan(plan, inputs)
            if notes:
                diag["normalized"] = True
                diag["normalize_notes"] = diag["normalize_notes"] + notes
            errs = validate_plan(plan, inputs)
            if not errs:
                _consider_best(plan, f"repair_{_repairs_done}")

        # 6: authoritative verdict.
        # v2: if the final attempt is hard-invalid but we retained a technically-valid candidate earlier, SHIP
        # the retained candidate instead of failing (owner §6). Only a chain with NO valid candidate at all is
        # a terminal failure, and its reason is always a HARD technical/integrity/safety one (never editorial).
        if errs and best_valid is not None:
            plan = best_valid
            errs = []
            diag["shipped_retained_candidate"] = True
            diag["best_valid_from_attempt"] = best_from

        if errs:
            diag["final"] = "invalid_after_repair"
            diag["final_errors"] = errs
            diag["raw_feasible"] = plan.get("feasible")
            diag["raw_infeasible_reason"] = (plan.get("infeasible_reason") or "")[:300]
            diag["raw_segment_count"] = len(plan.get("segments", []))
            self.last_diagnostics = diag
            # schema-valid but NON-executable even after repair. Never pass it on.
            raise StructuredOutputError(f"EditPlan failed deterministic validation after repair: {errs}")
        if plan.get("feasible") is False:
            diag["final"] = "infeasible"
            self.last_diagnostics = diag
            raise EditPlanInfeasibleError(plan.get("infeasible_reason") or "material cannot support a plan")

        # 6a: EDITORIAL-CONTINUITY GATE (owner decision 2026-10-21, supersedes the 2026-10-18 terminal
        # preservation gate). For a targeted revise (not broad-replan), editorial continuity is an OBJECTIVE,
        # not a hard rejection: a technically-valid revise that reasonably fulfils the latest request is
        # ACCEPTED even when the clip set changed. We compute the deterministic (no-model) base-vs-revised clip
        # delta and record it as a diagnostic/quality signal, and reject ONLY two cases: (1) a NO-OP (the
        # directed revise produced no effective change — an honest "couldn't apply that", never saved as
        # success), and (2) a WHOLESALE replacement (continuity below CONTINUITY_FLOOR when the instruction did
        # not itself authorize dropping clips — the model re-cut the whole edit instead of revising it). Adding/
        # removing clips, reordering, changing total duration or transitions no longer causes a terminal
        # failure. Technical validation (validate_plan) already passed and is unchanged.
        if _is_targeted_revise:
            cont = _continuity_assessment(rc.get("base_plan"), plan, rc)
            if cont is not None:
                diag["continuity"] = cont   # Phase-6: ratio + added/removed/reordered + verdict, always logged
                if cont["verdict"] == "noop":
                    diag["final"] = "preservation_noop"
                    self.last_diagnostics = diag
                    raise EditPlanInfeasibleError(
                        "That change could not be applied to your video — the result would be the same as your "
                        "current version, so nothing was saved.")
                if cont["verdict"] == "wholesale":
                    diag["final"] = "preservation_violation"
                    diag["preservation_error"] = cont["reason"]
                    self.last_diagnostics = diag
                    raise EditPlanInfeasibleError(
                        "This revision could not be applied without replacing most of your video "
                        f"({cont['reason']}). Your current version was kept unchanged — try naming the Moments "
                        "to keep or change, or use Create Another Version for a fresh edit.")

        # 6b: Phase-6 / Arm D — ONE bounded critique -> revision pass (flag-gated, OFF by default). Runs ONLY
        # after we already hold a VALID executable plan and only when a creative brief exists to critique
        # against. It is best-effort: the revised plan is adopted ONLY if it ALSO passes the deterministic
        # validator; ANY problem (provider error, empty critique, invalid revision) retains the original valid
        # plan. So the critique can never fail or degrade a Story — at worst it is a no-op that cost 2 calls.
        if inputs.critique_revision and inputs.creative_brief:
            diag["critique_attempted"] = True
            try:
                critique_text = _call_text(_build_critique(inputs, plan))
                if critique_text and critique_text.strip():
                    diag["critique_text"] = critique_text[:1200]
                    revised = _call(_build_revision(inputs, plan, critique_text))
                    revised, rnotes = normalize_plan(revised, inputs)
                    rerrs = validate_plan(revised, inputs)
                    if not rerrs and revised.get("feasible") is not False:
                        plan = revised                       # adopt the revision
                        diag["critique_applied"] = True
                        diag["normalize_notes"] = diag["normalize_notes"] + rnotes
                    else:
                        diag["critique_applied"] = False     # revision invalid -> keep original valid plan
                        diag["critique_rejected_reason"] = ("revision_invalid" if rerrs else "revision_infeasible")
                else:
                    diag["critique_applied"] = False
                    diag["critique_rejected_reason"] = "empty_critique"
            except (StructuredOutputError, ProviderError) as e:
                # Provider/throttle failure on the extra calls (e.g. daily-token quota) — never fail the Story;
                # keep the original valid plan. This is the quota-fragile path, so this guard matters.
                diag["critique_applied"] = False
                diag["critique_rejected_reason"] = f"provider_error:{type(e).__name__}"

        # v2 PARTIAL-SUCCESS DISCLOSURE (owner §9). The plan is technically valid and shippable. Score the
        # creative objectives (deterministic, no model) and record Complete vs Partial + the material unmet
        # instructions, so the device renders a SUCCESS (with a concise disclosure) rather than an "Adjust
        # instructions" error. Complete = valid + every present objective satisfied; Partial = valid + some
        # objective unmet. The result is ALWAYS a playable plan either way.
        if _objective_directives_on():
            cre = assess_creative_intent(plan, inputs)
            diag["creative_satisfaction"] = cre["satisfaction"]
            diag["creative_objective_count"] = cre["objective_count"]
            if cre["material_unmet"]:
                diag["material_unmet"] = cre["material_unmet"]
                diag["final"] = "executable"
                diag["completion"] = "partial"
                diag["partial_disclosure"] = (
                    "Your video is ready. A few of your creative requests couldn't all be applied: "
                    + "; ".join(sorted({m["code"] for m in cre["material_unmet"]})) + ".")
            else:
                diag["final"] = "executable"
                diag["completion"] = "complete"
            diag["used_fallback"] = bool(getattr(self._gw, "last_fallback", False))
            self.last_diagnostics = diag
            return _to_contract(plan, inputs)

        diag["final"] = "executable"
        diag["used_fallback"] = bool(getattr(self._gw, "last_fallback", False))
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
    "PROMPT_VERSION", "TASK", "MODEL_ID", "DURATION_TOLERANCE",
    "DURATION_OVERSHOOT_TOLERANCE", "DURATION_UNDERSHOOT_TOLERANCE", "SCHEMA",
    "SPEED_CONSISTENCY_ABS", "SPEED_CONSISTENCY_REL", "ROUND_SNAP_ABS",
    "RENDERER_SPEED_MIN", "RENDERER_SPEED_MAX",
    "EditPlanInputs", "EditPlanInfeasibleError", "MalformedPlanError",
    "SegmentTimeline", "validate_plan", "normalize_plan", "timeline_total_seconds",
    "preflight_directives", "diversity_diagnostics",
    "assess_creative_intent", "DURATION_RUNAWAY_GUARD",
    "EditPlannerEngine", "RealEditPlannerEngine", "MockEditPlannerEngine",
]
