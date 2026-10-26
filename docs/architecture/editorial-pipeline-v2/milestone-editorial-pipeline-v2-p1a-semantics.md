# Editorial Pipeline v2 — P1-A: Editorial-Type Metadata Foundation

## Status: **MERGED — DEVELOPMENT DEVICE ACCEPTED — FEATURE FLAG OFF**

P1-A's code is merged to `master` and has passed physical-device acceptance on a build of post-merge
master pointed at the **development** backend. The merged commit is **NOT deployed** to any environment
(development, beta, gamma, or production) as part of this milestone — this records *code acceptance*, not
a deployment. The `STORY_EDITORIAL_TYPE_V2` feature flag remains **OFF by default**, so runtime behavior is
identical to EditPlan v5.2 (Original / Revise / Explore unchanged).

Evidence legend: `[CONFIRMED]` code/CI · `[RUNTIME]` live dev data · `[DEVICE]` owner device · `[OPEN]` deferred.

---

## 1. What P1-A delivered

A backward-compatible **metadata foundation** for the two consumer editorial types (Highlights, Full Story).
It introduces the canonical `EditorialType` model, back-compat mapping from the legacy `editorialMode` seed,
an additive authoritative per-output type field (`GeneratedOutputModel.editorialTypeRaw`), and flag-gated
provenance stamping. It does **not** activate type switching — selecting/forcing Highlights vs Full Story per
attempt is **P1-B/P1-C** behavior. P1-A keeps the three editorial types able to *coexist in output metadata*
while the flag is OFF.

Kept strictly separate (per owner guidance): editorial **type** (Highlights / Full Story) vs **operation**
(Original / Revise / Explore) vs **creative instructions** vs **duration choice**. `custom` is a duration fact,
never an editorial type, and legacy `custom` is never mapped to Full Story.

## 2. Release coordinates `[CONFIRMED]`

- **PR:** [#55](https://github.com/lingzhang1/story/pull/55) — MERGED.
- **Final merge commit:** `cc7933b`.
- **master HEAD at closure:** `cc7933b`.
- **Branch:** `feat/editorial-p1a-semantics` (updated to current master before merge; merged via protected
  branch workflow — no `--admin`, no force-push, no bypass).
- **Deployment:** NONE. No dev/beta/gamma/prod deploy performed for P1-A.

## 3. Automated test results `[CONFIRMED]`

- CI on PR #55 green on the final (post-update-branch) commit: **CDK synth + jest**, **Lint (ruff Python)**,
  **Python tests + contract compatibility** — all pass. (CI has no iOS test job; authoritative iOS compile is
  the owner's device Xcode build.)
- iOS regression tests retained and establish: editorial-type semantics, legacy back-compat mapping,
  per-output ownership, flag default OFF, flag-gated provenance stamping (§2), and flag-OFF request-payload
  invariance (§5) — i.e. **different editorial types can coexist in output metadata**. These tests are kept,
  not removed, as the P1-A guarantee.
- Diff scope verified entirely within P1-A: only `apps/ios/**` and `docs/architecture/**`. No backend,
  prompt, model-routing, renderer, or infrastructure changes.

## 4. Device test results `[DEVICE]`

Post-rebuild dev runs on the owner's physical device (installed OVER the existing app database, not a clean
install):

| Signal | Explore `be867813` | Revise `d77349ba` |
|---|---|---|
| operation routing | explore | revise |
| planning_mode / sheets | multimodal / 35 | multimodal / 35 |
| completion | complete | complete |
| `evidence_accounting.reconciles` | true | true |
| census (linked/eligible/sheeted/missing) | 35 / 35 / 35 / 0 | 35 / 35 / 35 / 0 |
| `build_provenance` present | yes | yes |
| extraction policy | `au_extract/2` | `au_extract/2` |
| playable output | yes | yes |

The presence of `evidence_accounting` + `build_provenance` on these runs confirms the device executed the
current P0/P1-A iOS code (earlier runs lacked both because the device build was stale).

## 5. Backward compatibility `[DEVICE]`

Owner explicitly confirmed (2026-10-25) that the device build was installed **over the existing application
database** and that existing Stories, Moments, previously generated videos, and version history are all
present and playable — no data loss, no unexpected migration or persistence failure. No database was reset,
deleted, reinstalled, or replaced to perform this check.

## 6. Feature flag behavior `[CONFIRMED]`

`EditorialTypeFlag` default is **OFF** (`return false // P1-A default OFF — v5.2 behavior unchanged`), verified
on `master:cc7933b`. With the flag OFF: no per-attempt editorial-type selection, `editorialTypeRaw` is stamped
`nil` (provenance only), and the edit-plan request payload is byte-for-byte the v5.2 payload. P1-A is inert at
runtime.

## 7. Deferred — P1-B activation and follow-ups `[OPEN]`

These are intentionally NOT part of P1-A and were not touched by this merge:

1. **P1-B / P1-C — editorial-type switching becomes active** (mode-aware Highlights/Full Story planning and
   sizing; flag-gated). Not started; requires separate authorization.
2. **`GitCommitSHA` still reports `unknown`** on device `build_provenance` — the Xcode build-stamping Run Script
   is not yet wired. Bounded follow-up task; non-blocking (falls back to `unknown` by design).
3. **Audio playback preview fix** — verified fixed on device this session (owner reported "audio fixed").
4. **P0 full evidence diagnostics** — now verified on the latest device runs (reconciles=true, 35/35/35/0).
