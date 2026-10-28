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
                        GLOBAL_PK, _period, _day)
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


def _G():
    return _day()  # daily gens bucket attribute name: gens#YYYY-MM-DD


# correction 1: idempotent + atomic reservation under concurrent retries ----------------------------------

def test_duplicate_reservation_is_idempotent_no_double_count():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=5))
    r1 = q.reserve("u1", "op-123", estimate_usd=0.10, gens=1)
    r2 = q.reserve("u1", "op-123", estimate_usd=0.10, gens=1)  # retry, same op
    assert r1.reservation_id == r2.reservation_id == reservation_id("op-123")
    it = q._ddb.items[("u1", _P())]
    assert float(it["reserved_usd"]["N"]) == 0.10   # counted ONCE
    assert float(it[_G()]["N"]) == 1


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
        assert float(it[_G()]["N"]) == 5


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
    assert float(it[_G()]["N"]) == 0            # allowance refunded
    assert float(it["settled_usd"]["N"]) == 0.03       # spend NOT erased
    assert round(float(it["reserved_usd"]["N"]), 2) == 0.0   # reserved estimate removed
    q.release_allowance("u1", "op-1", gens=1, incurred_usd=0.03)   # idempotent
    assert float(it[_G()]["N"]) == 0
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
    assert float(it[_G()]["N"]) == 1        # allowance NOT refunded (it was a real settle)


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
    assert float(it[_G()]["N"]) == 0
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


# owner-approved external-beta thresholds (2026-10-22): $8/mo, 20 gens/day, 2 active jobs, $60 global -------

def _beta_cfg():
    # The EXACT proposed external-beta enforce config, so this test fails if a future change drifts from it.
    return QuotaConfig(user_monthly_usd=8.0, user_daily_gens=20, max_active_jobs=2, global_monthly_usd=60.0)


def test_beta_thresholds_daily_gens_boundary_20():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_beta_cfg())
    for i in range(20):
        q.reserve("u1", f"op-{i}", estimate_usd=0.01)   # 20 allowed
    with pytest.raises(QuotaDenied) as ei:
        q.reserve("u1", "op-21", estimate_usd=0.01)      # 21st denied
    assert ei.value.scope == "user_daily_gens"


def test_beta_thresholds_active_jobs_boundary_2():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_beta_cfg())
    assert q.reserve_slot("u1", "j1") is True
    assert q.reserve_slot("u1", "j2") is True
    with pytest.raises(QuotaDenied) as ei:
        q.reserve_slot("u1", "j3")                        # queued+running cap = 2
    assert ei.value.scope == "active_jobs"
    q.release_slot("u1", "j1")                            # a terminal frees a slot
    assert q.reserve_slot("u1", "j3") is True


def test_beta_thresholds_monthly_usd_boundary_8():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_beta_cfg())
    q.reserve("u1", "big", estimate_usd=7.95, gens=1)     # near the $8 cap
    with pytest.raises(QuotaDenied):
        q.reserve("u1", "over", estimate_usd=0.10, gens=1)  # 8.05 > 8.00


def test_beta_global_60_trips_before_budget_100():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_beta_cfg())
    # drive the global aggregate to the $60 breaker across users; it must trip BELOW the $100 AWS budget alert
    for i in range(6):
        q.reserve(f"u{i}", f"g-{i}", estimate_usd=7.0)    # 6 * 7 = 42 (each user under $8? no: 7<8 ok, 1/user)
    # one more 7.0 would be 49 global — still under 60; push to the boundary
    total = 42.0
    i = 100
    while total + 7.0 <= 60.0:
        q.reserve(f"ux{i}", f"gx-{i}", estimate_usd=7.0); total += 7.0; i += 1
    # now total is the largest multiple of 7 <= 60 (56); the next must be denied at the global cap
    with pytest.raises(QuotaDenied) as ei:
        q.reserve("ulast", "glast", estimate_usd=7.0)     # 56 + 7 = 63 > 60
    assert ei.value.scope == "global_monthly_usd"


