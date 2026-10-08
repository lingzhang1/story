"""Build evals/edit_planner/fixtures.json — 5 M-d.3 planning scenarios.

TMB reuses REAL MomentUnderstanding events from evals/story_coverage/real_moment_understanding.json; the other
four are authored but realistic. Each scenario carries: creative_intent, story_guide, story_coverage, moments[]
(id, duration_seconds, useful_segments, observed events summary), music_plan (frozen music_plan/1 shape), and a
CONTROLLED music_analysis (duration/bpm/beats/downbeats/highlight/sections) for the A/B comparison.

Usage: TMPDIR=/tmp .venv/bin/python evals/edit_planner/build_fixtures.py
"""
from __future__ import annotations
import json, pathlib

HERE = pathlib.Path(__file__).parent
REPO = HERE.resolve().parents[1]
REAL = json.loads((REPO / "evals/story_coverage/real_moment_understanding.json").read_text())


def mu_segments(key, dur, useful):
    """Pull a real MU record's observed events into a compact moment with useful_segments."""
    rec = REAL[key]["observed"]
    events = [{"t_start_s": e["t_start_s"], "t_end_s": e["t_end_s"], "description": e["description"]}
              for e in rec["events"]]
    return {"id": key, "duration_seconds": dur, "useful_segments": useful,
            "summary": rec["summary"], "events": events}


def beats(bpm, dur):
    step = 60.0 / bpm
    out, t, pos = [], 0.0, 1
    while t <= dur:
        out.append({"time": round(t, 2), "value": pos})
        pos = pos + 1 if pos < 4 else 1
        t += step
    return out


def downbeats(bts):
    return [b["time"] for b in bts if b["value"] == 1]


def analysis(dur, bpm, highlight, sections):
    bts = beats(bpm, dur)
    return {"duration_seconds": dur, "bpm": bpm, "beats": [b["time"] for b in bts],
            "downbeats": downbeats(bts), "highlight_window": highlight, "sections": sections,
            "vocal_type": "NONE"}


scenarios = {}

# 1) TMB cinematic 60s — REAL backpack/departure Moments
scenarios["tmb_cinematic_60s"] = {
    "creative_intent": {"summary": "A cinematic departure — the quiet anticipation before a big trip.",
                        "desired_feeling": ["anticipatory", "cinematic", "intimate"], "pace": "measured",
                        "target_duration_seconds": 60.0},
    "story_guide": {"framing_summary": "The threshold of a journey: preparation, the last look home, stepping out.",
        "dimensions": [{"id": "d_prep", "label": "Preparation", "purpose": "the deliberate readying before leaving"},
                       {"id": "d_threshold", "label": "The Threshold", "purpose": "crossing from home into the journey"}]},
    "story_coverage": {"sufficiency": "workable",
        "reason": "Strong preparation + departure captured; no destination material yet.",
        "strengths": ["intimate prep detail", "a real walk-away-then-return beat"]},
    "moments": [
        mu_segments("S01_backpack_static__A_exact_good", 6.0, [[0.5, 5.5]]),
        mu_segments("S02_departure__A_exact_good", 22.2, [[0.0, 7.5], [11.0, 22.2]]),
        mu_segments("S03_scenic_reveal__D_reverse_reveal__take1", 9.0, [[1.0, 8.0]]),
    ],
    "music_plan": {"character": {"mood_tags": ["anticipatory", "warm", "cinematic"], "energy": "dynamic"},
        "energy_arc": [{"label": "quiet readying", "start_fraction": 0.0, "end_fraction": 0.45, "intensity": "low"},
                       {"label": "stepping into the journey", "start_fraction": 0.45, "end_fraction": 1.0, "intensity": "rising"}],
        "audio_strategy": {"soundtrack_role": "continuous", "native_audio_priority": "low",
                           "guidance": "music carries this; ambient prep sound is texture, not focus"}},
    "music_analysis": analysis(62.0, 90, {"from": 41.0, "to": 55.0},
        [{"type": "intro", "start_seconds": 0.0, "end_seconds": 20.0},
         {"type": "build", "start_seconds": 20.0, "end_seconds": 41.0},
         {"type": "peak", "start_seconds": 41.0, "end_seconds": 55.0},
         {"type": "outro", "start_seconds": 55.0, "end_seconds": 62.0}]),
}

