"""Unit tests for the Asset Understanding engine with a FAKE gateway (no network).

Proves the FROZEN behaviour (06-asset-understanding.md §4-5): converts valid
structured output into the canonical MomentUnderstanding (server mints provenance);
applies EXACTLY ONE outer retry on malformed/provider failure; a second failure
raises AURetryableError (NO model fallback); and a Moment with no capture context
never carries a fabricated requested_shot/beat_contribution.
"""

from __future__ import annotations

from uuid import uuid4

import pytest

from asset_engine import (
    AUFrame,
    AURequestMeta,
    AURetryableError,
    CaptureContext,
    DEFAULT_AU_MODEL,
    PROMPT_VERSION,
    SCHEMA_VERSION,
    FRAME_POLICY,
    RealAssetUnderstandingEngine,
)
from contracts.schemas.ai_contracts import MomentUnderstandingContract
from model_gateway import (
    FakeModelGateway,
    ProviderError,
    StructuredOutputError,
    StructuredResult,
    Usage,
)

_FRAMES = [AUFrame(data=b"\xff\xd8jpeg%d" % i, t_ms=i * 100) for i in range(24)]

_GOOD = {
    "observed": {
        "summary": "A woman shoulders a pack and walks out down a corridor.",
        "subjects": ["woman", "backpack"],
        "events": [
            {"start_time": 0.0, "end_time": 4.0, "description": "shoulders the backpack"},
            {"start_time": 4.0, "end_time": 20.0, "description": "walks out down the corridor"},
        ],
        "temporal_order_note": "gear-up first, then departure down the hall",
        "useful_segments": [{"start_time": 0.0, "end_time": 20.0, "why_useful": "complete departure"}],
    },
    "story_context": {
        "story_utility": "strong_elsewhere",
        "requested_shot_contribution": "fulfilled — communicates departure",
        "requested_beat_contribution": "serves beat_departure",
    },
}


class _SequencedGateway:
    """Fake that yields a scripted sequence of outcomes (exception instance or dict)."""

    def __init__(self, outcomes):
        self._outcomes = list(outcomes)
        self.calls = 0

    def generate_structured(self, req):
        self.calls += 1
        out = self._outcomes.pop(0)
        if isinstance(out, Exception):
            raise out
        return StructuredResult(data=out, usage=Usage(1000, 500, 1500), model=DEFAULT_AU_MODEL, provider="fake")


def _ctx():
    return CaptureContext(shot={"id": "shot1", "purpose": "departure"}, beat={"id": "beat_departure"})


def test_analyze_converts_valid_output_and_mints_provenance():
    eng = RealAssetUnderstandingEngine(FakeModelGateway(response=_GOOD), model_id=DEFAULT_AU_MODEL)
    r = eng.analyze(_FRAMES, AURequestMeta(moment_id=uuid4(), capture_context=_ctx()))
    u = r.understanding
    assert isinstance(u, MomentUnderstandingContract)
    assert u.schema_version == SCHEMA_VERSION
    assert u.frame_policy == FRAME_POLICY
    assert u.prompt_version == PROMPT_VERSION
    assert u.model_id == "fake"  # provenance = what the gateway reported (FakeModelGateway)
    assert u.n_frames == 24
    assert u.story_context.story_utility.value == "strong_elsewhere"
    assert len(u.observed.events) == 2
    assert r.attempts == 1 and r.retried is False


def test_one_retry_then_success():
    gw = _SequencedGateway([StructuredOutputError("truncated"), _GOOD])
    eng = RealAssetUnderstandingEngine(gw, model_id=DEFAULT_AU_MODEL)
    r = eng.analyze(_FRAMES, AURequestMeta(moment_id=uuid4(), capture_context=_ctx()))
    assert gw.calls == 2
    assert r.retried is True and r.attempts == 2


def test_second_failure_raises_retryable_no_fallback():
    gw = _SequencedGateway([StructuredOutputError("bad1"), ProviderError("bad2")])
    eng = RealAssetUnderstandingEngine(gw, model_id=DEFAULT_AU_MODEL)
    with pytest.raises(AURetryableError):
        eng.analyze(_FRAMES, AURequestMeta(moment_id=uuid4(), capture_context=_ctx()))
    assert gw.calls == 2  # exactly one retry, then stop — no third/other-model call


def test_no_capture_context_strips_requested_contributions():
    # Model returns contributions, but there is NO capture context -> they must be nulled.
    eng = RealAssetUnderstandingEngine(FakeModelGateway(response=_GOOD), model_id=DEFAULT_AU_MODEL)
    r = eng.analyze(_FRAMES, AURequestMeta(moment_id=uuid4(), capture_context=None))
    sc = r.understanding.story_context
    assert sc.requested_shot_contribution is None
    assert sc.requested_beat_contribution is None
    assert sc.story_utility.value == "strong_elsewhere"  # observed utility retained


def test_empty_frames_is_retryable():
    eng = RealAssetUnderstandingEngine(FakeModelGateway(response=_GOOD))
    with pytest.raises(AURetryableError):
        eng.analyze([], AURequestMeta(moment_id=uuid4()))
