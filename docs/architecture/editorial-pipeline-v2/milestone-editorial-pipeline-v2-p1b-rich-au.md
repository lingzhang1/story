# Editorial Pipeline v2 — P1-B: Rich Editorial Asset Understanding v2

## Status: **MERGED — AUTOMATED TESTS PASSED — LIVE AU QUALITY VERIFICATION PENDING**

AU v2 is merged to `master` and its automated tests pass (backend pytest + on-device
Xcode StoryTests, owner-confirmed). It is **NOT** marked accepted for video quality: the
actual Gemini AU v2 outputs have not yet been run against representative real footage.
No deployment to any environment. EditPlan v5.2 behavior is unchanged.

Evidence legend: `[CONFIRMED]` code/CI · `[DEVICE]` owner device · `[PENDING]` not yet done.

---

## 1. Release coordinates `[CONFIRMED]`

- **PR:** [#58](https://github.com/lingzhang1/story/pull/58) — MERGED (protected workflow, no bypass).
- **Merge commit / master HEAD:** `59bd850`.
- **Branch (deleted post-merge):** `feat/editorial-p1b-rich-au`.
- **CI on PR #58:** green — CDK synth + jest, ruff lint, Python tests + contract compatibility.
- **Backend tests:** 493 passing.
- **Device:** `[DEVICE]` owner built the branch in Xcode; StoryTests (incl. `AssetUnderstandingV2Tests`) passed.
- **Deployment:** NONE (dev/beta/gamma/prod untouched).

## 2. What P1-B delivered `[CONFIRMED]`

One canonical Rich Editorial AU v2 pipeline — `moment_understanding/2` + `au_prompt/2` —
replacing v1 as the standard. A strict additive superset:

- **Observed** (summary, subjects, events, temporal_order_note, useful_segments) — byte-identical
  to v1; same consumers (Duration Intelligence, Story Coverage, EditPlan `useful_segments`).
- **Editorial** (NEW, optional): `visual_candidates[]` (start/end/approx `peak_time`/role/confidence/
  evidence; ~2–5s is a common Highlights case, not a limit) and `narrative_candidates[]` (longer
  intervals; `spoken_meaning` always "unknown" — dialogue never inferred from frames). No single
  beauty score — interpretable reasons + retained uncertainty (null peak when not identifiable).
  Derived from ONE understanding, not separate Highlights/Full Story calls.
- **Story context** — unchanged; kept separate from the reusable observed/editorial blocks.

Backend provider/routing untouched. iOS keeps `understandingJSON` as the single authoritative
record (no separate field). AU queue is version-aware: a stale v1 record is eligible for **lazy**
v2 enrichment on next use — no bulk re-analysis, no duplicate inference once v2 exists. R7 sync
is version-agnostic (carries `understandingJSON` wholesale), so v2 records push/restore unchanged.
`auActionTimestamps` is now populated locally (AU events + v2 visual peaks, ordered/in-bounds)
feeding only the local CreativeRefinementV2b stage — no EditPlan v5.2 wire/contract change.

## 3. Compatibility verified `[CONFIRMED]`

- AU v1 dev records decode read-only (`editorial = nil`, `is_v2 = false`); intact and usable.
- Existing Moments / Stories / GeneratedOutputs unaffected (additive JSON field — no SwiftData migration).
- No automatic bulk reanalysis. No provider-routing change. EditPlan v5.2 operational. No visual-evidence
  truncation. No new infrastructure.

## 4. Automated tests `[CONFIRMED]` / `[DEVICE]`

- Backend `test_asset_understanding_v2_editorial.py`: v1 read-only decode, multiple/zero candidates,
  peak/missing-peak, interval ordering/bounds, invalid intervals rejected, no beauty-score field,
  `spoken_meaning` unknown, observed block unchanged.
- iOS `AssetUnderstandingV2Tests`: v1/v2 decode, candidate shape, missing peak, `auActionTimestamps`
  bounds/ordering. **Device ⌘U green (owner-confirmed).**
- Also landed pre-existing **test-only** compile fixes that unblocked the on-device StoryTests target
  (never compiled on device before — CI has no iOS job): `nonisolated` sha256Hex;
  `StoryCreationCoordinator` / `GeneratedOutputModel` constructor arg order; `FakePlanner .fail(.unavailable)`.
  No product code changed by those fixes.

## 5. Known limitations `[PENDING]`

- **Live AU v2 quality not yet verified** — no Gemini run against real footage; candidate quality,
  peak plausibility, latency, and token/cost are unmeasured.
- Sparse 24-frame evidence gives approximate peaks only (modeled as nullable peak + confidence; a
  bounded refinement pass is designed but OFF by default).
- `GitCommitSHA` still reports `unknown` (separate bounded follow-up).

## 6. Next — development live validation (proposal, NOT run here)

A dev-only smoke test over a very small set of authorized clips (girl-in-dress twirl; TMB mountain
reveal; Egypt market interaction), recording per clip: visual + narrative candidates and timestamps,
peak confidence/uncertainty, AU latency, input/output tokens, estimated cost, schema validation, and
whether the source footage actually supports the generated candidates. Then **P1-C — EditPlan v5.3
mode-aware sizing** consumes visual candidates (Highlights) + narrative candidates (Full Story).
Both require separate owner authorization; no deploy or live inference without it.
