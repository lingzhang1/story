"""MusicPlan Engine — produce the Story-level MusicPlan/1 (Milestone R-d, Batch A).

Owns:
  - the FROZEN production prompt (prompts/music_plan/v1/system.md), used VERBATIM — not rewritten;
  - the structured-output (tool-use) schema for the MODEL-FILLABLE subset of a MusicPlan;
  - construction of the planning request from the Story's understanding;
  - conversion of model output into the canonical MusicPlanContract (server mints schema_version,
    story_id, target_duration_seconds and provenance — the model never sets those);
  - task-level failure (NEVER fabricate a MusicPlan — a provider/model failure raises, it does not
    invent a plan; the caller preserves no-music creation as the fallback).

Does NOT: pick a track (that is the provider adapter + ranking), analyze audio (MusicAnalysis/1),
cut/select Moments (Edit Planner), or mix audio (Media Engine).

Inputs (R-d §2): CreativeIntent, authoritative MusicDirection, StoryGuide, StoryCoverage/2, target
duration. MusicDirection stays AUTHORITATIVE for mood/energy; a USER-AUTHORED MusicDirection overrides
inferred defaults and is passed straight through here. One Opus 4.6 call at creation time — NOT per Moment.

The contract (music_plan/1) and the prompt (music_plan/v1) are FROZEN (Milestone M-b). This module only
WIRES production inference to them; it changes neither.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol, runtime_checkable
from uuid import UUID

from contracts.schemas.ai_contracts import (
    AudioStrategy,
    EnergyArcRegion,
    EnergyIntensity,
    MusicCharacter,
    MusicEnergy,
    MusicPlanContract,
    MusicPlanProvenance,
    NativeAudioPriority,
    SoundtrackRole,
    TrackSelectionCriteria,
)
from model_gateway import ModelGateway, StructuredRequest, StructuredOutputError
from pydantic import ValidationError

PROMPT_VERSION = "music_plan/1"
TASK = "music_plan.generate"
MODEL_ID = "us.anthropic.claude-opus-4-6-v1"  # frozen (M-b); Sonnet 4.6 a valid future cost alternative
_PROMPT_PATH = Path(__file__).resolve().parent.parent.parent / "prompts" / "music_plan" / "v1" / "system.md"

_ENERGY = [e.value for e in MusicEnergy]                 # creative_intent §7.3 energy vocabulary
_INTENSITY = [e.value for e in EnergyIntensity]          # low|rising|high|falling
_ROLE = [e.value for e in SoundtrackRole]                # continuous|supportive|sparse
_PRIORITY = [e.value for e in NativeAudioPriority]       # low|selective|important

# Tool-use schema: the MODEL-FILLABLE subset of music_plan/1. The server mints schema_version, story_id,
# target_duration_seconds and provenance — the model never sets those (mirrors how the Edit Planner mints
# ids). key_moments is intentionally ABSENT (ablated out in M-b; the frozen prompt text mentions it but the
# contract — and therefore this schema — does not expose it, so the model cannot emit it).
SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["character", "energy_arc", "audio_strategy"],
    "properties": {
        "character": {
            "type": "object", "additionalProperties": False,
            "required": ["mood_tags", "energy"],
            "properties": {
                "mood_tags": {"type": "array", "items": {"type": "string"}},
                "energy": {"type": "string", "enum": _ENERGY},
            },
        },
        "energy_arc": {
            "type": "array",
            "description": "SMALL, scope-sensitive. 1 region for an 8s Story; 1-2 for short/minimal; "
                           "3-4 only for a rich 60-120s Story where each earns its place.",
            "items": {
                "type": "object", "additionalProperties": False,
                "required": ["label", "start_fraction", "end_fraction", "intensity"],
                "properties": {
                    "label": {"type": "string"},
                    "start_fraction": {"type": "number", "minimum": 0.0, "maximum": 1.0},
                    "end_fraction": {"type": "number", "minimum": 0.0, "maximum": 1.0},
                    "intensity": {"type": "string", "enum": _INTENSITY},
                    "note": {"type": "string"},
                },
            },
        },
        "audio_strategy": {
            "type": "object", "additionalProperties": False,
            "required": ["soundtrack_role", "native_audio_priority"],
            "properties": {
                "soundtrack_role": {"type": "string", "enum": _ROLE},
                "native_audio_priority": {"type": "string", "enum": _PRIORITY},
                "guidance": {"type": "string"},
            },
        },
        "track_selection_criteria": {
            "type": "object", "additionalProperties": False,
            "properties": {
                "mood_tags": {"type": "array", "items": {"type": "string"}},
                "energy": {"type": "string", "enum": _ENERGY},
                "structure_hint": {"type": "string"},
            },
        },
    },
}


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _load_system() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8")


@dataclass
class MusicPlanInputs:
    """Everything the MusicPlan engine needs. music_direction is AUTHORITATIVE for mood/energy; a
    user-authored direction is passed through unchanged (the engine never regenerates over an edit)."""
    story_id: str
    creative_intent: dict
    music_direction: dict
    target_duration_seconds: float
    story_guide: dict = field(default_factory=dict)
    story_coverage: dict = field(default_factory=dict)
    sound_preference: str | None = None  # immersive|balanced|music_led; None => infer. Advisory input, no schema change.


@runtime_checkable
class MusicPlanEngine(Protocol):
    def generate(self, inputs: MusicPlanInputs) -> MusicPlanContract: ...


def _build_user(inputs: MusicPlanInputs) -> str:
    import json
    payload = {
        "creative_intent": inputs.creative_intent,
        "music_direction": inputs.music_direction,        # AUTHORITATIVE for mood/energy
        "story_guide": inputs.story_guide,
        "story_coverage": inputs.story_coverage,
        "target_duration_seconds": inputs.target_duration_seconds,
    }
    if inputs.sound_preference:
        payload["sound_preference"] = inputs.sound_preference
    pref_line = _sound_pref_directive(inputs.sound_preference)
    return (
        "Plan the SOUNDTRACK SHAPE (MusicPlan) for THIS Story from the material below. MusicDirection is the "
        "authoritative intended feel. Scale the energy arc to the Story's scope — do NOT mechanically produce "
        "a quiet->build->climax. Respect native audio.\n"
        + pref_line
        + "\nINPUT:\n"
        + json.dumps(payload, indent=2)
        + "\n\nReturn ONLY the MusicPlan via the tool."
    )


def _sound_pref_directive(pref: str | None) -> str:
    """One-line directive mapping the user's sound preference onto audio_strategy (role/priority). Advisory
    REQUEST context — the frozen music_plan/1 prompt already decides role/priority; this biases it. Empty when
    no preference (model infers from intent/guide as before). music_led is NOT music-only: important native
    audio is preserved."""
    if pref == "immersive":
        return ("SOUND PREFERENCE = immersive: the user wants natural sound and environmental atmosphere to lead. "
                "Set native_audio_priority=important and keep soundtrack_role supportive or sparse.")
    if pref == "balanced":
        return ("SOUND PREFERENCE = balanced: intelligently combine meaningful native audio with music. "
                "Prefer native_audio_priority=selective and soundtrack_role=supportive.")
    if pref == "music_led":
        return ("SOUND PREFERENCE = music_led: let the soundtrack lead (soundtrack_role=continuous is fine), but "
                "this is NOT music-only — do NOT drop IMPORTANT native audio; keep native_audio_priority at least low "
                "and preserve a genuine performance/speech if present.")
    return ""


def _to_contract(data: dict, inputs: MusicPlanInputs, *, model_id: str) -> MusicPlanContract:
    """Convert the model's fillable subset into the canonical contract. Server mints schema_version,
    story_id, target_duration_seconds and provenance; MusicDirection authority is preserved by passing
    the model's character snapshot straight through (it echoes the direction, it does not override it)."""
    char = data.get("character", {}) or {}
    character = MusicCharacter(mood_tags=char.get("mood_tags", []) or [], energy=char.get("energy"))
    # Normalize energy_arc before strict validation (adapter-side normalization; the contract VALIDATES the
    # normalized result). A direct-provider model (gpt-5.1) occasionally returns a fraction out of [0,1] (e.g.
    # a percentage or seconds) or an intensity outside the enum — previously that raised a raw pydantic
    # ValidationError, which escaped as a 500 and made the app drop music ungracefully (the music page
    # flashed then jumped to creation with no music). Clamp fractions; keep only valid intensities; a region
    # that still cannot be coerced is dropped rather than crashing the whole plan.
    _VALID_INTENSITY = {"low", "rising", "high", "falling"}
    def _frac(v: Any, default: float) -> float:
        try:
            f = float(v)
        except (TypeError, ValueError):
            return default
        if f != f:  # NaN
            return default
        return max(0.0, min(1.0, f))
    arc: list[EnergyArcRegion] = []
    for r in (data.get("energy_arc", []) or []):
        if not isinstance(r, dict):
            continue
        intensity = r.get("intensity")
        if intensity not in _VALID_INTENSITY:
            continue  # cannot guess a categorical direction — skip this region, keep the rest
        start = _frac(r.get("start_fraction"), 0.0)
        end = _frac(r.get("end_fraction"), 1.0)
        if end < start:
            start, end = end, start
        try:
            arc.append(EnergyArcRegion(
                label=r.get("label", "") or "", start_fraction=start, end_fraction=end,
                intensity=intensity, note=r.get("note")))
        except ValidationError:
            continue  # residual bad region -> drop, do not fail the plan
    strat = data.get("audio_strategy", {}) or {}
    audio_strategy = AudioStrategy(
        soundtrack_role=strat.get("soundtrack_role"),
        native_audio_priority=strat.get("native_audio_priority"),
        guidance=strat.get("guidance"),
    )
    tsc_raw = data.get("track_selection_criteria")
    tsc = None
    if tsc_raw:
        tsc = TrackSelectionCriteria(
            mood_tags=tsc_raw.get("mood_tags", []) or [],
            energy=tsc_raw.get("energy"),
            structure_hint=tsc_raw.get("structure_hint"),
        )
    which = ["creative_intent", "music_direction"]
    if inputs.story_guide:
        which.append("story_guide")
    if inputs.story_coverage:
        which.append("story_coverage")
    return MusicPlanContract(
        story_id=UUID(inputs.story_id),
        target_duration_seconds=inputs.target_duration_seconds,
        character=character,
        energy_arc=arc,
        audio_strategy=audio_strategy,
        track_selection_criteria=tsc,
        provenance=MusicPlanProvenance(
            model_id=model_id, prompt_version=PROMPT_VERSION, inputs=which, generated_at=_utcnow()
        ),
    )


