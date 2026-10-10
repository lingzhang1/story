"""Story Duration Planning — RECOMMEND a target duration (Milestone R-d.2).

Responsibility boundary (frozen R-d.2 §1):
  Duration Intelligence RECOMMENDS a target duration.
  Edit Planner (v4) decides which footage to select and how to allocate that budget.
  Media Engine executes the EditPlan. The USER owns the final duration decision.
  No circular duration expansion; no new persistent StoryBlueprint.

Two layers:
  1. compute_duration_evidence(moments) — DETERMINISTIC, LOCAL, no model. Union of useful-segment
     intervals per Moment (no double-count), longest continuous useful span, conservative feasible band.
  2. RealDurationPlannerEngine — ONE Opus call via the generic ModelGateway + the FROZEN prompt
     duration_recommendation/1. Maps intent/guide/coverage/evidence -> {recommended, highlights, ceiling}.
     NEVER fabricates; a model failure propagates so the caller falls back to manual selection.

Does NOT: select cuts/order (Edit Planner v4), change EditPlan/2, render (Media Engine).
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

from model_gateway import ModelGateway, StructuredRequest

PROMPT_VERSION = "duration_recommendation/1"
TASK = "duration.recommend"
MODEL_ID = "us.anthropic.claude-opus-4-6-v1"  # validated in the R-d.1 experiment; config-overridable
_PROMPT_PATH = Path(__file__).resolve().parent.parent.parent / "prompts" / "duration_recommendation" / "v1" / "system.md"


def _load_system() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8")


# --------------------------------------------------------------------------- #
# 1. Deterministic evidence (LOCAL, no model). Mirrors the edit_planner span   #
#    reader shapes: useful_segments may be [[s,e],...] or [{start/end},...].   #
# --------------------------------------------------------------------------- #
def _moment_spans(m: dict) -> list[tuple[float, float]]:
    raw = m.get("useful_segments") or []
    out: list[tuple[float, float]] = []
    for u in raw:
        s = e = None
        if isinstance(u, (list, tuple)) and len(u) >= 2:
            s, e = u[0], u[1]
        elif isinstance(u, dict):
            s = u.get("start", u.get("start_time", u.get("t_start_s")))
            e = u.get("end", u.get("end_time", u.get("t_end_s")))
        if s is None or e is None:
            continue
        try:
            s, e = float(s), float(e)
        except (TypeError, ValueError):
            continue
        if e > s:
            out.append((s, e))
    return out


def _merge(spans: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Union of intervals -> non-overlapping, so coverage is never double-counted."""
    if not spans:
        return []
    norm = sorted((min(a, b), max(a, b)) for a, b in spans)
    merged = [norm[0]]
    for s, e in norm[1:]:
        if s <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else:
            merged.append((s, e))
    return merged


def compute_duration_evidence(moments: list[dict]) -> dict:
    """Deterministic material analysis. Handles overlaps (union), missing/empty AU (falls back to the
    Moment's own duration as a single usable span so a clip without AU is still representable), zero usable
    material, short Stories, long continuous performances, and mixed imported/directed Moments (uniform
    treatment — the shape is identical). Returns evidence; NEVER equates useful seconds with desired output.
    """
    per: list[dict] = []
    total_source = 0.0
    total_useful = 0.0
    longest_single_cont = 0.0
    for m in moments:
        dur = float(m.get("duration_seconds") or 0.0)
        total_source += dur
        spans = _moment_spans(m)
        if not spans and dur > 0:
            # Missing/empty AU useful_segments -> fall back to the whole clip as one usable span,
            # so the Moment still contributes material rather than vanishing.
            spans = [(0.0, dur)]
        merged = _merge(spans)
        cov = sum(e - s for s, e in merged)
        cont = max((e - s for s, e in merged), default=0.0)
        total_useful += cov
        longest_single_cont = max(longest_single_cont, cont)
        per.append({
            "id": m.get("id"),
            "duration_seconds": round(dur, 1),
            "useful_coverage_seconds": round(cov, 1),
            "longest_continuous_seconds": round(cont, 1),
            "n_useful_segments": len(merged),
            "has_au": bool(_moment_spans(m)),
        })
    n = len(moments)
    total_useful = round(total_useful, 1)
    # Conservative feasible band: floor = a minimal highlights pass (brief appearances, capped by material);
    # ceiling = all distinct useful material (no padding, no repetition).
    floor = round(min(total_useful, max(4.0, n * 2.0)), 1) if total_useful > 0 else 0.0
    ceil = total_useful
    return {
        "n_moments": n,
        "total_source_seconds": round(total_source, 1),
        "total_useful_coverage_seconds": total_useful,
        "longest_continuous_span_seconds": round(longest_single_cont, 1),
        "feasible_band_seconds": [floor, ceil],
        "zero_usable_material": total_useful <= 0.0,
        "per_moment": per,
    }


