"""Deterministic-derivation tests for Shot Validation (C4A, model-free).

Proves the axes -> {clip_disposition, requested_shot_status, user_state, moment}
derivation matches the APPROVED rules (c4 design §3.2–§3.3, §4, §5.4) BEFORE any
model exists. Covers the user's worked examples and full-cross-product invariants.
"""

from __future__ import annotations

import itertools

import pytest

from shot_validation import (
    ClipDisposition,
    ExecutionMatch,
    RequestedShotStatus,
    ShotPurpose,
    ShotValidationJudgment,
    StoryUtility,
    TechnicalUsability,
    UserState,
    derive,
)

T = TechnicalUsability
E = ExecutionMatch
P = ShotPurpose
U = StoryUtility


def _j(tech, ex, purpose, util) -> ShotValidationJudgment:
    return ShotValidationJudgment(
        technical_usability=tech, execution_match=ex, shot_purpose=purpose, story_utility=util
    )


# --- the user's approved worked examples (§3.2) ---------------------------------

@pytest.mark.parametrize(
    "tech,ex,purpose,util,disp,status,user",
    [
        # technically good + requested purpose fulfilled -> keep + fulfilled -> GOT IT
        (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE,
         ClipDisposition.KEEP, RequestedShotStatus.FULFILLED, UserState.GOT_IT),
        # technically good + alternative fulfillment -> keep + fulfilled -> GOT IT
        (T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.STRONG_ELSEWHERE,
         ClipDisposition.KEEP, RequestedShotStatus.FULFILLED, UserState.GOT_IT),
        # technically good + partial -> keep + partial -> GOT IT
        (T.USABLE, E.MATCHED, P.PARTIAL, U.NONE,
         ClipDisposition.KEEP, RequestedShotStatus.PARTIAL, UserState.GOT_IT),
        # technically good + unfulfilled + useful_elsewhere -> keep + unfulfilled -> KEEP+ONE MORE
        (T.USABLE, E.MATCHED, P.UNFULFILLED, U.USEFUL_ELSEWHERE,
         ClipDisposition.KEEP, RequestedShotStatus.UNFULFILLED, UserState.KEEP_PLUS_ONE_MORE),
        # technically unusable -> discard + unfulfilled -> TRY AGAIN
        (T.UNUSABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE,
         ClipDisposition.DISCARD, RequestedShotStatus.UNFULFILLED, UserState.TRY_AGAIN),
        # technically good + unfulfilled + no utility -> discard + unfulfilled -> TRY AGAIN
        (T.USABLE, E.MATCHED, P.UNFULFILLED, U.NONE,
         ClipDisposition.DISCARD, RequestedShotStatus.UNFULFILLED, UserState.TRY_AGAIN),
    ],
)
def test_approved_worked_examples(tech, ex, purpose, util, disp, status, user):
    d = derive(_j(tech, ex, purpose, util))
    assert d.clip_disposition == disp
    assert d.requested_shot_status == status
    assert d.user_state == user
    assert d.becomes_moment == (disp == ClipDisposition.KEEP)


# --- contradiction (§5.4) -------------------------------------------------------

def test_contradiction_with_utility_is_keep_plus_one_more():
    # contradicted + useful story footage -> KEEP + ONE MORE (never GOT IT)
    d = derive(_j(T.USABLE, E.CONTRADICTED, P.UNFULFILLED, U.USEFUL_ELSEWHERE))
    assert d.clip_disposition == ClipDisposition.KEEP
    assert d.requested_shot_status == RequestedShotStatus.UNFULFILLED
    assert d.user_state == UserState.KEEP_PLUS_ONE_MORE


def test_contradiction_without_utility_is_try_again():
    d = derive(_j(T.USABLE, E.CONTRADICTED, P.UNFULFILLED, U.NONE))
    assert d.clip_disposition == ClipDisposition.DISCARD
    assert d.user_state == UserState.TRY_AGAIN


def test_contradiction_can_never_be_got_it():
    # Even if the model (wrongly) paired contradicted with a positive purpose,
    # contradiction forces requested_shot_status=unfulfilled, so never GOT IT.
    for purpose in P:
        for util in U:
            d = derive(_j(T.USABLE, E.CONTRADICTED, purpose, util))
            assert d.requested_shot_status == RequestedShotStatus.UNFULFILLED
            assert d.user_state != UserState.GOT_IT


def test_alternative_fulfilled_is_got_it_not_contradiction():
    d = derive(_j(T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.NONE))
    assert d.requested_shot_status == RequestedShotStatus.FULFILLED
    assert d.user_state == UserState.GOT_IT


# --- full cross-product invariants ---------------------------------------------

def test_full_cross_product_invariants():
    for tech, ex, purpose, util in itertools.product(T, E, P, U):
        d = derive(_j(tech, ex, purpose, util))

        # unusable is ALWAYS discard + try_again + unfulfilled, no exceptions
        if tech == T.UNUSABLE:
            assert d.clip_disposition == ClipDisposition.DISCARD
            assert d.user_state == UserState.TRY_AGAIN
            assert d.requested_shot_status == RequestedShotStatus.UNFULFILLED
            continue

        # keep <=> becomes_moment
        assert d.becomes_moment == (d.clip_disposition == ClipDisposition.KEEP)

        # discard <=> try_again (for non-unusable, discard only when unfulfilled+no-utility)
        if d.clip_disposition == ClipDisposition.DISCARD:
            assert d.user_state == UserState.TRY_AGAIN
            assert purpose == P.UNFULFILLED and util == U.NONE

        # got_it requires keep AND a fulfilled/partial requested shot
        if d.user_state == UserState.GOT_IT:
            assert d.clip_disposition == ClipDisposition.KEEP
            assert d.requested_shot_status in (RequestedShotStatus.FULFILLED, RequestedShotStatus.PARTIAL)

        # keep_plus_one_more requires keep AND unfulfilled requested shot (useful kept)
        if d.user_state == UserState.KEEP_PLUS_ONE_MORE:
            assert d.clip_disposition == ClipDisposition.KEEP
            assert d.requested_shot_status == RequestedShotStatus.UNFULFILLED

        # fulfilled requested status only from fulfilled/alternative_fulfilled purpose
        if d.requested_shot_status == RequestedShotStatus.FULFILLED:
            assert purpose in (P.FULFILLED, P.ALTERNATIVE_FULFILLED)
            assert ex != E.CONTRADICTED


def test_useful_elsewhere_unfulfilled_is_retained_but_beat_unfulfilled():
    # The explicit Story-material resolution: kept Moment, beat stays unfulfilled.
    for util in (U.USEFUL_ELSEWHERE, U.STRONG_ELSEWHERE):
        d = derive(_j(T.USABLE, E.ABSENT, P.UNFULFILLED, util))
        assert d.becomes_moment is True
        assert d.requested_beat_effect == RequestedShotStatus.UNFULFILLED
        assert d.user_state == UserState.KEEP_PLUS_ONE_MORE
