"""Shot Validation — internal judgment + deterministic derivations (Milestone C4A).

Implements the APPROVED design (milestone-c4-shot-validation-design.md §3):

  model output  -> ShotValidationJudgment (4 categorical axes ONLY)
  deterministic -> CLIP DISPOSITION {keep, discard}
               -> REQUESTED SHOT STATUS {fulfilled, partial, unfulfilled}
               -> USER STATE {got_it, keep_plus_one_more, try_again}

The model emits ONLY the four axes. The three derived concepts are pure functions
of the axes (never model-generated), so the model cannot contradict the product
rules. BeatProgress stays Director state and is NOT produced here.

This module is model-free and AWS-free — it is the testable core the eval runner,
the backend engine (C4B), and the Director loop (C4D) all share. B+ architecture:
the simple external ValidationResult / user state is derived here; the richer
internal judgment is a separate structured-output shape.
"""

from __future__ import annotations

from enum import Enum

from pydantic import BaseModel, ConfigDict, Field


# ---------------------------------------------------------------------------
# Approved 4-axis vocabulary (the ONLY model-generated semantic fields)
# ---------------------------------------------------------------------------


class TechnicalUsability(str, Enum):
    USABLE = "usable"
    MINOR_ISSUES = "minor_issues"
    UNUSABLE = "unusable"


class ExecutionMatch(str, Enum):
    MATCHED = "matched"
    DEVIATED = "deviated"
    ABSENT = "absent"
    CONTRADICTED = "contradicted"


class ShotPurpose(str, Enum):
    FULFILLED = "fulfilled"
    PARTIAL = "partial"
    UNFULFILLED = "unfulfilled"
    ALTERNATIVE_FULFILLED = "alternative_fulfilled"


class StoryUtility(str, Enum):
    NONE = "none"
    USEFUL_ELSEWHERE = "useful_elsewhere"
    STRONG_ELSEWHERE = "strong_elsewhere"


# ---------------------------------------------------------------------------
# Derived concepts (deterministic; NEVER model-generated)
# ---------------------------------------------------------------------------


class ClipDisposition(str, Enum):
    KEEP = "keep"
    DISCARD = "discard"


class RequestedShotStatus(str, Enum):
    FULFILLED = "fulfilled"
    PARTIAL = "partial"
    UNFULFILLED = "unfulfilled"


class UserState(str, Enum):
    GOT_IT = "got_it"
    KEEP_PLUS_ONE_MORE = "keep_plus_one_more"
    TRY_AGAIN = "try_again"


# Gross-failure issue codes — the frozen ValidationIssue enum EXTENDED (approved §8)
# with exactly out_of_focus / wrong_subject / unusable_motion. Kept here as the C4
# working vocabulary; the canonical contracts/schemas/ai_contracts.py enum is
# extended at C4B implementation time (not in this offline module).
class ShotValidationIssue(str, Enum):
    TOO_SHORT = "too_short"
    SEVERE_SHAKE = "severe_shake"
    SUBJECT_MISSING = "subject_missing"
    SEVERE_UNDEREXPOSURE = "severe_underexposure"
    SEVERE_OVEREXPOSURE = "severe_overexposure"
    INSTRUCTION_NOT_FOLLOWED = "instruction_not_followed"
    # C4 additions (approved):
    OUT_OF_FOCUS = "out_of_focus"
    WRONG_SUBJECT = "wrong_subject"
    UNUSABLE_MOTION = "unusable_motion"


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ShotValidationJudgment(_Strict):
    """The internal 4-axis judgment the multimodal validator emits (C4 §3.1).

    The model MUST return exactly these axes (+ optional confidence/reason/issues
    for diagnostics). It MUST NOT emit clip_disposition / requested_shot_status /
    user_state — those are derived (see derive()).
    """

    technical_usability: TechnicalUsability
    execution_match: ExecutionMatch
    shot_purpose: ShotPurpose
    story_utility: StoryUtility
    # Diagnostics only (not required, do not drive derivation except issues->none):
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    reason: str | None = Field(default=None, description="One plain sentence for the user when not got_it.")
    issues: list[ShotValidationIssue] = Field(default_factory=list)


class DerivedValidation(_Strict):
    """The deterministic derivation bundle (C4 §3.2–§3.3). Pure function of axes."""

    clip_disposition: ClipDisposition
    requested_shot_status: RequestedShotStatus
    user_state: UserState
    becomes_moment: bool
    requested_beat_effect: RequestedShotStatus  # beat effect mirrors requested-shot status


def derive(j: ShotValidationJudgment) -> DerivedValidation:
    """Deterministically derive disposition / shot-status / user-state from the
    4-axis judgment, per the APPROVED rules (C4 §3.2, §3.3, §4, §5.4).

    Rules (authoritative):
      CLIP DISPOSITION:
        discard  <=  technical_usability == unusable
                     OR (shot_purpose == unfulfilled AND story_utility == none)
        keep     otherwise
      REQUESTED SHOT STATUS:
        unfulfilled <= technical_usability == unusable
                       OR execution_match == contradicted
                       OR shot_purpose == unfulfilled
        partial     <= shot_purpose == partial            (and not forced unfulfilled above)
        fulfilled   <= shot_purpose in {fulfilled, alternative_fulfilled}
                                                          (and not forced unfulfilled above)
      USER STATE:
        try_again          <= disposition == discard
        keep_plus_one_more <= keep AND requested_shot_status == unfulfilled
        got_it             <= keep AND requested_shot_status in {fulfilled, partial}
      MOMENT: becomes_moment == (disposition == keep).
    Contradiction (execution_match == contradicted) therefore can NEVER be got_it:
      it forces requested_shot_status = unfulfilled, so with utility it is
      keep_plus_one_more and without utility it is try_again. alternative_fulfilled
      is the opposite (fulfilled -> got_it).
    """
    tech = j.technical_usability
    ex = j.execution_match
    purpose = j.shot_purpose
    util = j.story_utility

    # CLIP DISPOSITION
    if tech == TechnicalUsability.UNUSABLE or (
        purpose == ShotPurpose.UNFULFILLED and util == StoryUtility.NONE
    ):
        disposition = ClipDisposition.DISCARD
    else:
        disposition = ClipDisposition.KEEP

    # REQUESTED SHOT STATUS (contradiction / unusable / unfulfilled all force unfulfilled)
    if (
        tech == TechnicalUsability.UNUSABLE
        or ex == ExecutionMatch.CONTRADICTED
        or purpose == ShotPurpose.UNFULFILLED
    ):
        status = RequestedShotStatus.UNFULFILLED
    elif purpose == ShotPurpose.PARTIAL:
        status = RequestedShotStatus.PARTIAL
    else:  # fulfilled or alternative_fulfilled
        status = RequestedShotStatus.FULFILLED

    # USER STATE
    if disposition == ClipDisposition.DISCARD:
        user = UserState.TRY_AGAIN
    elif status == RequestedShotStatus.UNFULFILLED:
        user = UserState.KEEP_PLUS_ONE_MORE
    else:
        user = UserState.GOT_IT

    return DerivedValidation(
        clip_disposition=disposition,
        requested_shot_status=status,
        user_state=user,
        becomes_moment=(disposition == ClipDisposition.KEEP),
        requested_beat_effect=status,
    )


__all__ = [
    "TechnicalUsability", "ExecutionMatch", "ShotPurpose", "StoryUtility",
    "ClipDisposition", "RequestedShotStatus", "UserState", "ShotValidationIssue",
    "ShotValidationJudgment", "DerivedValidation", "derive",
]