# --------------------------------------------------------------------------- #
# 2. Semantic recommendation (ONE Opus call, frozen prompt).                   #
# --------------------------------------------------------------------------- #
SCHEMA: dict[str, Any] = {
    "type": "object", "additionalProperties": False,
    "required": ["recommended_range_seconds", "highlights_range_seconds", "feasible_ceiling_seconds", "rationale"],
    "properties": {
        "recommended_range_seconds": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
        "highlights_range_seconds": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
        "feasible_ceiling_seconds": {"type": "number"},
        "rationale": {"type": "string"},
        "payoff_breathing": {"type": "boolean"},
        "uncertain": {"type": "boolean"},
    },
}


@dataclass
class DurationPlannerInputs:
    creative_intent: dict
    evidence: dict
    story_guide: dict = field(default_factory=dict)
    story_coverage: dict = field(default_factory=dict)
    requested_scope: str | None = None  # 'highlights' | 'complete' | None


@runtime_checkable
class DurationPlannerEngine(Protocol):
    def recommend(self, inputs: DurationPlannerInputs) -> dict: ...


def _build_user(inputs: DurationPlannerInputs) -> str:
    ev = inputs.evidence
    payload = {
        "creative_intent": inputs.creative_intent,
        "story_guide_scope": inputs.story_guide.get("framing_summary") if inputs.story_guide else None,
        "story_coverage": inputs.story_coverage or None,
        "requested_scope": inputs.requested_scope,
        "evidence": {
            "n_moments": ev.get("n_moments"),
            "total_source_seconds": ev.get("total_source_seconds"),
            "total_useful_coverage_seconds": ev.get("total_useful_coverage_seconds"),
            "longest_continuous_span_seconds": ev.get("longest_continuous_span_seconds"),
            "feasible_band_seconds": ev.get("feasible_band_seconds"),
        },
    }
    return (
        "Recommend a target duration for THIS Story from the material and intent below. "
        "There is NO universal duration — scale to scope and evidence. Never exceed the feasible ceiling.\n\n"
        + json.dumps(payload, indent=2)
        + "\n\nReturn ONLY the recommendation via the tool."
    )


def _clamp_to_ceiling(rec: dict, ceiling: float) -> dict:
    """Deterministic guard: never let a recommendation exceed the feasible ceiling (the model is told, but
    we enforce it rather than trust it)."""
    if ceiling and ceiling > 0:
        for key in ("recommended_range_seconds", "highlights_range_seconds"):
            r = rec.get(key)
            if isinstance(r, list) and len(r) == 2:
                rec[key] = [min(float(r[0]), ceiling), min(float(r[1]), ceiling)]
        rec["feasible_ceiling_seconds"] = min(float(rec.get("feasible_ceiling_seconds", ceiling) or ceiling), ceiling)
    return rec


class RealDurationPlannerEngine:
    """One Opus call via the generic ModelGateway + the FROZEN duration_recommendation/1 prompt. Never
    fabricates: a provider/model failure propagates so the caller falls back to manual duration selection.
    The feasible ceiling is enforced deterministically on the output."""

    def __init__(self, gateway: ModelGateway, *, max_tokens: int = 600):
        self._gw = gateway
        self._system = _load_system()
        self._max_tokens = max_tokens
        self.last_diagnostics: dict[str, Any] = {}

    def recommend(self, inputs: DurationPlannerInputs) -> dict:
        req = StructuredRequest(
            task=TASK, schema=SCHEMA, prompt_version=PROMPT_VERSION, system=self._system,
            user_content=_build_user(inputs), max_repair_attempts=2,
            max_tokens=self._max_tokens, temperature=0.0,
        )
        result = self._gw.generate_structured(req)  # raises on failure
        u = result.usage
        self.last_diagnostics = {
            "model_calls": 1,
            "input_tokens": (u.input_tokens if u else 0) or 0,
            "output_tokens": (u.output_tokens if u else 0) or 0,
            "prompt_version": PROMPT_VERSION, "model_id": MODEL_ID,
        }
        ceiling = (inputs.evidence.get("feasible_band_seconds") or [0, 0])[1]
        return _clamp_to_ceiling(dict(result.data), float(ceiling or 0.0))


__all__ = [
    "PROMPT_VERSION", "TASK", "MODEL_ID", "SCHEMA",
    "compute_duration_evidence", "DurationPlannerInputs",
    "DurationPlannerEngine", "RealDurationPlannerEngine",
]
