# E2-a StoryGuide — Human-Review Criteria (FROZEN BEFORE SCORING)

Written before any model output was seen. Scoring is human-review against these
criteria; exact labels are NOT required. More dimensions / more possibilities is NOT
better — over-planning is penalized.

## Per-fixture rubric (score each 0=fail / 1=weak / 2=good per criterion)

| # | Criterion | What "good" (2) means |
|---|---|---|
| R1 | CreativeIntent alignment | Dimensions + framing clearly serve THIS intent; nothing contradicts stated constraints (e.g. "no people" honored). |
| R2 | Story-specificity | Labels/purposes are specific to this Story's domain, not generic. |
| R3 | Narrative usefulness | A real person could use the map to shoot a better Story; purposes are meaningful. |
| R4 | Cross-domain generality | Vocabulary fits the domain (guitar≠trail, party≠landscape, typewriter≠journey). |
| R5 | Anti-checklist behavior | Reads as inspiration ("a guide, not a checklist"), not required shots/homework. |
| R6 | Non-overplanning | No padding; each dimension earns its place; possibilities are a FEW examples. |
| R7 | Scope-sensitive count | Dimension count scales to scope (8s coffee = tiny; 2min road trip = richer). |
| R8 | Possibility usefulness | capture_possibilities read as example expressions, not sub-requirements or camera directions. |
| R9 | Diversity without padding | Dimensions are distinct/complementary, not near-duplicates to inflate the map. |
| R10 | Concise framing_summary | One short human-readable statement of what the Story is trying to capture. |
| R11 | No template bleed | No fixed travel/filmmaking vocabulary leaking into non-travel Stories. |
| R12 | Structured validity | Output validates against the experimental StoryGuide schema. |

## Hard gates (binary — a NO on any is a fixture FAIL regardless of rubric)

- **E (solitude):** MUST NOT introduce people/companionship/challenge/journey-arc. "No
  people" and "no narrative arc" are explicit constraints.
- **F (8s coffee):** MUST get a TINY Guide (≤2 dimensions). Six dimensions = fail.
- **H (typewriter):** MUST NOT leak travel/people/landscape/scale/journey template
  dimensions. Any such leak = fail (reveals pattern-matching).
- **B (SF):** MUST NOT hard-code iconic landmarks the user did not name.
- **ALL:** no `required` flags, no numeric weights, no completion %, no camera/framing
  instructions in dimensions or possibilities.

## Dimension-count expectation (scope sensitivity — guidance, not a quota)

| Fixture | scope | expected rough count |
|---|---|---|
| F coffee | 8s | 1–2 |
| E solitude | 30s, deliberately narrow | 2–3 |
| B SF / C guitar / D birthday | 45–60s | 3–5 |
| A TMB | 60s | 4–6 |
| H typewriter | 60s | 3–5 |
| G road trip | 120s, month-long | 5–7 (richest, but still useful) |

A model that returns ~6 for EVERY fixture regardless of scope fails R7 across the board.

## Model-selection decision rule

1. Both models must clear every hard gate on every fixture to be eligible.
2. Among eligible models, prefer the one with higher aggregate rubric score, weighting
   R4/R5/R6/R7/R11 (generality + restraint) most heavily — these are the behaviors the
   whole architecture depends on.
3. If scores are close and there is a genuine subjective tradeoff → STOP for owner review
   before freezing the model (do not pick unilaterally).
4. Cost is secondary but recorded; only a tiebreaker.

## PURPOSE > possibility (frozen semantic rule — belongs to the Guide prompt, tested in E2-b)

A dimension's coverage (set in E2-b Coverage, not here) is PURPOSE fulfillment, never
"how many capture_possibilities are checked." The Guide's job in E2-a is only to produce
good dimensions + example possibilities; the possibility-vs-purpose independence is
enforced and regression-tested in E2-b. Recorded here so the Guide prompt frames
possibilities as examples, never sub-requirements.
