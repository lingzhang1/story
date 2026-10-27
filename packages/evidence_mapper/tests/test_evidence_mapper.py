from __future__ import annotations

import evidence_mapper as mp


# 24 evenly-spaced frames across ~35.3s (au_frames/1 spacing ~= 1.535s), like a real Moment.
def _sampled(n=24, dur_s=35.3):
    step = (dur_s * 1000) / (n - 1)
    return [int(round(i * step)) for i in range(n)]


def _c(start, end, peak=None, conf=None):
    return mp.Candidate(start=start, end=end, peak=peak, confidence=conf)


# ---- determinism ---------------------------------------------------------------------------------
def test_deterministic_same_inputs_same_output():
    s = _sampled()
    args = dict(video_type=mp.HIGHLIGHTS, sampled_frame_ms=s,
                visual_candidates=[_c(6, 10.5, peak=9.5, conf=0.8)],
                narrative_candidates=[], event_times_s=[], budget=8)
    a = mp.select_frames(**args)
    b = mp.select_frames(**args)
    assert a == b
    assert a == sorted(a)                      # ascending
    assert len(a) == len(set(a))               # de-duplicated


# ---- budget compliance ---------------------------------------------------------------------------
def test_never_exceeds_budget_and_never_empty():
    s = _sampled()
    for budget in (4, 5, 7, 9):
        out = mp.select_frames(video_type=mp.HIGHLIGHTS, sampled_frame_ms=s,
                               visual_candidates=[_c(2, 5, 3.5), _c(12, 16, 14), _c(28, 33, 30)],
                               narrative_candidates=[], event_times_s=[], budget=budget)
        assert 0 < len(out) <= budget
        assert all(0 <= i < len(s) for i in out)


def test_budget_ge_frames_returns_all():
    s = _sampled(n=6)
    out = mp.select_frames(video_type=mp.HIGHLIGHTS, sampled_frame_ms=s,
                           visual_candidates=[], narrative_candidates=[], event_times_s=[], budget=10)
    assert out == [0, 1, 2, 3, 4, 5]


# ---- whole-Moment overview always preserved ------------------------------------------------------
def test_overview_floor_includes_first_and_last():
    s = _sampled()
    out = mp.select_frames(video_type=mp.HIGHLIGHTS, sampled_frame_ms=s,
                           visual_candidates=[_c(15, 17, 16, 0.9)],  # one mid candidate
                           narrative_candidates=[], event_times_s=[], budget=8)
    assert 0 in out and (len(s) - 1) in out    # opening + closing context survive a mid candidate


# ---- no-candidate fallback = uniform coverage ----------------------------------------------------
def test_no_candidate_uniform_fallback():
    s = _sampled()
    out = mp.select_frames(video_type=mp.HIGHLIGHTS, sampled_frame_ms=s,
                           visual_candidates=[], narrative_candidates=[], event_times_s=[], budget=6)
    assert len(out) == 6 and out[0] == 0 and out[-1] == len(s) - 1
    # roughly even spacing (no clustering)
    gaps = [out[i + 1] - out[i] for i in range(len(out) - 1)]
    assert max(gaps) - min(gaps) <= 2


# ---- Highlights: multiple distinct candidates each get coverage ----------------------------------
def test_highlights_covers_multiple_distinct_candidates():
    s = _sampled()
    # three reveals across the clip; high-confidence middle one must NOT crowd out the others
    out = mp.select_frames(video_type=mp.HIGHLIGHTS, sampled_frame_ms=s,
                           visual_candidates=[_c(3, 6, 4.5, 0.4), _c(14, 18, 16, 0.95), _c(27, 31, 29, 0.5)],
                           narrative_candidates=[], event_times_s=[], budget=9)
    # a frame near EACH candidate region is present (distinct-first, not confidence-collapse)
    def near(t_s):
        idx = min(range(len(s)), key=lambda i: abs(s[i] - t_s * 1000))
        return idx in out
    assert near(4.5) and near(16) and near(29)


