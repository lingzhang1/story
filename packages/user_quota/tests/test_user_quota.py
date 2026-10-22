"""P0 Beta Security Phase 4 — user-quota reserve/settle/release/slot tests (owner correction 9/12).

In-memory fake DynamoDB models the single-item conditional-update AND TransactWriteItems semantics the quota
module relies on, so idempotency / atomicity / boundary / crash-recovery behavior is exercised with no network.
Covers: concurrent users, per-user + GLOBAL budget boundaries, transaction-failure recovery, worker-crash
double-release, partial settlements, orphan (reserved-but-no-settle) recovery, observe-vs-enforce.
"""

from __future__ import annotations

import os
import threading

import pytest

from user_quota import (UserQuota, QuotaConfig, QuotaDenied, QuotaStoreError, reservation_id,
                        GLOBAL_PK, _period)
from user_quota.fakes import FakeDDB  # shared in-memory DynamoDB double


def _cfg(**kw):
    base = dict(user_monthly_usd=1.0, user_daily_gens=3, max_active_jobs=2, global_monthly_usd=60.0)
    base.update(kw)
    return QuotaConfig(**base)


def _q(cfg=None, *, support_transact=True):
    return UserQuota(ddb=FakeDDB(support_transact=support_transact), usage_table="t", cfg=cfg or _cfg())


@pytest.fixture(autouse=True)
def _env():
    saved = {k: os.environ.get(k) for k in ["STORY_QUOTA_MODE"]}
    yield
    for k, v in saved.items():
        os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)


def _P():
    return _period()


# correction 1: idempotent + atomic reservation under concurrent retries ----------------------------------

def test_duplicate_reservation_is_idempotent_no_double_count():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=5))
    r1 = q.reserve("u1", "op-123", estimate_usd=0.10, gens=1)
    r2 = q.reserve("u1", "op-123", estimate_usd=0.10, gens=1)  # retry, same op
    assert r1.reservation_id == r2.reservation_id == reservation_id("op-123")
    it = q._ddb.items[("u1", _P())]
    assert float(it["reserved_usd"]["N"]) == 0.10   # counted ONCE
    assert float(it["gens_used"]["N"]) == 1


def test_concurrent_same_op_reserves_once():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=5))
    def go(): q.reserve("u1", "op-x", estimate_usd=0.10)
    ts = [threading.Thread(target=go) for _ in range(10)]
    for t in ts: t.start()
    for t in ts: t.join()
    it = q._ddb.items[("u1", _P())]
    assert float(it["reserved_usd"]["N"]) == 0.10   # exactly one reservation applied


def test_concurrent_distinct_users_isolated():
    """correction 12: concurrent users — each user's ledger is independent (keyed by story_user_id)."""
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=5, user_daily_gens=99))
    def go(u):
        for i in range(5):
            q.reserve(u, f"{u}-op{i}", estimate_usd=0.10)
    ts = [threading.Thread(target=go, args=(f"user{n}",)) for n in range(6)]
    for t in ts: t.start()
    for t in ts: t.join()
    for n in range(6):
        it = q._ddb.items[(f"user{n}", _P())]
        assert round(float(it["reserved_usd"]["N"]), 2) == 0.50   # 5 * 0.10, no cross-user bleed
        assert float(it["gens_used"]["N"]) == 5


# per-user enforce boundary: monthly USD + daily gens -----------------------------------------------------

def test_enforce_denies_over_monthly_usd():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=0.15, user_daily_gens=99))
    q.reserve("u1", "op-1", estimate_usd=0.10)
    with pytest.raises(QuotaDenied):
        q.reserve("u1", "op-2", estimate_usd=0.10)   # 0.20 > 0.15


def test_enforce_denies_over_daily_gens():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=99, user_daily_gens=2))
    q.reserve("u1", "op-1", estimate_usd=0.01)
    q.reserve("u1", "op-2", estimate_usd=0.01)
    with pytest.raises(QuotaDenied):
        q.reserve("u1", "op-3", estimate_usd=0.01)


# correction 5: GLOBAL budget boundary (circuit breaker) --------------------------------------------------

def test_global_breaker_denies_at_cap_across_users():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=99, user_daily_gens=99, global_monthly_usd=0.25))
    q.reserve("ua", "a1", estimate_usd=0.10)   # global 0.10
    q.reserve("ub", "b1", estimate_usd=0.10)   # global 0.20
    with pytest.raises(QuotaDenied) as ei:
        q.reserve("uc", "c1", estimate_usd=0.10)   # 0.30 > 0.25 global
    assert ei.value.scope == "global_monthly_usd"
    g = q._ddb.items[(GLOBAL_PK, _P())]
    assert round(float(g["reserved_usd"]["N"]), 2) == 0.20   # denied reserve NOT applied


