# C4 — Shot Validation fixtures

Evaluation **cases + expectations** for Shot Validation. These are metadata only
and are committed to Git. The **actual video media lives elsewhere** and is
referenced, not duplicated:

```text
evals/assets/private_local/videos/<SET>/   (raw media, gitignored)
evals/assets/videos/<SET>/                 (public-safe media, if any)
        ↑ referenced by
evals/shot_validation/scenarios/<SET>/     (this directory — committed)
```

## Layout

```text
shot_validation/
├── README.md
├── scenarios/
│   ├── S01_backpack_static/
│   │   ├── request.json        ← NOT authored yet (schema TBD in C4 design)
│   │   └── expectations.json   ← NOT authored yet (schema TBD in C4 design)
│   ├── S02_departure/
│   ├── S03_scenic_reveal/
│   ├── S04_human_scale/
│   ├── S05_trail_progression/
│   ├── S06_difficulty/
│   ├── S07_companionship/
│   └── S08_end_of_day/
└── regressions/                 ← captured failing cases, added over time
```

## Do NOT author the fixture JSON yet

`request.json` / `expectations.json` schemas are intentionally **undefined**.
They are designed during the C4 **Shot Validation technical design**, because the
collected dataset may reveal that the current binary `ValidationResult` contract
is insufficient (e.g. it may need a `partial` / `alternative_success` axis).

For now, capture intent in the **`NOTES.md` inside each media set** under
`evals/assets/.../videos/<SET>/`, using the informal vocabulary in
`../README-collection-guide.md`.
