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

def test_editorial_type_in_user_message(monkeypatch):
    import edit_planner; monkeypatch.setattr(edit_planner, "_v53_active", lambda: True)
    u = _build_user(_inputs(editorial_type="highlights"))
    assert "EDITORIAL TYPE = HIGHLIGHTS" in u
    assert '"editorial_type": "highlights"' in u

def test_v52_request_no_editorial_type_unchanged():
    u = _build_user(_inputs())                      # no editorial_type
    assert "EDITORIAL TYPE" not in u                # v5.2 behavior: directive absent

def test_untrusted_evidence_stripped_from_payload(monkeypatch):
    import edit_planner; monkeypatch.setattr(edit_planner, "_v53_active", lambda: True)
    m = {"id": "m1", "duration_seconds": 30, "useful_segments": [[0, 10]],
         "editorial": {"visual_candidates": [{"start_time": 1, "end_time": 3, "peak_time": 2,
                                              "visual_value": "twirl", "evidence": "frames@FABRICATED"}],
                       "narrative_candidates": []}}
    u = _build_user(_inputs(moments=[m], editorial_type="highlights"))
    assert "frames@FABRICATED" not in u             # untrusted evidence never forwarded
    assert "twirl" in u                             # the real candidate value is kept

def test_missing_editorial_block_is_valid(monkeypatch):
    import edit_planner; monkeypatch.setattr(edit_planner, "_v53_active", lambda: True)
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


# ----------------------------------------------------------------------------- v5.2 rollback projection (§4)

def _moment_with_v53():
    return {"id": "m1", "duration_seconds": 30, "useful_segments": [[0, 10]],
            "editorial": {"visual_candidates": [{"start_time": 1, "end_time": 3, "visual_value": "twirl",
                                                 "evidence": "frames@X"}], "narrative_candidates": []},
            "events": [{"start_time": 0, "end_time": 5, "description": "walk"}],
            "sampled_frame_ms": [0, 1385, 2770]}

def test_rollback_v52_strips_all_v53_fields(monkeypatch):
    """Installed v5.3 client sends optional v5.3 fields; backend configured v5.2 must strip them so planning
    is behaviorally identical to pre-P1-C (§4 installed-client/server-rollback scenario)."""
    import edit_planner
    monkeypatch.setattr(edit_planner, "_v53_active", lambda: False)
    u = _build_user(_inputs(moments=[_moment_with_v53()], editorial_type="highlights"))
    assert "EDITORIAL TYPE" not in u                 # no type directive under v5.2
    assert "editorial_type" not in u                 # not in payload
    assert "visual_candidates" not in u              # editorial block stripped
    assert "sampled_frame_ms" not in u               # provenance stripped
    assert "walk" not in u                           # events stripped
    assert "frames@X" not in u                       # untrusted evidence never present either
    assert "m1" in u and "useful_segments" in u      # v5.2 moment shape intact

def test_v53_active_keeps_fields(monkeypatch):
    import edit_planner
    monkeypatch.setattr(edit_planner, "_v53_active", lambda: True)
    u = _build_user(_inputs(moments=[_moment_with_v53()], editorial_type="highlights"))
    assert "EDITORIAL TYPE = HIGHLIGHTS" in u
    assert "twirl" in u and "sampled_frame_ms" in u
    assert "frames@X" not in u                        # evidence still stripped even under v5.3
