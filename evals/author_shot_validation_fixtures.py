"""One-shot author of Shot Validation fixtures (C4A step 3).

Encodes, per fixture, the requested Shot/Beat CONTEXT and the EXPECTED four-axis
ground truth (+ tags), derived from the corpus filenames and NOTES semantics and
the approved axis vocabulary. Writes request.json + expectations.json under
evals/shot_validation/scenarios/<SET>/<FIXTURE_ID>/.

Ground truth is a human judgment call per clip; this file IS that record (review
it, not the generated JSON). Derived fields in expectations are computed by the
same deterministic derive() the runner uses, so expectations stay self-consistent.
Run once: python evals/author_shot_validation_fixtures.py
"""
from __future__ import annotations
import json, pathlib
from shot_validation import (ShotValidationJudgment as J, derive,
    TechnicalUsability as T, ExecutionMatch as E, ShotPurpose as P, StoryUtility as U)

REPO = pathlib.Path(__file__).resolve().parents[1]
OUT = REPO / "evals/shot_validation/scenarios"

# Per-set requested Shot + Beat context (the purpose the clips are judged against).
SETS = {
  "S01_backpack_static": dict(
    purpose="Hold a steady, clear shot of the backpack as the object of the moment.",
    instruction="Hold the camera steady on your backpack for a few seconds.",
    subject_action="backpack stationary, framed", camera_motion="static",
    target_duration_seconds=4, beat_id="beat_object", beat_purpose="Establish the gear/object."),
  "S02_departure": dict(
    purpose="Communicate departure / the beginning of the journey.",
    instruction="Walk toward the camera down the hallway, like you're heading out.",
    subject_action="walk toward camera and depart", camera_motion="static",
    target_duration_seconds=4, beat_id="beat_departure", beat_purpose="Beginning of the journey."),
  "S03_scenic_reveal": dict(
    purpose="Reveal the landscape by moving from the friend to the vista (friend -> landscape).",
    instruction="Start on your friend, then pan to reveal the landscape.",
    subject_action="pan from person to landscape", camera_motion="pan",
    target_duration_seconds=5, beat_id="beat_reveal", beat_purpose="Reveal the place."),
  "S04_human_scale": dict(
    purpose="Establish the scale contrast between a small human and the large landscape.",
    instruction="Frame your friend small against the big landscape.",
    subject_action="small person in large landscape", camera_motion="static",
    target_duration_seconds=4, beat_id="beat_scale", beat_purpose="Human/landscape scale contrast."),
  "S05_trail_progression": dict(
    purpose="Show progression deeper into the landscape (movement along the trail).",
    instruction="Follow behind your friend as they walk up the trail.",
    subject_action="subject progresses along trail", camera_motion="follow",
    target_duration_seconds=5, beat_id="beat_progress", beat_purpose="Progression into the landscape."),
  "S06_difficulty": dict(
    purpose="Convey the difficulty / effort of the hike.",
    instruction="Capture a moment that shows how tough the hike is.",
    subject_action="evidence of effort/hardship", camera_motion="any",
    target_duration_seconds=4, beat_id="beat_difficulty", beat_purpose="Show the effort it took."),
  "S07_companionship": dict(
    purpose="Convey genuine companionship between the people.",
    instruction="Capture you and your friend together, naturally.",
    subject_action="authentic interaction between companions", camera_motion="any",
    target_duration_seconds=5, beat_id="beat_companion", beat_purpose="The people you shared it with."),
  "S08_end_of_day": dict(
    purpose="Convey the quiet end-of-day winding-down mood.",
    instruction="Capture a calm end-of-day moment.",
    subject_action="quiet end-of-day activity", camera_motion="any",
    target_duration_seconds=5, beat_id="beat_endofday", beat_purpose="Settling, the day ending."),
  "T01_technical_controls": dict(
    purpose="Hold a clean, steady, well-exposed, in-focus shot of the subject.",
    instruction="Hold a steady, clear shot of the subject for a few seconds.",
    subject_action="subject framed clearly", camera_motion="static",
    target_duration_seconds=4, beat_id="beat_object", beat_purpose="A clean usable shot."),
  "A01_semantic_adversarial": dict(  # per-fixture purpose overridden below
    purpose="(adversarial — see per-fixture)", instruction="(see per-fixture)",
    subject_action="(see per-fixture)", camera_motion="any",
    target_duration_seconds=4, beat_id="beat_adv", beat_purpose="(adversarial)"),
}
CONCEPT = "A quiet, authentic hiking story — the people, the effort, and the landscape."