# 2) Guitar learning — real performance audio is the payoff
scenarios["guitar_progression"] = {
    "creative_intent": {"summary": "Weeks of practice building to the first real song played start to finish.",
                        "desired_feeling": ["earnest", "warm", "uplifting"], "pace": "measured",
                        "target_duration_seconds": 40.0},
    "story_guide": {"framing_summary": "A learning arc: fumbling practice resolving into one real performance.",
        "dimensions": [{"id": "d_practice", "label": "The Work", "purpose": "repetitive, imperfect practice"},
                       {"id": "d_payoff", "label": "The Performance", "purpose": "the first clean run-through"}]},
    "story_coverage": {"sufficiency": "sufficient",
        "reason": "Both the grind and a real complete performance are captured.",
        "strengths": ["authentic practice texture", "a full real performance take with its own audio"]},
    "moments": [
        {"id": "m_practice_1", "duration_seconds": 14.0, "useful_segments": [[2.0, 9.0]],
         "summary": "Close on hands fumbling a chord change, restarting several times.",
         "events": [{"t_start_s": 0.0, "t_end_s": 2.0, "description": "fumble + stop"},
                    {"t_start_s": 2.0, "t_end_s": 9.0, "description": "repeated chord attempts, buzzing strings"}]},
        {"id": "m_practice_2", "duration_seconds": 11.0, "useful_segments": [[1.0, 8.0]],
         "summary": "Metronome practice, slightly cleaner, player frowning in concentration.",
         "events": [{"t_start_s": 1.0, "t_end_s": 8.0, "description": "slow clean-ish repetition to a click"}]},
        {"id": "m_performance", "duration_seconds": 34.0, "useful_segments": [[0.0, 34.0]],
         "summary": "One continuous clean performance of the song, start to finish, warm room tone.",
         "events": [{"t_start_s": 0.0, "t_end_s": 34.0, "description": "full real performance, the emotional payoff — its OWN audio matters"}]},
    ],
    "music_plan": {"character": {"mood_tags": ["warm", "earnest", "intimate"], "energy": "dynamic"},
        "energy_arc": [{"label": "the grind", "start_fraction": 0.0, "end_fraction": 0.5, "intensity": "low"},
                       {"label": "hand to the real performance", "start_fraction": 0.5, "end_fraction": 1.0, "intensity": "falling"}],
        "audio_strategy": {"soundtrack_role": "supportive", "native_audio_priority": "important",
                           "guidance": "step back so the real guitar lands; music under practice, out during the performance"}},
    "music_analysis": analysis(42.0, 76, {"from": 6.0, "to": 18.0},
        [{"type": "intro", "start_seconds": 0.0, "end_seconds": 6.0},
         {"type": "verse", "start_seconds": 6.0, "end_seconds": 22.0},
         {"type": "outro", "start_seconds": 22.0, "end_seconds": 42.0}]),
}

# 3) SF exploration — city energy, no single payoff
scenarios["sf_exploration"] = {
    "creative_intent": {"summary": "A day wandering San Francisco — hills, fog, streetcars, a bite to eat.",
                        "desired_feeling": ["curious", "breezy", "warm"], "pace": "lively",
                        "target_duration_seconds": 45.0},
    "story_guide": {"framing_summary": "An exploratory city day; a loose string of places, not a climax.",
        "dimensions": [{"id": "d_streets", "label": "The Streets", "purpose": "movement through the city"},
                       {"id": "d_moments", "label": "Small Discoveries", "purpose": "little found details"}]},
    "story_coverage": {"sufficiency": "workable",
        "reason": "Good variety of places; no strong arc — a vignette collection.",
        "strengths": ["varied locations", "nice light on the fog"]},
    "moments": [
        {"id": "m_cablecar", "duration_seconds": 12.0, "useful_segments": [[1.0, 7.0]],
         "summary": "Cable car cresting a hill, bay behind.",
         "events": [{"t_start_s": 1.0, "t_end_s": 7.0, "description": "car climbs, bell dings, bay reveal"}]},
        {"id": "m_fog", "duration_seconds": 9.0, "useful_segments": [[0.5, 6.0]],
         "summary": "Fog rolling over the bridge towers.",
         "events": [{"t_start_s": 0.5, "t_end_s": 6.0, "description": "slow fog movement, muted color"}]},
        {"id": "m_mission_food", "duration_seconds": 10.0, "useful_segments": [[2.0, 8.0]],
         "summary": "Hands holding a taco, mural wall behind.",
         "events": [{"t_start_s": 2.0, "t_end_s": 8.0, "description": "food close-up, colorful mural"}]},
        {"id": "m_street", "duration_seconds": 13.0, "useful_segments": [[1.0, 9.0]],
         "summary": "Steep street, pedestrians, afternoon light.",
         "events": [{"t_start_s": 1.0, "t_end_s": 9.0, "description": "people crossing, streetcar passes"}]},
    ],
    "music_plan": {"character": {"mood_tags": ["curious", "breezy", "upbeat"], "energy": "medium"},
        "energy_arc": [{"label": "steady city groove", "start_fraction": 0.0, "end_fraction": 1.0, "intensity": "rising"}],
        "audio_strategy": {"soundtrack_role": "continuous", "native_audio_priority": "selective",
                           "guidance": "music leads; let the cable-car bell poke through"}},
    "music_analysis": analysis(46.0, 112, {"from": 24.0, "to": 36.0},
        [{"type": "intro", "start_seconds": 0.0, "end_seconds": 10.0},
         {"type": "groove", "start_seconds": 10.0, "end_seconds": 36.0},
         {"type": "outro", "start_seconds": 36.0, "end_seconds": 46.0}]),
}

