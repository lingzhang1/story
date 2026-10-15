"""Hybrid natural-language revision interpreter (Phase 2).

A SINGLE bounded structured model call that turns a free-form revision instruction into TYPED directives +
soft preferences, used only when deterministic parsing cannot fully cover the sentence. Design constraints
(owner): text-only, reuse the stable Moment-NUMBER snapshot, never fabricate Moment ids, flag unresolved
clauses, never silently drop part of a compound instruction, and do NOT invoke full multimodal planning merely
to parse.

The model is given the instruction + the Story's NUMBERED Moments (number + short summary, NO ids) and returns
directives keyed by DISPLAY NUMBER. This server then maps numbers -> stable Moment ids against the snapshot, so
the model literally cannot invent a UUID — an out-of-range number becomes an `unresolved` clause, never a
guessed id. The output is the SAME directive shape validate_plan already enforces (must_include / exclude /
opening / ending / order_after / order_adjacent) plus a free-text `soft_direction` and an `unsupported`
list for clauses the contract cannot express (e.g. "make it dreamier") that must reach the planner as soft text.
"""
from __future__ import annotations

from typing import Any

PROMPT_VERSION = "revision_interpret/1"
TASK = "revision.interpret"

# JSON schema for the interpreter's structured output. All Moment references are DISPLAY NUMBERS (integers),
# resolved to stable ids by the server afterwards.
SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "must_include": {"type": "array", "items": {"type": "integer"}},
        "exclude": {"type": "array", "items": {"type": "integer"}},
        "opening": {"type": ["integer", "null"]},
        "ending": {"type": ["integer", "null"]},
        # [after, before] number pairs
        "order_after": {"type": "array", "items": {"type": "array", "items": {"type": "integer"},
                                                    "minItems": 2, "maxItems": 2}},
        "order_adjacent": {"type": "array", "items": {"type": "array", "items": {"type": "integer"},
                                                       "minItems": 2, "maxItems": 2}},
        # free-text creative/pacing preferences the hard contract cannot express (kept, never dropped)
        "soft_direction": {"type": "string"},
        # clauses the model could not confidently map to a supported directive — surfaced for clarification,
        # NEVER silently discarded.
        "unsupported": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["must_include", "exclude", "order_after", "order_adjacent", "soft_direction", "unsupported"],
}

_SYSTEM = (
    "You convert ONE natural-language video-revision instruction into a strict set of editing directives.\n"
    "You are given the instruction and a NUMBERED list of the Story's Moments (number + short description).\n"
    "Refer to Moments ONLY by their given number. NEVER invent a number not in the list.\n\n"
    "Map the instruction to these HARD directives when the meaning is unambiguous:\n"
    "- opening: the Moment number that must be FIRST.\n"
    "- ending: the Moment number that must be LAST.\n"
    "- must_include: Moment numbers that must appear.\n"
    "- exclude: Moment numbers that must NOT appear.\n"
    "- order_after: [[A,B],...] A must appear somewhere AFTER B.\n"
    "- order_adjacent: [[A,B],...] A must appear IMMEDIATELY after B (directly next).\n\n"
    "Rules:\n"
    "- 'start with / use N to start / N first' => opening=N.\n"
    "- 'end with / N last / N at the end' => ending=N.\n"
    "- 'N follows' / 'then N' / 'N next' with no other antecedent => N is adjacent-after the opening.\n"
    "- 'N right/immediately after M' => order_adjacent [[N,M]]; 'N after M' => order_after [[N,M]].\n"
    "- Pacing/style/mood ('faster cuts', 'more cinematic', 'match the beat') is NOT a hard directive: put the "
    "verbatim phrase in soft_direction.\n"
    "- If a clause references a Moment NUMBER not in the list, or you cannot confidently map it, add the "
    "verbatim clause to 'unsupported' — do NOT guess and do NOT drop it.\n"
    "- Decompose COMPOUND instructions: every clause must land in a directive, soft_direction, or unsupported.\n"
    "Return ONLY the structured object."
)


