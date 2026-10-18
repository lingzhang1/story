"""Deterministic revision fast path (Phase 5).

Apply hard, unambiguous structural directives DIRECTLY to the exact base EditPlan — no model call — then let the
existing deterministic validator confirm the result. Covers the safe operations the owner named: exclude a
Moment, change opening, change ending, reorder / enforce adjacency of existing segments. Preserves every
unaffected segment's source range, speed, transition, native-audio and the music exactly as the base had them;
only segment ORDER (and the removal of excluded segments) changes, and `order` is renumbered 0..N-1.

Returns a NEW plan dict on success, or None when the request cannot be satisfied by pure reordering/removal
(e.g. a must_include Moment that is not already in the base plan, or an unsatisfiable combination). A None
result tells the caller to fall back to the targeted single-call AI revision — this module NEVER guesses.
"""
from __future__ import annotations

from typing import Any


def _first_index(order: list[str], mid: str) -> int | None:
    for i, a in enumerate(order):
        if a == mid:
            return i
    return None


def apply_deterministic_revision(base_plan: dict, directives: dict) -> dict | None:
    """Pure transform. `base_plan` = the exact executable EditPlan/2 dict; `directives` = resolved stable ids
    {must_include, exclude, opening, ending, order_after, order_adjacent}. Returns a reordered/pruned copy or
    None if pure structural editing cannot satisfy the directives."""
    import copy
    if not isinstance(base_plan, dict):
        return None
    segs = sorted(base_plan.get("segments", []), key=lambda s: s.get("order", 0))
    if not segs:
        return None

    def _as_list(v):
        return v if isinstance(v, list) else ([v] if v else [])

    # Case-INSENSITIVE id matching. Base-plan segment asset_ids are lowercase (moments[] payload is
    # lowercased); directive ids historically arrived UPPERCASE, so a raw `in`/`==` silently failed to find
    # them -> the reorder/exclude no-op'd and the "revised" plan came back byte-identical to the base. Fold
    # every directive id to lowercase and match against lowercased segment asset_ids throughout.
    def _lc(v):
        return v.lower() if isinstance(v, str) else v

    def _aid(s):
        a = s.get("asset_id")
        return a.lower() if isinstance(a, str) else a

    exclude = set(_lc(x) for x in _as_list(directives.get("exclude")))
    must_inc = [_lc(x) for x in _as_list(directives.get("must_include"))]
    opening = _lc(directives.get("opening"))
    ending = _lc(directives.get("ending"))
    after_pairs = [(_lc(p[0]), _lc(p[1])) for p in (directives.get("order_after") or [])
                   if isinstance(p, (list, tuple)) and len(p) == 2]
    adj_pairs = [(_lc(p[0]), _lc(p[1])) for p in (directives.get("order_adjacent") or [])
                 if isinstance(p, (list, tuple)) and len(p) == 2]

    # 1. Drop excluded segments (by asset_id).
    kept = [copy.deepcopy(s) for s in segs if _aid(s) not in exclude]
    if not kept:
        return None
    present = {_aid(s) for s in kept}

    # 2. must_include that is NOT already present cannot be satisfied by reordering alone -> fall back to AI
    #    (the AI path can pull a NEW segment from that Moment; this deterministic path never invents segments).
    for mid in must_inc:
        if mid not in present:
            return None
    # opening/ending/order ids must already be present (else excluded or absent -> cannot satisfy here).
    for mid in [opening, ending] + [x for pair in (after_pairs + adj_pairs) for x in pair]:
        if mid and mid not in present:
            return None

    # 3. Build the target order over UNIQUE kept asset_ids (owner semantics: the FIRST occurrence drives
    #    position; a Moment used in multiple segments keeps its segments grouped in original relative order).
    order: list[str] = []
    for s in kept:
        aid = _aid(s)
        if aid not in order:
            order.append(aid)

    # Helper: move `mid` to a target index within the unique-id order, preserving everything else.
    def move_to(order: list[str], mid: str, target: int) -> list[str]:
        idx = _first_index(order, mid)
        if idx is None:
            return order
        item = order.pop(idx)
        target = max(0, min(target, len(order)))
        order.insert(target, item)
        return order

    # opening first, then ending, then adjacency, then after — later constraints respect earlier ones.
    if opening:
        order = move_to(order, opening, 0)
    if ending:
        order = move_to(order, ending, len(order) - 1)
    for a, b in adj_pairs:
        ib = _first_index(order, b)
        if ib is None:
            return None
        order = move_to(order, a, ib + 1)
    for a, b in after_pairs:
        ia, ib = _first_index(order, a), _first_index(order, b)
        if ia is None or ib is None:
            return None
        if ia <= ib:
            order = move_to(order, a, ib + 1)

    # 4. Reassemble: for each asset_id in the unique order, emit ALL its kept segments (grouped, original order).
    from collections import defaultdict, deque
    buckets: dict[str, deque] = defaultdict(deque)
    for s in kept:
        buckets[_aid(s)].append(s)   # key by lowercased asset_id to match the normalized `order` space
    new_segs: list[dict] = []
    for aid in order:
        q = buckets.get(aid)
        while q:
            new_segs.append(q.popleft())

    # 5. Renumber order 0..N-1; keep every other field byte-identical.
    for i, s in enumerate(new_segs):
        s["order"] = i

    out = copy.deepcopy(base_plan)
    out["segments"] = new_segs
    return out


