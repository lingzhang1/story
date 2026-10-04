# Cross-component Story scenarios

End-to-end scenarios that exercise multiple components (C1→C2→C3→C4) against a
single coherent Story. Scenarios **reference** assets in `../assets/`; they never
copy media.

```text
scenarios/
├── tmb_story_001/
│   ├── scenario.json           ← schema TBD (after C4)
│   ├── scenes/                 ← references to assets/scenes/*
│   ├── moments/                ← *.ref pointers to assets/videos/*
│   └── expected/
│       └── story_behavior.json ← schema TBD (after C4)
├── ordinary_day_001/
├── birthday_001/
└── music_practice_001/
```

## Skeleton only — do not build fully yet

The cross-component scenario schema is **not defined**. C4 will teach us what a
scenario actually needs (how moments reference validated shots, what
story-level behavior to assert). Leave these directories empty until then.

The one firm architectural rule: **a scenario references a media asset by path,
it does not duplicate it.**

```text
assets/videos/S02_departure/S02_A_exact_good.mov
        ↑ referenced by
scenarios/tmb_story_001/moments/departure_good.ref
```
