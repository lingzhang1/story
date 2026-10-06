"""Build the Story Coverage experiment fixture set (reconciliation §11; task §1-3).

Each fixture: {id, creative_intent, scope(target_duration/format), moments[(id, pending?,
MomentUnderstanding)], pending_count, human_reference{sufficiency, idea_should_exist,
idea_opportunity?, expected_properties[], forbidden_properties[]}}.

Provenance per moment: REAL = verbatim from evals/results/au_production_gate.json (the real engine's
device-grade output); SYN = controlled synthetic structured MomentUnderstanding authored to isolate a
behavior (clearly flagged). We do NOT pin exact expected prose — only semantic properties.
"""
from __future__ import annotations
import json, pathlib

REPO = pathlib.Path(__file__).resolve().parents[2]
REAL = json.loads((REPO / "evals/story_coverage/real_moment_understanding.json").read_text())


def mu(observed, utility, shot=None, beat=None):
    """Synthetic MomentUnderstanding (observed/story_context split)."""
    return {"observed": observed,
            "story_context": {"story_utility": utility,
                              "requested_shot_contribution": shot,
                              "requested_beat_contribution": beat}}


def real(fid):
    r = REAL[fid]
    return {"observed": r["observed"], "story_context": r["story_context"]}


def obs(summary, subjects, events, temporal, useful):
    return {"summary": summary, "subjects": subjects, "events": events,
            "temporal_order_note": temporal, "useful_segments": useful}


# Shorthand synthetic observed blocks (SYN) ----------------------------------
def panorama(n):
    return obs(f"A wide static mountain panorama (variant {n}): snow-capped peaks under blue sky, no people.",
               ["mountain range", "sky"],
               [{"start_time": 0.0, "end_time": 6.0, "description": "static wide shot of snow-capped peaks"}],
               "single continuous static vista, no development",
               [{"start_time": 0.0, "end_time": 6.0, "why_useful": "clean establishing vista"}])


