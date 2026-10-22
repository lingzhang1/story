"""P0 Beta Security Phase 4 — user-quota reserve/settle/release tests (owner correction 12).

In-memory fake DynamoDB (single-item conditional-update semantics) models the atomic UpdateItem the real
limiter relies on, so idempotency/atomicity/boundary behavior is exercised without network.
"""

from __future__ import annotations

import os
import threading

import pytest

from user_quota import UserQuota, QuotaConfig, QuotaDenied, reservation_id


class FakeDDB:
    """Minimal DynamoDB double supporting get_item + a conditional update_item on ONE item keyed
    (story_user_id, quota_period). Numbers via ADD, strings via SET, with ConditionExpression honored for
    the specific expressions this module uses (attribute_not_exists(#r), state guards, budget sums)."""
    def __init__(self):
        self.items: dict[tuple, dict] = {}
        self.lock = threading.Lock()

    def _key(self, Key):
        return (Key["story_user_id"]["S"], Key["quota_period"]["S"])

    def get_item(self, TableName, Key):
        with self.lock:
            it = self.items.get(self._key(Key))
            return {"Item": dict(it)} if it else {}

    def update_item(self, TableName, Key, UpdateExpression, ConditionExpression=None,
                    ExpressionAttributeNames=None, ExpressionAttributeValues=None):
        names = ExpressionAttributeNames or {}
        vals = ExpressionAttributeValues or {}
        with self.lock:
            k = self._key(Key)
            it = self.items.setdefault(k, {})
            def num(attr):
                return float(it.get(attr, {}).get("N", "0"))
            # Evaluate the condition (only the shapes this module emits).
            if ConditionExpression:
                cond = ConditionExpression
                res_name = names.get("#r", "")
                if "attribute_not_exists(#r)" in cond and res_name in it:
                    raise Exception("ConditionalCheckFailedException")
                if "#r = :reserved" in cond and it.get(res_name, {}).get("S") != "reserved":
                    raise Exception("ConditionalCheckFailedException")
                if "<= :umax" in cond:
                    est = float(vals[":eu"]["N"]); umax = float(vals[":umax"]["N"])
                    if num("reserved_usd") + num("settled_usd") + est > umax:
                        raise Exception("ConditionalCheckFailedException")
                    g = int(float(vals[":g"]["N"])); gmax = float(vals[":gmax"]["N"])
                    if num("gens_used") + g > gmax:
                        raise Exception("ConditionalCheckFailedException")
            # Apply ADD (numbers) then SET (the res state string).
            if "ADD" in UpdateExpression:
                if "#ru :eu" in UpdateExpression:
                    it["reserved_usd"] = {"N": str(num("reserved_usd") + float(vals[":eu"]["N"]))}
                if "#g :g" in UpdateExpression:
                    it["gens_used"] = {"N": str(num("gens_used") + float(vals[":g"]["N"]))}
                if "#su :au" in UpdateExpression:
                    it["settled_usd"] = {"N": str(num("settled_usd") + float(vals[":au"]["N"]))}
                if "#g :neg" in UpdateExpression:
                    it["gens_used"] = {"N": str(num("gens_used") + float(vals[":neg"]["N"]))}
                if "#su :inc" in UpdateExpression:
                    it["settled_usd"] = {"N": str(num("settled_usd") + float(vals[":inc"]["N"]))}
            if "SET #r = :rid" in UpdateExpression:
                it[names["#r"]] = {"S": "reserved"}
            if "SET #r = :settled" in UpdateExpression:
                it[names["#r"]] = {"S": "settled"}
            if "SET #r = :released" in UpdateExpression:
                it[names["#r"]] = {"S": "released"}


def _q(cfg=None):
    return UserQuota(ddb=FakeDDB(), usage_table="t",
                     cfg=cfg or QuotaConfig(user_monthly_usd=1.0, user_daily_gens=3,
                                            max_active_jobs=5, global_monthly_usd=60.0))


@pytest.fixture(autouse=True)
def _env():
    saved = {k: os.environ.get(k) for k in ["STORY_QUOTA_MODE"]}
    yield
    for k, v in saved.items():
        os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)


