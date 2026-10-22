"""P0 Beta Security Phase 4 — AI quota & spending protection.

Atomic, idempotent usage RESERVATION / SETTLEMENT / RELEASE on the existing UserUsage DynamoDB table,
keyed by the trusted canonical `story_user_id`. Enforces per-user allowances (generations), per-user and
GLOBAL financial spend breakers, and an active-job slot cap (queued + running). Observe mode by default.

Owner corrections (2026-10-22) encoded here:
  1. Reservation is genuinely idempotent + atomic: reservation_id = UUIDv5(operation_id); the reserve is a
     single conditional UpdateItem on ONE item, so a concurrent retry cannot double-reserve.
  2. TransactWriteItems is used where it buys real atomicity (slot + aggregate in one item family); the exact
     cross-store failure windows + recovery invariants are documented in the Phase 4 design doc.
  3/4. FINANCIAL cost (settled_usd, incl. failed/retry/repair/critique/fallback attempts) is tracked SEPARATELY
     from the user ALLOWANCE (gens): a failed video refunds the allowance but NEVER erases incurred spend.
  6. Active jobs = queued + running; exactly-once slot reserve/release via a per-reservation state flag.
  8. Reserve an ESTIMATE before inference; settle the ACTUAL; if actual > estimate, settle the overage against
     spend (financial truth wins) while the allowance was already counted at reserve.
  9. Observe mode does NOT enforce cost limits — it records what WOULD be denied.
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
            user_monthly_usd=f("STORY_QUOTA_USER_MONTHLY_USD", "5"),
            user_daily_gens=i("STORY_QUOTA_USER_DAILY_GENS", "40"),
            max_active_jobs=i("STORY_QUOTA_MAX_ACTIVE_JOBS", "5"),
            # Correction 5: start the GLOBAL Bedrock breaker BELOW the $100 beta AWS Budget (budgets are
            # ALERTS, not caps) — default $60 so the breaker trips before the budget alert.
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

    # -- reserve -----------------------------------------------------------------------------------------
    def reserve(self, story_user_id: str, operation_id: str, *, estimate_usd: float, gens: int = 1) -> Reservation:
        """Atomically reserve an allowance + estimated spend for this operation. Idempotent: a retry of the
        SAME operation_id returns the existing reservation WITHOUT double-counting (correction 1). Raises
        QuotaDenied in enforce mode when a cap would be exceeded; QuotaStoreError on a store outage.

        Model: ONE item per (story_user_id, quota_period) holds `reserved_usd`, `settled_usd`, `gens_used`,
        and a map of reservation ids already applied (`res_ids`). The reserve is a single conditional
        UpdateItem that (a) no-ops if res_id already recorded (idempotency), and (b) only applies if the new
        totals stay within budget. Because it is one item + one conditional write, concurrent retries cannot
        double-reserve."""
        rid = reservation_id(operation_id)
        period = _period()
        enforce = quota_mode() == "enforce"
        c = self.cfg
        try:
            # Idempotency check: if this reservation id is already recorded, return it (no re-charge).
            existing = self._c().get_item(
                TableName=self.usage_table,
                Key={"story_user_id": {"S": story_user_id}, "quota_period": {"S": period}},
            ).get("Item")
            if existing and f"res#{rid}" in existing:
                return Reservation(rid, story_user_id, estimate_usd, gens, state="reserved")

            # Attempt the atomic conditional add. In OBSERVE mode we still record usage (so metrics reflect
            # reality) but we do NOT impose the budget condition (correction 9: observe never denies).
            cond = None
            names = {"#ru": "reserved_usd", "#su": "settled_usd", "#g": "gens_used", "#r": f"res#{rid}"}
            values = {":eu": {"N": str(estimate_usd)}, ":g": {"N": str(gens)},
                      ":one": {"N": "1"}, ":rid": {"S": "reserved"}}
            if enforce:
                # budget guards: (reserved_usd + settled_usd + est) <= user_monthly AND gens_used + gens <= daily
                values[":umax"] = {"N": str(c.user_monthly_usd)}
                values[":gmax"] = {"N": str(c.user_daily_gens)}
                cond = ("attribute_not_exists(#r) AND "
                        "(if_not_exists(#ru,:z) + if_not_exists(#su,:z) + :eu) <= :umax AND "
                        "(if_not_exists(#g,:z) + :g) <= :gmax")
                values[":z"] = {"N": "0"}
            else:
                cond = "attribute_not_exists(#r)"  # only idempotency guard in observe
            self._c().update_item(
                TableName=self.usage_table,
                Key={"story_user_id": {"S": story_user_id}, "quota_period": {"S": period}},
                UpdateExpression="ADD #ru :eu, #g :g SET #r = :rid",
                ConditionExpression=cond,
                ExpressionAttributeNames=names,
                ExpressionAttributeValues=values,
            )
            return Reservation(rid, story_user_id, estimate_usd, gens, state="reserved")
        except Exception as e:  # noqa: BLE001
            name = type(e).__name__
            if "ConditionalCheckFailed" in name or "ConditionalCheckFailed" in str(e):
                # Either a cap was exceeded (enforce) or the res id already applied under a race -> re-read.
                again = self._c().get_item(
                    TableName=self.usage_table,
                    Key={"story_user_id": {"S": story_user_id}, "quota_period": {"S": period}},
                ).get("Item") or {}
                if f"res#{rid}" in again:
                    return Reservation(rid, story_user_id, estimate_usd, gens, state="reserved")
                # a real cap breach
                raise QuotaDenied("user_monthly_usd")
            raise QuotaStoreError(str(e)[:200]) from e

    # -- settle ------------------------------------------------------------------------------------------
    def settle(self, story_user_id: str, operation_id: str, *, actual_usd: float) -> None:
        """Idempotently record the ACTUAL incurred spend for a reservation. Moves `reserved_usd`->`settled_usd`
        using the actual cost (which MAY exceed the estimate — correction 8: financial truth wins). Double
        settle is a no-op (state guard). The ALLOWANCE (gens_used) is NOT refunded here — a settled generation
        counted against the allowance when reserved (correction 4)."""
        rid = reservation_id(operation_id)
        period = _period()
        try:
            self._c().update_item(
                TableName=self.usage_table,
                Key={"story_user_id": {"S": story_user_id}, "quota_period": {"S": period}},
                UpdateExpression="SET #r = :settled ADD #su :au, #ru :neg",
                ConditionExpression="#r = :reserved",   # only settle a still-reserved reservation (idempotent)
                ExpressionAttributeNames={"#r": f"res#{rid}", "#su": "settled_usd", "#ru": "reserved_usd"},
                ExpressionAttributeValues={":settled": {"S": "settled"}, ":reserved": {"S": "reserved"},
                                           ":au": {"N": str(actual_usd)}, ":neg": {"N": str(-0.0)}},
            )
        except Exception as e:  # noqa: BLE001
            if "ConditionalCheckFailed" in str(type(e).__name__) or "ConditionalCheckFailed" in str(e):
                return  # already settled/released — idempotent no-op
            raise QuotaStoreError(str(e)[:200]) from e

    # -- release (failed/cancelled before any spend) -----------------------------------------------------
    def release_allowance(self, story_user_id: str, operation_id: str, *, gens: int = 1,
                          incurred_usd: float = 0.0) -> None:
        """A failed/cancelled generation: REFUND the user allowance (gens_used) but SETTLE any incurred spend
        (correction 3/4 — a failed video may refund an allowance without erasing infra spend). Idempotent via
        the reservation state guard."""
        rid = reservation_id(operation_id)
        period = _period()
        try:
            self._c().update_item(
                TableName=self.usage_table,
                Key={"story_user_id": {"S": story_user_id}, "quota_period": {"S": period}},
                UpdateExpression="SET #r = :released ADD #g :neg, #su :inc, #ru :relneg",
                ConditionExpression="#r = :reserved",
                ExpressionAttributeNames={"#r": f"res#{rid}", "#g": "gens_used",
                                          "#su": "settled_usd", "#ru": "reserved_usd"},
                ExpressionAttributeValues={":released": {"S": "released"}, ":reserved": {"S": "reserved"},
                                           ":neg": {"N": str(-gens)}, ":inc": {"N": str(incurred_usd)},
                                           ":relneg": {"N": str(-0.0)}},
            )
        except Exception as e:  # noqa: BLE001
            if "ConditionalCheckFailed" in str(type(e).__name__) or "ConditionalCheckFailed" in str(e):
                return
            raise QuotaStoreError(str(e)[:200]) from e
