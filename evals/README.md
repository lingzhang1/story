# Story — Evaluation Corpus

Executable eval corpus for the Story AI pipeline (C1–C4+). This directory holds
**reusable source media**, **per-component evaluation fixtures**, and eventually
**cross-component Story scenarios**. The architecture keeps media and expectations
separate so a single clip can serve many evaluators without being duplicated.

## Layout

```text
evals/
├── README.md                     # this file
├── README-collection-guide.md    # how to record/classify clips in the field
│
├── harness/                      # eval infrastructure (existing)
├── results/                      # generated eval runs — GITIGNORED
│
├── creative_intent/              # C1 fixtures
├── scene_understanding/          # C2 fixtures
├── story_director/               # C3 fixtures
├── shot_validation/              # C4 fixtures  ← collecting here now
│
├── scenarios/                    # cross-component end-to-end Story scenarios
│
└── assets/                       # reusable real evaluation media
    ├── _inbox/                   # casual field dumps, classify later
    ├── scenes/                   # C2 scan-frame sets (frames + metadata.json)
    ├── videos/                   # C4+ captured video clips (public-safe)
    └── private_local/            # personal raw media — GITIGNORED, never pushed
```

## The three roles — do not mix them

| Location                         | Role                                                    |
|----------------------------------|---------------------------------------------------------|
| `assets/`                        | **Actual reusable media.** No expected answers here.    |
| `shot_validation/`, `story_director/`, … | **Evaluation cases + expectations** (metadata, committed). |
| `scenarios/`                     | **Cross-component end-to-end stories** that reference assets. |

One media asset, multiple eval uses — referenced, never copied:

```text
assets/videos/S02_departure/S02_A_exact_good.mov
        ↑ referenced by
shot_validation fixture  →  eventually a Story scenario
```

## Privacy boundary

Real personal footage (friends, faces, homes, travel) lives **only** in
`assets/assets/private_local/` and is `.gitignore`d. Fixture metadata and
expectations under `shot_validation/` are committed to Git; the raw media is not.

```text
Git (committed)                    Local only (gitignored)
──────────────────────────         ──────────────────────────────
shot_validation/ fixtures          assets/private_local/ actual videos
  + expectations + metadata
```

## Status

- C1 (`creative_intent/`), C2 (`scene_understanding/`), C3 (`story_director/`):
  populated by earlier milestones.
- C4 (`shot_validation/`): **dataset collection in progress.** Fixture JSON
  schema is **not yet defined** — it is authored during C4 (Shot Validation)
  technical design, because the dataset may reveal that the current binary
  `ValidationResult` contract is insufficient.
- `scenarios/`: skeleton only. The cross-component schema is defined after C4.

See `README-collection-guide.md` for field recording and classification.