def test_highlights_not_single_nearest_peak():
    # a single candidate must still yield before/at/after context, never ONE nearest-peak frame
    s = _sampled()
    out = mp.select_frames(video_type=mp.HIGHLIGHTS, sampled_frame_ms=s,
                           visual_candidates=[_c(15, 19, 17, 0.9)],
                           narrative_candidates=[], event_times_s=[], budget=6)
    # frames spanning the candidate window (before 15 and after 19) both present
    before = [i for i in out if s[i] < 15000]
    after = [i for i in out if s[i] > 19000]
    assert before and after            # context on both sides, not a point collapse


# ---- Full Story: narrative candidates + events drive progression ---------------------------------
def test_full_story_uses_narrative_and_events():
    s = _sampled()
    out = mp.select_frames(video_type=mp.FULL_STORY, sampled_frame_ms=s,
                           visual_candidates=[_c(2, 4, 3, 0.9)],              # ignored for full story
                           narrative_candidates=[_c(0, 5, None, 0.6), _c(25, 33, None, 0.6)],
                           event_times_s=[10.0, 20.0], budget=9)
    def near(t_s):
        idx = min(range(len(s)), key=lambda i: abs(s[i] - t_s * 1000))
        return idx in out
    # opening, mid events, and resolution all represented (even narrative coverage)
    assert 0 in out and (len(s) - 1) in out
    assert near(10.0) or near(20.0)        # at least one event progression beat covered


def test_highlights_vs_full_story_differ():
    s = _sampled()
    vis = [_c(3, 6, 4.5, 0.9)]
    nar = [_c(28, 33, None, 0.6)]
    h = mp.select_frames(video_type=mp.HIGHLIGHTS, sampled_frame_ms=s,
                         visual_candidates=vis, narrative_candidates=nar, event_times_s=[], budget=6)
    f = mp.select_frames(video_type=mp.FULL_STORY, sampled_frame_ms=s,
                         visual_candidates=vis, narrative_candidates=nar, event_times_s=[], budget=6)
    assert h != f    # type-specific selection genuinely differs


# ---- uncertain peak (None) handled ---------------------------------------------------------------
def test_candidate_without_peak_still_selects_context():
    s = _sampled()
    out = mp.select_frames(video_type=mp.HIGHLIGHTS, sampled_frame_ms=s,
                           visual_candidates=[_c(10, 14, None, 0.5)],  # peak unknown
                           narrative_candidates=[], event_times_s=[], budget=6)
    assert any(8000 <= s[i] <= 16000 for i in out)   # candidate window still represented


# ---- IMG_9091 regression: misplaced peak must NOT collapse selection -----------------------------
def test_img9091_misplaced_peak_keeps_true_reveal_in_context():
    """IMG_9091: AU labeled the peak ~4s early (~12.5s) but the TRUE face-reveal is ~16.62s. The mapper
    must bracket the candidate window with bounded context so the true reveal frame is included even
    though the peak is wrong — never a single nearest-to-(wrong-peak) frame. We assert on the actual
    selected frame TIMESTAMPS, not candidate counts."""
    s = _sampled(n=24, dur_s=35.3)   # frame spacing ~1.535s; a frame lands ~16.9s (idx 11) near 16.62
    # AU candidate: interval 12..18 but peak MIS-estimated early at 12.5s.
    out = mp.select_frames(video_type=mp.HIGHLIGHTS, sampled_frame_ms=s,
                           visual_candidates=[_c(12, 18, peak=12.5, conf=0.86)],
                           narrative_candidates=[], event_times_s=[], budget=8)
    selected_ms = [s[i] for i in out]
    # The true reveal ~16.62s must be within ~1 frame-spacing of some SELECTED frame (it is bracketed
    # by the candidate's region-center context), proving we did not collapse onto the early mis-peak.
    true_reveal_ms = 16620
    assert any(abs(t - true_reveal_ms) <= 1600 for t in selected_ms), selected_ms
    # Anti-collapse: the true reveal is BRACKETED — at least one selected frame before it AND one after —
    # so a mislocated early peak cannot blind the planner to the real payoff (IMG_9091 principle).
    assert any(t < true_reveal_ms for t in selected_ms), selected_ms
    assert any(t > true_reveal_ms for t in selected_ms), selected_ms
    # And selection spans the candidate neighborhood (>=2 frames across [10.5s, 19.5s]), not one point.
    span = [t for t in selected_ms if 10500 <= t <= 19500]
    assert len(span) >= 2, selected_ms
