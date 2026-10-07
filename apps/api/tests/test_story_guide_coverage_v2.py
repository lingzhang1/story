"""E2-c backend tests: StoryGuide engine, Coverage/2 Mapper + Judge evidence firewall + composition."""
from __future__ import annotations

import sys
from pathlib import Path
from uuid import uuid4

import pytest

_ROOT = Path(__file__).resolve().parents[3]
for rel in (".", "packages", "apps/api"):
    p = str((_ROOT / rel).resolve())
    if p not in sys.path:
        sys.path.insert(0, p)

from model_gateway import FakeModelGateway, StructuredOutputError
from story_guide import RealStoryGuideEngine, MockStoryGuideEngine, GuideInput, GuideUnavailableError
from story_coverage_v2 import (
    RealStoryCoverageMapper, RealStoryJudgmentEngine, CoverageV2Input, CoverageUnavailableError,
    build_judge_evidence, assert_no_guide_leakage, material_scope, compose,
)
from contracts.schemas.ai_contracts import StoryGuideContract, StoryCoverageContractV2, CoverageMapping


# --- StoryGuide engine ------------------------------------------------------
def _guide_resp():
    return {"framing_summary": "For this Story: scale and stillness.", "dimensions": [
        {"id": "d1", "label": "Scale", "purpose": "make the mountains feel enormous",
         "capture_possibilities": [{"id": "d1p1", "label": "person beneath huge mountains"},
                                   {"id": "d1p2", "label": "wide landscape"}]},
        {"id": "d2", "label": "Stillness", "purpose": "hold the quiet", "capture_possibilities": []}]}


def test_guide_generation_mints_canonical_ids_over_model_ordinals():
    eng = RealStoryGuideEngine(FakeModelGateway(response=_guide_resp()))
    g = eng.generate(GuideInput(story_id=uuid4(), creative_intent={"summary": "x"}, scope={"target_duration_seconds": 30}))
    assert isinstance(g, StoryGuideContract)
    assert [d.id for d in g.dimensions] == ["dim_01", "dim_02"]          # model d1/d2 -> canonical
    assert g.dimensions[0].capture_possibilities[0].id == "dim_01_cp_01"  # model d1p1 -> canonical
    assert g.dimensions[1].capture_possibilities == []                   # zero-possibility dim allowed
    assert g.schema_version == "story_guide/1"


def test_guide_supports_zero_moment_story():
    eng = RealStoryGuideEngine(FakeModelGateway(response=_guide_resp()))
    g = eng.generate(GuideInput(story_id=uuid4(), creative_intent={"summary": "new story"}, scope={}))
    assert len(g.dimensions) == 2  # Guide needs NO MomentUnderstanding


def test_guide_failure_raises_and_does_not_fabricate():
    eng = RealStoryGuideEngine(FakeModelGateway(error=StructuredOutputError("no tool")))
    with pytest.raises(GuideUnavailableError):
        eng.generate(GuideInput(story_id=uuid4(), creative_intent={}, scope={}))


def test_mock_guide_is_deterministic_not_production():
    g = MockStoryGuideEngine().generate(GuideInput(story_id=uuid4(), creative_intent={}, scope={}))
    assert g.dimensions[0].id == "dim_01"


# --- Mapper -----------------------------------------------------------------
def _guide_dict():
    return {"story_id": "guide-1", "framing_summary": "x", "dimensions": [
        {"id": "dim_01", "label": "Scale", "purpose": "enormous",
         "capture_possibilities": [{"id": "dim_01_cp_01", "label": "person beneath mountains"}]}]}


def test_mapper_never_invents_dimensions_and_remaps_evidence():
    mid = str(uuid4())
    resp = {"dimension_coverage": [{"story_guide_dimension_id": "dim_01", "state": "strong",
            "evidence_moment_ids": [mid, "bogus"], "represented_possibility_ids": ["dim_01_cp_01", "nope"]}],
            "strengths": ["a storm"], "redundancies": []}
    mapper = RealStoryCoverageMapper(FakeModelGateway(response=resp))
    inp = CoverageV2Input(story_id=uuid4(), story_guide=_guide_dict(), creative_intent={}, scope={},
                          moment_understandings=[{"moment_id": mid, "observed": {"summary": "big wall"}}])
    mapping, gids = mapper.map(inp)
    assert gids == ["dim_01"]
    dc = mapping.dimension_coverage[0]
    assert dc.state.value == "strong"
    assert [str(x) for x in dc.evidence_moment_ids] == [mid]          # bogus dropped
    assert dc.represented_possibility_ids == ["dim_01_cp_01"]          # unknown possibility dropped
    assert mapping.strengths == ["a storm"]


