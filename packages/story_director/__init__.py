"""Story Director Engine — the real Director (Milestone C3A).

INITIALIZE: CreativeIntent + SceneUnderstanding + CaptureConstraints
            -> StoryConcept + StoryPlan{beats,shots} + DirectorState + DirectorDecision
NEXT:       prior DirectorState + Story-progress descriptors
            -> updated DirectorState + one DirectorDecision

Owns (milestone-c-story-director-design.md; task §4-§11): the versioned prompt,
the output envelope schema (composed from the FROZEN canonical contracts —
StoryConcept / StoryPlan{StoryBeat,Shot} / DirectorDecision / DirectorState),
request construction, referential-integrity + scene-grounding + safety guards,
canonical validation, and no-fabrication failure behaviour.

Depends only on contracts + model_gateway (03 §40). No provider SDK, no Bedrock
coupling. Model is task-specific config (Director model != CI != SU != validation).
No real Shot Validation here — that is C4.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Protocol, runtime_checkable
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field

from contracts.schemas.ai_contracts import (
    CreativeIntentContract,
    DirectorDecision,
    DirectorState,
    SceneUnderstandingContract,
    StoryConceptContract,
    StoryPlanContract,
)
from model_gateway import (
    ModelGateway,
    StructuredOutputError,
    StructuredRequest,
    StructuredResult,
)

PROMPT_VERSION = "story_director/v1"
SCHEMA_VERSION = "story_director.envelope/1"
TASK_INIT = "story_director.initialize"
TASK_NEXT = "story_director.next"

_PROMPT_DIR = Path(__file__).resolve().parent.parent.parent / "prompts" / "story_director" / "v1"

# Deterministic safety backstop — the model must not emit these in any shot
# instruction/purpose (prompt is the primary guard; this is the hard gate).
_UNSAFE_SUBSTRINGS = (
    "walk backward",
    "walking backward",
    "step back toward",
    "into traffic",
    "onto the road",
    "into the road",
    "climb onto",
    "lean over the edge",
    "near the edge while",
)


class DirectorOutput(BaseModel):
    """The Director's output envelope — composed from the frozen contracts.
    This is an ENGINE output shape, not a new canonical contract."""

    model_config = ConfigDict(extra="forbid")

    concept: StoryConceptContract
    plan: StoryPlanContract
    director_state: DirectorState
    decision: DirectorDecision


def _load_system_prompt() -> str:
    return (_PROMPT_DIR / "system.md").read_text()


def _envelope_schema() -> dict:
    """JSON Schema the model must satisfy. Server owns ids (concept/plan/shot
    ids are minted by us if the model omits them), so we relax `required` to the
    creative content and reconcile ids in _to_output."""
    schema = DirectorOutput.model_json_schema()
    return schema


@runtime_checkable
class StoryDirectorEngine(Protocol):
    def initialize(
        self,
        creative_intent: dict[str, Any],
        scene_understanding: dict[str, Any],
        capture_constraints: dict[str, Any] | None = None,
    ) -> DirectorOutput: ...

    def next(
        self,
        prior: dict[str, Any],
    ) -> DirectorOutput: ...


class RealStoryDirectorEngine:
    def __init__(self, gateway: ModelGateway, max_repair_attempts: int = 1):
        self._gateway = gateway
        self._system = _load_system_prompt()
        self._schema = _envelope_schema()
        self._max_repair_attempts = max_repair_attempts

    # ---- requests ----------------------------------------------------------

    def build_initialize_request(
        self,
        creative_intent: dict[str, Any],
        scene_understanding: dict[str, Any],
        capture_constraints: dict[str, Any] | None,
    ) -> StructuredRequest:
        import json
        content = {
            "operation": "initialize",
            "creative_intent": creative_intent,
            "scene_understanding": scene_understanding,
            "capture_constraints": capture_constraints or {},
        }
        return StructuredRequest(
            task=TASK_INIT,
            schema=self._schema,
            prompt_version=PROMPT_VERSION,
            system=self._system,
            user_content=(
                "INITIALIZE. Produce the concept, plan (beats + shots), initial "
                "director_state, and the first decision for this task:\n"
                + json.dumps(content, ensure_ascii=False)
            ),
            max_repair_attempts=self._max_repair_attempts,
            max_tokens=1600,
            temperature=0.3,
        )

    def build_next_request(self, prior: dict[str, Any]) -> StructuredRequest:
        import json
        return StructuredRequest(
            task=TASK_NEXT,
            schema=self._schema,
            prompt_version=PROMPT_VERSION,
            system=self._system,
            user_content=(
                "NEXT. Given the prior plan/state and the Story progress so far, "
                "update director_state and return exactly ONE next decision. Keep "
                "the same concept unless the plan genuinely must change:\n"
                + json.dumps(prior, ensure_ascii=False)
            ),
            max_repair_attempts=self._max_repair_attempts,
            max_tokens=1600,
            temperature=0.3,
        )

    # ---- ops ---------------------------------------------------------------

    def initialize(self, creative_intent, scene_understanding, capture_constraints=None) -> DirectorOutput:
        req = self.build_initialize_request(creative_intent, scene_understanding, capture_constraints)
        return self._to_output(self._gateway.generate_structured(req))

    def next(self, prior) -> DirectorOutput:
        req = self.build_next_request(prior)
        return self._to_output(self._gateway.generate_structured(req))

    # ---- validation --------------------------------------------------------

    def _to_output(self, result: StructuredResult) -> DirectorOutput:
        data = self._mint_ids(dict(result.data))
        try:
            out = DirectorOutput.model_validate(data)
        except Exception as e:
            raise StructuredOutputError(f"director output failed canonical validation: {e}") from e
        self._integrity_guard(out)
        self._safety_guard(out)
        return out

    @staticmethod
    def _mint_ids(data: dict[str, Any]) -> dict[str, Any]:
        """Server OWNS the opaque UUID ids (concept/plan/shot) — overwrite
        whatever the model emitted (it often returns 'shot1'/'s1'). StoryBeat.id
        is a free string and is left as-is; shot.beat_id references to those beats
        are preserved. The model's creative content is untouched."""
        shot_id_map: dict[str, str] = {}
        concept = data.get("concept")
        if isinstance(concept, dict):
            concept["id"] = str(uuid4())
            concept.pop("preview_asset_id", None)       # asset-owned, not the model's
            concept.pop("target_narrative_need_id", None)
        plan = data.get("plan")
        if isinstance(plan, dict):
            plan["id"] = str(uuid4())
            if isinstance(concept, dict):
                plan["concept_id"] = concept["id"]
            # Map any model shot id -> a fresh UUID; keep the decision's shot id aligned.
            for shot in plan.get("shots", []) or []:
                if isinstance(shot, dict):
                    shot.pop("example_asset_id", None)   # asset-owned, not the model's
                    old = shot.get("id")
                    new = str(uuid4())
                    if isinstance(old, str):
                        shot_id_map[old] = new
                    shot["id"] = new
            decision = data.get("decision")
            if isinstance(decision, dict) and isinstance(decision.get("shot"), dict):
                dshot = decision["shot"]
                dshot.pop("example_asset_id", None)
                old = dshot.get("id")
                # If the decision's shot matches a plan shot by old id, reuse its UUID.
                dshot["id"] = shot_id_map.get(old, str(uuid4())) if isinstance(old, str) else str(uuid4())
        data.setdefault("director_state", {"beat_progress": []})
        # director_state.last_decision may embed a shot with a model id too.
        ds = data.get("director_state")
        if isinstance(ds, dict):
            ds.setdefault("beat_progress", [])
            ld = ds.get("last_decision")
            if isinstance(ld, dict) and isinstance(ld.get("shot"), dict):
                ld["shot"].pop("example_asset_id", None)
                old = ld["shot"].get("id")
                ld["shot"]["id"] = shot_id_map.get(old, str(uuid4())) if isinstance(old, str) else str(uuid4())
        return data

    @staticmethod
    def _integrity_guard(out: DirectorOutput) -> None:
        beat_ids = {b.id for b in out.plan.beats}
        if not out.plan.beats:
            raise StructuredOutputError("plan has no beats; every shot must serve a beat")
        for s in out.plan.shots:
            if s.beat_id is None or s.beat_id not in beat_ids:
                raise StructuredOutputError(
                    f"shot {s.id} does not reference a real beat (beat_id={s.beat_id!r})"
                )
            if not (s.purpose and s.instruction):
                raise StructuredOutputError("every shot needs both a purpose and a user instruction")
        act = out.decision.action.value
        if act in ("capture_shot", "retry_shot") and out.decision.shot is None:
            raise StructuredOutputError(f"{act} decision must carry a shot")
        if act in ("create_now", "rescan_scene") and out.decision.shot is not None:
            raise StructuredOutputError(f"{act} decision must not carry a shot")

    @staticmethod
    def _safety_guard(out: DirectorOutput) -> None:
        texts = []
        for s in out.plan.shots:
            texts += [s.instruction or "", s.purpose or "", s.subject_action or "", s.camera_motion or ""]
        if out.decision.shot is not None:
            d = out.decision.shot
            texts += [d.instruction or "", d.purpose or "", d.subject_action or "", d.camera_motion or ""]
        blob = " ".join(texts).lower()
        hit = next((s for s in _UNSAFE_SUBSTRINGS if s in blob), None)
        if hit is not None:
            raise StructuredOutputError(
                f"director output contained an unsafe instruction ({hit!r}); "
                "Director must stay conservative regardless of scene"
            )


