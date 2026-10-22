"""P0 Beta Security Phase 4 — AI quota & spending protection.

Atomic, idempotent usage RESERVATION / SETTLEMENT / RELEASE on the existing UserUsage DynamoDB table,
keyed by the trusted canonical `story_user_id`. Enforces per-user allowances (generations), per-user and
GLOBAL financial spend breakers, and an active-job slot cap (queued + running). Observe mode by default.

Owner corrections (2026-10-22) encoded here:
  1. Reservation is genuinely idempotent + atomic: reservation_id = UUIDv5(operation_id); the reserve is a
     single conditional UpdateItem on ONE item, so a concurrent retry cannot double-reserve. The per-reservation
     marker (`res#<rid>`) carries its own amount + gens so settle/release move EXACTLY what was reserved.
  2/3. TransactWriteItems is EVALUATED (see design doc §2a). The per-user item is updated atomically on its
     own; the GLOBAL aggregate is a SEPARATE item so a single UpdateItem cannot cover both. `reserve()` uses
     TransactWriteItems to apply the per-user AND global deltas in ONE transaction when a global ddb client is
     available (full atomicity); otherwise it documents+falls back to per-user-first + best-effort global with
     a reconcilable drift window (design doc §2a "failure windows"). No cross-TABLE (UserUsage<->job store)
     atomicity is claimed.
  3/4. FINANCIAL cost (settled_usd, incl. failed/retry/repair/critique/fallback attempts) is tracked SEPARATELY
     from the user ALLOWANCE (gens): a failed video refunds the allowance but NEVER erases incurred spend.
  5. The GLOBAL Bedrock breaker defaults BELOW the $100 beta AWS Budget (budgets are ALERTS, not caps) — the
     initial proposal is $60 (overridable). It is a proposal, NOT an enforced spending guarantee.
  6. Active jobs = queued + running; EXACTLY-ONCE slot reserve/release via a per-job `slot#<job_id>` marker on
     the user item. A duplicate submit, SQS redelivery, retry, cancel, or worker crash can call reserve/release
     any number of times and the slot count moves at most once in each direction.
  8. Reserve an ESTIMATE before inference; settle the ACTUAL; if actual > estimate, settle the overage against
     spend (financial truth wins) while the allowance was already counted at reserve.
  9. Observe mode does NOT enforce cost/slot limits — it records what WOULD be denied.
 10. Low-cardinality metrics (op_type dim), trusted story_user_id key, never a user id as a dimension.

This module is pure logic over an injectable DynamoDB client; main.py / worker wire it to the real table.
"""

from __future__ import annotations

import os
import time
import uuid
from dataclasses import dataclass
from typing import Optional

# Stable namespace so reservation_id is deterministic from the operation id (idempotency, correction 1/6).
_RES_NS = uuid.UUID("6f6c1b4e-0000-4000-8000-000000000004")

GLOBAL_PK = "__global__"
# The global aggregate shares the monthly period SK shape with per-user rows.


def reservation_id(operation_id: str) -> str:
    return str(uuid.uuid5(_RES_NS, operation_id))


def quota_mode() -> str:
    """observe (default) records QuotaWouldDeny but never denies; enforce denies over-budget (correction 9)."""
    return os.environ.get("STORY_QUOTA_MODE", "observe").strip().lower()


def _period(now: Optional[float] = None) -> str:
    t = time.gmtime(now or time.time())
    return f"{t.tm_year:04d}-{t.tm_mon:02d}"  # monthly bucket, matches UserUsage SK shape


@dataclass(frozen=True)
class QuotaConfig:
    user_monthly_usd: float
    user_daily_gens: int
    max_active_jobs: int
    global_monthly_usd: float

    @classmethod
    def from_env(cls) -> "QuotaConfig":
        f = lambda k, d: float(os.environ.get(k, d))     # noqa: E731
        i = lambda k, d: int(os.environ.get(k, d))       # noqa: E731
        return cls(
            user_monthly_usd=f("STORY_QUOTA_USER_MONTHLY_USD", "8"),
            user_daily_gens=i("STORY_QUOTA_USER_DAILY_GENS", "20"),
            max_active_jobs=i("STORY_QUOTA_MAX_ACTIVE_JOBS", "2"),
            # Correction 5: start the GLOBAL Bedrock breaker BELOW the $100 beta AWS Budget (budgets are
            # ALERTS, not caps) — default $60 so the breaker trips before the budget alert. PROPOSAL only.
            global_monthly_usd=f("STORY_QUOTA_GLOBAL_MONTHLY_USD", "60"),
        )