# correction 1: idempotent + atomic reservation under concurrent retries ----------------------------------

def test_duplicate_reservation_is_idempotent_no_double_count():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q()
    r1 = q.reserve("u1", "op-123", estimate_usd=0.10, gens=1)
    r2 = q.reserve("u1", "op-123", estimate_usd=0.10, gens=1)  # retry, same op
    assert r1.reservation_id == r2.reservation_id == reservation_id("op-123")
    it = q._ddb.items[("u1", _period_now())]
    assert float(it["reserved_usd"]["N"]) == 0.10   # counted ONCE
    assert float(it["gens_used"]["N"]) == 1


def test_concurrent_same_op_reserves_once():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q()
    outs = []
    def go(): outs.append(q.reserve("u1", "op-x", estimate_usd=0.10))
    ts = [threading.Thread(target=go) for _ in range(10)]
    for t in ts: t.start()
    for t in ts: t.join()
    it = q._ddb.items[("u1", _period_now())]
    assert float(it["reserved_usd"]["N"]) == 0.10   # exactly one reservation applied


# enforce boundary: monthly USD + daily gens -------------------------------------------------------------

def test_enforce_denies_over_monthly_usd():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(QuotaConfig(user_monthly_usd=0.15, user_daily_gens=99, max_active_jobs=5, global_monthly_usd=60))
    q.reserve("u1", "op-1", estimate_usd=0.10)
    with pytest.raises(QuotaDenied):
        q.reserve("u1", "op-2", estimate_usd=0.10)   # 0.20 > 0.15


def test_enforce_denies_over_daily_gens():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(QuotaConfig(user_monthly_usd=99, user_daily_gens=2, max_active_jobs=5, global_monthly_usd=60))
    q.reserve("u1", "op-1", estimate_usd=0.01)
    q.reserve("u1", "op-2", estimate_usd=0.01)
    with pytest.raises(QuotaDenied):
        q.reserve("u1", "op-3", estimate_usd=0.01)


# correction 9: observe mode never denies ----------------------------------------------------------------

def test_observe_never_denies():
    os.environ["STORY_QUOTA_MODE"] = "observe"
    q = _q(QuotaConfig(user_monthly_usd=0.05, user_daily_gens=1, max_active_jobs=5, global_monthly_usd=60))
    q.reserve("u1", "op-1", estimate_usd=0.10)
    q.reserve("u1", "op-2", estimate_usd=0.10)  # would exceed, but observe -> allowed


# correction 3/8: settle actual (may exceed estimate); idempotent -----------------------------------------

def test_settle_records_actual_and_is_idempotent():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(QuotaConfig(user_monthly_usd=99, user_daily_gens=99, max_active_jobs=5, global_monthly_usd=60))
    q.reserve("u1", "op-1", estimate_usd=0.10)
    q.settle("u1", "op-1", actual_usd=0.25)   # actual EXCEEDS estimate -> financial truth wins
    it = q._ddb.items[("u1", _period_now())]
    assert float(it["settled_usd"]["N"]) == 0.25
    q.settle("u1", "op-1", actual_usd=0.25)   # double settle -> no-op
    assert float(it["settled_usd"]["N"]) == 0.25


# correction 3/4: failed inference refunds allowance but KEEPS incurred spend ----------------------------

def test_failed_inference_refunds_allowance_but_keeps_spend():
    os.environ["STORY_QUOTA_MODE"] = "enforce"
    q = _q(QuotaConfig(user_monthly_usd=99, user_daily_gens=99, max_active_jobs=5, global_monthly_usd=60))
    q.reserve("u1", "op-1", estimate_usd=0.10, gens=1)
    q.release_allowance("u1", "op-1", gens=1, incurred_usd=0.03)  # failed after spending 0.03
    it = q._ddb.items[("u1", _period_now())]
    assert float(it["gens_used"]["N"]) == 0            # allowance refunded
    assert float(it["settled_usd"]["N"]) == 0.03       # spend NOT erased
    # idempotent
    q.release_allowance("u1", "op-1", gens=1, incurred_usd=0.03)
    assert float(it["gens_used"]["N"]) == 0


def _period_now():
    from user_quota import _period
    return _period()