class MockStoryDirectorEngine:
    """Deterministic mock (no model). Dev/tests only — never production direction."""

    def initialize(self, creative_intent, scene_understanding, capture_constraints=None) -> DirectorOutput:
        cid, pid, sid, bid = uuid4(), uuid4(), uuid4(), "beat_open"
        from contracts.schemas.ai_contracts import ShotContract, StoryBeat
        concept = StoryConceptContract(id=cid, title="Mock concept", summary="A mock point of view.")
        shot = ShotContract(id=sid, order=1, instruction="Hold steady on the scene for a few seconds.",
                            beat_id=bid, purpose="Establish the place.")
        plan = StoryPlanContract(id=pid, concept_id=cid,
                                 beats=[StoryBeat(id=bid, purpose="Establish the place.")], shots=[shot])
        return DirectorOutput(
            concept=concept, plan=plan,
            director_state=DirectorState(current_beat_id=bid, beat_progress=[]),
            decision=DirectorDecision(action="capture_shot", shot=shot, reason="mock"),
        )

    def next(self, prior) -> DirectorOutput:
        return self.initialize(prior.get("creative_intent", {}), prior.get("scene_understanding", {}))


__all__ = [
    "PROMPT_VERSION", "SCHEMA_VERSION", "TASK_INIT", "TASK_NEXT",
    "DirectorOutput", "StoryDirectorEngine", "RealStoryDirectorEngine", "MockStoryDirectorEngine",
]
