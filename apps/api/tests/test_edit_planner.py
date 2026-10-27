"""Edit Planner engine + endpoint + deterministic-validator tests (Milestone M-d, frozen edit_plan/2).

No real model is invoked — a FakeModelGateway returns preset plans. Exercises: a valid plan -> EditPlanV2Contract;
a non-executable plan -> rejected (never reaches the client); infeasible material -> structured failure; the
no-music path; and the endpoint's 200 / 503 / 422 behavior.
"""
from __future__ import annotations

import json
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.deps import get_edit_planner_engine
from app.main import create_app
from edit_planner import (
    EditPlanInputs,
    EditPlanInfeasibleError,
    MockEditPlannerEngine,
    RealEditPlannerEngine,
    validate_plan,
)
from model_gateway import FakeModelGateway, ProviderError, StructuredOutputError

M1 = str(uuid4())
M2 = str(uuid4())


def _inputs(music=False, **over):
    base = dict(
        story_id=str(uuid4()), creative_intent_id=str(uuid4()),
        creative_intent={"target_duration_seconds": 18.0, "desired_feeling": ["calm"]},
        story_guide={"framing_summary": "a quiet mood"},
        story_coverage={"sufficiency": "sufficient"},
        moments=[
            {"id": M1, "duration_seconds": 11.0, "useful_segments": [[1.0, 9.0]], "summary": "steam on a sill"},
            {"id": M2, "duration_seconds": 8.0, "useful_segments": [[0.5, 6.0]], "summary": "hands on mug"},
        ],
        music_plan={"character": {"mood_tags": ["calm"], "energy": "low"},
                    "audio_strategy": {"soundtrack_role": "sparse", "native_audio_priority": "selective"}},
    )
    if music:
        base["music_analysis"] = {"duration_seconds": 20.0, "bpm": 60.0, "beats": [0.0, 1.0], "downbeats": [0.0]}
        base["music_asset_id"] = "epidemic:track-abc"
    base.update(over)
    return EditPlanInputs(**base)


def _good_plan():
    return {"target_duration_seconds": 18.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 1.0, "source_end_seconds": 9.0,
         "output_duration_seconds": 10.0, "native_audio": "keep", "narrative_role": "opening stillness"},
        {"order": 1, "asset_id": M2, "source_start_seconds": 0.5, "source_end_seconds": 6.0,
         "output_duration_seconds": 5.5, "native_audio": "keep", "narrative_role": "intimate detail"},
    ]}


def test_engine_valid_plan_to_contract():
    eng = RealEditPlannerEngine(FakeModelGateway(response=_good_plan()))
    plan = eng.generate(_inputs())
    assert plan.schema_version == "edit_plan/2"
    assert len(plan.segments) == 2
    assert str(plan.segments[0].asset_id) == M1
    assert plan.segments[0].native_audio.value == "keep"


def test_engine_rejects_non_executable_plan_invented_moment():
    bad = _good_plan()
    bad["segments"][0]["asset_id"] = str(uuid4())  # not a known Moment
    eng = RealEditPlannerEngine(FakeModelGateway(response=bad))
    with pytest.raises(StructuredOutputError):  # validation failure -> never fabricate / never pass on
        eng.generate(_inputs())


def test_engine_rejects_anchor_without_analysis():
    bad = _good_plan()
    bad["segments"][0]["music_alignment"] = {"anchor": "downbeat"}
    eng = RealEditPlannerEngine(FakeModelGateway(response=bad))
    with pytest.raises(StructuredOutputError):
        eng.generate(_inputs(music=False))


def test_engine_infeasible_raises():
    # OWNER POLICY (2026-10-25): length/shortness is NEVER a block. The ONLY terminal infeasible is a
    # feasible=false with NO playable cut at all (empty / unrenderable). A feasible=false WITH a valid
    # (even short) cut now ships — see test_engine_feasible_false_short_cut_still_ships.
    plan = {"target_duration_seconds": 18.0, "feasible": False, "infeasible_reason": "no usable footage at all",
            "segments": []}
    eng = RealEditPlannerEngine(FakeModelGateway(response=plan))
    with pytest.raises(EditPlanInfeasibleError):
        eng.generate(_inputs())


def test_engine_feasible_false_short_cut_still_ships():
    # A feasible=false whose cut is SHORT (8s vs 18s target) is still a PLAYABLE video -> it ships, no error.
    plan = {"target_duration_seconds": 18.0, "feasible": False, "infeasible_reason": "could not reach target",
            "segments": [{"order": 0, "asset_id": M1, "source_start_seconds": 1.0, "source_end_seconds": 9.0,
                          "output_duration_seconds": 8.0, "native_audio": "keep"}]}
    eng = RealEditPlannerEngine(FakeModelGateway(response=plan))
    out = eng.generate(_inputs())
    assert len(out.segments) == 1
    assert eng.last_diagnostics.get("feasible_false_overridden") is True


def test_engine_feasible_false_overshoot_still_ships():
    """OWNER POLICY regression: a model that declares feasible=false because it could not condense a rich
    Story DOWN to the target (the cut runs a bit LONG) must still SHIP its cut — never reject it. The
    screenshot bug: '...runs significantly longer than the requested duration' surfaced as material_infeasible.
    Here the cut totals 15.5s against a 12s target (+29% — a shippable overshoot WITHIN the +50% band that a
    feasible=true plan would also pass) but the model flagged feasible=false. It MUST ship, not raise.
    (A cut that genuinely busts the +50% overshoot band still fails the shared validator — that guard is
    unchanged; this only stops a self-declared infeasible from discarding an otherwise-valid cut.)"""
    plan = {"target_duration_seconds": 12.0, "feasible": False,
            "infeasible_reason": "the abundance of strong footage makes it hard to condense without losing atmosphere",
            "segments": [
                {"order": 0, "asset_id": M1, "source_start_seconds": 1.0, "source_end_seconds": 9.0,
                 "output_duration_seconds": 10.0, "native_audio": "keep"},
                {"order": 1, "asset_id": M2, "source_start_seconds": 0.5, "source_end_seconds": 6.0,
                 "output_duration_seconds": 5.5, "native_audio": "keep"}]}
    eng = RealEditPlannerEngine(FakeModelGateway(response=plan))
    out = eng.generate(_inputs(creative_intent={"target_duration_seconds": 12.0, "desired_feeling": ["calm"]}))
    assert out.schema_version == "edit_plan/2"
    assert len(out.segments) == 2
    assert eng.last_diagnostics.get("feasible_false_overridden") is True
    assert eng.last_diagnostics.get("final") == "executable"


def test_engine_feasible_false_empty_plan_still_rejects():
    """The genuine infeasible case stays terminal: feasible=false with NO usable cut to ship must raise
    (there is nothing to fall back to — not an overshoot)."""
    plan = {"target_duration_seconds": 18.0, "feasible": False,
            "infeasible_reason": "no usable footage at all", "segments": []}
    eng = RealEditPlannerEngine(FakeModelGateway(response=plan))
    with pytest.raises(EditPlanInfeasibleError):
        eng.generate(_inputs())


def test_engine_no_music_planning_supported():
    eng = RealEditPlannerEngine(FakeModelGateway(response=_good_plan()))
    plan = eng.generate(_inputs(music=False))  # no music_analysis
    assert plan.music_asset_id is None and len(plan.segments) == 2


def test_engine_with_music_carries_provenance():
    p = _good_plan()
    p["segments"][0]["music_alignment"] = {"anchor": "highlight"}
    eng = RealEditPlannerEngine(FakeModelGateway(response=p))
    plan = eng.generate(_inputs(music=True))
    assert plan.music_asset_id == "epidemic:track-abc"
    assert plan.segments[0].music_alignment.anchor.value == "highlight"


def test_mock_engine_produces_valid_contract():
    plan = MockEditPlannerEngine().generate(_inputs())
    assert plan.schema_version == "edit_plan/2" and plan.segments


def test_validator_catches_speed_inconsistency():
    bad = _good_plan()
    bad["segments"][0]["speed"] = 2.0  # 8s span @2x should be ~4s, but output says 10s
    errs = validate_plan(bad, _inputs())
    assert any("inconsistent" in e for e in errs)


# ---- never-block policy: source-range-outside-useful is EDITORIAL, not technical (P1-F dev regression) ----
def _plan_outside_useful():
    # A RENDERABLE plan whose seg0 source range [9.5,10.5] is within M1's duration (11s) + valid speed, but
    # overlaps NONE of M1's useful_segments ([1,9]). Technically playable; only an editorial miss.
    p = _good_plan()
    p["segments"][0]["source_start_seconds"] = 9.5
    p["segments"][0]["source_end_seconds"] = 10.5
    p["segments"][0]["output_duration_seconds"] = 1.0
    return p


def test_useful_range_hard_rejects_when_flag_off(monkeypatch):
    monkeypatch.delenv("STORY_EDITPLAN_USEFUL_RANGE_SOFT", raising=False)
    errs = validate_plan(_plan_outside_useful(), _inputs())
    assert any("overlaps NO useful_segment" in e for e in errs)   # strict (unchanged) behavior


def test_useful_range_soft_ships_renderable_plan_when_flag_on(monkeypatch):
    monkeypatch.setenv("STORY_EDITPLAN_USEFUL_RANGE_SOFT", "1")
    errs = validate_plan(_plan_outside_useful(), _inputs())
    # never-block: a playable range that merely misses useful_segments is NOT a hard error now.
    assert not any("useful_segment" in e for e in errs), errs
    # the HARD technical bounds still fire when genuinely violated (real-duration bound stays hard):
    over = _plan_outside_useful()
    over["segments"][0]["source_end_seconds"] = 99.0   # exceeds M1 duration 11s
    over["segments"][0]["output_duration_seconds"] = 1.0
    errs2 = validate_plan(over, _inputs())
    assert any("exceeds Moment duration" in e for e in errs2)


# ---- Part A: deterministic structural directive-placement repair ----
from edit_planner import repair_directive_placement, _errors_are_order_only  # noqa: E402


def _rev(directives):
    return {"mode": "revise", "directives": directives}


def test_structural_repair_fixes_opening_order_only():
    # Model produced two VALID segments but in the wrong order (M2 first); directive requires M1 opening.
    # Reorder whole segments (content stays valid) so the ONLY error is placement.
    gp = _good_plan()
    s_m1, s_m2 = gp["segments"][0], gp["segments"][1]
    bad = {**gp, "segments": [{**s_m2, "order": 0}, {**s_m1, "order": 1}]}
    inp = _inputs(revision_context=_rev({"opening": M1}))
    errs = validate_plan(bad, inp)
    assert errs and _errors_are_order_only(errs)
    fixed = repair_directive_placement(bad, inp)
    assert fixed is not None and validate_plan(fixed, inp) == []
    assert str(fixed["segments"][0]["asset_id"]).lower() == M1.lower()
    key = lambda p: sorted((str(s["asset_id"]).lower(), s["source_start_seconds"], s["source_end_seconds"],
                            s["output_duration_seconds"]) for s in p["segments"])
    assert key(bad) == key(fixed)


def test_structural_repair_opening_plus_adjacency():
    bad = _good_plan()  # M1 then M2
    # require M2 opening AND M1 immediately after M2 -> reorder must produce [M2, M1]
    inp = _inputs(revision_context=_rev({"opening": M2, "order_adjacent": [[M1, M2]]}))
    errs = validate_plan(bad, inp)
    assert errs and _errors_are_order_only(errs)
    fixed = repair_directive_placement(bad, inp)
    assert fixed is not None and validate_plan(fixed, inp) == []
    order = [str(s["asset_id"]).lower() for s in fixed["segments"]]
    assert order == [M2.lower(), M1.lower()]


def test_structural_repair_preserves_transition_and_music_alignment():
    # A reorder must carry per-segment transition + music_alignment WITH the segment (not positionally).
    gp = _good_plan()
    s_m1 = {**gp["segments"][0], "music_alignment": {"anchor": "highlight"}}   # M1 segment owns the alignment
    s_m2 = {**gp["segments"][1], "transition": {"type": "crossfade", "duration_seconds": 1.0}}
    bad = {**gp, "segments": [{**s_m2, "order": 0}, {**s_m1, "order": 1}]}     # M2 first; directive wants M1 open
    inp = _inputs(music=True, revision_context=_rev({"opening": M1}))
    fixed = repair_directive_placement(bad, inp)
    assert fixed is not None and validate_plan(fixed, inp) == []
    m1seg = next(s for s in fixed["segments"] if str(s["asset_id"]).lower() == M1.lower())
    assert m1seg.get("music_alignment", {}).get("anchor") == "highlight"


def test_structural_repair_none_when_opening_absent():
    # opening references a Moment not in the plan -> membership issue, not reorderable.
    bad = _good_plan()
    inp = _inputs(revision_context=_rev({"opening": str(uuid4())}))
    assert not _errors_are_order_only(validate_plan(bad, inp))   # ref-ineligible is NOT order-only
    assert repair_directive_placement(bad, inp) is None


def test_structural_repair_none_on_cyclic_order():
    bad = _good_plan()
    inp = _inputs(revision_context=_rev({"order_after": [[M1, M2], [M2, M1]]}))
    assert repair_directive_placement(bad, inp) is None


def test_must_include_absent_is_not_order_only():
    # must_include of a Moment that appears in no segment is a membership error the reorder must NOT claim.
    errs = ["directive must_include: Moment 'x' is required but appears in no segment"]
    assert _errors_are_order_only(errs) is False


def test_engine_structural_repair_end_to_end_no_model_repair():
    # The model returns a plan with the WRONG opening; the engine's deterministic pass fixes it WITHOUT a
    # second (repair) model call. FakeModelGateway returns the same response each call, so if the engine had
    # to model-repair, the opening would stay wrong and generate() would raise. Success proves the reorder ran.
    bad = _good_plan()
    s_m1, s_m2 = bad["segments"][0], bad["segments"][1]
    bad = {**bad, "segments": [{**s_m2, "order": 0}, {**s_m1, "order": 1}]}   # M2 first; directive wants M1 open
    eng = RealEditPlannerEngine(FakeModelGateway(response=bad))
    plan = eng.generate(_inputs(revision_context=_rev({"opening": M1})))
    assert str(plan.segments[0].asset_id).lower() == M1.lower()
    assert getattr(eng, "last_diagnostics", {}).get("structural_repair") is True


# ---- endpoint ----
def _client(engine):
    app = create_app()
    app.dependency_overrides[get_edit_planner_engine] = lambda: engine
    return TestClient(app)


def _req_body(music=False):
    i = _inputs(music=music)
    body = {
        "story_id": i.story_id, "creative_intent_id": i.creative_intent_id,
        "creative_intent": i.creative_intent, "story_guide": i.story_guide,
        "story_coverage": i.story_coverage, "moments": i.moments, "music_plan": i.music_plan,
    }
    if music:
        body["music_analysis"] = i.music_analysis
        body["music_asset_id"] = i.music_asset_id
    return body


def test_endpoint_success():
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    r = client.post("/v1/edit-plan", json=_req_body())
    assert r.status_code == 200, r.text
    assert r.json()["schema_version"] == "edit_plan/2"