def test_transaction_atomic_user_and_global_both_move():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=5, global_monthly_usd=60))
    q.reserve("u1", "op-1", estimate_usd=0.10)
    assert round(float(q._ddb.items[("u1", _P())]["reserved_usd"]["N"]), 2) == 0.10
    assert round(float(q._ddb.items[(GLOBAL_PK, _P())]["reserved_usd"]["N"]), 2) == 0.10  # same transaction


def test_transaction_failure_recovers_idempotently():
    """correction 12 (transaction failure): a TransactionCanceled on a duplicate op recovers the existing
    reservation rather than erroring or double-counting."""
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=5, global_monthly_usd=60))
    q.reserve("u1", "op-1", estimate_usd=0.10)
    r2 = q.reserve("u1", "op-1", estimate_usd=0.10)   # transact cancels on marker-exists -> recover
    assert r2.reservation_id == reservation_id("op-1")
    assert round(float(q._ddb.items[("u1", _P())]["reserved_usd"]["N"]), 2) == 0.10


# correction 9: observe mode never denies ----------------------------------------------------------------

def test_observe_never_denies_user_or_global_or_slot():
    os.environ["STORY_QUOTA_MODE"] = "observe"
    q = _q(_cfg(user_monthly_usd=0.05, user_daily_gens=1, max_active_jobs=1, global_monthly_usd=0.05))
    q.reserve("u1", "op-1", estimate_usd=0.10)
    q.reserve("u1", "op-2", estimate_usd=0.10)  # would exceed user+global, but observe -> allowed
    assert q.reserve_slot("u1", "j1") is True
    assert q.reserve_slot("u1", "j2") is True   # would exceed max_active_jobs=1, observe -> allowed


# correction 3/8: settle actual (may exceed estimate); idempotent; reserved actually drains ---------------

def test_settle_records_actual_drains_reserved_and_is_idempotent():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=99, user_daily_gens=99))
    q.reserve("u1", "op-1", estimate_usd=0.10)
    q.settle("u1", "op-1", actual_usd=0.25)   # actual EXCEEDS estimate -> financial truth wins
    it = q._ddb.items[("u1", _P())]
    assert float(it["settled_usd"]["N"]) == 0.25
    assert round(float(it["reserved_usd"]["N"]), 2) == 0.0    # reserved estimate DRAINED (not the -0.0 bug)
    q.settle("u1", "op-1", actual_usd=0.25)   # double settle -> no-op
    assert float(it["settled_usd"]["N"]) == 0.25
    # global settled symmetrically
    g = q._ddb.items[(GLOBAL_PK, _P())]
    assert float(g["settled_usd"]["N"]) == 0.25
    assert round(float(g["reserved_usd"]["N"]), 2) == 0.0


def test_partial_settlement_multiple_reservations():
    """correction 12 (partial settlements): settling one reservation leaves others reserved."""
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=99, user_daily_gens=99))
    q.reserve("u1", "op-1", estimate_usd=0.10)
    q.reserve("u1", "op-2", estimate_usd=0.20)
    q.settle("u1", "op-1", actual_usd=0.12)
    it = q._ddb.items[("u1", _P())]
    assert float(it["settled_usd"]["N"]) == 0.12
    assert round(float(it["reserved_usd"]["N"]), 2) == 0.20   # op-2 still reserved, op-1 drained


# correction 3/4: failed inference refunds allowance but KEEPS incurred spend ----------------------------

def test_failed_inference_refunds_allowance_but_keeps_spend():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=99, user_daily_gens=99))
    q.reserve("u1", "op-1", estimate_usd=0.10, gens=1)
    q.release_allowance("u1", "op-1", gens=1, incurred_usd=0.03)  # failed after spending 0.03
    it = q._ddb.items[("u1", _P())]
    assert float(it["gens_used"]["N"]) == 0            # allowance refunded
    assert float(it["settled_usd"]["N"]) == 0.03       # spend NOT erased
    assert round(float(it["reserved_usd"]["N"]), 2) == 0.0   # reserved estimate removed
    q.release_allowance("u1", "op-1", gens=1, incurred_usd=0.03)   # idempotent
    assert float(it["gens_used"]["N"]) == 0
    assert float(it["settled_usd"]["N"]) == 0.03


