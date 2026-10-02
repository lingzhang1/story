"""Runner + result persistence + run comparison (13-evaluation.md §27, §25).

The runner applies the deterministic layer to a (fixture, candidate_output)
pair and records a structured result. A RunRecord captures the component,
model/prompt/schema/fixture-set versions (§27) so iterations are comparable,
and `compare_runs` detects regressions between two runs (§25): a check that
passed before and fails now is a regression.

NO model calls here. For Milestone C's deterministic phase, `candidate_output`
is supplied by the caller (a fixture's own canned output, or — once real models
land — the engine's live output). This keeps the harness usable with zero cost
today and unchanged when real models are added.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from evals.harness.deterministic import run_deterministic_checks
from evals.harness.fixtures import Fixture

RESULTS_ROOT = Path(__file__).resolve().parent.parent / "results"


@dataclass
class FixtureResult:
    fixture_id: str
    component: str
    passed: bool
    checks: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class RunRecord:
    """One eval run over a fixture set. Versions make runs comparable (§27)."""

    run_id: str
    created_at: str
    # provenance / experiment tracking (§27)
    component: str | None = None
    model: str | None = None
    provider: str | None = None
    prompt_version: str | None = None
    schema_version: str | None = None
    fixture_set_version: str | None = None
    results: list[FixtureResult] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return all(r.passed for r in self.results)

    def save(self, root: Path | None = None) -> Path:
        base = root or RESULTS_ROOT
        base.mkdir(parents=True, exist_ok=True)
        out = base / f"{self.run_id}.json"
        out.write_text(json.dumps(asdict(self), indent=2, sort_keys=True) + "\n")
        return out


def run_deterministic(
    fixture: Fixture,
    candidate_output: dict[str, Any],
) -> FixtureResult:
    """Run Layer-0 checks for one fixture against a candidate structured output."""
    checks = run_deterministic_checks(fixture.component, candidate_output)
    return FixtureResult(
        fixture_id=fixture.id,
        component=fixture.component,
        passed=all(c.passed for c in checks),
        checks=[{"name": c.name, "passed": c.passed, "detail": c.detail} for c in checks],
    )


def new_run(
    results: list[FixtureResult],
    *,
    model: str | None = None,
    provider: str | None = None,
    prompt_version: str | None = None,
    schema_version: str | None = None,
    fixture_set_version: str | None = None,
) -> RunRecord:
    now = datetime.now(timezone.utc)
    return RunRecord(
        run_id=now.strftime("%Y%m%dT%H%M%SZ"),
        created_at=now.isoformat(),
        model=model,
        provider=provider,
        prompt_version=prompt_version,
        schema_version=schema_version,
        fixture_set_version=fixture_set_version,
        results=results,
    )


def compare_runs(baseline: RunRecord, candidate: RunRecord) -> dict[str, list[str]]:
    """Return regressions / fixes / newly-added between two runs (§25).

    regression = a fixture (or named check) that passed in baseline, fails now.
    """
    def check_map(run: RunRecord) -> dict[tuple[str, str], bool]:
        m: dict[tuple[str, str], bool] = {}
        for r in run.results:
            for c in r.checks:
                m[(r.fixture_id, c["name"])] = c["passed"]
        return m

    base_m = check_map(baseline)
    cand_m = check_map(candidate)
    regressions, fixes, added = [], [], []
    for key, cand_pass in cand_m.items():
        label = f"{key[0]}::{key[1]}"
        if key in base_m:
            if base_m[key] and not cand_pass:
                regressions.append(label)
            elif not base_m[key] and cand_pass:
                fixes.append(label)
        else:
            added.append(label)
    return {"regressions": sorted(regressions), "fixes": sorted(fixes), "added": sorted(added)}
