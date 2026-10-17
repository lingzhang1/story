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


__all__ = ["apply_deterministic_revision"]