def test_endpoint_503_on_provider_error():
    client = _client(RealEditPlannerEngine(FakeModelGateway(error=ProviderError("throttled"))))
    r = client.post("/v1/edit-plan", json=_req_body())
    assert r.status_code == 503


def test_endpoint_422_on_infeasible():
    # Only a feasible=false with NO playable cut (empty) is a 422 now; a short/long cut ships (200).
    plan = {"target_duration_seconds": 18.0, "feasible": False, "infeasible_reason": "no usable footage",
            "segments": []}
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=plan)))
    r = client.post("/v1/edit-plan", json=_req_body())
    assert r.status_code == 422
    assert "infeasible" in r.json()["detail"].lower()


# ===========================================================================
# R-c executability-repair + deterministic normalization + error semantics.
# A SeqGateway returns a scripted sequence of plans so we can exercise the
# repair loop without a live model. No real model is invoked.
# ===========================================================================
from edit_planner import (  # noqa: E402
    MalformedPlanError, normalize_plan, timeline_total_seconds, validate_plan as _vp,
)
from model_gateway import StructuredResult, Usage  # noqa: E402


class SeqGateway:
    """Returns plans[0], plans[1], ... on successive calls (clamps at the last)."""
    def __init__(self, plans):
        self.plans = plans
        self.calls = 0

    def generate_structured(self, req):
        import json as _j
        p = self.plans[min(self.calls, len(self.plans) - 1)]
        self.calls += 1
        return StructuredResult(data=_j.loads(_j.dumps(p)), usage=Usage(100, 40, 140),
                                attempts=1, model="fake", provider="fake")


def _target12_inputs(**over):
    base = dict(
        story_id=str(uuid4()), creative_intent_id=str(uuid4()),
        creative_intent={"target_duration_seconds": 12.0},
        story_guide={}, story_coverage={},
        moments=[
            {"id": M1, "duration_seconds": 8.0, "useful_segments": [[0.0, 6.0]]},
            {"id": M2, "duration_seconds": 7.0, "useful_segments": [[0.0, 5.0]]},
        ],
        music_plan={})
    base.update(over)
    return EditPlanInputs(**base)


def _plan12(d0, d1, **seg_over):
    """Two-segment plan for the target-12 inputs; d0/d1 are output_duration_seconds."""
    s0 = {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 6.0,
          "output_duration_seconds": d0, "native_audio": "keep"}
    s1 = {"order": 1, "asset_id": M2, "source_start_seconds": 0.0, "source_end_seconds": 5.0,
          "output_duration_seconds": d1, "native_audio": "keep"}
    s0.update(seg_over.get("s0", {}))
    s1.update(seg_over.get("s1", {}))
    return {"target_duration_seconds": 12.0, "feasible": True, "segments": [s0, s1]}


# ---- duration is NEVER a blocking constraint (owner 2026-10-25) ----
def test_duration_is_never_a_blocking_constraint():
    # OWNER POLICY (2026-10-25): length is NEVER a reason to reject. A playable cut of ANY length validates —
    # big overshoot AND deep undershoot both pass validate_plan. (The former +50% / -20% bands are removed.)
    inp = _target12_inputs(moments=_target12_inputs().moments + [
        {"id": "M3", "duration_seconds": 9.0, "useful_segments": [[0.0, 7.5]]}])
    def plan3(d0, d1, d2):
        return {"target_duration_seconds": 12.0, "feasible": True, "segments": [
            {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": d0,
             "output_duration_seconds": d0, "native_audio": "keep"},
            {"order": 1, "asset_id": M2, "source_start_seconds": 0.0, "source_end_seconds": d1,
             "output_duration_seconds": d1, "native_audio": "keep"},
            {"order": 2, "asset_id": "M3", "source_start_seconds": 0.0, "source_end_seconds": d2,
             "output_duration_seconds": d2, "native_audio": "keep"}]}
    # +25% overshoot -> accepted.
    assert _vp(plan3(5.0, 5.0, 5.0), inp) == []
    # +50% -> accepted.
    assert _vp(plan3(6.0, 6.0, 6.0), inp) == []
    # +67% (big overshoot) -> ALSO accepted now (no upper band). Never block a long but playable video.
    assert _vp(plan3(7.0, 7.0, 6.0), inp) == []
    # -33% deep undershoot -> ALSO accepted now (no lower band). A short but playable video still ships.
    inp2 = _target12_inputs()
    short = {"target_duration_seconds": 12.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 4.0,
         "output_duration_seconds": 4.0, "native_audio": "keep"},
        {"order": 1, "asset_id": M2, "source_start_seconds": 0.0, "source_end_seconds": 4.0,
         "output_duration_seconds": 4.0, "native_audio": "keep"}]}
    assert _vp(short, inp2) == []
    # A technically UNRENDERABLE plan (speed out of range) STILL rejects — that is not a length constraint.
    bad = _plan12(6.0, 6.0, s0={"speed": 9.0})
    assert _vp(bad, _target12_inputs()) != []


def test_repro_failure2_speed_output_mismatch():
    # seg source span 7.5 @1.0x but output 2.5 — the second device failure.
    inp = _target12_inputs(moments=[{"id": M1, "duration_seconds": 9.0, "useful_segments": [[0.0, 7.5]]}])
    p = {"target_duration_seconds": 12.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 7.5,
         "output_duration_seconds": 2.5, "speed": 1.0, "native_audio": "keep"}]}
    errs = _vp(p, inp)
    assert any("inconsistent" in e for e in errs)


# ---- deterministic normalization: safe rounding only ----
def test_normalize_snaps_harmless_rounding():
    inp = _target12_inputs()
    # 6.03 for a 6.0 span @1.0 is within the snap window -> snapped to 6.0, no model needed.
    p = _plan12(6.03, 6.0)
    out, notes = normalize_plan(p, inp)
    assert out["segments"][0]["output_duration_seconds"] == 6.0
    assert notes and "snapped" in notes[0]
    assert not _vp(out, inp)  # now executable


def test_normalize_does_not_touch_large_mismatch():
    inp = _target12_inputs(moments=[{"id": M1, "duration_seconds": 9.0, "useful_segments": [[0.0, 7.5]]}])
    p = {"target_duration_seconds": 12.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 7.5,
         "output_duration_seconds": 2.5, "speed": 1.0, "native_audio": "keep"}]}
    out, notes = normalize_plan(p, inp)
    assert notes == []  # a 7.5->2.5 mismatch is NOT auto-corrected
    assert out["segments"][0]["output_duration_seconds"] == 2.5
    assert _vp(out, inp)  # still invalid -> must go to model repair


def test_normalize_never_changes_speed_or_range():
    inp = _target12_inputs()
    p = _plan12(6.03, 6.0, s0={"speed": 1.0})
    out, _ = normalize_plan(p, inp)
    s = out["segments"][0]
    assert s["source_start_seconds"] == 0.0 and s["source_end_seconds"] == 6.0 and s["speed"] == 1.0


# ---- the executability-repair loop ----
def test_valid_plan_accepted_without_repair():
    inp = _target12_inputs()
    eng = RealEditPlannerEngine(SeqGateway([_plan12(6.0, 6.0)]))
    plan = eng.generate(inp)
    assert len(plan.segments) == 2
    assert eng.last_diagnostics["first_pass_executable"] is True
    assert eng.last_diagnostics["model_calls"] == 1
    assert eng.last_diagnostics["repaired"] is False


def test_invalid_plan_repaired_successfully():
    inp = _target12_inputs()
    bad = _plan12(5.0, 5.0)         # 10s... actually within tol; make it clearly off:
    bad = _plan12(2.0, 2.0)         # 4s total vs 12 (>20% low) -> invalid
    good = _plan12(6.0, 6.0)        # 12s -> valid
    eng = RealEditPlannerEngine(SeqGateway([bad, good]))
    plan = eng.generate(inp)
    assert len(plan.segments) == 2
    assert eng.last_diagnostics["first_pass_executable"] is False
    assert eng.last_diagnostics["executability_repairs_used"] == 1
    assert eng.last_diagnostics["model_calls"] == 2
    assert eng.last_diagnostics["final"] == "executable"


def test_repair_still_invalid_raises_structured_failure():
    inp = _target12_inputs()
    bad = _plan12(2.0, 2.0)
    eng = RealEditPlannerEngine(SeqGateway([bad, bad]))
    with pytest.raises(StructuredOutputError):
        eng.generate(inp)
    assert eng.last_diagnostics["final"] == "invalid_after_repair"
    assert eng.last_diagnostics["model_calls"] == 2  # one initial + one repair, bounded


def test_repair_bounded_no_duplicate_loops():
    inp = _target12_inputs()
    eng = RealEditPlannerEngine(SeqGateway([_plan12(2.0, 2.0), _plan12(2.0, 2.0), _plan12(6.0, 6.0)]))
    with pytest.raises(StructuredOutputError):
        eng.generate(inp)
    # exactly 1 initial + 1 repair; never consumes the 3rd scripted plan.
    assert eng.last_diagnostics["model_calls"] == 2


def test_repair_preserves_no_invented_moments():
    inp = _target12_inputs()
    bad = _plan12(6.0, 6.0, s0={"asset_id": str(uuid4())})  # invented id
    eng = RealEditPlannerEngine(SeqGateway([bad, bad]))
    with pytest.raises(StructuredOutputError):
        eng.generate(inp)  # invented moment never passes


# ---- duration accounting with dissolves (crossfade overlap) ----
def test_total_accounts_for_crossfade_overlap():
    segs = [
        {"output_duration_seconds": 6.0},
        {"output_duration_seconds": 6.0, "transition": {"type": "crossfade", "duration_seconds": 0.3}},
    ]
    # raw 12.0 minus 0.3 overlap = 11.7
    assert abs(timeline_total_seconds(segs) - 11.7) < 1e-9
    # fade_in does NOT shorten the timeline
    segs2 = [{"output_duration_seconds": 6.0, "transition": {"type": "fade_in", "duration_seconds": 0.3}}]
    assert abs(timeline_total_seconds(segs2) - 6.0) < 1e-9


def test_crossfade_plan_within_tolerance_valid():
    inp = _target12_inputs()
    # 6.6 + 6.6 - 0.6 overlap = 12.6 (within 20% of 12) and each output == span -> executable
    p = _plan12(6.6, 6.6,
                s0={"source_end_seconds": 6.0, "source_start_seconds": 0.0},
                s1={"source_end_seconds": 5.0, "source_start_seconds": 0.0,
                    "transition": {"type": "crossfade", "duration_seconds": 0.6}})
    # make outputs match spans exactly to isolate the total check
    p["segments"][0]["output_duration_seconds"] = 6.0
    p["segments"][1]["output_duration_seconds"] = 6.0
    errs = _vp(p, inp)
    assert not any("off target" in e for e in errs)


# ---- native-audio + music-alignment semantics unchanged ----
def test_native_audio_semantics_unchanged():
    inp = _target12_inputs()
    for na in ("keep", "duck", "mute"):
        p = _plan12(6.0, 6.0, s0={"native_audio": na})
        assert not any("native_audio" in e for e in _vp(p, inp))
    bad = _plan12(6.0, 6.0, s0={"native_audio": "loud"})
    assert any("native_audio" in e for e in _vp(bad, inp))


def test_music_alignment_without_analysis_still_rejected():
    inp = _target12_inputs()
    p = _plan12(6.0, 6.0, s0={"music_alignment": {"anchor": "downbeat"}})
    assert any("music_alignment" in e for e in _vp(p, inp))


# ---- malformed useful_segments -> clean 422 at the endpoint (no 500) ----
def test_endpoint_422_on_malformed_useful_segments():
    client = _client(RealEditPlannerEngine(SeqGateway([_plan12(6.0, 6.0)])))
    body = _req_body()
    # dict-shaped junk that the OLD validator crashed on (KeyError -> 500)
    body["moments"][0]["useful_segments"] = ["garbage"]
    r = client.post("/v1/edit-plan", json=body)
    assert r.status_code == 422, r.text
    assert "malformed" in r.json()["detail"].lower()


def test_endpoint_dict_useful_segments_tolerated():
    client = _client(RealEditPlannerEngine(SeqGateway([_plan12(6.0, 6.0)])))
    i = _target12_inputs()
    body = {"story_id": i.story_id, "creative_intent_id": i.creative_intent_id,
            "creative_intent": i.creative_intent, "story_guide": i.story_guide,
            "story_coverage": i.story_coverage,
            "moments": [dict(m) for m in i.moments], "music_plan": i.music_plan}
    body["moments"][0]["useful_segments"] = [{"start": 0.0, "end": 6.0}]  # dict shape read defensively
    r = client.post("/v1/edit-plan", json=body)
    assert r.status_code == 200, r.text


def test_endpoint_503_distinct_from_malformed_and_infeasible():
    # model-invalid-after-repair -> 503 with the executability detail, not the generic outage text.
    inp_bad = _plan12(2.0, 2.0)
    client = _client(RealEditPlannerEngine(SeqGateway([inp_bad, inp_bad])))
    r = client.post("/v1/edit-plan", json=_req_body())
    assert r.status_code == 503
    assert "executable" in r.json()["detail"].lower()


def test_feasible_false_empty_segments_surfaces_infeasible_not_no_segments():
    """R-d.2 fix: a model that honestly declares feasible=false with a reason + empty segments must raise
    EditPlanInfeasibleError (surfacing the reason), NOT be mislabeled 'no segments' -> StructuredOutputError.
    This was the real cause of crowded-library ('21 Moments') failures showing a false 'temporarily unavailable'."""
    import sys, pathlib
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "packages"))
    from edit_planner import (EditPlanInputs, RealEditPlannerEngine, validate_plan,
                              EditPlanInfeasibleError)
    from model_gateway import FakeModelGateway, StructuredOutputError
    inp = EditPlanInputs(story_id="x", creative_intent_id="x",
                         creative_intent={"target_duration_seconds": 55.0}, story_guide={}, story_coverage={},
                         moments=[{"id": "a", "duration_seconds": 5, "useful_segments": [[0, 4]]}], music_plan={})
    plan = {"target_duration_seconds": 55.0, "segments": [], "feasible": False,
            "infeasible_reason": "too many Moments for this length"}
    assert validate_plan(plan, inp) == []            # no longer flagged 'no segments'
    eng = RealEditPlannerEngine(FakeModelGateway(response=plan), executability_repair_attempts=2)
    try:
        eng.generate(inp)
        assert False, "should raise infeasible"
    except EditPlanInfeasibleError as e:
        assert "too many Moments" in str(e)          # the real reason is surfaced
    except StructuredOutputError:
        assert False, "regressed: feasible=false mislabeled as no-segments"


def test_empty_segments_without_feasible_false_still_fails():
    """A truly empty plan (no feasible=false declaration) is STILL a 'no segments' error — the fix is narrow."""
    import sys, pathlib
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "packages"))
    from edit_planner import EditPlanInputs, validate_plan
    inp = EditPlanInputs(story_id="x", creative_intent_id="x",
                         creative_intent={"target_duration_seconds": 55.0}, story_guide={}, story_coverage={},
                         moments=[{"id": "a", "duration_seconds": 5, "useful_segments": [[0, 4]]}], music_plan={})
    assert "no segments" in validate_plan({"target_duration_seconds": 55.0, "segments": []}, inp)