def test_double_settle_then_release_no_double_move():
    """correction 6/12: no double settlement AND no double release — once terminal, further calls no-op."""
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=99, user_daily_gens=99))
    q.reserve("u1", "op-1", estimate_usd=0.10)
    q.settle("u1", "op-1", actual_usd=0.08)
    q.release_allowance("u1", "op-1", gens=1, incurred_usd=0.05)   # already settled -> no-op
    it = q._ddb.items[("u1", _P())]
    assert float(it["settled_usd"]["N"]) == 0.08   # release did NOT also add 0.05
    assert float(it["gens_used"]["N"]) == 1        # allowance NOT refunded (it was a real settle)


# correction 6: active-job slots (queued+running) exactly-once under dup/retry/crash ---------------------

def test_slot_reserve_release_exactly_once():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(max_active_jobs=5))
    assert q.reserve_slot("u1", "job-1") is True
    assert q.reserve_slot("u1", "job-1") is True   # duplicate submit / redelivery -> still 1
    it = q._ddb.items[("u1", _P())]
    assert float(it["active_jobs"]["N"]) == 1
    q.release_slot("u1", "job-1")
    q.release_slot("u1", "job-1")   # worker crash + redelivery double-release -> still 0, never negative
    assert float(it["active_jobs"]["N"]) == 0


def test_slot_cap_enforced_and_concurrent():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(max_active_jobs=2))
    assert q.reserve_slot("u1", "j1") is True
    assert q.reserve_slot("u1", "j2") is True
    with pytest.raises(QuotaDenied) as ei:
        q.reserve_slot("u1", "j3")   # queued+running cap = 2
    assert ei.value.scope == "active_jobs"
    q.release_slot("u1", "j1")       # terminal frees a slot
    assert q.reserve_slot("u1", "j3") is True   # now fits


def test_slots_concurrent_distinct_jobs_cap_respected():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(max_active_jobs=3))
    granted = []
    lock = threading.Lock()
    def go(j):
        try:
            if q.reserve_slot("u1", j):
                with lock: granted.append(j)
        except QuotaDenied:
            pass
    ts = [threading.Thread(target=go, args=(f"j{n}",)) for n in range(10)]
    for t in ts: t.start()
    for t in ts: t.join()
    assert len(granted) == 3   # never over the cap under concurrency
    assert float(q._ddb.items[("u1", _P())]["active_jobs"]["N"]) == 3


# correction 12: orphan recovery — a reserved-but-never-settled reservation is releasable ---------------

def test_orphan_reservation_releasable_after_crash():
    """A crashed flow leaves a reservation `reserved` with no settle. The recovery path (release_allowance)
    reverses it exactly once; a later settle attempt is a no-op (terminal)."""
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=99, user_daily_gens=99))
    q.reserve("u1", "op-orphan", estimate_usd=0.10, gens=1)
    # worker crashed before settle -> reconcile sweep releases the orphan (no incurred spend recorded)
    q.release_allowance("u1", "op-orphan", gens=1, incurred_usd=0.0)
    it = q._ddb.items[("u1", _P())]
    assert round(float(it["reserved_usd"]["N"]), 2) == 0.0
    assert float(it["gens_used"]["N"]) == 0
    q.settle("u1", "op-orphan", actual_usd=0.10)   # stale settle after release -> no-op
    assert float(it["settled_usd"]["N"]) == 0.0


# store-failure -> QuotaStoreError (caller maps to fail-closed 503 for expensive ops) --------------------

def test_store_error_surfaces_as_quota_store_error():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    class Boom:
        def get_item(self, **k): raise RuntimeError("ddb down")
        def transact_write_items(self, **k): raise RuntimeError("ddb down")
        def update_item(self, **k): raise RuntimeError("ddb down")
    q = UserQuota(ddb=Boom(), usage_table="t", cfg=_cfg())
    with pytest.raises(QuotaStoreError):
        q.reserve("u1", "op-1", estimate_usd=0.10)


# fallback path (no TransactWriteItems support) still reserves per-user + best-effort global -------------

def test_fallback_without_transact_still_reserves_user_and_global():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=5, global_monthly_usd=60), support_transact=False)
    q.reserve("u1", "op-1", estimate_usd=0.10)
    assert round(float(q._ddb.items[("u1", _P())]["reserved_usd"]["N"]), 2) == 0.10
    assert round(float(q._ddb.items[(GLOBAL_PK, _P())]["reserved_usd"]["N"]), 2) == 0.10