def _to_contract_safe(data: dict, inputs: MusicPlanInputs, *, model_id: str) -> MusicPlanContract:
    """_to_contract wrapped so a residual pydantic ValidationError (a model value the normalizers could not
    coerce — e.g. an out-of-vocabulary soundtrack_role/native_audio_priority/energy) becomes a
    StructuredOutputError. The endpoint already maps that to a graceful 503 -> the client falls back to
    no-music creation, instead of an unhandled 500 that made the music page flash and skip. NEVER fabricates:
    it does not invent a plan, it declares the structured output unusable."""
    try:
        return _to_contract(data, inputs, model_id=model_id)
    except ValidationError as e:
        raise StructuredOutputError(f"music plan failed canonical validation: {e}") from e


class RealMusicPlanEngine:
    """Opus 4.6 via the generic ModelGateway + the frozen music_plan/1 prompt. One call, structured
    tool-use. NEVER fabricates: a provider/model failure propagates (ProviderError/StructuredOutputError)
    so the caller falls back to no-music creation rather than inventing a plan. The canonical contract is
    the enforcement point (Pydantic validation on conversion)."""

    def __init__(self, gateway: ModelGateway, *, max_tokens: int = 1200):
        self._gw = gateway
        self._system = _load_system()
        self._max_tokens = max_tokens
        self.last_diagnostics: dict[str, Any] = {}

    def generate(self, inputs: MusicPlanInputs) -> MusicPlanContract:
        req = StructuredRequest(
            task=TASK, schema=SCHEMA, prompt_version=PROMPT_VERSION, system=self._system,
            user_content=_build_user(inputs), max_repair_attempts=2,
            max_tokens=self._max_tokens, temperature=0.0,
        )
        result = self._gw.generate_structured(req)  # raises StructuredOutputError / ProviderError
        u = result.usage
        self.last_diagnostics = {
            "model_calls": 1,
            "input_tokens": (u.input_tokens if u else 0) or 0,
            "output_tokens": (u.output_tokens if u else 0) or 0,
            "regions": len(result.data.get("energy_arc", []) or []),
        }
        return _to_contract_safe(result.data, inputs, model_id=MODEL_ID)


__all__ = [
    "PROMPT_VERSION", "TASK", "MODEL_ID", "SCHEMA",
    "MusicPlanInputs", "MusicPlanEngine", "RealMusicPlanEngine",
]