def _infeasible_engine(reason="too many Moments for 55s"):
    from edit_planner import EditPlanInfeasibleError
    class E:
        last_diagnostics = {"model_calls": 3}
        def generate(self, inputs): raise EditPlanInfeasibleError(reason)
    return E()


def test_endpoint_material_insufficient_maps_422():
    """coverage < target -> genuine material infeasibility -> 422 (shorter-Story recovery is appropriate)."""
    from fastapi.testclient import TestClient
    from app.main import create_app
    from app.deps import get_edit_planner_engine
    app = create_app(); app.dependency_overrides[get_edit_planner_engine] = lambda: _infeasible_engine()
    c = TestClient(app)
    body = {"story_id": "00000000-0000-0000-0000-000000000001",
            "creative_intent_id": "00000000-0000-0000-0000-000000000002",
            "creative_intent": {"target_duration_seconds": 55.0},
            "moments": [{"id": "m1", "duration_seconds": 10, "useful_segments": [[0, 8]]}]}  # 8s << 55s
    r = c.post("/v1/edit-plan", json=body)
    assert r.status_code == 422 and "material" in r.json()["detail"]


def test_endpoint_sufficient_material_but_model_refused_maps_503_not_shorter():
    """coverage >= target but model declared infeasible = PLANNING DEFECT -> 503 (NOT a 422 shorter-Story)."""
    from fastapi.testclient import TestClient
    from app.main import create_app
    from app.deps import get_edit_planner_engine
    app = create_app(); app.dependency_overrides[get_edit_planner_engine] = lambda: _infeasible_engine()
    c = TestClient(app)
    # 21 short Moments, ~5s useful each = ~105s coverage >> 55s target: material is plenty.
    moms = [{"id": f"m{i}", "duration_seconds": 7, "useful_segments": [[0, 5]]} for i in range(21)]
    body = {"story_id": "00000000-0000-0000-0000-000000000001",
            "creative_intent_id": "00000000-0000-0000-0000-000000000002",
            "creative_intent": {"target_duration_seconds": 55.0}, "moments": moms}
    r = c.post("/v1/edit-plan", json=body)
    assert r.status_code == 503          # NOT 422 -> client won't be told to shorten a Story with ample footage
    assert "material" not in r.json()["detail"]


# ---- truncation escalation: stop_reason=max_tokens -> retry at the higher cap, then succeed ----
class _TruncThenOkGateway:
    """First call returns a truncated EMPTY plan (stop_reason=max_tokens); the escalated retry returns a
    valid plan. Records the max_tokens each call was issued with so we can assert the escalation happened."""
    def __init__(self, good_plan):
        self.good = good_plan
        self.caps_seen = []
        self.n = 0

    def generate_structured(self, req):
        import json as _j
        self.caps_seen.append(req.max_tokens)
        self.n += 1
        if self.n == 1:
            # truncated: feasible but empty segments, stopped at the cap
            return StructuredResult(data={"target_duration_seconds": 12.0, "feasible": True, "segments": []},
                                    usage=Usage(100, req.max_tokens, 100 + req.max_tokens),
                                    attempts=1, model="fake", provider="fake", stop_reason="max_tokens")
        return StructuredResult(data=_j.loads(_j.dumps(self.good)), usage=Usage(100, 300, 400),
                                attempts=1, model="fake", provider="fake", stop_reason="end_turn")


def test_truncation_escalates_max_tokens_and_recovers():
    gw = _TruncThenOkGateway(_plan12(6.0, 6.0))
    eng = RealEditPlannerEngine(gw, max_tokens=2600, max_tokens_ceiling=16384)
    plan = eng.generate(_target12_inputs())
    assert len(plan.segments) == 2                      # recovered a valid plan
    assert gw.caps_seen[0] == 2600                       # first try at base cap
    assert gw.caps_seen[1] == 16384                      # escalated retry at the ceiling
    assert eng.last_diagnostics.get("truncation_escalations", 0) >= 1


def test_no_escalation_when_not_truncated():
    # a clean first result must NOT trigger a second (escalated) call
    gw = _TruncThenOkGateway(_plan12(6.0, 6.0)); gw.n = 1  # force "already past the truncation branch"
    gw2 = SeqGateway([_plan12(6.0, 6.0)])
    eng = RealEditPlannerEngine(gw2, max_tokens=8192, max_tokens_ceiling=16384)
    eng.generate(_target12_inputs())
    assert gw2.calls == 1                                # exactly one call, no escalation


# ===========================================================================
# MVP Multimodal Edit Planner — contact sheets + versioned creative brief.
# The frozen v5.2 SYSTEM body is never touched; images + brief ride the USER
# message / StructuredRequest.images. Text-only path stays byte-identical.
# ===========================================================================
from model_gateway import ImageInput  # noqa: E402


def test_engine_attaches_images_and_brief_to_request():
    gw = FakeModelGateway(response=_good_plan())
    eng = RealEditPlannerEngine(gw)
    inp = _inputs(images=[ImageInput(data=b"JPEGBYTES")],
                  creative_brief="Prioritize visually engaging footage.",
                  image_moment_order=[M1])
    eng.generate(inp)
    req = gw.calls[-1]
    assert len(req.images) == 1 and req.images[0].data == b"JPEGBYTES"
    assert "=== CREATIVE DIRECTION ===" in req.user_content
    assert "Prioritize visually engaging footage." in req.user_content
    assert f"in this order: {M1}" in req.user_content


def test_engine_text_only_request_has_no_images_or_brief():
    gw = FakeModelGateway(response=_good_plan())
    RealEditPlannerEngine(gw).generate(_inputs())  # no images / brief
    req = gw.calls[-1]
    assert req.images == []
    assert "CREATIVE DIRECTION" not in req.user_content
    assert "Contact-sheet images" not in req.user_content


def _mm_parts(music=False, moment_ids=None, brief=None):
    body = _req_body(music=music)
    ids = moment_ids if moment_ids is not None else [m["id"] for m in body["moments"][:1]]
    data = {"body": json.dumps(body), "sheet_order": json.dumps(ids)}
    if brief is not None:
        data["brief"] = brief
    return body, ids, data


def test_endpoint_mm_success_with_sheets():
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body, ids, data = _mm_parts()
    if "brief" in data:  # creative_brief is a separate form field named creative_brief
        data["creative_brief"] = data.pop("brief")
    files = [("sheets", (f"{mid}.jpg", b"\xff\xd8\xff" + b"x" * 50, "image/jpeg")) for mid in ids]
    r = client.post("/v1/edit-plan-mm", data=data, files=files)
    assert r.status_code == 200, r.text
    assert r.json()["schema_version"] == "edit_plan/2"


def test_endpoint_mm_text_only_fallback_no_sheets():
    # No sheets attached => the SAME frozen planning path, 200 (graceful text-only).
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body = _req_body()
    r = client.post("/v1/edit-plan-mm",
                    data={"body": json.dumps(body), "sheet_order": json.dumps([])})
    assert r.status_code == 200, r.text


def test_endpoint_mm_rejects_sheet_for_unknown_moment():
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body = _req_body()
    bad_id = str(uuid4())
    files = [("sheets", (f"{bad_id}.jpg", b"\xff\xd8\xffxx", "image/jpeg"))]
    r = client.post("/v1/edit-plan-mm",
                    data={"body": json.dumps(body), "sheet_order": json.dumps([bad_id])},
                    files=files)
    assert r.status_code == 422
    assert "unknown Moment id" in r.json()["detail"]


def test_endpoint_mm_rejects_order_count_mismatch():
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body = _req_body()
    files = [("sheets", (f"{M1}.jpg", b"\xff\xd8\xffxx", "image/jpeg"))]
    r = client.post("/v1/edit-plan-mm",
                    data={"body": json.dumps(body), "sheet_order": json.dumps([M1, M2])},  # 2 ids, 1 sheet
                    files=files)
    assert r.status_code == 422


# ---- 422 DIAGNOSTICS: every multimodal rejection logs edit_plan_mm_rejected with a stable reject_reason ----
# so a device fallback is never a silent mystery — the next device run's CloudWatch names the exact branch.
def test_mm_rejection_logs_reason_unknown_moment(caplog):
    import logging
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body = _req_body()
    bad_id = str(uuid4())
    files = [("sheets", (f"{bad_id}.jpg", b"\xff\xd8\xffxx", "image/jpeg"))]
    with caplog.at_level(logging.WARNING):
        r = client.post("/v1/edit-plan-mm",
                        data={"body": json.dumps(body), "sheet_order": json.dumps([bad_id])},
                        files=files)
    assert r.status_code == 422
    rec = next((x for x in caplog.records if getattr(x, "message", "") == "edit_plan_mm_rejected"
                or x.getMessage() == "edit_plan_mm_rejected"), None)
    assert rec is not None, "expected an edit_plan_mm_rejected diagnostic log"
    assert getattr(rec, "reject_reason", None) == "unknown_moment_id"
    assert getattr(rec, "http_status", None) == 422
    assert getattr(rec, "sheet_part_count", None) == 1
    assert getattr(rec, "sheet_order_len", None) == 1
    # The verbatim detail is logged (truncated) so the client-facing reason is reconstructable from the log.
    assert "unknown Moment id" in getattr(rec, "detail", "")
    # A sample of KNOWN ids is logged (never the images) so an id-mismatch is diagnosable from the log alone.
    assert isinstance(getattr(rec, "known_ids_sample", None), list)


def test_mm_rejection_logs_reason_count_mismatch(caplog):
    import logging
    client = _client(RealEditPlannerEngine(FakeModelGateway(response=_good_plan())))
    body = _req_body()
    files = [("sheets", (f"{M1}.jpg", b"\xff\xd8\xffxx", "image/jpeg"))]
    with caplog.at_level(logging.WARNING):
        r = client.post("/v1/edit-plan-mm",
                        data={"body": json.dumps(body), "sheet_order": json.dumps([M1, M2])},
                        files=files)
    assert r.status_code == 422
    rec = next((x for x in caplog.records if x.getMessage() == "edit_plan_mm_rejected"), None)
    assert rec is not None
    assert getattr(rec, "reject_reason", None) == "order_sheet_count_mismatch"
    assert getattr(rec, "sheet_part_count", None) == 1
    assert getattr(rec, "sheet_order_len", None) == 2


# ---- Phase-6 / Arm D: bounded critique -> revision pass (flag-gated) --------------------------------------
def _crit(text="hook is weak; lead with M2's expressive moment"):
    return {"critique": text}


def test_critique_applied_when_revision_valid():
    # plan -> critique -> VALID revised plan: the revision is adopted (final plan = revised).
    orig = _plan12(6.0, 6.0)
    revised = _plan12(6.0, 6.0, )  # structurally valid, different enough to represent a revision
    revised = json.loads(json.dumps(revised)); revised["segments"][0]["source_start_seconds"] = 0.0
    eng = RealEditPlannerEngine(SeqGateway([orig, _crit(), revised]))
    inp = _target12_inputs(creative_brief="Make a punchy short-form edit.", critique_revision=True)
    plan = eng.generate(inp)
    d = eng.last_diagnostics
    assert d.get("critique_attempted") is True
    assert d.get("critique_applied") is True
    assert d.get("model_calls") == 3   # plan + critique + revise
    assert plan.feasible


def test_critique_retains_original_when_revision_invalid():
    # plan (valid) -> critique -> INVALID revised plan: keep the original valid plan, never fail the Story.
    orig = _plan12(6.0, 6.0)
    bad_rev = _plan12(6.0, 6.0); bad_rev = json.loads(json.dumps(bad_rev))
    bad_rev["segments"][0]["output_duration_seconds"] = 99.0   # breaks duration-consistency -> invalid
    eng = RealEditPlannerEngine(SeqGateway([orig, _crit(), bad_rev]))
    inp = _target12_inputs(creative_brief="brief", critique_revision=True)
    plan = eng.generate(inp)                 # must still succeed (original retained)
    d = eng.last_diagnostics
    assert d.get("critique_applied") is False
    assert d.get("critique_rejected_reason") == "revision_invalid"
    assert plan.feasible


def test_critique_skipped_without_brief():
    # critique requires a brief to critique against; no brief => no critique pass (single model call).
    eng = RealEditPlannerEngine(SeqGateway([_plan12(6.0, 6.0)]))
    inp = _target12_inputs(critique_revision=True)   # brief omitted
    eng.generate(inp)
    d = eng.last_diagnostics
    assert d.get("critique_attempted") in (None, False)
    assert d.get("model_calls") == 1


def test_critique_off_by_default():
    # flag not set => never attempts a critique even with a brief.
    eng = RealEditPlannerEngine(SeqGateway([_plan12(6.0, 6.0)]))
    inp = _target12_inputs(creative_brief="brief")   # critique_revision defaults False
    eng.generate(inp)
    assert eng.last_diagnostics.get("critique_attempted") in (None, False)
    assert eng.last_diagnostics.get("model_calls") == 1


# ---------------------------------------------------------------------------
# Creative Revision Foundation — revision_context (additive; USER-message only).
# ---------------------------------------------------------------------------
from edit_planner import _build_user, _revision_context_block, diversity_diagnostics  # noqa: E402


def test_revision_context_absent_user_message_unchanged():
    """When revision_context is None, the USER message carries NO version-context block (behavior unchanged)."""
    msg = _build_user(_inputs())
    assert "VERSION CONTEXT" not in msg


def test_revision_context_explore_injects_objective_and_summaries():
    ctx = {"mode": "explore", "base_version_id": "v-parent",
           "prior_edit_summaries": [{"version_id": "v-parent", "segments": [{"asset_id": M1}, {"asset_id": M2}]}]}
    msg = _build_user(_inputs(revision_context=ctx))
    assert "=== VERSION CONTEXT ===" in msg
    assert "base_version_id: v-parent" in msg
    assert "MEANINGFULLY DIFFERENT" in msg          # explicit alternative-edit objective
    assert "v-parent" in msg                         # the prior summary is present
    # frozen system body is untouched: the block lives only in the user message
    assert "VERSION CONTEXT" not in RealEditPlannerEngine(FakeModelGateway(response=_good_plan()))._system


def test_revision_context_history_is_bounded():
    many = [{"version_id": f"v{i}", "segments": [{"asset_id": M1}]} for i in range(10)]
    block = _revision_context_block({"mode": "explore", "prior_edit_summaries": many})
    # bounded to <= 4 summaries injected (defense-in-depth)
    assert block.count('"version_id"') <= 4


def test_revision_context_revise_carries_directives_and_soft():
    ctx = {"mode": "revise", "base_version_id": "v1",
           "soft_direction": "more cinematic",
           "directives": {"must_include": [M1], "exclude": [], "opening": M2}}
    block = _revision_context_block(ctx)
    assert "LATEST REVISE INTENT (soft): more cinematic" in block
    assert "HARD REQUIREMENT" in block
    assert f"MUST include a segment from each of these Moment ids: {M1}" in block
    assert f"the FIRST segment (order 0) MUST be Moment id {M2}" in block
    assert "LATEST request wins" in block


def test_diversity_diagnostics_identical_is_near_identical():
    parent = {"segments": [{"asset_id": M1}, {"asset_id": M2}]}
    new = {"segments": [{"asset_id": M1}, {"asset_id": M2}]}
    d = diversity_diagnostics(parent, new)
    assert d["moment_set_jaccard"] == 1.0
    assert d["near_identical"] is True
    assert d["opening_changed"] is False and d["order_changed"] is False


