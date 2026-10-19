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

# v1 is FROZEN and preserved verbatim below as _SYSTEM_V1 / "revision_interpret/1". v2 is the candidate that
# fixes interpreter OVERREACH (inventing exclude directives from inclusion/ordering-only instructions). The
# active version is PROMPT_VERSION; callers may override per-call. Do NOT edit v1 in place.
PROMPT_VERSION = "revision_interpret/2"
PROMPT_VERSION_V1 = "revision_interpret/1"
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

_SYSTEM_V1 = (
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

# revision_interpret/2 — candidate. Identical directive model to v1, with EXPLICIT anti-overreach semantics:
# inclusion / opening / ending / ordering must NEVER imply exclusion of other Moments. exclude is emitted ONLY
# when the user explicitly omits Moments ("remove/drop/skip/without/don't use N") OR explicitly RESTRICTS the
# eligible set ("use only A, B, C" / "nothing except A, B, C"). This directly fixes the observed failure where
# "Use Moment 13 first and Moment 2 immediately after. Use Moment 6 as end." produced a large invented exclude
# set. v1 wording is otherwise preserved so ordering/opening/ending behavior is unchanged.
_SYSTEM_V2 = (
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
    "CRITICAL — do NOT invent constraints the user did not state:\n"
    "- Naming a Moment to USE, INCLUDE, OPEN with, END with, or ORDER does NOT mean other Moments are "
    "excluded. The rest of the Story stays eligible. 'Use Moment 13 first and Moment 2 immediately after, "
    "Moment 6 as end' sets opening/adjacent/ending ONLY — exclude MUST be empty.\n"
    "- Emit `exclude` ONLY when the user explicitly OMITS Moments ('remove N', 'drop N', 'skip N', 'without "
    "N', \"don't use N\", 'leave out N') OR explicitly RESTRICTS the set ('use ONLY Moments A, B, C', 'nothing "
    "except A, B, C', 'just A, B, C'). A plain 'use A, B, C' is inclusion, NOT a restriction — do not exclude "
    "the others.\n"
    "- For an explicit 'use only A, B, C' restriction, you MAY either set must_include=[A,B,C] OR exclude the "
    "others; prefer must_include and leave exclude empty unless the user named the Moments to remove.\n"
    "- Never add opening/ending/ordering the user did not ask for. Never add must_include beyond what was named.\n\n"
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

_SYSTEMS = {PROMPT_VERSION_V1: _SYSTEM_V1, "revision_interpret/2": _SYSTEM_V2}


class RevisionInterpretation:
    """Resolved result: directive dict (keyed by STABLE id, ready for revision_context.directives), the soft
    direction string, and human-readable `unresolved` clauses (unsupported + out-of-range references).
    `raw` is the model's number-keyed output and `instruction` the original text, both kept so a deterministic
    grounding guard can check that each hard directive is actually supported by the user's request."""

    def __init__(self, directives: dict, soft_direction: str, unresolved: list[str],
                 raw: dict | None = None, instruction: str = ""):
        self.directives = directives
        self.soft_direction = soft_direction
        self.unresolved = unresolved
        self.raw = raw or {}
        self.instruction = instruction

    @property
    def needs_clarification(self) -> bool:
        return bool(self.unresolved)


def _build_user(instruction: str, numbered: list[dict]) -> str:
    import json
    lines = [f"{m['number']}: {m.get('summary') or m.get('caption') or 'Moment'}" for m in numbered]
    return ("INSTRUCTION:\n" + instruction.strip() + "\n\nMOMENTS (number: description):\n"
            + "\n".join(lines) + "\n\nReturn the structured directives per the schema.")


# Keywords that legitimately justify an EXCLUDE directive: an explicit omission, or an explicit restriction of
# the eligible set. Used by the grounding guard to decide whether a model-emitted exclude set is SUPPORTED by
# the user's words (Phase 3). This is NOT a full parser — it is a narrow support check on ONE directive type.
_OMISSION_WORDS = ("exclude", "remove", "drop", "skip", "without", "leave out", "don't use", "do not use",
                   "dont use", "no moment", "not moment", "take out", "get rid")
_RESTRICTION_WORDS = ("only", "except", "nothing but", "just moment", "just the", "exclusively",
                      "limit to", "restrict to")


def exclude_is_supported(instruction: str) -> bool:
    """True when the user's text contains an explicit OMISSION or RESTRICTION cue that justifies ANY exclude
    directive. A plain 'use/start/end/order' instruction has neither -> an exclude emitted from it is
    unsupported interpreter overreach. Deliberately narrow: it answers only 'could an exclude be legitimate
    here', not 'which Moments'. 'use only A, B, C' is a legitimate restriction and passes."""
    low = (instruction or "").lower()
    return any(w in low for w in _OMISSION_WORDS) or any(w in low for w in _RESTRICTION_WORDS)


def ground_directives(result: "RevisionInterpretation") -> list[str]:
    """Deterministic hard-directive GROUNDING guard (Phase 3). Returns a list of unsupported-constraint reasons
    (empty => every hard directive is backed by the user's request). It does NOT mutate the result and does NOT
    silently drop anything — the caller decides (reinterpret once, else clarify). Currently checks the one
    overreach we have evidence for: an EXCLUDE set produced from an instruction with no omission/restriction
    cue. Legitimate 'use only A, B, C' restrictions pass (they carry a restriction word)."""
    reasons: list[str] = []
    directives = result.directives or {}
    exc = directives.get("exclude") or []
    if exc and not exclude_is_supported(result.instruction):
        reasons.append(
            "unsupported_exclude: the interpreter marked Moments to exclude, but your instruction only "
            "named Moments to use/order — it did not ask to remove or restrict anything")
    return reasons


def interpret_revision(instruction: str, numbered: list[dict], gateway,
                       prompt_version: str | None = None) -> RevisionInterpretation:
    """ONE structured model call. `numbered` = [{number:int, id:str, summary:str}, ...] (the stable snapshot).
    Maps the model's number-keyed output to stable ids; an out-of-range number becomes an unresolved clause
    (never a fabricated id). `prompt_version` selects the system prompt (defaults to the active PROMPT_VERSION;
    pass 'revision_interpret/1' for the frozen baseline in A/B comparison). Raises StructuredOutputError/
    ProviderError to the caller (handled as 503)."""
    from model_gateway import StructuredRequest
    num_to_id = {int(m["number"]): m["id"] for m in numbered if "number" in m and "id" in m}

    pv = prompt_version or PROMPT_VERSION
    system = _SYSTEMS.get(pv, _SYSTEM_V2)
    req = StructuredRequest(
        task=TASK, schema=SCHEMA, prompt_version=pv, system=system,
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
    return RevisionInterpretation(directives=directives, soft_direction=soft, unresolved=unresolved,
                                  raw=data, instruction=instruction)


__all__ = ["PROMPT_VERSION", "PROMPT_VERSION_V1", "TASK", "SCHEMA", "RevisionInterpretation",
           "interpret_revision", "ground_directives", "exclude_is_supported"]