# daily-vs-monthly: the gens allowance resets per UTC DAY (bucket gens#YYYY-MM-DD), USD stays monthly ------
def test_daily_gens_resets_each_utc_day(monkeypatch):
    """user_daily_gens is a DAILY cap: gens accumulate in a per-day attribute so a new day starts fresh,
    while reserved/settled USD stays in the monthly item. Verifies the daily-vs-monthly semantic fix."""
    import user_quota as uq
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(user_monthly_usd=99, user_daily_gens=2))
    # Day 1: two gens allowed, third denied (daily cap = 2)
    t1 = 1_700_000_000.0  # fixed day
    monkeypatch.setattr(uq.time, "time", lambda: t1)
    q.reserve("u1", "d1-a", estimate_usd=0.01, gens=1)
    q.reserve("u1", "d1-b", estimate_usd=0.01, gens=1)
    with pytest.raises(QuotaDenied) as e:
        q.reserve("u1", "d1-c", estimate_usd=0.01, gens=1)
    assert e.value.scope == "user_daily_gens"
    # Next UTC day (+86400s): same month, fresh daily bucket -> allowed again
    t2 = t1 + 86_400.0
    monkeypatch.setattr(uq.time, "time", lambda: t2)
    r = q.reserve("u1", "d2-a", estimate_usd=0.01, gens=1)
    assert r.state == "reserved"
    it = q._ddb.items[("u1", uq._period(t1))]
    assert float(it[uq._day(t1)]["N"]) == 2   # day 1 bucket unchanged
    assert float(it[uq._day(t2)]["N"]) == 1   # day 2 fresh bucket


# =========================================================================================================
# P0 CONCURRENCY RACE (fix/prebeta-concurrency-readiness §3). The old reserve_slot read `active_jobs`, checked
# the cap in Python, then wrote with ONLY an idempotency guard (attribute_not_exists(#sm)). Two concurrent
# submits with DIFFERENT job_ids both read the same count and both wrote distinct markers -> over-admission.
#
# The pre-existing `test_slots_concurrent_distinct_jobs_cap_respected` did NOT catch this: FakeDDB.update_item
# holds a lock across the WHOLE read-check-write, collapsing it into one atomic step the real store does not
# provide (real DynamoDB does the Python get_item OUTSIDE the conditional UpdateItem). The test below models
# the REAL semantics with a barrier so BOTH reservers complete their get_item BEFORE either conditional write,
# exactly the production interleave. It passes ONLY because the cap now lives in the ConditionExpression
# (`#aj < :max`), not in the Python pre-check. Reverting reserve_slot to the idempotency-only guard fails it.
# =========================================================================================================

def test_reserve_slot_emits_atomic_cap_condition_in_enforce():
    """STRUCTURAL guard: in enforce mode the slot reserve MUST carry the cap INSIDE the ConditionExpression
    (`#aj < :max`), not only in the Python pre-check. This is the single line that makes the write atomic;
    a regression that drops it back to an idempotency-only guard (`attribute_not_exists(#sm)` alone) is
    caught here regardless of whether an in-process fake can reproduce the distributed interleave."""
    os.environ["STORY_QUOTA_MODE"] = "enforce"

    class CapturingDDB(FakeDDB):
        def __init__(self): super().__init__(); self.conds = []
        def update_item(self, **kw):
            self.conds.append(kw.get("ConditionExpression"))
            return super().update_item(**kw)

    ddb = CapturingDDB()
    q = UserQuota(ddb=ddb, usage_table="t", cfg=_cfg(max_active_jobs=2))
    q.reserve_slot("u1", "j1")
    assert ddb.conds, "no conditional write emitted"
    cond = ddb.conds[-1]
    assert "#aj < :max" in cond, f"cap is NOT in the condition (race!): {cond!r}"
    assert "attribute_not_exists(#sm)" in cond, "idempotency guard lost"

    # OBSERVE mode must NOT carry the cap condition (it never denies).
    os.environ["STORY_QUOTA_MODE"] = "observe"
    ddb2 = CapturingDDB()
    q2 = UserQuota(ddb=ddb2, usage_table="t", cfg=_cfg(max_active_jobs=1))
    q2.reserve_slot("u1", "a"); q2.reserve_slot("u1", "b")   # both admitted in observe
    assert all("#aj < :max" not in (c or "") for c in ddb2.conds), "observe must not enforce the cap"
    assert float(ddb2.items[("u1", _P())]["active_jobs"]["N"]) == 2