def test_diversity_diagnostics_reordered_detected():
    parent = {"segments": [{"asset_id": M1}, {"asset_id": M2}]}
    new = {"segments": [{"asset_id": M2}, {"asset_id": M1}]}   # same set, swapped opening/ending/order
    d = diversity_diagnostics(parent, new)
    assert d["moment_set_jaccard"] == 1.0
    assert d["opening_changed"] is True
    assert d["ending_changed"] is True
    assert d["order_changed"] is True
    assert d["near_identical"] is False


def test_diversity_diagnostics_different_set():
    M3 = str(uuid4())
    parent = {"segments": [{"asset_id": M1}, {"asset_id": M2}]}
    new = {"segments": [{"asset_id": M1}, {"asset_id": M3}]}
    d = diversity_diagnostics(parent, new)
    assert 0.0 < d["moment_set_jaccard"] < 1.0
    assert d["near_identical"] is False


def test_revision_context_in_request_fingerprint():
    """revision_context lives in the request body, so the canonical async fingerprint (body-hashed) already
    covers it — a changed revision_context => different fingerprint, with NO fingerprint-logic change."""
    from edit_plan_jobs import payload_fingerprint
    body_a = json.dumps({"story_id": "s", "revision_context": {"mode": "explore", "base_version_id": "v1"}})
    body_b = json.dumps({"story_id": "s", "revision_context": {"mode": "explore", "base_version_id": "v2"}})
    fp_a = payload_fingerprint(body_a, [], False, "storytelling", creative_brief=None, sheet_digests=[])
    fp_b = payload_fingerprint(body_b, [], False, "storytelling", creative_brief=None, sheet_digests=[])
    assert fp_a != fp_b
    # identical body => identical fingerprint (transport recovery resumes the same job)
    fp_a2 = payload_fingerprint(body_a, [], False, "storytelling", creative_brief=None, sheet_digests=[])
    assert fp_a == fp_a2


# ---------------------------------------------------------------------------
# P0 — EditPlan renderer capability: speed must be 0.5x–2.0x (MediaEngineV1 limit).
# Reject (not clamp) unsupported speeds so bounded repair can pick an executable alternative.
# ---------------------------------------------------------------------------
def _speed_plan(speed):
    """A single-segment plan whose output_duration is CONSISTENT with (span / speed), so the ONLY
    thing a validator can object to is the speed value itself — isolating the renderer-range gate."""
    span = 8.0  # M1 source [1,9]
    out = round(span / speed, 3) if (isinstance(speed, (int, float)) and speed and speed > 0) else 8.0
    return {"target_duration_seconds": 18.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 1.0, "source_end_seconds": 9.0,
         "speed": speed, "output_duration_seconds": out, "native_audio": "keep"},
    ]}


def _speed_errs(plan):
    return [e for e in validate_plan(plan, _inputs()) if "speed" in e]


def test_speed_0_5_accepted():
    assert _speed_errs(_speed_plan(0.5)) == []


def test_speed_1_0_accepted():
    assert _speed_errs(_speed_plan(1.0)) == []


def test_speed_2_0_accepted():
    assert _speed_errs(_speed_plan(2.0)) == []


def test_speed_0_49_rejected():
    errs = _speed_errs(_speed_plan(0.49))
    assert any("out of renderer-supported range" in e for e in errs)


def test_speed_4_0_rejected():
    # The exact hiking failure: 4.0x passes the schema (speed>0) but is unrenderable.
    errs = _speed_errs(_speed_plan(4.0))
    assert any("out of renderer-supported range" in e and "[0.5, 2.0]" in e for e in errs)


def test_speed_non_finite_rejected():
    for bad in (float("inf"), float("nan"), "fast"):
        errs = _speed_errs(_speed_plan(bad))
        assert any("finite number" in e for e in errs), f"did not reject speed={bad!r}"


def test_absent_speed_defaults_to_1x_accepted():
    # An omitted speed is the schema default (1.0) and must stay valid — no regression.
    plan = _speed_plan(1.0)
    plan["segments"][0].pop("speed")
    assert _speed_errs(plan) == []


def test_existing_valid_plans_unchanged():
    # The canonical good plan (no explicit speed) still passes the FULL validator unchanged.
    assert validate_plan(_good_plan(), _inputs()) == []


# ---------------------------------------------------------------------------
# Phase 2 — bounded repair: an unsupported speed routes to ONE repair call carrying the exact
# validator error; the repaired plan is re-validated and must be clean, or the Story fails honestly.
# ---------------------------------------------------------------------------
from model_gateway import StructuredResult, Usage  # noqa: E402