# Per-fixture expected axes + tags. (tech, exec, purpose, util, tags)
FX = {
  # S01 backpack static
  "S01_backpack_static__A_exact_good": (T.USABLE, E.MATCHED, P.FULFILLED, U.USEFUL_ELSEWHERE, ["technical"]),
  "S01_backpack_static__B_too_short": (T.UNUSABLE, E.MATCHED, P.UNFULFILLED, U.NONE, ["technical"]),
  "S01_backpack_static__C_shaky": (T.MINOR_ISSUES, E.MATCHED, P.PARTIAL, U.USEFUL_ELSEWHERE, ["technical"]),
  "S01_backpack_static__D_poor_framing": (T.MINOR_ISSUES, E.DEVIATED, P.PARTIAL, U.USEFUL_ELSEWHERE, []),
  "S01_backpack_static__E_wrong_subject": (T.USABLE, E.ABSENT, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["wrong_subject"]),
  "S01_backpack_static__F_alternative_good": (T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.STRONG_ELSEWHERE, ["alternative_success"]),
  # S02 departure (temporal)
  "S02_departure__A_exact_good": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, ["temporal"]),
  "S02_departure__B_stand_still": (T.USABLE, E.ABSENT, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["temporal"]),
  "S02_departure__D_walk_away_through_door": (T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.STRONG_ELSEWHERE, ["temporal","alternative_success"]),
  "S02_departure__E_pickup_backpack_and_leave": (T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.STRONG_ELSEWHERE, ["temporal","alternative_success"]),
  "S02_departure__F_slightly_shaky_but_good": (T.MINOR_ISSUES, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, ["temporal","technical"]),
  "S02_departure__G_contradictory_action": (T.USABLE, E.CONTRADICTED, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["temporal","contradiction"]),
  # S03 scenic reveal (temporal direction)
  "S03_scenic_reveal__A_exact_friend_to_landscape__take1": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, ["temporal"]),
  "S03_scenic_reveal__A_exact_friend_to_landscape__take2": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, ["temporal"]),
  "S03_scenic_reveal__B_landscape_only": (T.USABLE, E.ABSENT, P.UNFULFILLED, U.STRONG_ELSEWHERE, ["temporal"]),
  "S03_scenic_reveal__C_friend_only__take1": (T.USABLE, E.ABSENT, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["temporal"]),
  "S03_scenic_reveal__C_friend_only__take2": (T.USABLE, E.ABSENT, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["temporal"]),
  "S03_scenic_reveal__D_reverse_reveal__take1": (T.USABLE, E.CONTRADICTED, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["temporal","contradiction"]),
  "S03_scenic_reveal__D_reverse_reveal__take2": (T.USABLE, E.CONTRADICTED, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["temporal","contradiction"]),
  "S03_scenic_reveal__E_bad_whip_pan": (T.UNUSABLE, E.MATCHED, P.UNFULFILLED, U.NONE, ["technical"]),
  # S04 human scale
  "S04_human_scale__A_exact_small_person_landscape__take1": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  "S04_human_scale__A_exact_small_person_landscape__take2": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  "S04_human_scale__B_person_too_large": (T.USABLE, E.MATCHED, P.UNFULFILLED, U.USEFUL_ELSEWHERE, []),
  "S04_human_scale__C_landscape_no_person": (T.USABLE, E.ABSENT, P.UNFULFILLED, U.STRONG_ELSEWHERE, []),
  "S04_human_scale__D_small_person_moving": (T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.STRONG_ELSEWHERE, ["alternative_success"]),
  "S04_human_scale__E_two_people_small": (T.USABLE, E.DEVIATED, P.PARTIAL, U.USEFUL_ELSEWHERE, []),
  # S05 trail progression (temporal)
  "S05_trail_progression__A_follow_behind": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, ["temporal"]),
  "S05_trail_progression__B_static_camera_walk_away": (T.USABLE, E.DEVIATED, P.PARTIAL, U.USEFUL_ELSEWHERE, ["temporal"]),
  "S05_trail_progression__C_subject_static_camera_moves": (T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.USEFUL_ELSEWHERE, ["temporal","alternative_success"]),
  "S05_trail_progression__D_follow_but_shaky": (T.MINOR_ISSUES, E.MATCHED, P.PARTIAL, U.USEFUL_ELSEWHERE, ["temporal","technical"]),
  "S05_trail_progression__E_feet_walking__take1": (T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.USEFUL_ELSEWHERE, ["temporal","alternative_success"]),
  "S05_trail_progression__E_feet_walking__take2": (T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.USEFUL_ELSEWHERE, ["temporal","alternative_success"]),
  "S05_trail_progression__E_static_camera_two_people": (T.USABLE, E.ABSENT, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["temporal"]),
  # S06 difficulty
  "S06_difficulty__B_tired_face__take1": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  "S06_difficulty__B_tired_face__take2": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  "S06_difficulty__C_hand_trekking_pole": (T.USABLE, E.DEVIATED, P.PARTIAL, U.USEFUL_ELSEWHERE, []),
  "S06_difficulty__D_heavy_footsteps": (T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.USEFUL_ELSEWHERE, ["alternative_success"]),
  "S06_difficulty__E_cross_river": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  "S06_difficulty__F_eat_food_in_snow": (T.USABLE, E.DEVIATED, P.PARTIAL, U.USEFUL_ELSEWHERE, []),
  "S06_difficulty__G_storm_cold": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  "S06_difficulty__G_storm_wind": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  # S07 companionship
  "S07_companionship__A_natural_conversation": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  "S07_companionship__C_one_person_only": (T.USABLE, E.ABSENT, P.UNFULFILLED, U.USEFUL_ELSEWHERE, []),
  "S07_companionship__D_imperfect_but_natural": (T.MINOR_ISSUES, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, ["technical"]),
  "S07_companionship__E_wrong_people": (T.USABLE, E.ABSENT, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["wrong_subject"]),
  "S07_companionship__F_two_people_selfie": (T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.STRONG_ELSEWHERE, ["alternative_success"]),
  "S07_companionship__G_walking_together": (T.USABLE, E.DEVIATED, P.ALTERNATIVE_FULFILLED, U.STRONG_ELSEWHERE, ["alternative_success"]),
  # S08 end of day
  "S08_end_of_day__A_quiet_window": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  "S08_end_of_day__B_quiet_stove": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  "S08_end_of_day__C_sleepy_person": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  "S08_end_of_day__D_cooking_dinner": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, ["long_clip"]),
  "S08_end_of_day__E_tired_face": (T.USABLE, E.DEVIATED, P.PARTIAL, U.USEFUL_ELSEWHERE, []),
  "S08_end_of_day__F_nice_dinner_window_view": (T.USABLE, E.MATCHED, P.FULFILLED, U.STRONG_ELSEWHERE, []),
  # T01 technical controls
  "T01_technical_controls__A_clean_4s": (T.USABLE, E.MATCHED, P.FULFILLED, U.USEFUL_ELSEWHERE, ["technical"]),
  "T01_technical_controls__B_too_short_08s": (T.UNUSABLE, E.MATCHED, P.UNFULFILLED, U.NONE, ["technical"]),
  "T01_technical_controls__C_moderate_shake": (T.MINOR_ISSUES, E.MATCHED, P.PARTIAL, U.USEFUL_ELSEWHERE, ["technical"]),
  "T01_technical_controls__D_severe_shake": (T.UNUSABLE, E.MATCHED, P.UNFULFILLED, U.NONE, ["technical"]),
  "T01_technical_controls__E_underexposed": (T.UNUSABLE, E.MATCHED, P.UNFULFILLED, U.NONE, ["technical"]),
  "T01_technical_controls__F_overexposed": (T.UNUSABLE, E.MATCHED, P.UNFULFILLED, U.NONE, ["technical"]),
  "T01_technical_controls__G_out_of_focus": (T.UNUSABLE, E.MATCHED, P.UNFULFILLED, U.NONE, ["technical","focus"]),
  "T01_technical_controls__H_partial_occlusion": (T.MINOR_ISSUES, E.MATCHED, P.PARTIAL, U.USEFUL_ELSEWHERE, ["technical"]),
  "T01_technical_controls__I_camera_points_away": (T.UNUSABLE, E.ABSENT, P.UNFULFILLED, U.NONE, ["technical"]),
  # A01 adversarial (per-fixture purpose)
  "A01_semantic_adversarial__A01_hiking_but_not_difficulty": (T.USABLE, E.MATCHED, P.UNFULFILLED, U.STRONG_ELSEWHERE, ["adversarial"]),
  "A01_semantic_adversarial__A02_people_but_not_companionship": (T.USABLE, E.MATCHED, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["adversarial"]),
  "A01_semantic_adversarial__A03_backpack_but_arrival_not_departure": (T.USABLE, E.CONTRADICTED, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["adversarial","temporal","contradiction"]),
  "A01_semantic_adversarial__A04_person_mountain_but_no_scale": (T.USABLE, E.MATCHED, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["adversarial"]),
  "A01_semantic_adversarial__A05_motion_but_wrong_motion": (T.USABLE, E.CONTRADICTED, P.UNFULFILLED, U.USEFUL_ELSEWHERE, ["adversarial","temporal","contradiction"]),
  "A01_semantic_adversarial__A06_beautiful_but_wrong_beat": (T.USABLE, E.MATCHED, P.UNFULFILLED, U.STRONG_ELSEWHERE, ["adversarial"]),
}

