"""Run the REAL Creative Intent engine over the creative_intent fixtures.

Milestone C1 evaluation driver. Calls Bedrock (costs a few cents), applies the
Layer-0 deterministic checks (schema validity against the canonical contract),
and prints per-fixture output + latency + usage, then persists a RunRecord.

Usage:  TMPDIR=/tmp .venv/bin/python evals/run_creative_intent.py
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
for rel in (".", "packages", "apps/api"):
    p = str((_ROOT / rel).resolve())
    if p not in sys.path:
        sys.path.insert(0, p)

from creative_intent import PROMPT_VERSION, SCHEMA_VERSION, RealCreativeIntentEngine
from evals.harness.fixtures import load_fixtures
from evals.harness.runner import FixtureResult, new_run
from evals.harness.deterministic import check_schema_valid
from model_gateway import BedrockModelGateway, ProviderError, StructuredOutputError


def main() -> None:
    gateway = BedrockModelGateway()
    engine = RealCreativeIntentEngine(gateway)
    fixtures = load_fixtures(component="creative_intent")

    results: list[FixtureResult] = []
    latencies: list[float] = []
    total_in = total_out = 0
    print(f"Running {len(fixtures)} creative_intent fixtures through {gateway.model_id}\n")

    for fx in fixtures:
        raw = fx.inputs["raw_text"]
        t = time.monotonic()
        status = "OK"
        payload: dict = {}
        checks = []
        try:
            # Call the gateway directly so we can capture usage, then convert.
            req = engine.build_request(raw)
            sr = gateway.generate_structured(req)
            if sr.usage:
                total_in += sr.usage.input_tokens or 0
                total_out += sr.usage.output_tokens or 0
            intent = engine._to_contract(sr, raw)  # noqa: SLF001 (eval driver)
            payload = intent.model_dump(mode="json")
            checks = [check_schema_valid("creative_intent", payload)]
        except (StructuredOutputError, ProviderError) as e:
            status = f"FAIL:{type(e).__name__}"
            checks = []
        dt = (time.monotonic() - t) * 1000
        latencies.append(dt)
        passed = status == "OK" and all(c.passed for c in checks)
        results.append(FixtureResult(fx.id, fx.component, passed,
                                     [{"name": c.name, "passed": c.passed, "detail": c.detail} for c in checks]))
        print(f"[{status}] {fx.id}  {dt:.0f}ms")
        if payload:
            compact = {k: v for k, v in payload.items() if k not in ("id", "created_at", "source_inputs") and v not in (None, [], "")}
            print("   " + json.dumps(compact, ensure_ascii=False))
        print()

    run = new_run(results, model=gateway.model_id, provider="bedrock",
                  prompt_version=PROMPT_VERSION, schema_version=SCHEMA_VERSION,
                  fixture_set_version="ci-v1")
    out = run.save()
    ok = sum(1 for r in results if r.passed)
    lat_sorted = sorted(latencies)
    p50 = lat_sorted[len(lat_sorted)//2]
    p90 = lat_sorted[int(len(lat_sorted)*0.9)]
    print("=" * 60)
    print(f"contract success: {ok}/{len(results)}")
    print(f"latency ms: min={min(latencies):.0f} p50={p50:.0f} p90={p90:.0f} max={max(latencies):.0f}")
    print(f"tokens: in={total_in} out={total_out}")
    print(f"RunRecord: {out}")


if __name__ == "__main__":
    main()
