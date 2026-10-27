"""P1-F — deterministic editorial candidate->frame mapper.

Given the ACTUAL cached sampled-frame timestamps for one Moment + the AU editorial candidates, pick
WHICH of those frames a per-Video-Type contact sheet should contain. Pure + deterministic: no model
call, no network, no randomness. Same inputs -> same output.

This changes frame RELEVANCE, not frame COUNT: it returns a subset of the already-sampled frames
within the SAME per-Moment budget the contact-sheet builder uses today (P1-F §8). It never fabricates
a timestamp and never invents a frame that was not sampled.

TRUST MODEL (P1-F §7, and the IMG_9091 regression):
  * AU candidate intervals, roles, confidence and peak_time are ADVISORY. The model can receive the
    correct frame and still mis-estimate the peak (IMG_9091: the true face-reveal ~16.62s was present
    but the peak was labeled ~4s early). So:
      - never select ONLY the single nearest-to-peak frame;
      - always include BOUNDED temporal context around a candidate (before / at / after);
      - always keep whole-Moment OVERVIEW frames so a mislocated candidate cannot blind the planner;
      - treat sampled_frame_ms as provenance (which frames existed), not semantic proof.
  * The model-authored `evidence` 'frames@..ms' string is NEVER consulted here (it is untrusted and is
    already stripped upstream).
  * Candidates are ranked by DISTINCT editorial value + coverage, NOT by raw uncalibrated confidence.
    Confidence is at most a weak tiebreak, never the primary sort (P1-F §7/§8).

Video Type (P1-F §7):
  * HIGHLIGHTS  -> visual_candidates: setup-before / approx-payoff / aftermath, across DISTINCT
                   candidates, plus opening+closing context.
  * FULL STORY  -> narrative_candidates + observed events: opening, event progression, interactions,
                   action, environment, transitions, resolution — favor EVEN narrative coverage.
  * No / weak candidates -> uniform overview fallback (identical spirit to today's even subsample).
"""
from __future__ import annotations

from dataclasses import dataclass

# Bounded temporal context around a candidate, in seconds. Chosen so a mislocated peak (the IMG_9091
# class of error) is still bracketed: we pull the nearest sampled frame on EACH side of the candidate
# window expanded by this padding, not just the one nearest the peak. NOT a clipping bound.
CONTEXT_PAD_S = 1.5

HIGHLIGHTS = "highlights"
FULL_STORY = "full"


@dataclass(frozen=True)
class SampledFrame:
    index: int
    t_ms: int


@dataclass(frozen=True)
class Candidate:
    """A normalized editorial candidate (visual OR narrative). Times in SECONDS. peak may be None."""
    start: float
    end: float
    peak: float | None = None
    confidence: float | None = None


def _nearest_index(frames: list[SampledFrame], t_ms: int) -> int:
    """Index into `frames` of the sampled frame nearest `t_ms` (ties -> earlier). O(n), n<=24."""
    best = 0
    best_d = None
    for i, f in enumerate(frames):
        d = abs(f.t_ms - t_ms)
        if best_d is None or d < best_d:
            best = i
            best_d = d
    return best


def _overview_indices(n_frames: int, k: int) -> list[int]:
    """k evenly-spaced indices over [0, n_frames-1], inclusive of first and last. Deterministic —
    the whole-Moment coverage floor so a candidate error can never blind the planner."""
    if n_frames <= 0 or k <= 0:
        return []
    if k >= n_frames:
        return list(range(n_frames))
    if k == 1:
        return [0]
    out = []
    for i in range(k):
        out.append(round(i / (k - 1) * (n_frames - 1)))
    return sorted(set(out))


def _candidate_context_indices(frames: list[SampledFrame], c: Candidate) -> list[int]:
    """Bounded context for ONE candidate, returned in PRIORITY order (most representative first) so a
    round-robin that takes one pick per candidate lands a region-center frame first. The set is the
    nearest frames to the MIDPOINT, then (start-pad), then (end+pad), then — ADVISORY — the peak. This is
    deliberately 3-4 frames SPANNING the candidate, NOT a single nearest-to-peak frame (IMG_9091): the
    peak is just one of several and never the sole or first pick. De-duplicated, priority order preserved."""
    pad_ms = int(CONTEXT_PAD_S * 1000)
    mid = (c.start + c.end) / 2.0
    ordered_targets = [
        int(mid * 1000),                       # 1) region center — the representative frame
        int(c.start * 1000) - pad_ms,          # 2) bounded setup before
        int(c.end * 1000) + pad_ms,            # 3) bounded aftermath after
    ]
    if c.peak is not None:
        ordered_targets.append(int(c.peak * 1000))   # 4) advisory peak — extra breadth, never first/alone
    out: list[int] = []
    for t in ordered_targets:
        idx = _nearest_index(frames, t)
        if idx not in out:
            out.append(idx)
    return out