def test_slot_race_interleaved_reads_cannot_over_admit():
    """FAITHFUL interleave model of real DynamoDB: both reservers run their Python `get_item` + cap pre-check
    against a STALE snapshot (active_jobs=1) BEFORE either conditional write commits, then the writes commit
    one after another. Real DynamoDB evaluates each ConditionExpression against the LATEST committed item, not
    the caller's stale read — so the second write sees active_jobs already at the cap and is rejected.

    The `DeferredWriteDDB` reproduces exactly that: `get_item` returns the pre-write snapshot for BOTH racers
    (so both pass the Python pre-check on the stale count), while `update_item` evaluates the condition and
    mutates against the live item under a lock (so the committed state advances between the two writes). With
    the atomic guard the second reserve is denied; WITHOUT it (idempotency-only) both commit and active_jobs
    reaches 3 — i.e. this test FAILS against the pre-fix code, which is what makes it a real regression guard."""
    os.environ["STORY_QUOTA_MODE"] = "enforce"

    class DeferredWriteDDB(FakeDDB):
        """Forces the stale-read interleave: the first get_item per racer returns a FROZEN snapshot taken
        before any racer wrote, so both racers' Python pre-checks see active_jobs=1. Writes still evaluate
        the condition against the LIVE item (real DynamoDB semantics), so the cap condition is the only thing
        that can stop over-admission."""
        def __init__(self):
            super().__init__()
            self._frozen = None
            self._freeze_for = set()
        def arm(self, racers):
            # Snapshot the current state; every racer's first user-item read returns this frozen view.
            import copy as _copy
            self._frozen = _copy.deepcopy(self.items.get(("u1", _P())))
            self._freeze_for = set(racers)
        def get_item(self, TableName, Key):
            if (self._frozen is not None and Key["story_user_id"]["S"] == "u1"):
                import copy as _copy
                return {"Item": _copy.deepcopy(self._frozen)}
            return super().get_item(TableName=TableName, Key=Key)

    ddb = DeferredWriteDDB()
    q = UserQuota(ddb=ddb, usage_table="t", cfg=_cfg(max_active_jobs=2))
    q.reserve_slot("u1", "seed")    # active_jobs -> 1 (not frozen yet)
    ddb.arm(racers={"raceA", "raceB"})   # from here, every u1 read returns the active_jobs=1 snapshot

    results = {}
    for j in ("raceA", "raceB"):
        try:
            q.reserve_slot("u1", j)
            results[j] = "granted"
        except QuotaDenied:
            results[j] = "denied"

    final = float(ddb.items[("u1", _P())]["active_jobs"]["N"])
    assert final == 2, f"over-admitted past cap: active_jobs={final} (expected 2)"
    assert sorted(results.values()) == ["denied", "granted"], results


def test_slot_failed_submit_after_reservation_releases(monkeypatch):
    """§3: a submit that reserves a slot then fails downstream (enqueue error) must not leak the slot. The
    worker_release / release_slot path reverses it; here we assert release after a held reserve frees it."""
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(max_active_jobs=1))
    assert q.reserve_slot("u1", "j1") is True
    # downstream failure -> release (worker_release on FAILED, or the submit path on an enqueue error)
    q.release_slot("u1", "j1")
    assert float(q._ddb.items[("u1", _P())]["active_jobs"]["N"]) == 0
    assert q.reserve_slot("u1", "j2") is True   # the freed slot is reusable (no permanent block)


def test_slot_redelivery_then_terminal_never_negative():
    """§3 worker retry/redelivery + concurrent release: a slot decrements at most once even under a double
    terminal transition racing a redelivered reserve. Final count is non-negative and correct."""
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(_cfg(max_active_jobs=2))
    q.reserve_slot("u1", "j1")
    q.reserve_slot("u1", "j1")   # SQS redelivery of the same job -> still 1 (idempotent)
    assert float(q._ddb.items[("u1", _P())]["active_jobs"]["N"]) == 1
    # concurrent terminal transitions (completion racing a cancel) both call release_slot
    def rel(): q.release_slot("u1", "j1")
    ts = [threading.Thread(target=rel) for _ in range(4)]
    for t in ts: t.start()
    for t in ts: t.join()
    assert float(q._ddb.items[("u1", _P())]["active_jobs"]["N"]) == 0   # exactly once, never negative