class RevisionInterpretation:
    """Resolved result: directive dict (keyed by STABLE id, ready for revision_context.directives), the soft
    direction string, and human-readable `unresolved` clauses (unsupported + out-of-range references)."""

    def __init__(self, directives: dict, soft_direction: str, unresolved: list[str]):
        self.directives = directives
        self.soft_direction = soft_direction
        self.unresolved = unresolved

    @property
    def needs_clarification(self) -> bool:
        return bool(self.unresolved)


def _build_user(instruction: str, numbered: list[dict]) -> str:
    import json
    lines = [f"{m['number']}: {m.get('summary') or m.get('caption') or 'Moment'}" for m in numbered]
    return ("INSTRUCTION:\n" + instruction.strip() + "\n\nMOMENTS (number: description):\n"
            + "\n".join(lines) + "\n\nReturn the structured directives per the schema.")


def interpret_revision(instruction: str, numbered: list[dict], gateway) -> RevisionInterpretation:
    """ONE structured model call. `numbered` = [{number:int, id:str, summary:str}, ...] (the stable snapshot).
    Maps the model's number-keyed output to stable ids; an out-of-range number becomes an unresolved clause
    (never a fabricated id). Raises StructuredOutputError/ProviderError to the caller (handled as 503)."""
    from model_gateway import StructuredRequest
    num_to_id = {int(m["number"]): m["id"] for m in numbered if "number" in m and "id" in m}

    req = StructuredRequest(
        task=TASK, schema=SCHEMA, prompt_version=PROMPT_VERSION, system=_SYSTEM,
        user_content=_build_user(instruction, numbered), max_repair_attempts=1,
        max_tokens=800, temperature=0.0)
    data = gateway.generate_structured(req).data or {}

    unresolved: list[str] = []
    for clause in (data.get("unsupported") or []):
        if isinstance(clause, str) and clause.strip():
            unresolved.append(clause.strip())

    def _map_ids(nums) -> list[str]:
        out: list[str] = []
        for n in (nums or []):
            try:
                n = int(n)
            except (TypeError, ValueError):
                continue
            mid = num_to_id.get(n)
            if mid is None:
                unresolved.append(f"Moment {n} is not in this Story")
            elif mid not in out:
                out.append(mid)
        return out

    def _map_one(n) -> str | None:
        if n is None:
            return None
        try:
            n = int(n)
        except (TypeError, ValueError):
            return None
        mid = num_to_id.get(n)
        if mid is None:
            unresolved.append(f"Moment {n} is not in this Story")
            return None
        return mid

    def _map_pairs(pairs) -> list[list[str]]:
        out: list[list[str]] = []
        for p in (pairs or []):
            if isinstance(p, (list, tuple)) and len(p) == 2:
                a, b = _map_one(p[0]), _map_one(p[1])
                if a and b and a != b:
                    out.append([a, b])
        return out

    directives: dict[str, Any] = {}
    inc = _map_ids(data.get("must_include"))
    exc = _map_ids(data.get("exclude"))
    opening = _map_one(data.get("opening"))
    ending = _map_one(data.get("ending"))
    oa = _map_pairs(data.get("order_after"))
    adj = _map_pairs(data.get("order_adjacent"))
    if inc: directives["must_include"] = inc
    if exc: directives["exclude"] = exc
    if opening: directives["opening"] = opening
    if ending: directives["ending"] = ending
    if oa: directives["order_after"] = oa
    if adj: directives["order_adjacent"] = adj

    soft = (data.get("soft_direction") or "").strip()
    return RevisionInterpretation(directives=directives, soft_direction=soft, unresolved=unresolved)


__all__ = ["PROMPT_VERSION", "TASK", "SCHEMA", "RevisionInterpretation", "interpret_revision"]