class QuotaDenied(Exception):
    def __init__(self, scope: str):
        self.scope = scope  # user_monthly_usd | user_daily_gens | active_jobs | global_monthly_usd
        super().__init__(f"quota_exceeded:{scope}")


class QuotaStoreError(Exception):
    pass


@dataclass
class Reservation:
    reservation_id: str
    story_user_id: str
    estimate_usd: float
    gens: int = 1
    state: str = "reserved"  # reserved -> settled | released


def _is_conditional_failure(e: Exception) -> bool:
    n = type(e).__name__
    return "ConditionalCheckFailed" in n or "ConditionalCheckFailed" in str(e) \
        or "TransactionCanceled" in n or "ConditionalCheckFailed" in str(e)


class UserQuota:
    """Reserve/settle/release over UserUsage. `_ddb` injectable for tests (no network)."""

    def __init__(self, *, ddb=None, usage_table: str = "", region: str = "us-east-1",
                 cfg: Optional[QuotaConfig] = None):
        self._ddb = ddb
        self.usage_table = usage_table or os.environ.get("STORY_USER_USAGE_TABLE", "")
        self.region = region or os.environ.get("AWS_REGION", "us-east-1")
        self.cfg = cfg or QuotaConfig.from_env()

    def _c(self):
        if self._ddb is None:
            import boto3
            self._ddb = boto3.client("dynamodb", region_name=self.region)
        return self._ddb

    def _key(self, pk: str, period: str) -> dict:
        return {"story_user_id": {"S": pk}, "quota_period": {"S": period}}

    # -- reserve -----------------------------------------------------------------------------------------
    def reserve(self, story_user_id: str, operation_id: str, *, estimate_usd: float, gens: int = 1) -> Reservation:
        """Atomically reserve an allowance + estimated spend for this operation. Idempotent: a retry of the
        SAME operation_id returns the existing reservation WITHOUT double-counting (correction 1). Raises
        QuotaDenied in enforce mode when a per-user OR global cap would be exceeded; QuotaStoreError on a store
        outage (the CALLER maps that to fail-closed 503 for expensive ops, correction/Phase-3 amendment 1).

        Model: ONE item per (story_user_id, quota_period) holds `reserved_usd`, `settled_usd`, `gens_used`,
        and a per-reservation marker `res#<rid>` recording this reservation's amount+gens+state. The reserve
        is a single conditional write that (a) no-ops if the marker already exists (idempotency), and (b) only
        applies if the new per-user totals stay within budget. A SEPARATE `__global__` item tracks month-to-date
        spend across all users (correction 5). When both the per-user and global deltas must apply atomically,
        a TransactWriteItems covers them in one transaction (correction 2/3); failing that it falls back to
        per-user-first + a best-effort global add whose drift is reconcilable (design doc §2a)."""
        rid = reservation_id(operation_id)
        period = _period()
        enforce = quota_mode() == "enforce"
        c = self.cfg
        marker = f"res#{rid}"
        try:
            # Idempotency check: if this reservation marker is already recorded, return it (no re-charge).
            existing = self._c().get_item(
                TableName=self.usage_table, Key=self._key(story_user_id, period)).get("Item")
            if existing and marker in existing:
                return Reservation(rid, story_user_id, estimate_usd, gens, state="reserved")

            # Global breaker pre-check (enforce only): read the month-to-date global spend and deny if this
            # estimate would cross the cap. The authoritative global add happens below (atomic where possible).
            if enforce and c.global_monthly_usd > 0:
                g = self._c().get_item(
                    TableName=self.usage_table, Key=self._key(GLOBAL_PK, period)).get("Item") or {}
                g_reserved = float(g.get("reserved_usd", {}).get("N", "0"))
                g_settled = float(g.get("settled_usd", {}).get("N", "0"))
                if g_reserved + g_settled + estimate_usd > c.global_monthly_usd:
                    raise QuotaDenied("global_monthly_usd")

            names = {"#ru": "reserved_usd", "#g": "gens_used", "#r": marker}
            # The per-reservation marker is a MAP capturing exactly what to reverse on settle/release.
            values = {":eu": {"N": str(estimate_usd)}, ":g": {"N": str(gens)},
                      ":rid": {"M": {"state": {"S": "reserved"}, "usd": {"N": str(estimate_usd)},
                                     "gens": {"N": str(gens)}}}}
            if enforce:
                values[":umax"] = {"N": str(c.user_monthly_usd)}
                values[":gmax"] = {"N": str(c.user_daily_gens)}
                values[":z"] = {"N": "0"}
                cond = ("attribute_not_exists(#r) AND "
                        "(if_not_exists(#ru,:z) + :eu) <= :umax AND "
                        "(if_not_exists(#g,:z) + :g) <= :gmax")
                names["#su"] = "settled_usd"
                # include settled in the monthly ceiling: reserved + settled + est <= umax
                cond = ("attribute_not_exists(#r) AND "
                        "(if_not_exists(#ru,:z) + if_not_exists(#su,:z) + :eu) <= :umax AND "
                        "(if_not_exists(#g,:z) + :g) <= :gmax")
            else:
                cond = "attribute_not_exists(#r)"  # only idempotency guard in observe

            user_update = {
                "TableName": self.usage_table, "Key": self._key(story_user_id, period),
                "UpdateExpression": "ADD #ru :eu, #g :g SET #r = :rid",
                "ConditionExpression": cond, "ExpressionAttributeNames": names,
                "ExpressionAttributeValues": values,
            }
            # Correction 2/3: apply per-user AND global in ONE transaction where the client supports it.
            if hasattr(self._c(), "transact_write_items") and c.global_monthly_usd > 0:
                gmarker = f"gres#{rid}"
                gnames = {"#gru": "reserved_usd", "#gm": gmarker}
                gvals = {":eu": {"N": str(estimate_usd)},
                         ":gm": {"M": {"state": {"S": "reserved"}, "usd": {"N": str(estimate_usd)}}}}
                gcond = "attribute_not_exists(#gm)"
                if enforce:
                    gnames["#gs"] = "settled_usd"
                    gvals[":gmax"] = {"N": str(c.global_monthly_usd)}
                    gvals[":z"] = {"N": "0"}
                    gcond = ("attribute_not_exists(#gm) AND "
                             "(if_not_exists(#gru,:z) + if_not_exists(#gs,:z) + :eu) <= :gmax")
                try:
                    self._c().transact_write_items(TransactItems=[
                        {"Update": {k: v for k, v in user_update.items()}},
                        {"Update": {"TableName": self.usage_table, "Key": self._key(GLOBAL_PK, period),
                                    "UpdateExpression": "ADD #gru :eu SET #gm = :gm",
                                    "ConditionExpression": gcond,
                                    "ExpressionAttributeNames": gnames,
                                    "ExpressionAttributeValues": gvals}},
                    ])
                    return Reservation(rid, story_user_id, estimate_usd, gens, state="reserved")
                except Exception as e:  # noqa: BLE001
                    if _is_conditional_failure(e):
                        return self._reserve_conditional_recover(story_user_id, period, marker, rid,
                                                                 estimate_usd, gens)
                    raise QuotaStoreError(str(e)[:200]) from e

            # Fallback (no transact support): per-user atomic first, then best-effort global add.
            self._c().update_item(**user_update)
            if c.global_monthly_usd > 0:
                self._global_add(period, rid, estimate_usd)
            return Reservation(rid, story_user_id, estimate_usd, gens, state="reserved")
        except QuotaDenied:
            raise
        except Exception as e:  # noqa: BLE001
            if _is_conditional_failure(e):
                return self._reserve_conditional_recover(story_user_id, period, marker, rid, estimate_usd, gens)
            raise QuotaStoreError(str(e)[:200]) from e

    def _reserve_conditional_recover(self, story_user_id, period, marker, rid, estimate_usd, gens):
        again = self._c().get_item(
            TableName=self.usage_table, Key=self._key(story_user_id, period)).get("Item") or {}
        if marker in again:
            return Reservation(rid, story_user_id, estimate_usd, gens, state="reserved")
        # Determine WHICH per-user bound the conditional breached, so the denial scope (and the app's message)
        # is accurate. Daily-gens is checked before monthly-usd so "you've hit today's limit" wins when both
        # would trip. (A global breach is raised earlier by the pre-check, never here.)
        c = self.cfg
        cur_gens = float(again.get("gens_used", {}).get("N", "0"))
        cur_res = float(again.get("reserved_usd", {}).get("N", "0"))
        cur_set = float(again.get("settled_usd", {}).get("N", "0"))
        if cur_gens + gens > c.user_daily_gens:
            raise QuotaDenied("user_daily_gens")
        if cur_res + cur_set + estimate_usd > c.user_monthly_usd:
            raise QuotaDenied("user_monthly_usd")
        # Neither per-user bound explains it -> the global transaction leg failed (global breaker).
        raise QuotaDenied("global_monthly_usd")

    def _global_add(self, period: str, rid: str, estimate_usd: float) -> None:
        """Best-effort idempotent global reserve add (fallback path only). Marker gres#<rid> keeps it
        idempotent; a failure here is a reconcilable drift (design doc §2a), not a user-facing error."""
        gmarker = f"gres#{rid}"
        try:
            self._c().update_item(
                TableName=self.usage_table, Key=self._key(GLOBAL_PK, period),
                UpdateExpression="ADD #gru :eu SET #gm = :gm",
                ConditionExpression="attribute_not_exists(#gm)",
                ExpressionAttributeNames={"#gru": "reserved_usd", "#gm": gmarker},
                ExpressionAttributeValues={":eu": {"N": str(estimate_usd)},
                                           ":gm": {"M": {"state": {"S": "reserved"},
                                                         "usd": {"N": str(estimate_usd)}}}})
        except Exception:  # noqa: BLE001
            pass  # idempotency marker collision or transient — reconcile sweep corrects drift

    # -- settle ------------------------------------------------------------------------------------------
    def settle(self, story_user_id: str, operation_id: str, *, actual_usd: float) -> None:
        """Idempotently record the ACTUAL incurred spend for a reservation. Moves the reserved estimate off
        `reserved_usd` and ADDs the ACTUAL onto `settled_usd` (actual MAY exceed the estimate — correction 8:
        financial truth wins). Double settle is a no-op (state guard). The ALLOWANCE (gens_used) is NOT
        refunded here — a settled generation counted against the allowance when reserved (correction 4).
        Also settles the GLOBAL aggregate marker symmetrically."""
        rid = reservation_id(operation_id)
        period = _period()
        marker = f"res#{rid}"
        try:
            # Read the reserved estimate off the marker so we subtract EXACTLY what was reserved (fixes the
            # earlier -0.0 no-op). If the marker is gone / not 'reserved', this is an idempotent no-op.
            item = self._c().get_item(
                TableName=self.usage_table, Key=self._key(story_user_id, period)).get("Item") or {}
            m = item.get(marker, {}).get("M")
            if not m or m.get("state", {}).get("S") != "reserved":
                return  # already settled/released — idempotent
            est = float(m.get("usd", {}).get("N", "0"))
            self._c().update_item(
                TableName=self.usage_table, Key=self._key(story_user_id, period),
                UpdateExpression="SET #r.#st = :settled ADD #su :au, #ru :neg",
                ConditionExpression="#r.#st = :reserved",   # only settle a still-reserved marker (idempotent)
                ExpressionAttributeNames={"#r": marker, "#st": "state",
                                          "#su": "settled_usd", "#ru": "reserved_usd"},
                ExpressionAttributeValues={":settled": {"S": "settled"}, ":reserved": {"S": "reserved"},
                                           ":au": {"N": str(actual_usd)}, ":neg": {"N": str(-est)}})
            self._global_settle(period, rid, actual_usd)
        except Exception as e:  # noqa: BLE001
            if _is_conditional_failure(e):
                return  # already settled/released — idempotent no-op
            raise QuotaStoreError(str(e)[:200]) from e

    def _global_settle(self, period: str, rid: str, actual_usd: float) -> None:
        gmarker = f"gres#{rid}"
        try:
            g = self._c().get_item(
                TableName=self.usage_table, Key=self._key(GLOBAL_PK, period)).get("Item") or {}
            m = g.get(gmarker, {}).get("M")
            if not m or m.get("state", {}).get("S") != "reserved":
                return
            est = float(m.get("usd", {}).get("N", "0"))
            self._c().update_item(
                TableName=self.usage_table, Key=self._key(GLOBAL_PK, period),
                UpdateExpression="SET #gm.#st = :settled ADD #gs :au, #gru :neg",
                ConditionExpression="#gm.#st = :reserved",
                ExpressionAttributeNames={"#gm": gmarker, "#st": "state",
                                          "#gs": "settled_usd", "#gru": "reserved_usd"},
                ExpressionAttributeValues={":settled": {"S": "settled"}, ":reserved": {"S": "reserved"},
                                           ":au": {"N": str(actual_usd)}, ":neg": {"N": str(-est)}})
        except Exception:  # noqa: BLE001
            pass  # reconcilable drift

    # -- release (failed/cancelled) ----------------------------------------------------------------------
    def release_allowance(self, story_user_id: str, operation_id: str, *, gens: int = 1,
                          incurred_usd: float = 0.0) -> None:
        """A failed/cancelled generation: REFUND the user allowance (gens_used) and remove the reserved
        estimate, but SETTLE any incurred spend (correction 3/4 — a failed video may refund an allowance
        without erasing infra spend). Idempotent via the per-reservation state guard. Also releases the GLOBAL
        marker (reserved estimate off; incurred spend kept)."""
        rid = reservation_id(operation_id)
        period = _period()
        marker = f"res#{rid}"
        try:
            item = self._c().get_item(
                TableName=self.usage_table, Key=self._key(story_user_id, period)).get("Item") or {}
            m = item.get(marker, {}).get("M")
            if not m or m.get("state", {}).get("S") != "reserved":
                return  # already settled/released — idempotent
            est = float(m.get("usd", {}).get("N", "0"))
            rgens = int(float(m.get("gens", {}).get("N", str(gens))))
            self._c().update_item(
                TableName=self.usage_table, Key=self._key(story_user_id, period),
                UpdateExpression="SET #r.#st = :released ADD #g :neg, #su :inc, #ru :relneg",
                ConditionExpression="#r.#st = :reserved",
                ExpressionAttributeNames={"#r": marker, "#st": "state", "#g": "gens_used",
                                          "#su": "settled_usd", "#ru": "reserved_usd"},
                ExpressionAttributeValues={":released": {"S": "released"}, ":reserved": {"S": "reserved"},
                                           ":neg": {"N": str(-rgens)}, ":inc": {"N": str(incurred_usd)},
                                           ":relneg": {"N": str(-est)}})
            self._global_release(period, rid, incurred_usd)
        except Exception as e:  # noqa: BLE001
            if _is_conditional_failure(e):
                return
            raise QuotaStoreError(str(e)[:200]) from e

    def _global_release(self, period: str, rid: str, incurred_usd: float) -> None:
        gmarker = f"gres#{rid}"
        try:
            g = self._c().get_item(
                TableName=self.usage_table, Key=self._key(GLOBAL_PK, period)).get("Item") or {}
            m = g.get(gmarker, {}).get("M")
            if not m or m.get("state", {}).get("S") != "reserved":
                return
            est = float(m.get("usd", {}).get("N", "0"))
            self._c().update_item(
                TableName=self.usage_table, Key=self._key(GLOBAL_PK, period),
                UpdateExpression="SET #gm.#st = :released ADD #gs :inc, #gru :relneg",
                ConditionExpression="#gm.#st = :reserved",
                ExpressionAttributeNames={"#gm": gmarker, "#st": "state",
                                          "#gs": "settled_usd", "#gru": "reserved_usd"},
                ExpressionAttributeValues={":released": {"S": "released"}, ":reserved": {"S": "reserved"},
                                           ":inc": {"N": str(incurred_usd)}, ":relneg": {"N": str(-est)}})
        except Exception:  # noqa: BLE001
            pass

    # -- active-job slots (correction 6: queued + running, exactly-once) --------------------------------
    def reserve_slot(self, story_user_id: str, job_id: str) -> bool:
        """Reserve ONE active-job slot for this job, EXACTLY ONCE. Idempotent + atomic via a per-job marker
        `slot#<job_id>` on the user item: the counter `active_jobs` moves at most once per job regardless of
        duplicate submits / SQS redelivery / retries. Returns True if a slot is held for this job (newly or
        already). In ENFORCE mode raises QuotaDenied('active_jobs') when the cap (queued+running) is reached
        and this job does not already hold a slot. In OBSERVE mode never denies (correction 9)."""
        period = _period()
        enforce = quota_mode() == "enforce"
        marker = f"slot#{job_id}"
        c = self.cfg
        try:
            item = self._c().get_item(
                TableName=self.usage_table, Key=self._key(story_user_id, period)).get("Item") or {}
            if item.get(marker, {}).get("M", {}).get("state", {}).get("S") == "held":
                return True  # already holds a slot — idempotent
            names = {"#sm": marker, "#aj": "active_jobs"}
            values = {":held": {"M": {"state": {"S": "held"}}}, ":one": {"N": "1"}}
            if enforce:
                values[":max"] = {"N": str(c.max_active_jobs)}
                values[":z"] = {"N": "0"}
                cond = "attribute_not_exists(#sm) AND (if_not_exists(#aj,:z) + :one) <= :max"
            else:
                cond = "attribute_not_exists(#sm)"
            self._c().update_item(
                TableName=self.usage_table, Key=self._key(story_user_id, period),
                UpdateExpression="ADD #aj :one SET #sm = :held",
                ConditionExpression=cond,
                ExpressionAttributeNames=names, ExpressionAttributeValues=values)
            return True
        except Exception as e:  # noqa: BLE001
            if _is_conditional_failure(e):
                again = self._c().get_item(
                    TableName=self.usage_table, Key=self._key(story_user_id, period)).get("Item") or {}
                if again.get(marker, {}).get("M", {}).get("state", {}).get("S") == "held":
                    return True  # raced to held — idempotent
                raise QuotaDenied("active_jobs")
            raise QuotaStoreError(str(e)[:200]) from e

    def release_slot(self, story_user_id: str, job_id: str) -> None:
        """Release this job's active-job slot EXACTLY ONCE on terminal (completed/failed/cancelled/expired).
        Idempotent via the per-job marker state guard: a worker crash + redelivery, a duplicate terminal
        transition, or a cancel racing a completion all decrement `active_jobs` at most once."""
        period = _period()
        marker = f"slot#{job_id}"
        try:
            self._c().update_item(
                TableName=self.usage_table, Key=self._key(story_user_id, period),
                UpdateExpression="SET #sm.#st = :released ADD #aj :neg",
                ConditionExpression="#sm.#st = :held",
                ExpressionAttributeNames={"#sm": marker, "#st": "state", "#aj": "active_jobs"},
                ExpressionAttributeValues={":released": {"S": "released"}, ":held": {"S": "held"},
                                           ":neg": {"N": "-1"}})
        except Exception as e:  # noqa: BLE001
            if _is_conditional_failure(e):
                return  # not held / already released — idempotent no-op
            raise QuotaStoreError(str(e)[:200]) from e
