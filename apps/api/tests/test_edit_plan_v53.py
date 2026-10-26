"""EditPlan v5.3 mode-aware offline tests (no live model). Verifies the additive editorial-type contract,
advisory-evidence handling, untrusted-evidence exclusion, and v5.2 compatibility. P1-C §12."""
from __future__ import annotations
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "packages"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from edit_planner import (
    EditPlanInputs, _build_user, _editorial_type_directive, _editorial_evidence_lines,
)

_CI = {"target_duration_seconds": 30}
def _inputs(**kw):
    base = dict(story_id="s", creative_intent_id="c", creative_intent=_CI, story_guide={}, story_coverage={},
                moments=[{"id": "m1", "duration_seconds": 30, "useful_segments": [[0, 10]]}], music_plan={})
    base.update(kw)
    return EditPlanInputs(**base)


def test_highlights_directive_distinct_from_full_story():
    h = _editorial_type_directive("highlights"); f = _editorial_type_directive("full_story")
    assert "HIGHLIGHTS" in h and "compressed Full Story" in h
    assert "FULL STORY" in f and "Highlights montage" in f
    assert h != f                                   # genuinely different intents
    assert _editorial_type_directive(None) == ""    # unset => v5.2 behavior

def test_editorial_type_in_user_message():
    u = _build_user(_inputs(editorial_type="highlights"))
    assert "EDITORIAL TYPE = HIGHLIGHTS" in u
    assert '"editorial_type": "highlights"' in u

def test_v52_request_no_editorial_type_unchanged():
    u = _build_user(_inputs())                      # no editorial_type
    assert "EDITORIAL TYPE" not in u                # v5.2 behavior: directive absent

def test_untrusted_evidence_stripped_from_payload():
    m = {"id": "m1", "duration_seconds": 30, "useful_segments": [[0, 10]],
         "editorial": {"visual_candidates": [{"start_time": 1, "end_time": 3, "peak_time": 2,
                                              "visual_value": "twirl", "evidence": "frames@FABRICATED"}],
                       "narrative_candidates": []}}
    u = _build_user(_inputs(moments=[m], editorial_type="highlights"))
    assert "frames@FABRICATED" not in u             # untrusted evidence never forwarded
    assert "twirl" in u                             # the real candidate value is kept

def test_missing_editorial_block_is_valid():
    # a Moment with no editorial block must not break planning
    m = {"id": "m1", "duration_seconds": 30, "useful_segments": [[0, 10]]}
    u = _build_user(_inputs(moments=[m], editorial_type="full_story"))
    assert "EDITORIAL TYPE = FULL STORY" in u        # type still applied
    assert _editorial_evidence_lines(m) == ""        # no candidate lines, no crash

def test_extra_moment_keys_are_lenient():
    # per-moment v5.3 keys are extra dict keys the v5.2 planner path reads via .get() — harmless
    m = {"id": "m1", "duration_seconds": 30, "useful_segments": [[0, 10]],
         "editorial": {"visual_candidates": [], "narrative_candidates": []},
         "events": [{"start_time": 0, "end_time": 5, "description": "x"}],
         "sampled_frame_ms": [0, 1385]}
    # no editorial_type (v5.2-style): must still build without error and ignore the extras gracefully
    u = _build_user(_inputs(moments=[m]))
    assert "m1" in u