class _SeqGateway:
    """Returns a preset response per call, in order (last repeats). Records every request so a test
    can assert the exact validator error was fed back into the repair prompt."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = []
        self.last_fallback = False

    def generate_structured(self, req):
        self.calls.append(req)
        idx = min(len(self.calls) - 1, len(self._responses) - 1)
        return StructuredResult(
            data=json.loads(json.dumps(self._responses[idx])),
            usage=Usage(input_tokens=100, output_tokens=40, total_tokens=140),
            attempts=1, model="fake", provider="fake",
        )


def test_invalid_speed_triggers_bounded_repair():
    # First call: 4.0x (unrenderable). Repair call: a duration-valid plan within 0.5x–2.0x.
    bad, good = _speed_plan(4.0), _good_plan()
    gw = _SeqGateway([bad, good])
    eng = RealEditPlannerEngine(gw)
    plan = eng.generate(_inputs())
    assert eng.last_diagnostics["repaired"] is True
    assert eng.last_diagnostics["executability_repairs_used"] == 1
    # the EXACT validator error reached the repair prompt
    assert len(gw.calls) == 2
    assert "out of renderer-supported range" in gw.calls[1].user_content
    assert all((s.speed or 1.0) <= 2.0 for s in plan.segments)


def test_repaired_plan_passes_full_validation():
    gw = _SeqGateway([_speed_plan(4.0), _good_plan()])
    plan = RealEditPlannerEngine(gw).generate(_inputs())
    # round-trip the emitted contract back through the validator — zero errors.
    emitted = {"target_duration_seconds": 18.0, "feasible": True, "segments": [
        {"order": s.order, "asset_id": str(s.asset_id),
         "source_start_seconds": s.source_start_seconds, "source_end_seconds": s.source_end_seconds,
         "speed": s.speed, "output_duration_seconds": s.output_duration_seconds,
         "native_audio": s.native_audio.value} for s in plan.segments]}
    assert validate_plan(emitted, _inputs()) == []


def test_repair_preserves_target_duration():
    # The repaired alternative keeps the total within the accept band of the 18s target.
    gw = _SeqGateway([_speed_plan(4.0), _good_plan()])
    plan = RealEditPlannerEngine(gw).generate(_inputs())
    total = sum(s.output_duration_seconds for s in plan.segments)
    assert 18.0 * 0.8 <= total <= 18.0 * 1.5


def test_repair_still_invalid_fails_honestly():
    # Repair ALSO returns an unsupported speed -> never shipped; honest StructuredOutputError.
    gw = _SeqGateway([_speed_plan(4.0), _speed_plan(3.0)])
    eng = RealEditPlannerEngine(gw)
    with pytest.raises(StructuredOutputError):
        eng.generate(_inputs())
    assert eng.last_diagnostics["final"] == "invalid_after_repair"
    # bounded: exactly one repair attempt, no unbounded loop
    assert len(gw.calls) == 2


def test_critique_revision_cannot_reintroduce_invalid_speed():
    # Valid base plan, but the critique->revision pass emits a 4.0x speed. The deterministic validator
    # rejects the revision and the ORIGINAL valid plan is retained (revision never silently adopted).
    base = _good_plan()
    revised_bad = _speed_plan(4.0)
    gw = _SeqGateway([base, "critique text", revised_bad])
    # critique call returns a {"critique": ...} dict; wrap the text as that shape
    gw._responses[1] = {"critique": "lead with a stronger hook"}
    eng = RealEditPlannerEngine(gw)
    plan = eng.generate(_inputs(creative_brief="punchy, fast", critique_revision=True))
    assert eng.last_diagnostics.get("critique_applied") is False
    assert eng.last_diagnostics.get("critique_rejected_reason") == "revision_invalid"
    # original valid plan survived — no 4.0x speed leaked through
    assert all((s.speed or 1.0) <= 2.0 for s in plan.segments)


# ---------------------------------------------------------------------------
# Explicit Moment References — deterministic hard-directive validation.
# Directives carry RESOLVED stable Moment ids (asset_id values), never display numbers.
# ---------------------------------------------------------------------------
def _ctx(directives, mode="revise"):
    return {"mode": mode, "base_version_id": "v1", "directives": directives}


def test_directive_must_include_satisfied():
    plan = _good_plan()  # uses M1 and M2
    errs = validate_plan(plan, _inputs(revision_context=_ctx({"must_include": [M1]})))
    assert [e for e in errs if "must_include" in e] == []


def test_directive_must_include_violated():
    plan = _good_plan()
    plan["segments"] = [s for s in plan["segments"] if s["asset_id"] != M2]  # drop M2
    errs = validate_plan(plan, _inputs(revision_context=_ctx({"must_include": [M2]})))
    assert any("must_include" in e and "appears in no segment" in e for e in errs)


def test_directive_exclude_violated():
    plan = _good_plan()  # contains M2
    errs = validate_plan(plan, _inputs(revision_context=_ctx({"exclude": [M2]})))
    assert any("exclude" in e and "must NOT be used" in e for e in errs)


def test_directive_opening_satisfied_and_violated():
    plan = _good_plan()  # order 0 is M1
    ok = validate_plan(plan, _inputs(revision_context=_ctx({"opening": M1})))
    assert [e for e in ok if "opening" in e] == []
    bad = validate_plan(plan, _inputs(revision_context=_ctx({"opening": M2})))
    assert any("opening" in e and "first segment must be" in e for e in bad)


def test_directive_ending_satisfied_and_violated():
    plan = _good_plan()  # last is M2
    ok = validate_plan(plan, _inputs(revision_context=_ctx({"ending": M2})))
    assert [e for e in ok if "ending" in e] == []
    bad = validate_plan(plan, _inputs(revision_context=_ctx({"ending": M1})))
    assert any("ending" in e and "last segment must be" in e for e in bad)


def test_directive_id_case_insensitive():
    """Regression: a client that sends directive ids in a DIFFERENT case than the moments[]/segment ids
    (iOS historically sent UPPERCASE UUID.uuidString directives while moments/asset_ids were lowercased) must
    STILL be enforced — not silently ignored. A case-sensitive comparison here let "Start with Moment N" go
    unenforced, so every "new version" came back as the same default edit."""
    plan = _good_plan()  # order 0 is M1 (lowercase), order 1/last is M2 (lowercase)
    # opening named in UPPERCASE must resolve to the same Moment -> satisfied (no opening error).
    ok = validate_plan(plan, _inputs(revision_context=_ctx({"opening": M1.upper()})))
    assert [e for e in ok if "opening" in e] == []
    # opening=M2 (uppercase) is NOT the first segment -> must be flagged, and must NOT be treated as an
    # "unknown Moment" (the old case-sensitive bug flagged it "not in the eligible source set").
    bad = validate_plan(plan, _inputs(revision_context=_ctx({"opening": M2.upper()})))
    assert any("opening" in e and "first segment must be" in e for e in bad)
    assert not any("not in the eligible source set" in e for e in bad)
    # exclude in uppercase still catches a used Moment.
    exc = validate_plan(plan, _inputs(revision_context=_ctx({"exclude": [M2.upper()]})))
    assert any("exclude" in e and "must NOT be used" in e for e in exc)


def test_directive_unknown_moment_is_error_not_silent():
    # A reference to a Moment not in the eligible source set must be flagged (deleted/unavailable case),
    # never silently ignored or substituted.
    ghost = str(uuid4())
    errs = validate_plan(_good_plan(), _inputs(revision_context=_ctx({"must_include": [ghost]})))
    assert any(ghost in e and "not in the eligible source set" in e for e in errs)


def test_directive_conflict_include_and_exclude():
    errs = validate_plan(_good_plan(), _inputs(revision_context=_ctx({"must_include": [M1], "exclude": [M1]})))
    assert any("conflict" in e and M1 in e for e in errs)


def test_directive_duplicate_references_safe():
    # Duplicate ids in must_include are handled without error when satisfied.
    errs = validate_plan(_good_plan(), _inputs(revision_context=_ctx({"must_include": [M1, M1]})))
    assert [e for e in errs if "must_include" in e] == []


def test_no_directives_behaves_unchanged():
    # revision_context without directives (or absent) must not add any directive errors.
    assert validate_plan(_good_plan(), _inputs()) == []
    assert validate_plan(_good_plan(), _inputs(revision_context=_ctx({}))) == []
    assert validate_plan(_good_plan(), _inputs(revision_context={"mode": "explore"})) == []


def test_directive_lines_rendered_for_model():
    block = _revision_context_block(_ctx({"must_include": [M1], "exclude": [M2], "opening": M1, "ending": M2}))
    assert f"MUST include a segment from each of these Moment ids: {M1}" in block
    assert f"MUST NOT use any of these Moment ids: {M2}" in block
    assert f"FIRST segment (order 0) MUST be Moment id {M1}" in block
    assert f"LAST segment MUST be Moment id {M2}" in block


# ---------------------------------------------------------------------------
# Ordering directives — order_after (A somewhere after B) + order_adjacent (A immediately after B).
# ---------------------------------------------------------------------------
def _plan3(a, b, c):
    """3-segment plan with the given asset ids in order a,b,c (all consistent 1x)."""
    segs = []
    for i, aid in enumerate([a, b, c]):
        segs.append({"order": i, "asset_id": aid, "source_start_seconds": 1.0, "source_end_seconds": 7.0,
                     "output_duration_seconds": 6.0, "native_audio": "keep"})
    return {"target_duration_seconds": 18.0, "feasible": True, "segments": segs}


def _inputs3(a, b, c):
    return _inputs(moments=[
        {"id": a, "duration_seconds": 9.0, "useful_segments": [[1.0, 8.0]], "summary": "a"},
        {"id": b, "duration_seconds": 9.0, "useful_segments": [[1.0, 8.0]], "summary": "b"},
        {"id": c, "duration_seconds": 9.0, "useful_segments": [[1.0, 8.0]], "summary": "c"},
    ])


def test_order_after_satisfied_and_violated():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    base = _inputs3(a, b, c)
    # plan order a,b,c : "c after a" holds; "a after c" fails
    ok = validate_plan(_plan3(a, b, c), _with_rc(base, {"order_after": [[c, a]]}))
    assert [e for e in ok if "order_after" in e] == []
    bad = validate_plan(_plan3(a, b, c), _with_rc(base, {"order_after": [[a, c]]}))
    assert any("must come after" in e for e in bad)


def test_order_adjacent_satisfied_and_violated():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    base = _inputs3(a, b, c)
    # a,b,c : b immediately after a holds; c immediately after a fails (c is 2 later)
    ok = validate_plan(_plan3(a, b, c), _with_rc(base, {"order_adjacent": [[b, a]]}))
    assert [e for e in ok if "order_adjacent" in e] == []
    bad = validate_plan(_plan3(a, b, c), _with_rc(base, {"order_adjacent": [[c, a]]}))
    assert any("immediately follow" in e for e in bad)


def test_order_unknown_moment_is_error():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    ghost = str(uuid4())
    errs = validate_plan(_plan3(a, b, c), _with_rc(_inputs3(a, b, c), {"order_after": [[a, ghost]]}))
    assert any(ghost in e and "not in the eligible source set" in e for e in errs)


def test_order_contradictory_conflict():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    errs = validate_plan(_plan3(a, b, c), _with_rc(_inputs3(a, b, c),
                         {"order_after": [[a, b], [b, a]]}))
    assert any("contradictory ordering" in e for e in errs)


def test_order_excluded_moment_conflict():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    errs = validate_plan(_plan3(a, b, c), _with_rc(_inputs3(a, b, c),
                         {"exclude": [a], "order_after": [[a, b]]}))
    assert any("excluded but also named in an ordering" in e for e in errs)


def test_order_impossible_adjacency_conflict():
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    # a immediately after b AND a immediately after c — impossible
    errs = validate_plan(_plan3(a, b, c), _with_rc(_inputs3(a, b, c),
                         {"order_adjacent": [[a, b], [a, c]]}))
    assert any("immediately after multiple Moments" in e for e in errs)


def test_opening_plus_adjacent_use_moment5_to_start_moment2_follow():
    # The owner's exact instruction, resolved: opening=A ("moment 5 to start"),
    # order_adjacent [B,A] ("moment 2 follow" = B immediately after A).
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    base = _inputs3(a, b, c)
    rc = {"opening": a, "order_adjacent": [[b, a]]}
    # plan a,b,c satisfies both; plan b,a,c violates opening
    assert validate_plan(_plan3(a, b, c), _with_rc(base, rc)) == []
    bad = validate_plan(_plan3(b, a, c), _with_rc(base, rc))
    assert any("opening" in e for e in bad)


def _with_rc(inp, directives):
    """Clone an EditPlanInputs adding a revise revision_context with the given directives."""
    import dataclasses
    return dataclasses.replace(inp, revision_context={"mode": "revise", "directives": directives})


# ---------------------------------------------------------------------------
# Phase 2 — hybrid revision interpreter (unit, fake gateway).
# ---------------------------------------------------------------------------
def test_interpret_revision_maps_numbers_to_ids_and_flags_unresolved():
    from edit_planner.revision_interpreter import interpret_revision

    class _GW:
        def __init__(self, d): self._d = d
        def generate_structured(self, req):
            from model_gateway import StructuredResult, Usage
            return StructuredResult(data=self._d, usage=Usage())

    numbered = [{"number": 1, "id": "id-a", "summary": "summit"},
                {"number": 2, "id": "id-b", "summary": "river"}]
    gw = _GW({"must_include": [], "exclude": [], "opening": 1, "ending": None,
              "order_after": [], "order_adjacent": [[2, 1]],
              "soft_direction": "faster cuts", "unsupported": ["make it dreamier"]})
    r = interpret_revision("use moment 1 to start and moment 2 follow, faster cuts, dreamier", numbered, gw)
    assert r.directives["opening"] == "id-a"
    assert r.directives["order_adjacent"] == [["id-b", "id-a"]]
    assert r.soft_direction == "faster cuts"
    assert "make it dreamier" in r.unresolved
    assert r.needs_clarification

    # out-of-range number -> unresolved, never a fabricated id
    gw2 = _GW({"must_include": [9], "exclude": [], "opening": None, "ending": None,
               "order_after": [], "order_adjacent": [], "soft_direction": "", "unsupported": []})
    r2 = interpret_revision("include moment 9", numbered, gw2)
    assert r2.directives == {}
    assert any("9" in u for u in r2.unresolved)


# ---------------------------------------------------------------------------
# Interpreter OVERREACH — grounding guard (revision_interpret/2). The guard checks that an EXCLUDE directive is
# supported by the user's words; it never silently drops, and it preserves legitimate "use only" restrictions.
# These are INTERPRETATION-level (scripted gateway), not EditPlanner tests.
# ---------------------------------------------------------------------------
class _ScriptGW:
    def __init__(self, d): self._d = d
    def generate_structured(self, req):
        from model_gateway import StructuredResult, Usage
        return StructuredResult(data=self._d, usage=Usage())


def _numbered(n):
    return [{"number": i + 1, "id": f"id-{i+1}", "summary": f"m{i+1}"} for i in range(n)]


def test_ground_flags_invented_exclude_from_ordering_only():
    # The exact failed instruction: ordering-only, no omission words -> an exclude set is UNSUPPORTED.
    from edit_planner.revision_interpreter import interpret_revision, ground_directives
    gw = _ScriptGW({"must_include": [], "exclude": [4, 5, 7, 8, 9, 10], "opening": 13, "ending": 6,
                    "order_after": [], "order_adjacent": [[2, 13]], "soft_direction": "", "unsupported": []})
    r = interpret_revision("Use Moment 13 first and Moment 2 immediately after. And use Moment 6 as end.",
                           _numbered(15), gw)
    flags = ground_directives(r)
    assert any("unsupported_exclude" in f for f in flags)


def test_ground_allows_exclude_with_omission_word():
    from edit_planner.revision_interpreter import interpret_revision, ground_directives
    gw = _ScriptGW({"must_include": [], "exclude": [4], "opening": None, "ending": None,
                    "order_after": [], "order_adjacent": [], "soft_direction": "", "unsupported": []})
    r = interpret_revision("Remove Moment 4.", _numbered(8), gw)
    assert ground_directives(r) == []


def test_ground_allows_exclude_with_only_restriction():
    # "use only A, B, C" is a legitimate restriction — an exclude of the others is SUPPORTED.
    from edit_planner.revision_interpreter import interpret_revision, ground_directives
    gw = _ScriptGW({"must_include": [13, 2, 6], "exclude": [1, 3, 4, 5], "opening": None, "ending": None,
                    "order_after": [], "order_adjacent": [], "soft_direction": "", "unsupported": []})
    r = interpret_revision("Use only Moments 13, 2, and 6.", _numbered(15), gw)
    assert ground_directives(r) == []


def test_ground_allows_nothing_except_restriction():
    from edit_planner.revision_interpreter import interpret_revision, ground_directives
    gw = _ScriptGW({"must_include": [13, 2, 6], "exclude": [1, 3], "opening": None, "ending": None,
                    "order_after": [], "order_adjacent": [], "soft_direction": "", "unsupported": []})
    r = interpret_revision("Don't show anything except Moments 13, 2, and 6.", _numbered(15), gw)
    assert ground_directives(r) == []


def test_ground_allows_exclude_but_include_mix():
    from edit_planner.revision_interpreter import interpret_revision, ground_directives
    gw = _ScriptGW({"must_include": [5], "exclude": [8], "opening": None, "ending": None,
                    "order_after": [], "order_adjacent": [], "soft_direction": "", "unsupported": []})
    r = interpret_revision("Use Moment 5 but exclude Moment 8.", _numbered(10), gw)
    assert ground_directives(r) == []


def test_ground_noop_when_no_exclude():
    # Opening-only, no exclude -> nothing to flag (the correct v2 output for the failed instruction).
    from edit_planner.revision_interpreter import interpret_revision, ground_directives
    gw = _ScriptGW({"must_include": [], "exclude": [], "opening": 13, "ending": 6,
                    "order_after": [], "order_adjacent": [[2, 13]], "soft_direction": "", "unsupported": []})
    r = interpret_revision("Use Moment 13 first and Moment 2 immediately after. And use Moment 6 as end.",
                           _numbered(15), gw)
    assert ground_directives(r) == []
    assert r.directives.get("opening") == "id-13"
    assert r.directives.get("ending") == "id-6"
    assert r.directives.get("order_adjacent") == [["id-2", "id-13"]]
    assert "exclude" not in r.directives


def test_ground_soft_only_instruction_passes():
    from edit_planner.revision_interpreter import interpret_revision, ground_directives
    gw = _ScriptGW({"must_include": [], "exclude": [], "opening": 5, "ending": None,
                    "order_after": [], "order_adjacent": [], "soft_direction": "make the cuts faster",
                    "unsupported": []})
    r = interpret_revision("Start with Moment 5 and make the cuts faster.", _numbered(8), gw)
    assert ground_directives(r) == []
    assert r.soft_direction == "make the cuts faster"


def test_v2_is_active_prompt_version():
    from edit_planner.revision_interpreter import PROMPT_VERSION, PROMPT_VERSION_V1
    assert PROMPT_VERSION == "revision_interpret/2"
    assert PROMPT_VERSION_V1 == "revision_interpret/1"


def test_v1_prompt_still_selectable_for_comparison():
    # The frozen v1 prompt must remain usable for A/B (never edited in place).
    from edit_planner.revision_interpreter import interpret_revision, PROMPT_VERSION_V1
    gw = _ScriptGW({"must_include": [], "exclude": [], "opening": 1, "ending": None,
                    "order_after": [], "order_adjacent": [], "soft_direction": "", "unsupported": []})
    r = interpret_revision("start with moment 1", _numbered(3), gw, prompt_version=PROMPT_VERSION_V1)
    assert r.directives.get("opening") == "id-1"


def test_exclude_is_supported_helper():
    from edit_planner.revision_interpreter import exclude_is_supported
    assert exclude_is_supported("remove moment 4")
    assert exclude_is_supported("use only moments 1, 2, 3")
    assert exclude_is_supported("don't use moment 8")
    assert not exclude_is_supported("start with moment 5 then moment 2")
    assert not exclude_is_supported("use moment 13 first and moment 6 as end")


# ---------------------------------------------------------------------------
# Phase 5 — deterministic revision fast path (zero model calls).
# ---------------------------------------------------------------------------
def test_deterministic_transform_reorders_and_prunes():
    from edit_planner.deterministic_revision import apply_deterministic_revision as A
    def seg(o, a): return {"order": o, "asset_id": a, "source_start_seconds": 0.0,
                           "source_end_seconds": 4.0, "output_duration_seconds": 4.0, "native_audio": "keep"}
    base = {"schema_version": "edit_plan/2", "feasible": True,
            "segments": [seg(0, "a"), seg(1, "b"), seg(2, "c"), seg(3, "d")]}
    def ids(p): return [s["asset_id"] for s in sorted(p["segments"], key=lambda s: s["order"])]
    assert ids(A(base, {"opening": "c"})) == ["c", "a", "b", "d"]
    assert ids(A(base, {"exclude": ["b"]})) == ["a", "c", "d"]
    assert ids(A(base, {"opening": "a", "order_adjacent": [["c", "a"]]})) == ["a", "c", "b", "d"]
    assert ids(A(base, {"ending": "a"})) == ["b", "c", "d", "a"]
    # must_include a Moment not in the base plan cannot be done by reorder -> None (fall back to AI)
    assert A(base, {"must_include": ["zz"]}) is None
    # order renumbered 0..n-1
    assert [s["order"] for s in sorted(A(base, {"opening": "c"})["segments"], key=lambda s: s["order"])] == [0, 1, 2, 3]
    # Case-INSENSITIVE: an UPPERCASE directive id must move the matching lowercase segment (regression: the
    # pure-reorder path used a case-sensitive `in`/`==`, so an UPPERCASE "opening" silently no-op'd and the
    # "revised" plan came back identical to the base).
    assert ids(A(base, {"opening": "C"})) == ["c", "a", "b", "d"]
    assert ids(A(base, {"exclude": ["B"]})) == ["a", "c", "d"]


def test_deterministic_retime_trims_source_at_normal_speed():
    # "shorten each clip to ~5s" means SHOW ~5s of footage at NORMAL speed (trim the source window), NOT cram
    # the whole clip into 5s (which forces ~2x speed + pitched audio — the on-device bug). The clip SET, order
    # and music are preserved; the source END is trimmed toward start+5s; speed stays 1.0.
    from edit_planner.deterministic_revision import apply_deterministic_retime
    def seg(o, a, s0, s1, outd): return {"order": o, "asset_id": a, "source_start_seconds": s0,
                                         "source_end_seconds": s1, "output_duration_seconds": outd,
                                         "native_audio": "keep", "speed": 1.0}
    base = {"schema_version": "edit_plan/2", "feasible": True, "music_asset_id": "trk",
            "segments": [seg(0, "a", 0.0, 10.0, 10.0), seg(1, "b", 2.0, 6.0, 4.0), seg(2, "c", 0.0, 3.0, 3.0)]}
    out = apply_deterministic_retime(base, 5.0)
    assert out is not None
    segs = sorted(out["segments"], key=lambda s: s["order"])
    assert [s["asset_id"] for s in segs] == ["a", "b", "c"]   # clips + order preserved
    assert out["music_asset_id"] == "trk"                     # soundtrack preserved
    # EVERY segment plays at normal speed (no pitch-up of native audio).
    for s in segs:
        assert abs(s["speed"] - 1.0) < 1e-6, f"speed {s['speed']} should be normal (1.0)"
        assert abs(s["output_duration_seconds"] - (s["source_end_seconds"] - s["source_start_seconds"])) < 1e-6
    # clip 'a' (10s available) is TRIMMED to a 5s window at its original in-point, normal speed.
    assert segs[0]["source_start_seconds"] == 0.0 and abs(segs[0]["source_end_seconds"] - 5.0) < 0.01
    assert abs(segs[0]["output_duration_seconds"] - 5.0) < 0.01
    # clip 'b' (4s available, < 5s target) keeps its whole window — we never stretch footage that isn't there.
    assert (segs[1]["source_start_seconds"], segs[1]["source_end_seconds"]) == (2.0, 6.0)
    assert abs(segs[1]["output_duration_seconds"] - 4.0) < 0.01
    # clip 'c' (3s available) keeps its whole 3s window at normal speed.
    assert abs(segs[2]["output_duration_seconds"] - 3.0) < 0.01


def test_deterministic_retime_respects_target_lower_bound():
    # A user-exact target the naive ~5s trim would undershoot: the trim window is widened uniformly (bounded by
    # each clip's AVAILABLE footage) until the total clears the lower bound — all at NORMAL speed, clips kept.
    from edit_planner.deterministic_revision import apply_deterministic_retime
    def seg(o, a, s0, s1): return {"order": o, "asset_id": a, "source_start_seconds": s0,
                                   "source_end_seconds": s1, "output_duration_seconds": 10.0,
                                   "native_audio": "keep", "speed": 1.0}
    # 3 clips, 10s available each. Naive 5s each -> total 15s. Reachable lower bound 24s (8s/clip <= 10 avail).
    base = {"schema_version": "edit_plan/2", "feasible": True,
            "segments": [seg(0,"a",0,10), seg(1,"b",0,10), seg(2,"c",0,10)]}
    out = apply_deterministic_retime(base, 5.0, min_total_seconds=24.0)
    segs = sorted(out["segments"], key=lambda s: s["order"])
    total = sum(s["output_duration_seconds"] for s in segs)
    assert total >= 24.0, f"total {total} should clear the lower bound"
    assert [s["asset_id"] for s in segs] == ["a","b","c"]   # clips preserved
    for s in segs:
        assert abs(s["speed"] - 1.0) < 1e-6   # normal speed throughout (trim, not speed-up)
        assert abs(s["output_duration_seconds"] - (s["source_end_seconds"]-s["source_start_seconds"])) < 1e-6


def test_parse_target_clip_seconds():
    from edit_planner import _parse_target_clip_seconds
    assert _parse_target_clip_seconds("shorten each clip to around 5s") == 5.0
    assert _parse_target_clip_seconds("make the cuts about 3 seconds") == 3.0
    assert _parse_target_clip_seconds("keep shots under 4 sec") == 4.0
    # Not a clip-length ask -> None (takes the model path, never the retime path).
    assert _parse_target_clip_seconds("make it more cinematic") is None
    assert _parse_target_clip_seconds("start with moment 5") is None
    assert _parse_target_clip_seconds("") is None
    # A seconds value with no clip/cut/shot word is NOT a per-clip ask.
    assert _parse_target_clip_seconds("make it 30 seconds total") is None


# ---------------------------------------------------------------------------
# P0 Revision Constraint Priority (owner 2026-10-18): duration provenance, operation-scoped validation,
# the no-silent-replan boundary, and the preservation gate.
# ---------------------------------------------------------------------------
def _retimable_base_plan(target, span=6.0):
    """A base plan whose clips, re-timed toward ~5s, would UNDERSHOOT `target` — the exact situation that used
    to be rejected and re-planned. Uses only the known moments M1/M2 so the retimed plan validates."""
    def seg(o, aid, s0, s1): return {"order": o, "asset_id": aid, "source_start_seconds": s0,
                                     "source_end_seconds": s1, "output_duration_seconds": 12.0,
                                     "native_audio": "keep", "speed": 1.0}
    return {"schema_version": "edit_plan/2", "target_duration_seconds": target, "feasible": True,
            "segments": [seg(0, M1, 0.0, span), seg(1, M2, 0.0, span)]}


def test_undershoot_relaxed_for_ai_recommended_timing_revise():
    # Timing-only revise + AI-recommended target: the undershoot floor is lifted, so a shortened plan validates
    # without any model call and WITHOUT lengthening shots. Clips preserved, total allowed to shrink.
    base_plan = _retimable_base_plan(target=30.0, span=6.0)
    rc = {"mode": "revise", "base_version_id": "v9", "base_plan": base_plan,
          "soft_direction": "shorten each clip to ~5s and keep the highlights",
          "duration_target_source": "ai_recommended"}
    class _Boom:
        last_fallback = False
        def generate_structured(self, req):
            raise AssertionError("ai_recommended timing revise must stay deterministic (0 model calls)")
    eng = RealEditPlannerEngine(_Boom())
    plan = eng.generate(_inputs(revision_context=rc,
                                creative_intent={"target_duration_seconds": 30.0, "desired_feeling": ["calm"]}))
    assert eng.last_diagnostics["revision_path"] == "deterministic_retime"
    assert eng.last_diagnostics["model_calls"] == 0
    # same clips, in the same order, each shortened toward ~5s (total < old 30s target, and that is allowed).
    ids = [str(s.asset_id) for s in plan.segments]
    assert ids == [s["asset_id"] for s in base_plan["segments"]]
    total = sum(s.output_duration_seconds for s in plan.segments)
    assert total < 30.0


def test_user_exact_timing_revise_keeps_strict_lower_bound():
    # Same instruction but the user fixed the length exactly -> the lower bound stays strict and the retime
    # lifts shot durations to keep the total near the target (clips still preserved).
    base_plan = _retimable_base_plan(target=18.0, span=12.0)   # span 12 => room to lift up to 24s/clip
    rc = {"mode": "revise", "base_version_id": "v9", "base_plan": base_plan,
          "soft_direction": "shorten each clip to ~5s",
          "duration_target_source": "user_exact"}
    class _Boom:
        last_fallback = False
        def generate_structured(self, req):
            raise AssertionError("must stay deterministic")
    eng = RealEditPlannerEngine(_Boom())
    plan = eng.generate(_inputs(revision_context=rc,
                                creative_intent={"target_duration_seconds": 18.0, "desired_feeling": ["calm"]},
                                moments=[
        {"id": M1, "duration_seconds": 13.0, "useful_segments": [[0.0, 12.0]]},
        {"id": M2, "duration_seconds": 13.0, "useful_segments": [[0.0, 12.0]]}]))
    total = sum(s.output_duration_seconds for s in plan.segments)
    assert total >= 18.0 * 0.8   # strict lower bound honored for the explicit length
    assert [str(s.asset_id) for s in plan.segments] == [s["asset_id"] for s in base_plan["segments"]]


def test_initial_creation_undershoot_unchanged():
    # No revision_context => _undershoot_tolerance_for returns the strict default (creation behavior intact).
    from edit_planner import _undershoot_tolerance_for, DURATION_UNDERSHOOT_TOLERANCE
    assert _undershoot_tolerance_for(_inputs()) == DURATION_UNDERSHOOT_TOLERANCE


def test_timing_revise_validation_failure_never_replans(monkeypatch):
    # OWNER POLICY (2026-10-25): if a pacing/timing retime cannot be made valid, the engine does NOT error and
    # does NOT silently model-replan — it ships the user's EXISTING base plan (a known-playable cut), so the
    # pacing change simply wasn't applied. Force the retime to produce an invalid plan and assert the model is
    # never called AND a valid contract (the base) is returned.
    import edit_planner.deterministic_revision as dr
    base_plan = _retimable_base_plan(target=30.0, span=6.0)
    rc = {"mode": "revise", "base_version_id": "v9", "base_plan": base_plan,
          "soft_direction": "shorten each clip to ~5s", "duration_target_source": "ai_recommended"}
    def _bad(bp, target, min_total_seconds=None):
        import copy
        p = copy.deepcopy(bp)
        for s in p["segments"]:
            s["source_start_seconds"] = 999.0; s["source_end_seconds"] = 1004.0
            s["output_duration_seconds"] = 5.0; s["speed"] = 1.0
        return p
    monkeypatch.setattr(dr, "apply_deterministic_retime", _bad)
    class _Boom:
        last_fallback = False
        def generate_structured(self, req):
            raise AssertionError("a failed timing retime must NOT replan via the model")
    eng = RealEditPlannerEngine(_Boom())
    out = eng.generate(_inputs(revision_context=rc,
                               creative_intent={"target_duration_seconds": 30.0, "desired_feeling": ["calm"]}))
    assert len(out.segments) == len(base_plan["segments"])           # shipped the base, unchanged
    assert eng.last_diagnostics["revision_path"] == "retime_infeasible_shipped_base"
    assert eng.last_diagnostics.get("retime_change_applied") is False
    assert eng.last_diagnostics.get("model_calls", 0) == 0
    # NEVER MISLEAD (owner §5-B): the unchanged base is disclosed, not shown as a successful revision.
    assert eng.last_diagnostics.get("completion") == "partial"
    assert "unchanged" in eng.last_diagnostics.get("partial_disclosure", "").lower()


# ---------------------------------------------------------------------------
# Phase 5 — unsupported-operation handling (owner 2026-10-18): explain + preserve, never substitute.
# ---------------------------------------------------------------------------
def test_classify_unsupported_ops():
    from edit_planner import _classify_unsupported_ops as c
    # Unsupported capability asks.
    for t in ["make it warmer", "add a glow", "color correct the whole thing", "reframe to square",
              "increase the brightness", "add a vignette", "stabilize the shaky clip", "add captions"]:
        assert c(t)["verdict"] == "all_unsupported", t
    # Supported editing asks (no false positives).
    for t in ["shorten each clip to 5s", "reorder the clips", "change the music", "faster cuts",
              "make it more cinematic", "remove moment 3", "use moment 5 to open"]:
        assert c(t)["verdict"] == "supported", t
    # Mixed: a supported edit + an unsupported effect.
    m = c("shorten the clips and make it warmer")
    assert m["verdict"] == "mixed" and "color tone changes" in m["phrase"]
    assert c("")["verdict"] == "supported"
    # Color-NOUN phrasings (regression: "make the sky more blue" slipped through the first vocabulary).
    assert c("make the sky more blue")["verdict"] == "all_unsupported"
    assert c("make it bluer")["verdict"] == "all_unsupported"
    assert c("Shorten to 5s for each clip and make sky color more blue")["verdict"] == "mixed"


def test_unsupported_revise_preserves_version_never_plans():
    # An all-unsupported revise must keep the version and explain — never call the model (which would return
    # SOME re-cut plan = a silent substitution of a different edit for the one the user asked for).
    base_plan = _good_plan()
    rc = {"mode": "revise", "base_version_id": "v3", "base_plan": base_plan,
          "soft_direction": "make the colors warmer and add a glow"}
    class _Boom:
        last_fallback = False
        def generate_structured(self, req):
            raise AssertionError("an unsupported revise must NOT plan a substitute edit")
    eng = RealEditPlannerEngine(_Boom())
    with pytest.raises(EditPlanInfeasibleError) as ei:
        eng.generate(_inputs(revision_context=rc, moments=[
            {"id": M1, "duration_seconds": 11.0, "useful_segments": [[0.0, 10.0]]},
            {"id": M2, "duration_seconds": 9.0, "useful_segments": [[0.0, 9.0]]}]))
    msg = str(ei.value).lower()
    assert "kept" in msg and "unchanged" in msg          # preserved
    assert "color" in msg                                 # explains the specific limitation
    assert eng.last_diagnostics["final"] == "unsupported_operation"
    assert eng.last_diagnostics.get("model_calls", 0) == 0


def test_mixed_revise_records_partial_note_and_still_plans():
    # A mixed instruction (supported edit + unsupported effect) runs the supported part but records a note
    # saying what could not be applied — not silently dropped, not a fabricated success.
    base_plan = _good_plan()
    rc = {"mode": "revise", "base_version_id": "v3", "base_plan": base_plan,
          "soft_direction": "shorten each clip to ~5s and make it warmer",
          "duration_target_source": "ai_recommended"}
    class _Boom:
        last_fallback = False
        def generate_structured(self, req):
            raise AssertionError("timing part should take the deterministic retime, no model call")
    eng = RealEditPlannerEngine(_Boom())
    eng.generate(_inputs(revision_context=rc,
                         creative_intent={"target_duration_seconds": 18.0, "desired_feeling": ["calm"]}))
    assert eng.last_diagnostics.get("partial_support_note")
    assert "color tone changes" in eng.last_diagnostics["partial_support_note"]
    assert eng.last_diagnostics["revision_path"] == "deterministic_retime"   # supported part ran


def test_wholesale_revise_now_ships_non_blocking():
    # OWNER POLICY (2026-10-25): a wholesale re-pick is still a PLAYABLE video, so it SHIPS (recorded as
    # continuity_nonblocking='wholesale') instead of erroring. The user gets a video; the prior version is
    # preserved in history. Was previously a terminal preservation_violation.
    M3 = str(uuid4()); M4 = str(uuid4()); M5 = str(uuid4())
    base_plan = {"target_duration_seconds": 36.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 1.0, "source_end_seconds": 9.0,
         "output_duration_seconds": 9.0, "native_audio": "keep"},
        {"order": 1, "asset_id": M2, "source_start_seconds": 0.5, "source_end_seconds": 9.0,
         "output_duration_seconds": 9.0, "native_audio": "keep"},
        {"order": 2, "asset_id": M4, "source_start_seconds": 0.0, "source_end_seconds": 9.0,
         "output_duration_seconds": 9.0, "native_audio": "keep"},
        {"order": 3, "asset_id": M5, "source_start_seconds": 0.0, "source_end_seconds": 9.0,
         "output_duration_seconds": 9.0, "native_audio": "keep"}]}
    rc = {"mode": "revise", "base_version_id": "v3", "base_plan": base_plan,
          "soft_direction": "make it feel more energetic"}   # no clip-length target, no selection authorization
    # Model keeps only M1 (1 of 4 = 25% continuity, below the old 50% floor) and re-picks M3 — a wholesale re-pick.
    repicked = {"target_duration_seconds": 18.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 9.0,
         "output_duration_seconds": 9.0, "native_audio": "keep"},
        {"order": 1, "asset_id": M3, "source_start_seconds": 0.0, "source_end_seconds": 9.0,
         "output_duration_seconds": 9.0, "native_audio": "keep"}]}
    eng = RealEditPlannerEngine(FakeModelGateway(response=repicked))
    out = eng.generate(_inputs(revision_context=rc, moments=[
        {"id": M1, "duration_seconds": 11.0, "useful_segments": [[0.0, 10.0]]},
        {"id": M2, "duration_seconds": 9.0, "useful_segments": [[0.0, 9.0]]},
        {"id": M3, "duration_seconds": 9.0, "useful_segments": [[0.0, 9.0]]},
        {"id": M4, "duration_seconds": 9.0, "useful_segments": [[0.0, 9.0]]},
        {"id": M5, "duration_seconds": 9.0, "useful_segments": [[0.0, 9.0]]}]))
    assert len(out.segments) == 2                                   # the re-pick SHIPPED
    assert eng.last_diagnostics["continuity"]["verdict"] == "wholesale"
    assert eng.last_diagnostics.get("continuity_nonblocking") == "wholesale"
    # NEVER MISLEAD (owner §5-C): disclose the substantial change; the previous version is preserved.
    assert eng.last_diagnostics.get("completion") == "partial"
    assert "previous version" in eng.last_diagnostics.get("partial_disclosure", "").lower()


def test_preservation_gate_allows_model_preserving_revise():
    # Same soft revise, but the model preserves the clip set (only re-times/reorders) -> accepted.
    base_plan = _good_plan()
    rc = {"mode": "revise", "base_version_id": "v3", "base_plan": base_plan,
          "soft_direction": "make it feel more energetic"}
    # output_duration == source span (speed 1.0) to satisfy the consistency check; total 13.5s vs a 14s target.
    preserved = {"target_duration_seconds": 14.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M2, "source_start_seconds": 0.5, "source_end_seconds": 6.0,
         "output_duration_seconds": 5.5, "speed": 1.0, "native_audio": "keep"},
        {"order": 1, "asset_id": M1, "source_start_seconds": 1.0, "source_end_seconds": 9.0,
         "output_duration_seconds": 8.0, "speed": 1.0, "native_audio": "keep"}]}
    eng = RealEditPlannerEngine(FakeModelGateway(response=preserved))
    plan = eng.generate(_inputs(revision_context=rc,
                                creative_intent={"target_duration_seconds": 14.0, "desired_feeling": ["calm"]},
                                moments=[
        {"id": M1, "duration_seconds": 11.0, "useful_segments": [[0.0, 10.0]]},
        {"id": M2, "duration_seconds": 9.0, "useful_segments": [[0.0, 9.0]]}]))
    assert {str(s.asset_id) for s in plan.segments} == {M1, M2}


def test_broad_replan_flag_bypasses_preservation_gate():
    # When the user explicitly authorizes a broad redesign, a changed clip set is allowed.
    base_plan = _good_plan()
    rc = {"mode": "revise", "base_version_id": "v3", "base_plan": base_plan,
          "soft_direction": "completely redesign this", "allow_broad_replan": True}
    repicked = {"target_duration_seconds": 18.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 9.0,
         "output_duration_seconds": 9.0, "native_audio": "keep"},
        {"order": 1, "asset_id": M2, "source_start_seconds": 0.0, "source_end_seconds": 9.0,
         "output_duration_seconds": 9.0, "native_audio": "keep"}]}
    eng = RealEditPlannerEngine(FakeModelGateway(response=repicked))
    plan = eng.generate(_inputs(revision_context=rc, moments=[
        {"id": M1, "duration_seconds": 11.0, "useful_segments": [[0.0, 10.0]]},
        {"id": M2, "duration_seconds": 9.0, "useful_segments": [[0.0, 9.0]]}]))
    assert eng.last_diagnostics.get("final") != "preservation_violation"


# ---- Phase 7: editorial-continuity gate (owner 2026-10-21) ----

def test_continuity_gate_accepts_clip_change_within_floor():
    # A soft revise where the model keeps 3 of 4 base clips (75% >= 50% floor) and swaps one is now ACCEPTED —
    # a technically-valid revise is not discarded solely because the clip set changed (owner principle 5).
    M3 = str(uuid4()); M4 = str(uuid4())
    base_plan = {"target_duration_seconds": 32.0, "feasible": True, "segments": [
        {"order": i, "asset_id": a, "source_start_seconds": 0.0, "source_end_seconds": 8.0,
         "output_duration_seconds": 8.0, "speed": 1.0, "native_audio": "keep"}
        for i, a in enumerate([M1, M2, M3, M4])]}
    rc = {"mode": "revise", "base_version_id": "v3", "base_plan": base_plan,
          "soft_direction": "make it feel more energetic"}
    M5 = str(uuid4())
    revised = {"target_duration_seconds": 32.0, "feasible": True, "segments": [
        {"order": i, "asset_id": a, "source_start_seconds": 0.0, "source_end_seconds": 8.0,
         "output_duration_seconds": 8.0, "speed": 1.0, "native_audio": "keep"}
        for i, a in enumerate([M1, M2, M3, M5])]}   # dropped M4, added M5 -> 3/4 retained = 0.75
    eng = RealEditPlannerEngine(FakeModelGateway(response=revised))
    plan = eng.generate(_inputs(revision_context=rc, creative_intent={"target_duration_seconds": 32.0,
                                "desired_feeling": ["calm"]}, moments=[
        {"id": m, "duration_seconds": 9.0, "useful_segments": [[0.0, 9.0]]} for m in [M1, M2, M3, M4, M5]]))
    assert {str(s.asset_id) for s in plan.segments} == {M1, M2, M3, M5}
    assert eng.last_diagnostics["final"] == "executable"
    assert eng.last_diagnostics["continuity"]["verdict"] == "ok"
    assert eng.last_diagnostics["continuity"]["continuity_ratio"] == 0.75


def test_continuity_gate_rejects_noop_revise():
    # OWNER POLICY (2026-10-25): continuity is a DIAGNOSTIC, never a block. A directed revise whose result is
    # byte-identical to the base is still a PLAYABLE video, so it SHIPS (recorded as continuity_nonblocking),
    # rather than erroring. The user is never blocked after the pipeline produced a playable cut.
    base_plan = _good_plan()
    rc = {"mode": "revise", "base_version_id": "v3", "base_plan": base_plan,
          "soft_direction": "make it feel more energetic"}
    identical = json.loads(json.dumps(base_plan))   # model returns the base unchanged
    eng = RealEditPlannerEngine(FakeModelGateway(response=identical))
    out = eng.generate(_inputs(revision_context=rc, moments=[
        {"id": M1, "duration_seconds": 11.0, "useful_segments": [[0.0, 10.0]]},
        {"id": M2, "duration_seconds": 9.0, "useful_segments": [[0.0, 9.0]]}]))
    assert len(out.segments) == len(base_plan["segments"])          # shipped, not rejected
    assert eng.last_diagnostics["continuity"]["verdict"] == "noop"
    assert eng.last_diagnostics.get("continuity_nonblocking") == "noop"
    # NEVER MISLEAD (owner §2-B/§5-D): a noop must be disclosed, not shown as a clean successful revision.
    assert eng.last_diagnostics.get("completion") == "partial"
    assert "same" in eng.last_diagnostics.get("partial_disclosure", "").lower()


def test_continuity_gate_allows_shorter_duration_to_drop_clips():
    # A retime/shorter instruction authorizes dropping clips, so even heavy loss is accepted (not wholesale).
    # Model handles it (not a parseable clip target here) and keeps only 1 of 4; the "shorter" intent lifts the
    # floor, so it is ACCEPTED rather than rejected as a whole-video replacement.
    M3 = str(uuid4()); M4 = str(uuid4())
    base_plan = {"target_duration_seconds": 32.0, "feasible": True, "segments": [
        {"order": i, "asset_id": a, "source_start_seconds": 0.0, "source_end_seconds": 8.0,
         "output_duration_seconds": 8.0, "speed": 1.0, "native_audio": "keep"}
        for i, a in enumerate([M1, M2, M3, M4])]}
    rc = {"mode": "revise", "base_version_id": "v3", "base_plan": base_plan,
          "soft_direction": "make it much shorter, just the best shots"}
    shortened = {"target_duration_seconds": 8.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 8.0,
         "output_duration_seconds": 8.0, "speed": 1.0, "native_audio": "keep"}]}
    eng = RealEditPlannerEngine(FakeModelGateway(response=shortened))
    plan = eng.generate(_inputs(revision_context={**rc, "duration_target_source": "ai_recommended"},
                                creative_intent={"target_duration_seconds": 8.0, "desired_feeling": ["calm"]},
                                moments=[{"id": m, "duration_seconds": 9.0, "useful_segments": [[0.0, 9.0]]}
                                         for m in [M1, M2, M3, M4]]))
    assert {str(s.asset_id) for s in plan.segments} == {M1}
    assert eng.last_diagnostics["final"] == "executable"
    assert eng.last_diagnostics["continuity"]["authorized_change"] is True


def test_directive_authorized_ids_reads_the_directive_dict():
    # D5 fix: authorized ids come from the directive DICT (opening/ending/include/exclude/order pairs), not a
    # list-of-dicts. The old code iterated a dict's keys and produced an ALWAYS-EMPTY set.
    from edit_planner import _directive_authorized_ids
    a, b, c, d = "aa", "bb", "cc", "dd"
    directives = {"opening": a.upper(), "ending": b, "exclude": [c], "must_include": [d],
                  "order_after": [[a, b]], "order_adjacent": [[c, d]]}
    got = _directive_authorized_ids(directives)
    assert got == {a, b, c, d}   # lowercased, from the real shape
    assert _directive_authorized_ids({}) == set()
    assert _directive_authorized_ids([{"asset_id": "EE"}]) == {"ee"}   # forward-compat list shape


def test_revision_context_block_injects_base_plan_for_revise():
    # D1: the Revise USER-message block must carry the exact base_plan + a preserve/latest-wins objective, and
    # must NOT render Explore's prior-version summaries.
    from edit_planner import _revision_context_block
    base_plan = {"feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 5.0,
         "output_duration_seconds": 5.0, "native_audio": "keep"}]}
    block = _revision_context_block({"mode": "revise", "base_version_id": "v2", "base_plan": base_plan,
                                     "soft_direction": "make it more cinematic",
                                     "prior_edit_summaries": [{"version": "v1"}]})
    assert "BASE PLAN" in block and M1 in block
    assert "LATEST request wins" in block
    assert "PREVIOUS VERSION(S)" not in block   # summaries are Explore-only


def test_explore_block_unchanged_still_seeks_diversity():
    # Revise must not inherit Explore's objective; Explore keeps "MEANINGFULLY DIFFERENT".
    from edit_planner import _revision_context_block
    block = _revision_context_block({"mode": "explore", "base_version_id": "v2",
                                     "prior_edit_summaries": [{"version": "v1"}]})
    assert "MEANINGFULLY DIFFERENT" in block
    assert "BASE PLAN" not in block


def test_mixed_retime_plus_directive_accepts_shorter_total():
    # Phase 5/7 TMB case: "Start with Moment 1, shorten each clip to ~5s, make it more cinematic" on an ~85s
    # base. Mixed (opening directive + retime + creative) -> AI path with base_plan injected. The retime intent
    # relaxes the AI-recommended undershoot floor even WITH a directive, so a shorter total is accepted; all
    # clips preserved, Moment 1 first.
    m = [str(uuid4()) for _ in range(6)]
    base_plan = {"target_duration_seconds": 85.0, "feasible": True, "segments": [
        {"order": i, "asset_id": a, "source_start_seconds": 0.0, "source_end_seconds": 14.0,
         "output_duration_seconds": 14.0, "speed": 1.0, "native_audio": "keep"} for i, a in enumerate(m)]}
    ro = [m[0], m[2], m[1], m[3], m[4], m[5]]
    revised = {"target_duration_seconds": 30.0, "feasible": True, "segments": [
        {"order": i, "asset_id": a, "source_start_seconds": 0.0, "source_end_seconds": 5.0,
         "output_duration_seconds": 5.0, "speed": 1.0, "native_audio": "keep"} for i, a in enumerate(ro)]}
    rc = {"mode": "revise", "base_version_id": "tmbA", "base_plan": base_plan,
          "directives": {"opening": m[0]},
          "soft_direction": "shorten each clip to approximately five seconds, and make the video more cinematic",
          "duration_target_source": "ai_recommended"}
    eng = RealEditPlannerEngine(FakeModelGateway(response=revised))
    plan = eng.generate(_inputs(revision_context=rc,
                                creative_intent={"target_duration_seconds": 85.0, "desired_feeling": ["cinematic"]},
                                moments=[{"id": a, "duration_seconds": 15.0, "useful_segments": [[0.0, 15.0]]}
                                         for a in m]))
    order = [str(s.asset_id) for s in plan.segments]
    assert order[0] == m[0]                                   # Moment 1 first
    assert set(order) == set(m)                               # all clips preserved
    total = sum(s.output_duration_seconds for s in plan.segments)
    assert total < 85.0                                       # shorter total allowed (not padded to 85s)
    assert eng.last_diagnostics["final"] == "executable"
    assert eng.last_diagnostics["continuity"]["verdict"] == "ok"


def test_duration_target_source_defaults_to_user_exact():
    from edit_planner import _duration_target_source
    assert _duration_target_source(_inputs()) == "user_exact"
    assert _duration_target_source(_inputs(revision_context={"duration_target_source": "ai_recommended"})) == "ai_recommended"
    assert _duration_target_source(_inputs(revision_context={"duration_target_source": "garbage"})) == "user_exact"


def test_engine_deterministic_fast_path_zero_model_calls():
    # A revise carrying base_plan + a structural directive and NO soft_direction must resolve with 0 model calls.
    a, b = M1, M2
    def seg(o, aid): return {"order": o, "asset_id": aid, "source_start_seconds": 1.0,
                             "source_end_seconds": 7.0, "output_duration_seconds": 6.0, "native_audio": "keep"}
    # base plan must itself be duration-valid for the target (reorder keeps total unchanged); use a target
    # that matches the base so the fast-path result passes the duration gate.
    base_plan = {"schema_version": "edit_plan/2", "target_duration_seconds": 12.0, "feasible": True,
                 "segments": [seg(0, a), seg(1, b)]}
    rc = {"mode": "revise", "base_version_id": "v1", "base_plan": base_plan,
          "directives": {"opening": b}}   # make B the opening
    # A gateway that FAILS if called — proves the fast path never calls the model.
    class _Boom:
        last_fallback = False
        def generate_structured(self, req):
            raise AssertionError("model must NOT be called on the deterministic fast path")
    eng = RealEditPlannerEngine(_Boom())
    plan = eng.generate(_inputs(revision_context=rc, creative_intent={"target_duration_seconds": 12.0, "desired_feeling": ["calm"]}))
    assert eng.last_diagnostics["revision_path"] == "deterministic"
    assert eng.last_diagnostics["model_calls"] == 0
    assert str(plan.segments[0].asset_id) == b   # opening honored


# ---------------------------------------------------------------------------
# Phase 4 — preflight (plan-independent) directive validation.
# ---------------------------------------------------------------------------
def test_preflight_passes_clean_directives():
    from edit_planner import preflight_directives
    a, b = str(uuid4()), str(uuid4())
    assert preflight_directives({"opening": a, "order_adjacent": [[b, a]]}, {a, b}) == []


def test_preflight_flags_missing_reference():
    from edit_planner import preflight_directives
    a = str(uuid4()); ghost = str(uuid4())
    errs = preflight_directives({"opening": ghost}, {a})
    assert any(ghost in e and "not in this Story" in e for e in errs)


def test_preflight_flags_include_exclude_conflict():
    from edit_planner import preflight_directives
    a = str(uuid4())
    errs = preflight_directives({"must_include": [a], "exclude": [a]}, {a})
    assert any("both required and excluded" in e for e in errs)


def test_preflight_flags_over_exclusion_leaves_too_few():
    # Regression (device scenario #2): the interpreter produced excludes that stripped the Story down to <2
    # eligible Moments; the planner then honestly failed 'invalid_after_repair'. Preflight must catch this
    # BEFORE the expensive job and turn it into an upfront clarify.
    from edit_planner import preflight_directives
    a, b, c, d = str(uuid4()), str(uuid4()), str(uuid4()), str(uuid4())
    eligible = {a, b, c, d}
    # Excluding 3 of 4 leaves only 1 -> block.
    errs = preflight_directives({"exclude": [a, b, c]}, eligible)
    assert any("keep at least 2" in e for e in errs)
    # Excluding 2 of 4 leaves 2 -> allowed (no over-exclusion error).
    ok = preflight_directives({"exclude": [a, b]}, eligible)
    assert not any("keep at least 2" in e for e in ok)


def test_preflight_flags_contradictory_and_impossible_adjacency():
    from edit_planner import preflight_directives
    a, b, c = str(uuid4()), str(uuid4()), str(uuid4())
    e1 = preflight_directives({"order_after": [[a, b], [b, a]]}, {a, b})
    assert any("Contradictory ordering" in e for e in e1)
    e2 = preflight_directives({"order_adjacent": [[a, b], [a, c]]}, {a, b, c})
    assert any("immediately follow more than one" in e for e in e2)


def test_preflight_empty_is_noop():
    from edit_planner import preflight_directives
    assert preflight_directives({}, set()) == []


def test_repair_errors_non_visual_classification():
    # Phase 3 targeted repair: numeric/structural errors send NO images; a useful_segment error keeps them.
    from edit_planner import _errors_are_non_visual
    assert _errors_are_non_visual(["seg0: speed 4.0 out of range [0.5, 2.0]"])
    assert _errors_are_non_visual(["seg2: source_end 12.0 exceeds Moment duration 9.8",
                                   "segment order not monotonic: [0, 2, 1]"])
    assert _errors_are_non_visual(["directive opening: first segment must be Moment 'x' but is 'y'"])
    # A useful-segment coverage error benefits from frames -> keep images (not non-visual).
    assert not _errors_are_non_visual(["seg1: source range [1.0,3.0] overlaps NO useful_segment [[4.0,6.0]]"])
    # Mixed: any visual marker keeps images.
    assert not _errors_are_non_visual(["seg0: speed 4.0 out of range",
                                       "seg1: source range overlaps NO useful_segment"])


# ============================================================================
# Creative Freedom AMENDMENT v2 — creative directives as strong editorial
# objectives, not terminal failures. Cost-aware repair. Safety/privacy hard.
# All behind flags, default OFF. These tests FLIP the flags per-case.
# ============================================================================
from edit_planner import (  # noqa: E402
    assess_creative_intent,
    _validate_directives_split,
    _exclude_is_safety,
    _objective_directives_on,
)


def _obj_env(monkeypatch, **extra):
    monkeypatch.setenv("STORY_EDITPLAN_OBJECTIVE_DIRECTIVES", "1")
    monkeypatch.setenv("STORY_EDITPLAN_BEST_VALID_RETENTION", "1")
    for k, v in extra.items():
        monkeypatch.setenv(k, v)


def test_v2_flags_default_off_is_legacy(monkeypatch):
    # With no flags set, an unmet opening directive is STILL a hard validation error (unchanged behavior).
    monkeypatch.delenv("STORY_EDITPLAN_OBJECTIVE_DIRECTIVES", raising=False)
    assert _objective_directives_on() is False
    bad = _good_plan()  # M1 then M2; require M2 opening
    inp = _inputs(revision_context=_rev({"opening": M2}))
    errs = validate_plan(bad, inp)
    assert any("directive opening:" in e for e in errs)   # hard in legacy mode


def test_v2_unmet_opening_is_objective_not_hard(monkeypatch):
    # Flag ON: a mis-ordered opening is NOT a hard error — validate_plan passes; the miss is an OBJECTIVE.
    _obj_env(monkeypatch)
    bad = _good_plan()  # M1 then M2
    inp = _inputs(revision_context=_rev({"opening": M2}))
    assert validate_plan(bad, inp) == []                  # technically valid -> shippable
    hard, obj = _validate_directives_split(bad, inp, {str(m["id"]).lower(): m for m in inp.moments})
    assert hard == [] and any("directive opening:" in e for e in obj)
    rep = assess_creative_intent(bad, inp)
    assert rep["satisfied"] is False and rep["material_unmet"]
    assert rep["material_unmet"][0]["code"] == "opening"


def test_v2_reference_to_unknown_moment_stays_hard(monkeypatch):
    # An unknown/unowned Moment reference is a HARD error even in objective mode (integrity).
    _obj_env(monkeypatch)
    inp = _inputs(revision_context=_rev({"opening": str(uuid4())}))
    errs = validate_plan(_good_plan(), inp)
    assert any("not in the eligible source set" in e for e in errs)


def test_v2_safety_exclude_is_hard_creative_exclude_is_objective(monkeypatch):
    _obj_env(monkeypatch)
    plan = _good_plan()  # uses M1 and M2
    ms = {str(m["id"]).lower(): m for m in _inputs().moments}
    # Creative exclude (explicitly marked) of a used Moment -> OBJECTIVE, not hard.
    inp_creative = _inputs(revision_context=_rev({"exclude": [M2], "exclude_creative": [M2]}))
    hard, obj = _validate_directives_split(plan, inp_creative, ms)
    assert hard == [] and any("directive exclude:" in e for e in obj)
    assert validate_plan(plan, inp_creative) == []
    # Safety exclude (marked privacy) of a used Moment -> HARD, never shippable.
    inp_safety = _inputs(revision_context=_rev({"exclude": [M2], "exclude_reason": {M2: "privacy"}}))
    hard2, _ = _validate_directives_split(plan, inp_safety, ms)
    assert any("safety/privacy" in e for e in hard2)
    assert any("safety/privacy" in e for e in validate_plan(plan, inp_safety))


def test_v2_missing_exclude_marker_defaults_to_safety(monkeypatch):
    # Owner principle 3: a missing marker must NOT be treated as creative — fail safe.
    _obj_env(monkeypatch)
    directives = {"exclude": [M2]}  # no marker at all
    assert _exclude_is_safety(directives, M2) is True
    plan = _good_plan()
    inp = _inputs(revision_context=_rev(directives))
    assert any("safety/privacy" in e for e in validate_plan(plan, inp))


def test_v2_contradiction_stays_hard(monkeypatch):
    _obj_env(monkeypatch)
    inp = _inputs(revision_context=_rev({"order_after": [[M1, M2], [M2, M1]]}))
    errs = validate_plan(_good_plan(), inp)
    assert any("directive conflict:" in e for e in errs)


def test_v2_approx_duration_soft_but_runaway_hard(monkeypatch):
    # OWNER POLICY (2026-10-25): duration is NEVER a block, so even a very large overshoot ships. The former
    # runaway guard is removed — a playable cut of any length validates. Moments are long enough that the big
    # cut is TECHNICALLY valid (source windows within bounds), isolating the length axis.
    _obj_env(monkeypatch, STORY_EDITPLAN_APPROX_DURATION_SOFT="1")
    inp = _target12_inputs(
        revision_context={"mode": "explore", "duration_target_source": "ai_recommended"},
        moments=[
            {"id": M1, "duration_seconds": 12.0, "useful_segments": [[0.0, 12.0]]},
            {"id": M2, "duration_seconds": 12.0, "useful_segments": [[0.0, 12.0]]},
            {"id": "M3", "duration_seconds": 12.0, "useful_segments": [[0.0, 12.0]]}])
    def plan3(d0, d1, d2):
        return {"target_duration_seconds": 12.0, "feasible": True, "segments": [
            {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": d0,
             "output_duration_seconds": d0, "native_audio": "keep"},
            {"order": 1, "asset_id": M2, "source_start_seconds": 0.0, "source_end_seconds": d1,
             "output_duration_seconds": d1, "native_audio": "keep"},
            {"order": 2, "asset_id": "M3", "source_start_seconds": 0.0, "source_end_seconds": d2,
             "output_duration_seconds": d2, "native_audio": "keep"}]}
    # +67% overshoot (20s vs 12) -> ships.
    assert validate_plan(plan3(7.0, 7.0, 6.0), inp) == []
    # +200% (36s vs 12 — a huge overshoot) -> ALSO ships now (no runaway guard). Never block a playable video.
    assert validate_plan(plan3(12.0, 12.0, 12.0), inp) == []


def test_v2_exact_duration_also_never_blocks_on_length(monkeypatch):
    # Even an EXPLICIT user-exact duration no longer blocks on length — a playable overshoot ships. (The user
    # asked for a length as an AIM; the pipeline gives them the best playable cut, never an error.)
    _obj_env(monkeypatch, STORY_EDITPLAN_APPROX_DURATION_SOFT="1")
    inp = _target12_inputs(revision_context={"mode": "revise", "duration_target_source": "user_exact"},
                           moments=_target12_inputs().moments + [
                               {"id": "M3", "duration_seconds": 9.0, "useful_segments": [[0.0, 8.5]]}])
    plan = {"target_duration_seconds": 12.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 0.0, "source_end_seconds": 7.0,
         "output_duration_seconds": 7.0, "native_audio": "keep"},
        {"order": 1, "asset_id": M2, "source_start_seconds": 0.0, "source_end_seconds": 7.0,
         "output_duration_seconds": 7.0, "native_audio": "keep"},
        {"order": 2, "asset_id": "M3", "source_start_seconds": 0.0, "source_end_seconds": 6.0,
         "output_duration_seconds": 6.0, "native_audio": "keep"}]}   # 20s vs 12 = +67%
    assert validate_plan(plan, inp) == []


def test_v2_47p5s_mis_ordered_directive_ships_via_reorder(monkeypatch):
    # The 47.5s class: model returns valid segments but wrong order for opening+adjacency. In objective mode the
    # engine reorders deterministically (0 extra model calls) and ships a FULLY satisfied plan.
    _obj_env(monkeypatch)
    gp = _good_plan()
    s_m1, s_m2 = gp["segments"][0], gp["segments"][1]
    wrong = {**gp, "segments": [{**s_m2, "order": 0}, {**s_m1, "order": 1}]}  # M2 first
    eng = RealEditPlannerEngine(FakeModelGateway(response=wrong))
    out = eng.generate(_inputs(revision_context={"mode": "explore", "directives": {"opening": M1}}))
    d = eng.last_diagnostics
    assert d["final"] == "executable"
    assert d["model_calls"] == 1                       # no extra repair call
    assert d.get("structural_repair") is True
    assert str(out.segments[0].asset_id).lower() == M1.lower()
    assert d.get("completion") == "complete"


def test_v2_partial_ships_with_disclosure_no_extra_calls(monkeypatch):
    # Objective that a reorder CANNOT satisfy (must_include of a Moment the model simply didn't place) -> the
    # plan is technically valid, so it SHIPS with a partial disclosure and ZERO extra model calls (cost policy).
    _obj_env(monkeypatch)
    plan = _good_plan()  # uses M1, M2
    M3 = str(uuid4())
    inp = _inputs(
        moments=_inputs().moments + [{"id": M3, "duration_seconds": 5.0, "useful_segments": [[0.0, 4.0]]}],
        revision_context={"mode": "explore", "directives": {"must_include": [M3]}})
    eng = RealEditPlannerEngine(FakeModelGateway(response=plan))
    eng.generate(inp)
    d = eng.last_diagnostics
    assert d["final"] == "executable" and d["completion"] == "partial"
    assert d["model_calls"] == 1                       # no repair spent chasing the objective
    assert any(m["code"] == "inclusion" for m in d["material_unmet"])
    assert "partial_disclosure" in d


def test_v2_best_valid_retained_not_discarded(monkeypatch):
    # First call returns a VALID plan but with a HARD error nowhere; a (hypothetical) later regression must not
    # discard it. Here: initial valid plan with an unmet objective -> retained + shipped, never invalid.
    _obj_env(monkeypatch)
    plan = _good_plan()
    M3 = str(uuid4())
    inp = _inputs(
        moments=_inputs().moments + [{"id": M3, "duration_seconds": 5.0, "useful_segments": [[0.0, 4.0]]}],
        revision_context={"mode": "explore", "directives": {"must_include": [M3]}})
    eng = RealEditPlannerEngine(FakeModelGateway(response=plan))
    out = eng.generate(inp)
    assert out is not None and eng.last_diagnostics["final"] == "executable"


def test_v2_revise_zero_repair_budget(monkeypatch):
    # Revise with a HARD-valid first plan: budget is 0 repairs, ships immediately.
    _obj_env(monkeypatch)
    eng = RealEditPlannerEngine(FakeModelGateway(response=_good_plan()))
    eng.generate(_inputs(revision_context={"mode": "revise", "base_plan": _good_plan(),
                                            "allow_broad_replan": True}))
    d = eng.last_diagnostics
    assert d["repair_budget"] == 0 and d["executability_repairs_used"] == 0


def test_v2_technical_error_still_fails_when_unrecoverable(monkeypatch):
    # A HARD technical error with no valid candidate anywhere still fails honestly (speed unrenderable).
    _obj_env(monkeypatch)
    bad = _good_plan()
    bad["segments"][0]["speed"] = 4.0   # out of renderer range -> HARD, unrecoverable here (Fake repeats it)
    eng = RealEditPlannerEngine(FakeModelGateway(response=bad))
    with pytest.raises(StructuredOutputError):
        eng.generate(_inputs(revision_context={"mode": "explore", "directives": {"opening": M1}}))
    assert eng.last_diagnostics["final"] == "invalid_after_repair"


# ---- Directed Create Another Version (Explore + directives) — owner routing fix 2026-10-22 ----
# A directed Create Another Version stays mode=explore (not rerouted to revise). These assert the ENGINE
# honors that: directives are enforced/scored independently of mode, the revise continuity gate does NOT
# apply to explore, and a valid plan still ships.

def test_v2_directed_explore_enforces_directive_reference(monkeypatch):
    # An explore request with a directive referencing an UNKNOWN Moment is a HARD error regardless of mode.
    _obj_env(monkeypatch)
    inp = _inputs(revision_context={"mode": "explore", "directives": {"opening": str(uuid4())}})
    errs = validate_plan(_good_plan(), inp)
    assert any("not in the eligible source set" in e for e in errs)


def test_v2_directed_explore_scores_objectives(monkeypatch):
    # In explore mode, an unmet opening is an OBJECTIVE (scored), not a hard error — same as revise.
    _obj_env(monkeypatch)
    bad = _good_plan()  # M1 then M2; ask for M2 opening
    inp = _inputs(revision_context={"mode": "explore", "directives": {"opening": M2}})
    assert validate_plan(bad, inp) == []                       # technically valid -> shippable
    rep = assess_creative_intent(bad, inp)
    assert rep["satisfied"] is False and rep["material_unmet"][0]["code"] == "opening"


def test_v2_directed_explore_no_continuity_gate(monkeypatch):
    # The revise continuity gate must NOT apply to explore: a plan with a totally different clip set from a
    # (hypothetical) base ships. Explore carries no base_plan and is not a targeted revise, so even a plan
    # that shares nothing with a prior version is accepted. model_calls stays 1, final executable.
    _obj_env(monkeypatch)
    plan = _good_plan()
    inp = _inputs(revision_context={"mode": "explore",
                                    "directives": {"opening": M1},
                                    # a base_plan present in an explore ctx must NOT trigger the revise gate
                                    "base_plan": {"target_duration_seconds": 18.0, "feasible": True,
                                                  "segments": [{"order": 0, "asset_id": M2,
                                                                "source_start_seconds": 0.5, "source_end_seconds": 6.0,
                                                                "output_duration_seconds": 5.5, "native_audio": "keep"}]}})
    eng = RealEditPlannerEngine(FakeModelGateway(response=plan))
    out = eng.generate(inp)
    d = eng.last_diagnostics
    assert d["final"] == "executable"
    assert "continuity" not in d, "explore must not run the revise continuity assessment"
    assert str(out.segments[0].asset_id).lower() == M1.lower()


def test_v2_directed_explore_ships_meaningfully_different(monkeypatch):
    # Representative fixture: an explore whose model output selects/orders a genuinely different set than the
    # parent (M1 opening + a 3rd moment) ships as a valid, complete plan at 1 call.
    _obj_env(monkeypatch)
    M3 = str(uuid4())
    plan = {"target_duration_seconds": 18.0, "feasible": True, "segments": [
        {"order": 0, "asset_id": M1, "source_start_seconds": 1.0, "source_end_seconds": 9.0,
         "output_duration_seconds": 10.0, "native_audio": "keep"},
        {"order": 1, "asset_id": M3, "source_start_seconds": 0.0, "source_end_seconds": 5.0,
         "output_duration_seconds": 5.0, "native_audio": "keep"}]}
    inp = _inputs(
        moments=_inputs().moments + [{"id": M3, "duration_seconds": 6.0, "useful_segments": [[0.0, 5.0]]}],
        revision_context={"mode": "explore", "directives": {"opening": M1}})
    eng = RealEditPlannerEngine(FakeModelGateway(response=plan))
    out = eng.generate(inp)
    d = eng.last_diagnostics
    assert d["final"] == "executable" and d["completion"] == "complete"
    assert d["model_calls"] == 1
    assert str(out.segments[0].asset_id).lower() == M1.lower()
