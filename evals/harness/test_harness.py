"""Self-tests for the DIRECT eval harness (deterministic layer only — no models).

Proves the harness itself works BEFORE real models exist: fixtures load with
unique ids, a well-formed Director envelope passes all Layer-0 checks, and
malformed/unsafe envelopes are caught. Also exercises run comparison.
"""

from __future__ import annotations

from uuid import uuid4

from evals.harness.deterministic import run_deterministic_checks
from evals.harness.fixtures import load_fixtures
from evals.harness.runner import compare_runs, new_run, run_deterministic


def _good_director_envelope() -> dict:
    beat_id = "beat_scale"
    shot_id = str(uuid4())
    return {
        "story_plan": {
            "id": str(uuid4()),
            "concept_id": str(uuid4()),
            "beats": [{"id": beat_id, "purpose": "Establish the human/landscape scale contrast."}],
            "shots": [
                {
                    "id": shot_id,
                    "order": 1,
                    "instruction": "Stand still near the trail; keep your partner small against the mountain.",
                    "beat_id": beat_id,
                    "purpose": "Establish scale.",
                }
            ],
        },
        "decision": {
            "action": "capture_shot",
            "shot": {
                "id": shot_id,
                "order": 1,
                "instruction": "Stand still near the trail; keep your partner small against the mountain.",
                "beat_id": beat_id,
            },
        },
    }


def test_fixtures_load_with_unique_ids():
    fixtures = load_fixtures()
    assert fixtures, "expected at least the seeded Director fixtures"
    ids = [f.id for f in fixtures]
    assert len(ids) == len(set(ids))


def test_good_envelope_passes_all_checks():
    checks = run_deterministic_checks("story_director", _good_director_envelope())
    failed = [c for c in checks if not c.passed]
    assert not failed, f"unexpected failures: {[(c.name, c.detail) for c in failed]}"


def test_orphan_beat_id_fails():
    env = _good_director_envelope()
    env["story_plan"]["shots"][0]["beat_id"] = "beat_does_not_exist"
    checks = run_deterministic_checks("story_director", env)
    assert any(c.name == "every_shot_beat_id_exists" and not c.passed for c in checks)


def test_capture_shot_without_shot_fails():
    env = _good_director_envelope()
    env["decision"] = {"action": "capture_shot"}  # no shot
    checks = run_deterministic_checks("story_director", env)
    assert any(c.name == "action_requires_shot" and not c.passed for c in checks)


def test_create_now_with_shot_fails():
    env = _good_director_envelope()
    env["decision"] = {"action": "create_now", "shot": env["story_plan"]["shots"][0]}
    checks = run_deterministic_checks("story_director", env)
    assert any(c.name == "action_omits_shot" and not c.passed for c in checks)


def test_unsafe_instruction_flagged():
    env = _good_director_envelope()
    env["story_plan"]["shots"][0]["instruction"] = "Walk backward near the edge while filming."
    checks = run_deterministic_checks("story_director", env)
    assert any(c.name.startswith("safety::") and not c.passed for c in checks)


def test_bad_enum_action_fails_schema():
    env = _good_director_envelope()
    env["decision"]["action"] = "do_a_barrel_roll"
    checks = run_deterministic_checks("story_director", env)
    assert any(c.name == "decision_schema_valid" and not c.passed for c in checks)


def test_run_record_and_regression_comparison():
    fixtures = load_fixtures(component="story_director")
    fx = fixtures[0]
    good = run_deterministic(fx, _good_director_envelope())
    baseline = new_run([good], model="mock", prompt_version="v0")
    assert baseline.passed

    bad_env = _good_director_envelope()
    bad_env["story_plan"]["shots"][0]["beat_id"] = "nope"
    bad = run_deterministic(fx, bad_env)
    candidate = new_run([bad], model="mock", prompt_version="v1")

    diff = compare_runs(baseline, candidate)
    assert any("every_shot_beat_id_exists" in r for r in diff["regressions"])
