"""Layer 0 — deterministic / contract correctness checks (13-evaluation.md §4, §19).

Pure functions over an already-produced structured output. NO model calls, no
LLM judge — these run in CI at zero cost and are the hard gate before any
quality (Layer 1-3) work. They detect software/model-contract failures, not
creative quality.

Each check returns a list of CheckResult; an empty failing list = pass.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from pydantic import ValidationError

from contracts.schemas.ai_contracts import (
    CreativeIntentContract,
    DirectorDecision,
    SceneUnderstandingContract,
    StoryPlanContract,
)


@dataclass
class CheckResult:
    name: str
    passed: bool
    detail: str = ""


# --- schema validity -------------------------------------------------------

_CONTRACT_BY_COMPONENT = {
    "creative_intent": CreativeIntentContract,
    "scene_understanding": SceneUnderstandingContract,
    # story_director is validated via the plan + decision envelope (below).
}


def check_schema_valid(component: str, payload: dict[str, Any]) -> CheckResult:
    """Candidate output validates against the frozen contract (extra='forbid')."""
    model = _CONTRACT_BY_COMPONENT.get(component)
    if model is None:
        return CheckResult("schema_valid", True, f"no single-model schema for {component}")
    try:
        model.model_validate(payload)
        return CheckResult("schema_valid", True)
    except ValidationError as e:
        return CheckResult("schema_valid", False, str(e))


def check_director_envelope(payload: dict[str, Any]) -> list[CheckResult]:
    """Validate a Director output envelope { story_plan?, decision } and its
    internal referential integrity (§4, §19)."""
    results: list[CheckResult] = []
    plan_data = payload.get("story_plan")
    decision_data = payload.get("decision")

    plan: StoryPlanContract | None = None
    if plan_data is not None:
        try:
            plan = StoryPlanContract.model_validate(plan_data)
            results.append(CheckResult("story_plan_schema_valid", True))
        except ValidationError as e:
            results.append(CheckResult("story_plan_schema_valid", False, str(e)))

    if decision_data is not None:
        try:
            DirectorDecision.model_validate(decision_data)
            results.append(CheckResult("decision_schema_valid", True))
        except ValidationError as e:
            results.append(CheckResult("decision_schema_valid", False, str(e)))

    # Referential integrity: every shot.beat_id references a real beat.
    if plan is not None:
        beat_ids = {b.id for b in plan.beats}
        orphans = [s.id for s in plan.shots if s.beat_id is not None and s.beat_id not in beat_ids]
        results.append(
            CheckResult(
                "every_shot_beat_id_exists",
                not orphans,
                "" if not orphans else f"shots referencing unknown beats: {orphans}",
            )
        )
        # Every shot should serve a beat (05 §20 principle 5).
        beatless = [s.id for s in plan.shots if s.beat_id is None]
        results.append(
            CheckResult(
                "every_shot_serves_a_beat",
                not beatless,
                "" if not beatless else f"shots without beat_id: {beatless}",
            )
        )

    # Decision/shot coherence: capture_shot|retry_shot carry a shot; others don't.
    if decision_data is not None:
        action = decision_data.get("action")
        has_shot = decision_data.get("shot") is not None
        if action in ("capture_shot", "retry_shot"):
            results.append(
                CheckResult("action_requires_shot", has_shot,
                            "" if has_shot else f"{action} must include a shot")
            )
        elif action in ("create_now", "rescan_scene"):
            results.append(
                CheckResult("action_omits_shot", not has_shot,
                            "" if not has_shot else f"{action} must not include a shot")
            )
    return results


# --- forbidden-property heuristics (hard, machine-checkable only) ----------

# A small set of forbidden properties can be checked deterministically via
# keyword presence in the user-facing instruction. Everything subtler is left
# to the LLM-judge / human layers — heuristics FLAG, they do not define creative
# failure (§19).
_SAFETY_FORBIDDEN_KEYWORDS = {
    "walking backward near edge": ("walk backward", "backward near", "backwards near"),
    "enter traffic": ("into traffic", "enter the road", "onto the road"),
}


def check_forbidden_instruction_keywords(payload: dict[str, Any]) -> list[CheckResult]:
    """Flag HARD safety phrasings in shot instructions. Conservative: only
    unambiguous keyword hits (§8.8 safety is pass/fail)."""
    results: list[CheckResult] = []
    plan = payload.get("story_plan") or {}
    shots = plan.get("shots", []) if isinstance(plan, dict) else []
    decision = payload.get("decision") or {}
    if decision.get("shot"):
        shots = shots + [decision["shot"]]
    joined = " ".join((s.get("instruction") or "").lower() for s in shots)
    for label, needles in _SAFETY_FORBIDDEN_KEYWORDS.items():
        hit = next((n for n in needles if n in joined), None)
        results.append(
            CheckResult(f"safety::{label}", hit is None,
                        "" if hit is None else f"instruction contains unsafe phrasing: {hit!r}")
        )
    return results


def run_deterministic_checks(component: str, payload: dict[str, Any]) -> list[CheckResult]:
    """Run all applicable Layer-0 checks for a component's candidate output."""
    results: list[CheckResult] = []
    if component == "story_director":
        results += check_director_envelope(payload)
        results += check_forbidden_instruction_keywords(payload)
    elif component == "creative_intent":
        results.append(check_schema_valid(component, payload))
        results.append(check_creative_intent_no_overlap(payload))
    elif component == "scene_understanding":
        results.append(check_schema_valid(component, payload))
        results.append(check_scene_observational(payload))
    else:
        results.append(check_schema_valid(component, payload))
    return results


_SCENE_FORBIDDEN = (
    "safe to ", "you should ", "walk toward", "walk backward",
    "pan across", "cut to", "cut on", "zoom in on",
)


def check_scene_observational(payload: dict[str, Any]) -> CheckResult:
    """SceneUnderstanding must describe observable reality — no directing,
    editing, or safety-certification language (04-scene-understanding.md §23)."""
    parts = [payload.get("summary", "")]
    for k in ("motion_opportunities", "composition_opportunities", "constraints"):
        parts += [s for s in payload.get(k, []) if isinstance(s, str)]
    blob = " ".join(parts).lower()
    hit = next((s for s in _SCENE_FORBIDDEN if s in blob), None)
    return CheckResult(
        "scene_observational",
        hit is None,
        "" if hit is None else f"leaked non-observational phrase: {hit!r}",
    )


def check_creative_intent_no_overlap(payload: dict[str, Any]) -> CheckResult:
    """desired_feeling / style_tags / emphasis must not share values — a value
    repeated across lists is the duplicate-chip regression (found on-device:
    'beautiful'/'tough' appeared as both feeling and emphasis)."""
    feeling = {s.lower() for s in payload.get("desired_feeling", []) if isinstance(s, str)}
    style = {s.lower() for s in payload.get("style_tags", []) if isinstance(s, str)}
    emphasis = {s.lower() for s in payload.get("emphasis", []) if isinstance(s, str)}
    dupes = (feeling & emphasis) | (feeling & style) | (style & emphasis)
    return CheckResult(
        "creative_intent_lists_disjoint",
        not dupes,
        "" if not dupes else f"value(s) repeated across feeling/style/emphasis: {sorted(dupes)}",
    )