# 4) Minimal solitude — anti-template; a few held calm shots
scenarios["minimal_solitude"] = {
    "creative_intent": {"summary": "A quiet solo morning with coffee by the window. Stillness.",
                        "desired_feeling": ["calm", "still", "reflective"], "pace": "slow",
                        "target_duration_seconds": 18.0},
    "story_guide": {"framing_summary": "A single quiet mood; no journey, no build — presence.",
        "dimensions": [{"id": "d_stillness", "label": "Stillness", "purpose": "being, not doing"}]},
    "story_coverage": {"sufficiency": "sufficient",
        "reason": "The mood is fully present in two held shots; nothing is missing.",
        "strengths": ["genuine stillness", "soft morning light"]},
    "moments": [
        {"id": "m_window", "duration_seconds": 11.0, "useful_segments": [[1.0, 9.0]],
         "summary": "Steam rising from a mug on the sill, soft light, no movement.",
         "events": [{"t_start_s": 1.0, "t_end_s": 9.0, "description": "steam curls, quiet, static frame"}]},
        {"id": "m_hands", "duration_seconds": 8.0, "useful_segments": [[0.5, 6.0]],
         "summary": "Hands wrapped around the mug, a slow breath.",
         "events": [{"t_start_s": 0.5, "t_end_s": 6.0, "description": "hands still, tiny movement, calm"}]},
    ],
    "music_plan": {"character": {"mood_tags": ["calm", "still", "ambient"], "energy": "low"},
        "energy_arc": [{"label": "stable stillness", "start_fraction": 0.0, "end_fraction": 1.0, "intensity": "low"}],
        "audio_strategy": {"soundtrack_role": "sparse", "native_audio_priority": "selective",
                           "guidance": "barely-there pad; keep the room quiet"}},
    "music_analysis": analysis(20.0, 60, {"from": 6.0, "to": 14.0},
        [{"type": "ambient", "start_seconds": 0.0, "end_seconds": 20.0}]),
}

# 5) Energetic short-form — one stable burst
scenarios["energetic_shortform"] = {
    "creative_intent": {"summary": "A punchy skate-session clip for sharing. Fast, fun, loud.",
                        "desired_feeling": ["energetic", "fun", "bold"], "pace": "fast",
                        "target_duration_seconds": 12.0},
    "story_guide": {"framing_summary": "A single high-energy burst; land one trick, feel the hit.",
        "dimensions": [{"id": "d_action", "label": "The Hit", "purpose": "the trick and its impact"}]},
    "story_coverage": {"sufficiency": "workable",
        "reason": "One good landing + some ramp-up; short and punchy.",
        "strengths": ["clean landing", "good motion energy"]},
    "moments": [
        {"id": "m_rollup", "duration_seconds": 6.0, "useful_segments": [[1.5, 5.0]],
         "summary": "Skater rolls toward the ledge, speed building.",
         "events": [{"t_start_s": 1.5, "t_end_s": 5.0, "description": "approach, crouch"}]},
        {"id": "m_trick", "duration_seconds": 7.0, "useful_segments": [[0.5, 4.5]],
         "summary": "The kickflip and clean landing, board clack.",
         "events": [{"t_start_s": 0.5, "t_end_s": 4.5, "description": "pop, flip, land — the hit; board clack is great native audio"}]},
    ],
    "music_plan": {"character": {"mood_tags": ["energetic", "bold", "driving"], "energy": "high"},
        "energy_arc": [{"label": "one stable burst", "start_fraction": 0.0, "end_fraction": 1.0, "intensity": "high"}],
        "audio_strategy": {"soundtrack_role": "continuous", "native_audio_priority": "selective",
                           "guidance": "loud music; punch the board-clack through on the landing"}},
    "music_analysis": analysis(13.0, 150, {"from": 3.0, "to": 9.0},
        [{"type": "drop", "start_seconds": 0.0, "end_seconds": 13.0}]),
}

out = {"_meta": {"experiment": "M-d.3 Edit Planner planning-quality",
                 "note": "TMB reuses real MomentUnderstanding; others authored. music_analysis is CONTROLLED (synthetic beats/downbeats/highlight) for the A/B comparison — NOT from a real track.",
                 "arms": "A = MusicPlan only; B = MusicPlan + MusicAnalysis"},
       "scenarios": scenarios}
(HERE / "fixtures.json").write_text(json.dumps(out, indent=2))
print(f"wrote {HERE/'fixtures.json'} with {len(scenarios)} scenarios")
for k, sc in scenarios.items():
    print(f"  {k}: {len(sc['moments'])} moments, target {sc['creative_intent']['target_duration_seconds']}s")
