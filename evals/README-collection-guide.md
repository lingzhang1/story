# Collection Guide — recording & classifying eval clips

Practical guide for building the C4 Shot Validation corpus (and future sets).
The goal is a clean experiment: **hold semantics constant, vary one thing.**

## Where to put raw footage

Everything personal goes under the **gitignored** private path:

```text
evals/assets/private_local/videos/<SET>/
```

Classified, public-safe clips (no identifiable people/homes) may later move to
`evals/assets/videos/<SET>/`. When unsure, keep it in `private_local/`.

## The `_inbox` — don't do hygiene in the field

When out hiking/traveling, don't maintain perfect structure. Just dump:

```text
evals/assets/_inbox/
├── IMG_3921.MOV
├── IMG_3922.MOV
└── note.txt        # a line per clip: "3921 = friend turning to view, S03?"
```

Classify into the right `S0x_*` set later, at a desk.

## Naming convention

```text
<SET>_<VARIANT>_<short_label>.mov

S02_A_exact_good.mov
S02_D_walk_away_through_door.mov
T01_C_moderate_shake.mov
A03_backpack_but_arrival_not_departure.mov
```

- `A` is usually the exact/good execution; later letters are deliberate variations.
- Keep labels short and descriptive of **what makes this clip different**.

## Expectation vocabulary (informal, for NOTES.md only)

The canonical C4 result schema does **not** exist yet. For now, in NOTES.md use
plain words so intent is preserved:

- `good` / `usable` — correct semantics, acceptable quality
- `partial` — some requested elements present, others missing
- `failed` — requested action/meaning absent or contradicted
- `alternative_success` — doesn't follow the literal instruction but strongly
  communicates the intended beat/purpose anyway

Do **not** author `request.json` / `expectations.json` yet — the schema is
defined during C4 technical design.

## The experiment design

Three set families, each isolating a variable:

1. **Scenario sets (`S01`–`S08`)** — vary *execution* of a narrative instruction.
2. **Technical controls (`T01`)** — hold subject/framing constant (e.g. the
   backpack every time), vary only *capture quality* (shake, exposure, focus,
   duration, occlusion). `semantic content = constant, capture quality = variable`.
3. **Semantic adversarial (`A01`)** — clips engineered to fool shallow validation:
   right *context*, wrong *purpose* (e.g. a beautiful effortless panorama offered
   as evidence of "difficulty").

## Collect-now priority (≈25–35 clips, no mountains needed)

```text
S01_backpack_static
S02_departure
S06_difficulty
S07_companionship
T01_technical_controls
A01_semantic_adversarial
```

`S03_scenic_reveal`, `S04_human_scale`, `S05_trail_progression` need outdoor
environments — collect opportunistically via `_inbox`.

## Always leave a NOTES.md

Each set directory has a `NOTES.md` recording the director instruction, shot
purpose, beat purpose, and **why each clip was recorded**. This is easy to forget
three weeks later — write it when you record.
