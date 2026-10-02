"""Story DIRECT evaluation harness.

Repo-aware implementation of the evaluation architecture in
spec/implementation-plan/13-evaluation.md (a LIVING spec — fixtures grow from
real failures). This package is the OPERATIONAL harness that must be in place
BEFORE real models are turned on, so every prompt/model change is measurable.

Layer scope of what is buildable WITHOUT a model (built here now):
  - Layer 0  — contract/deterministic correctness (schema validity, referential
               integrity, enum validity, id uniqueness).
  - Loader   — stable fixture format + loader.
  - Runner   — run deterministic checks over a candidate output + fixture.
  - Results  — persist a run record; compare two runs (regression detection).

Layers that REQUIRE a model (plan-only until real models land, see
milestone-c-eval-harness-plan.md):
  - Layer 1  — component quality (intent fidelity, scene grounding) via LLM judge.
  - Layer 2  — Director behavior rubric (scene-specificity, intent-sensitivity,
               loop adaptation) — contrastive, LLM-assisted + human.
  - Layer 3  — end-to-end / real-device / field outcomes.

NO model calls occur in this package. The deterministic layer is pure functions
over already-produced structured output + a fixture's expected/forbidden
properties, so it runs in CI with zero cost.
"""

from __future__ import annotations