def _rank_candidates(cands: list[Candidate]) -> list[Candidate]:
    """Order candidates by DISTINCT editorial value, NOT by raw confidence. Primary: earlier start
    (narrative/temporal order is the stable, meaningful axis). Confidence is only a weak tiebreak when
    two candidates start at the same time. This keeps selection from collapsing onto one high-confidence
    window and ensures distinct candidates each get coverage (P1-F §7/§8)."""
    return sorted(cands, key=lambda c: (round(c.start, 3), -(c.confidence or 0.0)))


def select_frames(
    *,
    video_type: str,
    sampled_frame_ms: list[int],
    visual_candidates: list[Candidate],
    narrative_candidates: list[Candidate],
    event_times_s: list[float],
    budget: int,
) -> list[int]:
    """Return the chosen sampled-frame INDICES (ascending, de-duplicated, <= budget) for a Moment's
    contact sheet. Pure + deterministic. `budget` is the SAME per-Moment frame budget the contact-sheet
    builder uses today (typically 4-9); the result never exceeds it and is never empty when frames exist.

    Algorithm (identical skeleton for both types; the candidate SOURCE differs):
      1. Always reserve an OVERVIEW floor (>=2: first + last, plus a couple interior for longer budgets)
         so whole-Moment coverage survives any candidate error.
      2. Spend the remaining budget on bounded CONTEXT around ranked candidates (distinct-first), each
         contributing before/at/after(/peak) frames.
      3. If candidates are absent/weak, the overview floor expands to a uniform subsample (today's
         behavior) — an ordinary Moment stays fully usable.
    Clamped to budget by keeping overview first (coverage guarantee), then candidate context in rank
    order until full."""
    frames = [SampledFrame(index=i, t_ms=t) for i, t in enumerate(sampled_frame_ms)]
    n = len(frames)
    if n == 0 or budget <= 0:
        return []
    if budget >= n:
        return list(range(n))

    # 1) candidate source (resolve first so the overview floor can adapt when there are none).
    cands = visual_candidates if video_type == HIGHLIGHTS else narrative_candidates
    cands = list(cands)
    # FULL STORY also folds observed event times as lightweight point-candidates (progression coverage).
    if video_type == FULL_STORY and event_times_s:
        for t in event_times_s:
            cands.append(Candidate(start=t, end=t, peak=None, confidence=None))

    # 2) overview floor — whole-Moment coverage that survives ANY candidate error. With NO candidates we
    #    want a clean uniform FULL-budget subsample (today's behavior, evenly spaced); WITH candidates we
    #    reserve ~half the budget so candidate context has room.
    if not cands:
        overview_k = budget
    else:
        overview_k = max(2, min(budget // 2 + 1, budget))
    chosen: list[int] = list(_overview_indices(n, overview_k))

    # 3) candidate context, DISTINCT-FIRST round-robin: give EACH ranked candidate one context frame per
    #    pass before any candidate gets a second, so a high-confidence candidate cannot crowd out the
    #    others (P1-F §7: balance coverage across distinct candidates, not confidence-collapse). Each
    #    candidate's context list is priority-ordered (region-center first), so pass 1 lands a
    #    representative frame for every candidate, later passes add setup/aftermath/peak breadth.
    ranked = _rank_candidates(cands)
    ctx_lists = [_candidate_context_indices(frames, c) for c in ranked]
    cursors = [0] * len(ctx_lists)
    progressed = True
    while len(set(chosen)) < budget and progressed:
        progressed = False
        for ci, ctx in enumerate(ctx_lists):
            if len(set(chosen)) >= budget:
                break
            # advance this candidate's cursor to its next not-yet-chosen context frame
            while cursors[ci] < len(ctx) and ctx[cursors[ci]] in chosen:
                cursors[ci] += 1
            if cursors[ci] < len(ctx):
                chosen.append(ctx[cursors[ci]])
                cursors[ci] += 1
                progressed = True

    # 4) top-up: if candidates were present but did not fill the budget, expand to a uniform overview at
    #    the FULL budget so whole-Moment coverage is complete (never under-filled when frames exist).
    if len(set(chosen)) < budget:
        for idx in _overview_indices(n, budget):
            if idx not in chosen:
                chosen.append(idx)
            if len(set(chosen)) >= budget:
                break

    # 4) de-dup, clamp to budget preserving coverage (overview + distinct candidates added first), ascending.
    seen: set[int] = set()
    ordered: list[int] = []
    for idx in chosen:
        if idx not in seen:
            seen.add(idx)
            ordered.append(idx)
        if len(ordered) >= budget:
            break
    return sorted(ordered)