# --- Evidence builder + information firewall (load-bearing) -----------------
def test_material_scope_is_deterministic_from_useful_segments():
    inp = CoverageV2Input(story_id=uuid4(), story_guide=_guide_dict(), creative_intent={},
        scope={"target_duration_seconds": 40}, moment_understandings=[
            {"moment_id": str(uuid4()), "observed": {"useful_segments": [
                {"t_start_s": 0, "t_end_s": 12.0, "why_useful": "x"},
                {"t_start_s": 20, "t_end_s": 25.5, "why_useful": "y"}]}},
            {"moment_id": str(uuid4()), "observed": {"useful_segments": []}}])
    ms = material_scope(inp)
    assert ms.understood_moment_count == 2
    assert ms.useful_moment_count == 1
    assert ms.total_useful_segment_duration_seconds == 17.5
    assert ms.target_output_duration_seconds == 40


def test_judge_evidence_contains_no_guide_signal():
    inp = CoverageV2Input(story_id=uuid4(), story_guide=_guide_dict(), creative_intent={"summary": "s"},
        scope={"target_duration_seconds": 30}, moment_understandings=[
            {"moment_id": str(uuid4()), "observed": {"useful_segments": [{"t_start_s": 0, "t_end_s": 10, "why_useful": "z"}]}}])
    mapping = CoverageMapping(dimension_coverage=[], strengths=["strong scale material"], redundancies=["two similar panoramas"])
    ev = build_judge_evidence(inp, mapping)
    assert set(ev.keys()) == {"creative_intent", "scope", "positive_actual_story_evidence",
                              "material_scope_evidence", "redundancy", "pending_count"}
    import json
    blob = json.dumps(ev).lower()
    for forbidden in ("dimension_coverage", "could_use_more", "capture_possib", "story_guide_dimension_id"):
        assert forbidden not in blob


def test_firewall_rejects_leaked_guide_keys():
    with pytest.raises(CoverageUnavailableError):
        assert_no_guide_leakage({"creative_intent": {}, "dimension_coverage": []})
    with pytest.raises(CoverageUnavailableError):
        assert_no_guide_leakage({"positive_actual_story_evidence": ["this dim could_use_more work"]})


# --- Judge + composition ----------------------------------------------------
def test_judge_and_compose_build_valid_v2():
    jresp = {"sufficiency": {"status": "sufficient", "reason": "enough for 8s"},
             "story_idea": {"title": "A moment of stillness", "description": "one sentence",
                            "rationale": "rich internal", "target_story_guide_dimension_id": None}}
    judge = RealStoryJudgmentEngine(FakeModelGateway(response=jresp))
    j = judge.judge({"creative_intent": {}, "scope": {}, "positive_actual_story_evidence": [],
                     "material_scope_evidence": {}, "redundancy": [], "pending_count": 0})
    assert j.sufficiency.status.value == "sufficient"
    assert j.story_idea.title == "A moment of stillness"
    mid = str(uuid4())
    inp = CoverageV2Input(story_id=uuid4(), story_guide=_guide_dict(), creative_intent={}, scope={},
                          moment_understandings=[{"moment_id": mid, "observed": {}}])
    mapping = CoverageMapping(dimension_coverage=[], strengths=["s"], redundancies=[])
    cov = compose(inp, mapping, j)
    assert isinstance(cov, StoryCoverageContractV2)
    assert cov.schema_version == "story_coverage/2"
    assert cov.sufficiency.status.value == "sufficient"          # independent of idea
    assert cov.story_idea is not None                            # sufficient + idea is VALID
    assert [str(x) for x in cov.source_understanding_ids] == [mid]