# Renderer speed envelope — mirror of the validator's RENDERER_SPEED_MIN/MAX. A re-time must never produce a
# segment outside it (the deterministic validator would reject the plan).
_SPEED_MIN, _SPEED_MAX = 0.5, 2.0


def apply_deterministic_retime(base_plan: dict, target_clip_seconds: float,
                               min_total_seconds: float | None = None) -> dict | None:
    """Phase 3 timing-only fast path. Re-time EVERY segment of the exact base plan toward `target_clip_seconds`
    WITHOUT a model call and WITHOUT changing which clips are used, their order, their source ranges, the
    soundtrack, native-audio policy or transitions — the owner's preservation contract for a pure pacing
    revise ("shorten each clip to ~5s"). Only `output_duration_seconds` (and the derived `speed`) change.

    For each segment: keep the source span [start,end]; set output_duration = clamp(target, so that
    speed = span/output_duration stays within [0.5, 2.0]). `min_total_seconds` (when given) is the target
    duration's LOWER tolerance bound — shortening every clip to the literal per-clip target can drive the WHOLE
    video under that bound, which the deterministic validator rejects; so if the naive re-time undershoots, we
    lengthen clips back up PROPORTIONALLY (still preserving identities/order/ranges) just enough to clear the
    bound. A clip whose span cannot reach a duration within the speed envelope gets the closest legal value.
    Returns a new plan dict, or None when the base plan is unusable. The caller MUST run the validator."""
    import copy
    if not isinstance(base_plan, dict) or not base_plan.get("segments"):
        return None
    if not (isinstance(target_clip_seconds, (int, float)) and target_clip_seconds > 0):
        return None
    out = copy.deepcopy(base_plan)
    # Per-segment legal output window [min_out, max_out] from the speed envelope; and the naive target-clamped
    # value. Segments with no usable span keep their base duration and don't move.
    windows = []  # (seg, span_or_None, min_out, max_out)
    for s in out.get("segments", []):
        a = s.get("source_start_seconds"); b = s.get("source_end_seconds")
        if not isinstance(a, (int, float)) or not isinstance(b, (int, float)) or b <= a:
            windows.append((s, None, None, None)); continue
        span = float(b) - float(a)
        windows.append((s, span, span / _SPEED_MAX, span / _SPEED_MIN))

    def _assign(target_per_clip: float):
        for s, span, lo, hi in windows:
            if span is None:
                continue
            new_out = max(lo, min(float(target_per_clip), hi))
            s["output_duration_seconds"] = round(new_out, 3)
            s["speed"] = round(span / new_out, 4)

    _assign(target_clip_seconds)
    # If honoring the literal per-clip target undershoots the target-duration lower bound, raise the per-clip
    # target uniformly until the total clears it (bounded search), keeping all clips and the envelope.
    if min_total_seconds and min_total_seconds > 0:
        def _total():
            return sum((s.get("output_duration_seconds") or 0.0) for s in out["segments"])
        if _total() < min_total_seconds:
            # Max achievable total = sum of each clip's max_out. If even that can't reach the bound, give the
            # longest legal duration to every clip (best effort) and let the validator decide.
            lift = target_clip_seconds
            for _ in range(24):  # bounded: widen the per-clip target toward each clip's max
                lift *= 1.25
                _assign(lift)
                if _total() >= min_total_seconds:
                    break
    return out


__all__ = ["apply_deterministic_revision", "apply_deterministic_retime"]
