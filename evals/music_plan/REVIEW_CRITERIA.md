# M-b MusicPlan — Human-Review Criteria (FROZEN BEFORE SCORING)

Written before any model output seen. Smallest-useful wins: a more elaborate / more dramatic / more-
sectioned plan is NOT better. Exact section labels NOT required.

## Per-fixture expectations (frozen)

| Fixture | character (feel) | arc (energy movement) | scope (complexity) | key structural behavior | native-audio expectation | 
|---|---|---|---|---|---|
| A TMB | cinematic, emotional, now with GRIT (storm/struggle in Coverage) | build toward an EARNED resolve, not a glossy swell | 3–4 regions ok (60s rich) | restraint early, difficulty mid, payoff/resolve late | music may largely carry; leave a beat for the storm's own sound | 
| B guitar | warm, intimate, uplifting | lift toward the real song | 2–3 regions | the SONG must become the focus; music RECEDES for it | **native guitar must dominate the payoff** — soundtrack supportive→sparse | 
| C SF | urban, rhythmic, lived-in | steady pulse with lifts, not a climax | 2–3 regions | stable groove; city ambience has room | supportive; street ambience audible | 
| D birthday | warm, playful | lively with a tender peak | 2–3 regions | DUCK at the cake moment (singing) | **singing/laughter must have room** — supportive, ducks at peak | 
| E solitude | sparse, still, ambient | STABLE low energy — NOT quiet→build→climax | 1–2 regions (tiny) | restraint; hold stillness | sparse soundtrack; wind/ambience may carry | 
| F skate 8s | punchy, high | immediate, stable high | **1 region only** | one hit, no arc | music can dominate (no meaningful native audio) | 

## Rubric (score each 0=fail / 1=weak / 2=good)
R1 CreativeIntent alignment · R2 StoryGuide alignment · R3 Coverage responsiveness (Arm B) · R4 emotional-arc
coherence · R5 duration/scope sensitivity · R6 cross-domain specificity · R7 usefulness to Edit Planner ·
R8 restraint / non-over-specification · R9 native-audio awareness · R10 avoids generic cinematic template ·
R11 structured validity · R12 (latency) · R13 (cost).

## Hard gates (binary — a NO = fixture FAIL)
- **F (8s skate):** exactly 1 energy region. 4 sections = fail.
- **E (solitude):** NO quiet→build→climax arc; stable low energy; ≤2 regions.
- **B (guitar) + D (birthday):** audio_strategy must mark native audio important/selective and soundtrack
  supportive/sparse (music must NOT be "continuous" dominating the song/singing).
- **A (TMB):** Arm B must reflect the storm/struggle Coverage (grit/resolve), not a generic scenic swell.
- **ALL:** fractions (0..1), NO absolute cut times, NO Moment/clip ids, NO transitions, NO numeric energy
  scores, NO camera/edit instructions, NO one-section-per-Guide-dimension, no travel vocab leaking cross-domain.

## Ablations (decide from evidence, not taste)
- **Coverage A/B** (run on A, B, D at least): does Arm B (with Coverage) produce a MEANINGFULLY better/
  different plan than Arm A (Guide only)? If Coverage only adds noise → drop it as a production input.
- **key_moments vs energy_arc:** can the Edit Planner infer build/payoff/breath/ending from the arc alone?
  If yes → drop key_moments. Keep ONLY if a concrete planner decision needs it that the arc can't express.

## Planner-usefulness test (per field)
For `character`, `energy_arc.{label,fractions,intensity,note}`, `key_moments`, `track_selection_criteria`,
`audio_strategy.*`: answer "what could Edit Planner do DIFFERENTLY because it knows this?" No concrete
answer → drop the field. We are designing an interface between intelligence systems, not prose.

## Model-selection rule
Both models clear every hard gate to be eligible; among eligible, prefer the one with higher R5/R7/R8/R9/R10
(scope discipline, planner-usefulness, restraint, native-audio, anti-template). Close + subjective → STOP for
owner review. Cost is a tiebreaker only.