# Per-fixture purpose overrides for adversarial set (the REQUESTED purpose each
# clip is adversarial against).
ADV_PURPOSE = {
  "A01_semantic_adversarial__A01_hiking_but_not_difficulty": ("Convey the DIFFICULTY of the hike.", "beat_difficulty", "Show the effort it took."),
  "A01_semantic_adversarial__A02_people_but_not_companionship": ("Convey genuine COMPANIONSHIP.", "beat_companion", "The people you shared it with."),
  "A01_semantic_adversarial__A03_backpack_but_arrival_not_departure": ("Communicate DEPARTURE / beginning of journey.", "beat_departure", "Beginning of the journey."),
  "A01_semantic_adversarial__A04_person_mountain_but_no_scale": ("Establish human/landscape SCALE contrast.", "beat_scale", "Scale contrast."),
  "A01_semantic_adversarial__A05_motion_but_wrong_motion": ("Communicate departure via walking toward the camera.", "beat_departure", "Beginning of the journey."),
  "A01_semantic_adversarial__A06_beautiful_but_wrong_beat": ("Convey the DIFFICULTY of the hike.", "beat_difficulty", "Show the effort it took."),
}

def main():
    n = 0
    for fid, (tech, ex, purpose, util, tags) in FX.items():
        set_ = fid.split("__", 1)[0]
        base = dict(SETS[set_])
        if set_ == "A01_semantic_adversarial":
            pur, bid, bpur = ADV_PURPOSE[fid]
            base["purpose"] = pur; base["beat_id"] = bid; base["beat_purpose"] = bpur
            base["instruction"] = f"Capture a shot that: {pur}"
        d = derive(J(technical_usability=tech, execution_match=ex, shot_purpose=purpose, story_utility=util))
        fdir = OUT / set_ / fid
        fdir.mkdir(parents=True, exist_ok=True)
        request = {
            "fixture_id": fid,
            "shot": {"purpose": base["purpose"], "instruction": base["instruction"],
                     "subject_action": base["subject_action"], "camera_motion": base["camera_motion"],
                     "target_duration_seconds": base["target_duration_seconds"]},
            "beat": {"id": base["beat_id"], "purpose": base["beat_purpose"]},
            "concept_summary": CONCEPT,
        }
        expectations = {
            "technical_usability": tech.value, "execution_match": ex.value,
            "shot_purpose": purpose.value, "story_utility": util.value,
            "clip_disposition": d.clip_disposition.value,
            "requested_shot_status": d.requested_shot_status.value,
            "user_state": d.user_state.value,
            "becomes_moment": d.becomes_moment,
            "tags": tags,
        }
        (fdir / "request.json").write_text(json.dumps(request, indent=2) + "\n")
        (fdir / "expectations.json").write_text(json.dumps(expectations, indent=2) + "\n")
        n += 1
    print(f"authored {n} fixtures under {OUT}")

if __name__ == "__main__":
    main()
