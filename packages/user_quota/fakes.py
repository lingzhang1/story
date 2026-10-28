"""Shared in-memory DynamoDB double for user_quota tests (unit + API integration).

Models the SINGLE-ITEM conditional-update AND TransactWriteItems semantics the quota module relies on,
supporting exactly the expression shapes it emits: ADD on numeric attrs, SET on a top-level marker map,
SET on a nested marker state (#r.#st / #sm.#st / #gm.#st), and the budget / idempotency / state
ConditionExpressions. Not a general DynamoDB emulator — only what user_quota uses.
"""

from __future__ import annotations

import copy
import threading


class Cancel(Exception):
    """Mimics botocore ConditionalCheckFailedException / TransactionCanceledException BY NAME (the quota
    module matches on the exception class name)."""
    def __init__(self, kind="ConditionalCheckFailedException"):
        super().__init__(kind)
        self.__class__.__name__ = kind


class FakeDDB:
    def __init__(self, *, support_transact=True):
        self.items: dict[tuple, dict] = {}
        self.lock = threading.RLock()
        self._support_transact = support_transact

    def __getattribute__(self, name):
        if name == "transact_write_items" and not object.__getattribute__(self, "_support_transact"):
            raise AttributeError(name)
        return object.__getattribute__(self, name)

    def _k(self, Key):
        return (Key["story_user_id"]["S"], Key["quota_period"]["S"])

    def get_item(self, TableName, Key):
        with self.lock:
            it = self.items.get(self._k(Key))
            return {"Item": copy.deepcopy(it)} if it else {}

    def _apply(self, it, UpdateExpression, ConditionExpression, names, vals):
        def num(a):
            return float(it.get(a, {}).get("N", "0"))
        if ConditionExpression:
            cond = ConditionExpression
            # Real DynamoDB REJECTS arithmetic (`+`) in a ConditionExpression with a ValidationException
            # (it is only valid in an UpdateExpression SET). Mirror that here so a regression that puts a
            # budget sum back into the condition fails the unit tests instead of silently passing.
            if "+" in cond:
                raise ValueError(
                    "Invalid ConditionExpression: Syntax error; token: \"+\" "
                    "(DynamoDB conditions cannot contain arithmetic — enforce budgets in app code)")
            rname = names.get("#r") or names.get("#sm") or names.get("#gm") or ""
            if "attribute_not_exists(#r)" in cond and rname in it:
                raise Cancel()
            if "attribute_not_exists(#sm)" in cond and names.get("#sm", "") in it:
                raise Cancel()
            if "attribute_not_exists(#gm)" in cond and names.get("#gm", "") in it:
                raise Cancel()
            # Atomic active-job cap (P0 concurrency fix): the reserve emits
            # `attribute_not_exists(#sm) AND (attribute_not_exists(#aj) OR #aj < :max)`.
            # `#aj < :max` is a COMPARISON (valid in a DynamoDB condition); model it so a concurrent
            # over-admission is rejected here exactly as real DynamoDB would reject it.
            if "#aj < :max" in cond and ":max" in vals:
                mx = float(vals[":max"]["N"])
                if num("active_jobs") >= mx:
                    raise Cancel()
            for mk in ("#r", "#sm", "#gm"):
                if f"{mk}.#st = :reserved" in cond:
                    st = it.get(names[mk], {}).get("M", {}).get("state", {}).get("S")
                    if st != "reserved":
                        raise Cancel()
                if f"{mk}.#st = :held" in cond:
                    st = it.get(names[mk], {}).get("M", {}).get("state", {}).get("S")
                    if st != "held":
                        raise Cancel()
            if "<= :umax" in cond:
                est = float(vals[":eu"]["N"]); umax = float(vals[":umax"]["N"])
                if num("reserved_usd") + num("settled_usd") + est > umax:
                    raise Cancel()
                g = float(vals[":g"]["N"]); gmax = float(vals[":gmax"]["N"])
                if num("gens_used") + g > gmax:
                    raise Cancel()
            if "<= :gmax" in cond and ":eu" in vals and "#gru" in names:
                est = float(vals[":eu"]["N"]); gmax = float(vals[":gmax"]["N"])
                if num("reserved_usd") + num("settled_usd") + est > gmax:
                    raise Cancel()
            if "<= :max" in cond:
                mx = float(vals[":max"]["N"])
                if num("active_jobs") + 1 > mx:
                    raise Cancel()
        ue = UpdateExpression
        if "ADD" in ue:
            if "#ru :eu" in ue:  it["reserved_usd"] = {"N": str(num("reserved_usd") + float(vals[":eu"]["N"]))}
            if "#gru :eu" in ue: it["reserved_usd"] = {"N": str(num("reserved_usd") + float(vals[":eu"]["N"]))}
            if "#g :g" in ue:    it[names["#g"]] = {"N": str(float(it.get(names["#g"],{}).get("N","0")) + float(vals[":g"]["N"]))}
            if "#su :au" in ue:  it["settled_usd"] = {"N": str(num("settled_usd") + float(vals[":au"]["N"]))}
            if "#gs :au" in ue:  it["settled_usd"] = {"N": str(num("settled_usd") + float(vals[":au"]["N"]))}
            if "#su :inc" in ue: it["settled_usd"] = {"N": str(num("settled_usd") + float(vals[":inc"]["N"]))}
            if "#gs :inc" in ue: it["settled_usd"] = {"N": str(num("settled_usd") + float(vals[":inc"]["N"]))}
            if "#ru :neg" in ue: it["reserved_usd"] = {"N": str(num("reserved_usd") + float(vals[":neg"]["N"]))}
            if "#gru :neg" in ue: it["reserved_usd"] = {"N": str(num("reserved_usd") + float(vals[":neg"]["N"]))}
            if "#ru :relneg" in ue:  it["reserved_usd"] = {"N": str(num("reserved_usd") + float(vals[":relneg"]["N"]))}
            if "#gru :relneg" in ue: it["reserved_usd"] = {"N": str(num("reserved_usd") + float(vals[":relneg"]["N"]))}
            if "#g :neg" in ue:  it[names["#g"]] = {"N": str(float(it.get(names["#g"],{}).get("N","0")) + float(vals[":neg"]["N"]))}
            if "#aj :one" in ue: it["active_jobs"] = {"N": str(num("active_jobs") + 1)}
            if "#aj :neg" in ue: it["active_jobs"] = {"N": str(num("active_jobs") - 1)}
        if "SET #r = :rid" in ue:   it[names["#r"]] = copy.deepcopy(vals[":rid"])
        if "SET #sm = :held" in ue: it[names["#sm"]] = copy.deepcopy(vals[":held"])
        if "SET #gm = :gm" in ue:   it[names["#gm"]] = copy.deepcopy(vals[":gm"])
        for mk, sv in (("#r", ":settled"), ("#r", ":released"), ("#sm", ":released"),
                       ("#gm", ":settled"), ("#gm", ":released")):
            if f"{mk}.#st = {sv}" in ue:
                it.setdefault(names[mk], {"M": {}})["M"]["state"] = {"S": vals[sv]["S"]}

    def update_item(self, TableName, Key, UpdateExpression, ConditionExpression=None,
                    ExpressionAttributeNames=None, ExpressionAttributeValues=None):
        with self.lock:
            it = self.items.setdefault(self._k(Key), {})
            self._apply(it, UpdateExpression, ConditionExpression,
                        ExpressionAttributeNames or {}, ExpressionAttributeValues or {})

    def transact_write_items(self, TransactItems):
        with self.lock:
            snapshot = copy.deepcopy(self.items)
            try:
                for ti in TransactItems:
                    up = ti["Update"]
                    it = self.items.setdefault(self._k(up["Key"]), {})
                    self._apply(it, up["UpdateExpression"], up.get("ConditionExpression"),
                                up.get("ExpressionAttributeNames", {}), up.get("ExpressionAttributeValues", {}))
            except Cancel:
                self.items = snapshot
                raise Cancel("TransactionCanceledException")