FIXTURES = {
 # A — scenery only (REAL scenery Moments). Intent allows a human opportunity.
 "A_scenery_only": {
   "creative_intent": {"raw_text": "the beauty and scale of the Tour du Mont Blanc", "theme": "landscape journey",
     "tone": "awe", "subject": "the mountains", "desired_feeling": ["awe", "vastness"], "emphasis": ["landscape"]},
   "scope": {"target_duration_seconds": 60, "format": "vertical"},
   "moments": [
     {"id": "m1", "provenance": "REAL", **real("S04_human_scale__A_exact_small_person_landscape__take1")},
     {"id": "m2", "provenance": "REAL", **real("S03_scenic_reveal__D_reverse_reveal__take1")},
     {"id": "m3", "provenance": "REAL", **real("A01_semantic_adversarial__A01_hiking_but_not_difficulty")},
     {"id": "m4", "provenance": "SYN", **mu(panorama(1), "useful_elsewhere")},
   ],
   "pending_count": 0,
   "human_reference": {"sufficiency": "workable", "idea_should_exist": True,
     "idea_opportunity": "a human/relational or quiet end-of-day moment to complement the strong landscape coverage",
     "expected_properties": ["environment/place = strong", "recognizes landscape is well covered",
        "may suggest a human/emotional opportunity (intent permits)"],
     "forbidden_properties": ["asks for more scenery", "invents a required 'companionship' slot as obligation",
        "emits camera/framing direction"]}},

 # B — broad coverage (REAL: scenery+departure+progression+difficulty+companionship).
 "B_broad_coverage": {
   "creative_intent": {"raw_text": "our 8-day Tour du Mont Blanc trek", "theme": "journey", "tone": "reflective",
     "subject": "our trek", "desired_feeling": ["adventure", "togetherness"], "emphasis": ["journey", "people"]},
   "scope": {"target_duration_seconds": 90, "format": "vertical"},
   "moments": [
     {"id": "m1", "provenance": "REAL", **real("S02_departure__A_exact_good")},
     {"id": "m2", "provenance": "REAL", **real("S05_trail_progression__A_follow_behind")},
     {"id": "m3", "provenance": "REAL", **real("S06_difficulty__E_cross_river")},
     {"id": "m4", "provenance": "REAL", **real("S07_companionship__A_natural_conversation")},
     {"id": "m5", "provenance": "REAL", **real("S03_scenic_reveal__D_reverse_reveal__take1")},
   ],
   "pending_count": 0,
   "human_reference": {"sufficiency": "sufficient", "idea_should_exist": False,
     "expected_properties": ["recognizes complementary coverage across departure/progression/difficulty/companionship/scenery",
        "concludes sufficient or near-sufficient for a 90s story"],
     "forbidden_properties": ["invents an arbitrary missing requirement", "suggests more of an already-strong dimension"]}},

 # C — redundant scenery (8 near-identical SYN panoramas + 1 real).
 "C_redundant_scenery": {
   "creative_intent": {"raw_text": "mountains of the TMB", "theme": "landscape", "tone": "awe",
     "subject": "mountains", "desired_feeling": ["vastness"], "emphasis": ["landscape"]},
   "scope": {"target_duration_seconds": 45, "format": "vertical"},
   "moments": [{"id": f"m{i}", "provenance": "SYN", **mu(panorama(i), "useful_elsewhere")} for i in range(1, 9)]
             + [{"id": "m9", "provenance": "REAL", **real("S04_human_scale__A_exact_small_person_landscape__take1")}],
   "pending_count": 0,
   "human_reference": {"sufficiency": "workable", "idea_should_exist": True,
     "idea_opportunity": "variety beyond repeated panoramas — a human or progression moment",
     "expected_properties": ["identifies redundancy among the panoramas", "environment = strong (ONE strong, not eight)",
        "quantity does not inflate coverage"],
     "forbidden_properties": ["treats 8 similar panoramas as 8 distinct needs met", "asks for more panoramas",
        "reports environment coverage as stronger because of count"]}},

 # D — strong_elsewhere (REAL S02_D: failed requested departure 'walk away' but strong_elsewhere).
 "D_strong_elsewhere": {
   "creative_intent": {"raw_text": "our departure and the start of the journey", "theme": "journey", "tone": "hopeful",
     "subject": "setting out", "desired_feeling": ["anticipation"], "emphasis": ["departure"]},
   "scope": {"target_duration_seconds": 30, "format": "vertical"},
   "moments": [{"id": "m1", "provenance": "REAL", **real("S02_departure__D_walk_away_through_door")}],
   "pending_count": 0,
   "human_reference": {"sufficiency": "workable", "idea_should_exist": True,
     "idea_opportunity": "complementary departure/journey material; the existing clip still contributes threshold-crossing value",
     "expected_properties": ["preserves the Moment's broader value (strong_elsewhere, threshold-crossing)",
        "does NOT treat requested-shot failure as zero contribution"],
     "forbidden_properties": ["discards the Moment because it failed the requested 'walk away' shot",
        "reports no usable departure material at all"]}},

 # E — contextless (REAL S08_F but with story_context contributions nulled to simulate Skip-Scan).
 "E_contextless": {
   "creative_intent": {"raw_text": "a quiet trip", "theme": "travel", "tone": "calm", "subject": "the trip",
     "desired_feeling": ["calm"], "emphasis": []},
   "scope": {"target_duration_seconds": 30, "format": "vertical"},
   "moments": [{"id": "m1", "provenance": "REAL(context-stripped)",
     "observed": REAL["S08_end_of_day__F_nice_dinner_window_view"]["observed"],
     "story_context": {"story_utility": "strong_elsewhere", "requested_shot_contribution": None,
                       "requested_beat_contribution": None}}],
   "pending_count": 0,
   "human_reference": {"sufficiency": "workable", "idea_should_exist": True,
     "idea_opportunity": "complementary material; reasons purely from observed meal+window-vista content",
     "expected_properties": ["reasons from observed content alone", "does not require a Director history",
        "recognizes an end-of-day / place detail from observed content"],
     "forbidden_properties": ["treats the Moment as empty because requested_* is null",
        "claims it cannot assess without a requested shot"]}},

 # F1 / F2 — one exceptional Moment, two intents (sufficiency relative to scope).
 "F1_one_exceptional_short": {
   "creative_intent": {"raw_text": "one perfect shot of the valley", "theme": "a single moment", "tone": "awe",
     "subject": "the valley", "desired_feeling": ["awe"], "emphasis": ["landscape"]},
   "scope": {"target_duration_seconds": 8, "format": "vertical"},
   "moments": [{"id": "m1", "provenance": "REAL", **real("S04_human_scale__A_exact_small_person_landscape__take1")}],
   "pending_count": 0,
   "human_reference": {"sufficiency": "sufficient", "idea_should_exist": False,
     "expected_properties": ["for an intentionally tiny story, one exceptional Moment may be sufficient"],
     "forbidden_properties": ["manufactures missing requirements for an 8s single-shot story"]}},
 "F2_one_exceptional_rich": {
   "creative_intent": {"raw_text": "the full story of our whole trek", "theme": "epic journey", "tone": "reflective",
     "subject": "the whole trek", "desired_feeling": ["adventure", "togetherness", "accomplishment"],
     "emphasis": ["journey", "people", "difficulty"]},
   "scope": {"target_duration_seconds": 120, "format": "vertical"},
   "moments": [{"id": "m1", "provenance": "REAL", **real("S04_human_scale__A_exact_small_person_landscape__take1")}],
   "pending_count": 0,
   "human_reference": {"sufficiency": "insufficient", "idea_should_exist": True,
     "idea_opportunity": "the journey/people/difficulty the rich intent asks for, none of which one landscape clip covers",
     "expected_properties": ["SAME single Moment is NOT sufficient for a rich 120s whole-trek story",
        "sufficiency is relative to CreativeIntent scope, not Moment count"],
     "forbidden_properties": ["declares sufficient just because a strong Moment exists"]}},

 # G — conflicting material (REAL good footage, intent it doesn't match).
 "G_conflicting": {
   "creative_intent": {"raw_text": "an intimate film about my relationship with my partner", "theme": "relationship",
     "tone": "tender", "subject": "my partner and me", "desired_feeling": ["intimacy", "love"], "emphasis": ["people", "faces"]},
   "scope": {"target_duration_seconds": 60, "format": "vertical"},
   "moments": [
     {"id": "m1", "provenance": "REAL", **real("S06_difficulty__E_cross_river")},
     {"id": "m2", "provenance": "REAL", **real("A01_semantic_adversarial__A01_hiking_but_not_difficulty")},
     {"id": "m3", "provenance": "REAL", **real("S03_scenic_reveal__D_reverse_reveal__take1")},
   ],
   "pending_count": 0,
   "human_reference": {"sufficiency": "insufficient", "idea_should_exist": True,
     "idea_opportunity": "intimate human/relationship material; existing clips are strong landscape/journey but weak on the intended intimacy",
     "expected_properties": ["preserves factual asset value of the landscape/river Moments",
        "recognizes weak alignment with the intimate-relationship intent"],
     "forbidden_properties": ["claims good footage automatically satisfies the relationship story",
        "discards the Moments as worthless"]}},

 # H1/H2/H3 — accumulation/stability (REAL, additive).
 "H1_accum": {"creative_intent": {"raw_text": "our TMB trek", "theme": "journey", "tone": "reflective",
     "subject": "our trek", "desired_feeling": ["adventure"], "emphasis": ["journey"]},
   "scope": {"target_duration_seconds": 90, "format": "vertical"},
   "moments": [{"id": "m1", "provenance": "REAL", **real("S04_human_scale__A_exact_small_person_landscape__take1")},
               {"id": "m2", "provenance": "REAL", **real("S05_trail_progression__A_follow_behind")}],
   "pending_count": 0,
   "human_reference": {"sufficiency": "workable", "idea_should_exist": True,
     "idea_opportunity": "human/companionship or difficulty material to deepen the journey",
     "expected_properties": ["environment+progression present", "coherent baseline coverage"],
     "forbidden_properties": ["already declaring sufficient with only scenery+progression for a 90s trek"]}},
 "H2_accum": {"creative_intent": {"raw_text": "our TMB trek", "theme": "journey", "tone": "reflective",
     "subject": "our trek", "desired_feeling": ["adventure"], "emphasis": ["journey"]},
   "scope": {"target_duration_seconds": 90, "format": "vertical"},
   "moments": [{"id": "m1", "provenance": "REAL", **real("S04_human_scale__A_exact_small_person_landscape__take1")},
               {"id": "m2", "provenance": "REAL", **real("S05_trail_progression__A_follow_behind")},
               {"id": "m3", "provenance": "REAL", **real("S07_companionship__A_natural_conversation")}],
   "pending_count": 0,
   "human_reference": {"sufficiency": "workable", "idea_should_exist": True,
     "idea_opportunity": "the companionship gap from H1 is now FILLED by m3; a new opportunity (difficulty/ending) may appear, NOT companionship again",
     "expected_properties": ["companionship/human now covered (vs H1)", "environment+progression retain identity from H1",
        "newest Moment does not reset or rename unrelated dimensions"],
     "forbidden_properties": ["still recommends companionship after m3 fills it", "drops environment/progression that H1 had",
        "radically renames stable dimensions"]}},
 "H3_accum": {"creative_intent": {"raw_text": "our TMB trek", "theme": "journey", "tone": "reflective",
     "subject": "our trek", "desired_feeling": ["adventure"], "emphasis": ["journey"]},
   "scope": {"target_duration_seconds": 90, "format": "vertical"},
   "moments": [{"id": "m1", "provenance": "REAL", **real("S04_human_scale__A_exact_small_person_landscape__take1")},
               {"id": "m2", "provenance": "REAL", **real("S05_trail_progression__A_follow_behind")},
               {"id": "m3", "provenance": "REAL", **real("S07_companionship__A_natural_conversation")},
               {"id": "m4", "provenance": "REAL", **real("S06_difficulty__E_cross_river")}],
   "pending_count": 0,
   "human_reference": {"sufficiency": "sufficient", "idea_should_exist": False,
     "expected_properties": ["broad coverage: scenery+progression+companionship+difficulty",
        "dimensions stable across H1->H2->H3", "likely sufficient -> no idea"],
     "forbidden_properties": ["story idea recommending already-captured material",
        "dimension set churns vs H2"]}},

 # I — no intervention (sufficient OR unimportant gap).
 "I_no_intervention_sufficient": {
   "creative_intent": {"raw_text": "a short calm montage of the mountains", "theme": "calm landscape", "tone": "serene",
     "subject": "mountains", "desired_feeling": ["calm", "serenity"], "emphasis": ["landscape"]},
   "scope": {"target_duration_seconds": 20, "format": "vertical"},
   "moments": [{"id": "m1", "provenance": "REAL", **real("S03_scenic_reveal__D_reverse_reveal__take1")},
               {"id": "m2", "provenance": "REAL", **real("S04_human_scale__A_exact_small_person_landscape__take1")}],
   "pending_count": 0,
   "human_reference": {"sufficiency": "sufficient", "idea_should_exist": False,
     "expected_properties": ["two complementary calm landscape Moments satisfy a 20s calm montage"],
     "forbidden_properties": ["any story idea", "insists on people/difficulty the intent never asked for"]}},

 # J — ANTI-CHECKLIST: quiet-solitude intent must NOT demand companionship/difficulty/arrival.
 "J_anti_checklist_solitude": {
   "creative_intent": {"raw_text": "a film about quiet solitude alone in the mountains", "theme": "solitude",
     "tone": "contemplative", "subject": "being alone in nature", "desired_feeling": ["solitude", "peace"],
     "emphasis": ["landscape", "aloneness"], "creative_constraints": ["no other people", "no crowds"]},
   "scope": {"target_duration_seconds": 40, "format": "vertical"},
   "moments": [{"id": "m1", "provenance": "REAL", **real("S04_human_scale__A_exact_small_person_landscape__take1")},
               {"id": "m2", "provenance": "REAL", **real("S03_scenic_reveal__D_reverse_reveal__take1")},
               {"id": "m3", "provenance": "REAL", **real("A01_semantic_adversarial__A01_hiking_but_not_difficulty")}],
   "pending_count": 0,
   "human_reference": {"sufficiency": "sufficient", "idea_should_exist": False,
     "expected_properties": ["respects the solitude intent", "treats solo-in-landscape as ON-theme and sufficient"],
     "forbidden_properties": ["demands companionship/people", "demands difficulty/departure/arrival/food",
        "treats absence of common travel categories as a gap", "any homework-style suggestion"]}},

 # K — NON-TRAVEL (guitar practice), all SYN, so coverage can't overfit TMB.
 "K_nontravel_guitar": {
   "creative_intent": {"raw_text": "my progress learning guitar this month", "theme": "practice & progress",
     "tone": "earnest", "subject": "me practicing guitar", "desired_feeling": ["focus", "growth"],
     "emphasis": ["concentration", "progress"]},
   "scope": {"target_duration_seconds": 45, "format": "vertical"},
   "moments": [
     {"id": "m1", "provenance": "SYN", **mu(obs("A person tunes an acoustic guitar at a desk, adjusting pegs and checking pitch.",
        ["guitarist", "acoustic guitar"], [{"start_time":0.0,"end_time":12.0,"description":"tuning the guitar, head bent in concentration"}],
        "a quiet preparation moment before playing", [{"start_time":0.0,"end_time":12.0,"why_useful":"preparation/concentration beat"}]),
        "useful_elsewhere", shot="establishes preparation", beat="serves a 'getting ready' beat")},
     {"id": "m2", "provenance": "SYN", **mu(obs("Close-up of the left hand moving through a chord progression, fingers pressing frets, a few fumbles then a clean change.",
        ["hands", "fretboard"], [{"start_time":0.0,"end_time":18.0,"description":"practicing a chord change, fumble then clean"}],
        "effortful practice with a small visible improvement", [{"start_time":6.0,"end_time":18.0,"why_useful":"the clean chord change shows progress"}]),
        "strong_elsewhere")},
   ],
   "pending_count": 0,
   "human_reference": {"sufficiency": "workable", "idea_should_exist": True,
     "idea_opportunity": "a performance/payoff moment (playing a full phrase) to resolve the practice arc — in GUITAR terms, not travel terms",
     "expected_properties": ["dimensions are guitar/practice-relevant (preparation/concentration/progress/performance)",
        "does NOT apply travel categories (scenery/departure/companionship)"],
     "forbidden_properties": ["uses travel dimensions (landscape/journey/difficulty-of-hike)",
        "asks for scenery or companionship", "overfits to the TMB corpus"]}},

 # L — PENDING AU (some Moments understood, some pending/unknown).
 "L_pending_au": {
   "creative_intent": {"raw_text": "our TMB trek", "theme": "journey", "tone": "reflective", "subject": "our trek",
     "desired_feeling": ["adventure"], "emphasis": ["journey"]},
   "scope": {"target_duration_seconds": 90, "format": "vertical"},
   "moments": [
     {"id": "m1", "provenance": "REAL", **real("S05_trail_progression__A_follow_behind")},
     {"id": "m2", "provenance": "REAL", **real("S04_human_scale__A_exact_small_person_landscape__take1")},
     {"id": "m3", "provenance": "PENDING", "pending": True},   # not yet analyzed — UNKNOWN, not absent
     {"id": "m4", "provenance": "PENDING", "pending": True},
   ],
   "pending_count": 2,
   "human_reference": {"sufficiency": "workable", "idea_should_exist": False,
     "expected_properties": ["computes coverage from the 2 understood Moments", "pending_count reported as 2",
        "treats m3/m4 as UNKNOWN not absent", "high uncertainty may suppress a confident Story Idea"],
     "forbidden_properties": ["declares a gap solely because pending media is unanalyzed",
        "invents content for the pending Moments", "treats pending Moments as empty/absent"]}},
}


def main():
    out = REPO / "evals/story_coverage/fixtures.json"
    out.write_text(json.dumps({"fixtures": FIXTURES}, indent=2))
    n_real = sum(1 for f in FIXTURES.values() for m in f["moments"] if "REAL" in m.get("provenance", ""))
    n_syn = sum(1 for f in FIXTURES.values() for m in f["moments"] if m.get("provenance") in ("SYN",))
    n_pend = sum(1 for f in FIXTURES.values() for m in f["moments"] if m.get("provenance") == "PENDING")
    print(f"wrote {out}: {len(FIXTURES)} fixtures; moment provenance REAL={n_real} SYN={n_syn} PENDING={n_pend}")


if __name__ == "__main__":
    main()
