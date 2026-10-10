"""Duration Planner tests (Milestone R-d.2, frozen duration_recommendation/1).

No real model — FakeModelGateway returns a preset recommendation or error. Covers §8: no universal default,
useful-segment union (no double-count), scope sensitivity carried to the model, long-performance evidence,
explicit-duration precedence, feasible-ceiling enforcement, zero-material recovery, no fabrication.
"""
from __future__ import annotations
import pytest
from fastapi.testclient import TestClient
from app.deps import get_duration_planner_engine
from app.main import create_app
from duration_planner import (compute_duration_evidence, RealDurationPlannerEngine,
                              DurationPlannerInputs)
from model_gateway import FakeModelGateway, ProviderError, StructuredOutputError

GUITAR = [
    {"id": "string_first_touch", "duration_seconds": 7.4, "useful_segments": [[0, 1.3], [1.3, 6.8]]},
    {"id": "final_song", "duration_seconds": 39.3, "useful_segments": [[0, 39.3]]},
]

# ---- deterministic evidence ----
def test_union_no_double_count():
    ev = compute_duration_evidence([{"id": "a", "duration_seconds": 10, "useful_segments": [[0, 6], [4, 8]]}])
    assert ev["total_useful_coverage_seconds"] == 8.0  # union 0..8, NOT 10

def test_longest_continuous_span():
    ev = compute_duration_evidence(GUITAR)
    assert ev["longest_continuous_span_seconds"] == 39.3  # the performance recognized as one span

def test_missing_au_falls_back_to_clip():
    ev = compute_duration_evidence([{"id": "b", "duration_seconds": 12}])
    pm = ev["per_moment"][0]
    assert pm["useful_coverage_seconds"] == 12.0 and pm["has_au"] is False

def test_zero_material_flagged():
    ev = compute_duration_evidence([{"id": "c", "duration_seconds": 0, "useful_segments": []}])
    assert ev["zero_usable_material"] is True

def test_dict_shape_segments():
    ev = compute_duration_evidence([{"id": "d", "duration_seconds": 10,
                                     "useful_segments": [{"start_time": 1, "end_time": 5}]}])
    assert ev["total_useful_coverage_seconds"] == 4.0

def test_no_universal_default():
    # two very different materials must NOT both yield the same band
    short = compute_duration_evidence([{"id": "x", "duration_seconds": 6, "useful_segments": [[0, 4]]}])
    long = compute_duration_evidence(GUITAR)
    assert short["feasible_band_seconds"][1] != long["feasible_band_seconds"][1]

# ---- engine ----
def _rec(**over):
    r = {"recommended_range_seconds": [55, 75], "highlights_range_seconds": [15, 25],
         "feasible_ceiling_seconds": 137.2, "rationale": "payoff needs room", "payoff_breathing": True}
    r.update(over); return r

def test_engine_clamps_to_ceiling():
    # model over-recommends beyond the material ceiling -> clamped
    ev = compute_duration_evidence([{"id": "e", "duration_seconds": 20, "useful_segments": [[0, 10]]}])  # ceil 10
    eng = RealDurationPlannerEngine(FakeModelGateway(response=_rec(recommended_range_seconds=[30, 40],
                                                                   highlights_range_seconds=[12, 18],
                                                                   feasible_ceiling_seconds=40)))
    out = eng.recommend(DurationPlannerInputs(creative_intent={}, evidence=ev))
    assert max(out["recommended_range_seconds"]) <= 10.0
    assert out["feasible_ceiling_seconds"] <= 10.0

def test_engine_passes_scope():
    eng = RealDurationPlannerEngine(FakeModelGateway(response=_rec()))
    out = eng.recommend(DurationPlannerInputs(creative_intent={}, evidence=compute_duration_evidence(GUITAR),
                                              requested_scope="highlights"))
    assert out["recommended_range_seconds"]  # returns a recommendation

# ---- endpoint ----
def _client(engine):
    app = create_app()
    app.dependency_overrides[get_duration_planner_engine] = lambda: engine
    return TestClient(app)

def _body(**over):
    b = {"creative_intent": {}, "moments": GUITAR, "story_guide": {"framing_summary": "learning to play"}}
    b.update(over); return b

def test_endpoint_returns_evidence_and_recommendation():
    c = _client(RealDurationPlannerEngine(FakeModelGateway(response=_rec())))
    r = c.post("/v1/duration-recommendation", json=_body())
    assert r.status_code == 200
    d = r.json()
    assert d["evidence"]["longest_continuous_span_seconds"] == 39.3
    assert d["recommendation"]["recommended_range_seconds"]
    assert d["explicit_target_seconds"] is None

def test_endpoint_explicit_duration_precedence_echoed():
    c = _client(RealDurationPlannerEngine(FakeModelGateway(response=_rec())))
    r = c.post("/v1/duration-recommendation", json=_body(creative_intent={"target_duration_seconds": 42.0}))
    assert r.json()["explicit_target_seconds"] == 42.0

def test_endpoint_model_failure_still_200_with_evidence():
    c = _client(RealDurationPlannerEngine(FakeModelGateway(error=ProviderError("down"))))
    r = c.post("/v1/duration-recommendation", json=_body())
    assert r.status_code == 200  # NOT a hard failure
    d = r.json()
    assert d["recommendation"] is None and d["evidence"]["n_moments"] == 2
    assert "manual" in d["note"]

def test_endpoint_zero_material_recovery():
    c = _client(RealDurationPlannerEngine(FakeModelGateway(response=_rec())))
    r = c.post("/v1/duration-recommendation", json=_body(moments=[{"id": "z", "duration_seconds": 0, "useful_segments": []}]))
    d = r.json()
    assert d["recommendation"] is None and "keep shooting" in d["note"]
