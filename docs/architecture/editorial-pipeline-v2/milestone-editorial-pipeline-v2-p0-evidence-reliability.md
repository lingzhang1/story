# Editorial Pipeline v2 — P0: Evidence Completeness + Never Block Playable Videos

## Status: **DEV ACCEPTED — BETA PROMOTION NOT YET AUTHORIZED**

Owner completed physical-device acceptance on a build of merged master; device tests passed.
Merged to master and deployed to **development only**. Beta/gamma/production untouched.
Evidence legend: `[CONFIRMED]` code/CI · `[RUNTIME]` live dev data · `[DEVICE]` owner device · `[OPEN]` unresolved.

---

## 1. What P0 delivered

A reliability + diagnostics baseline, plus the product policy that **a technically valid, playable video is
never discarded for an unmet creative/editorial objective** (duration, pacing, opening/ending, continuity,
explore-similarity, model-declared creative infeasibility) — with truthful partial-success disclosures.
Technical validation stays strict (renderable source ranges, speed 0.5–2.0×, output consistency, native audio,
known assets, non-empty plan). **No editorial UX redesign** (that is P1); the Create screen is unchanged.

## 2. Release coordinates `[CONFIRMED]`

- **PR:** [#53](https://github.com/lingzhang1/story/pull/53) — MERGED.
- **Final merge commit:** `5a5e5e2`.
- **Branch:** `feat/p0-evidence-accounting` (5 P0 commits: `d5be23a`, `2626e2f`, `93b1fbd`, `ea7bee4`, `882a73c`).
- **Dev deploy:** GitHub Actions `deploy-dev.yml` run `40256927323` — success.
  - App Runner `story-development-api` image digest `sha256:0fe7a26c…` == ECR tag `git-5a5e5e2eaaa7`.
  - Worker Lambda `story-development-edit-plan-worker` LastModified 2026-10-26T02:02:04Z (fresh asset, not a
    restart); `build_worker_asset.sh` copies all of `packages/.` so the updated `edit_planner` is in the worker.
  - Env preserved: `STORY_EDIT_PLAN_VERSION=5.2`, `STORY_MODEL_PROVIDER=direct`, `STORY_QUOTA_MODE=observe`.
  - Smoke: `GET /health` → 200; `/openapi.json` serves 46 routes incl. `/v1/edit-plan-jobs`.

## 3. Automated test results `[CONFIRMED]`

- **481/481 backend tests pass** (full `apps/api/tests`), incl. the P0 behavior matrix: overshoot/undershoot
  ship, `feasible=false` ±segments, noop/wholesale/retime disclosures, explore-similarity non-terminal, strict
  technical invalidity enforced, no-dup-output, no-reinference-on-resume, evidence reconciliation,
  frame-extraction classification. No technical validation test weakened.
- CI on PR #53 green (CDK synth+jest, ruff lint, Python tests + contract compatibility).
- iOS logic tests added (evidence reconciliation, feasibility floor); `swiftc -parse` clean. Authoritative iOS
  compile = owner device Xcode build (sandbox cannot run the SwiftData macro).

## 4. Owner-confirmed physical-device acceptance `[DEVICE]`

Owner reports device tests passed on a build of merged master. Highlights + Full Story generated end to end.

## 5. Visual-evidence results (the headline P0 win) `[RUNTIME]`

Full Story run `f0dd7eca` (150s target), on the deployed backend:
- `planning_mode: multimodal`, **`sheet_count: 35`** — every eligible Moment sheeted.
- **`evidence_stage12_cut_without_sheet: 0`** — ZERO selected Moments planned blind (vs the pre-fix 7/16 and
  19/35). The restore-before-extract + async track-load reliability fix is working on real footage.
- `completion: complete`, `creative_satisfaction: 1.0`, 18 segments selected, all `native_audio: keep`.

## 6. Remaining diagnostic limitations — DO NOT claim full device-diagnostic verification `[OPEN]`

The completed job `f0dd7eca` did **NOT** contain `evidence_accounting` or `build_provenance`.
Investigation (read-only, §2 of the P1-prep brief):
- The **deployed worker ran the new code** — `evidence_stage11_selected_distinct`,
  `evidence_stage12_cut_without_sheet`, `evidence_cut_without_sheet_ids` (all WORKER-derived by `_evidence_diag`
  from the plan) ARE present on the job.
- `_evidence_diag` copies `evidence_accounting`/`build_provenance` into the persisted diagnostics **only when
  they exist in the submit envelope**. Their absence therefore means the **device did not send them** in the
  multipart submit.
- **Conclusion: an OUTDATED device build** (predating iOS commits `d5be23a`/`882a73c` that assemble the census
  and add the multipart fields), **NOT a serialization or persistence defect.** The backend accept→stage→persist
  path is proven working by the worker-derived stages.
- The missing `GitCommitSHA` Run Script is a **separate, smaller** issue: it would only make
  `build_provenance.commit_sha == "unknown"`, never remove the whole provenance object.
- **Not yet verified on device:** the device-sourced `evidence_accounting` census (linked/AU-ready/eligible/
  submitted/sheeted/missing-by-reason) and `build_provenance`. Requires a rebuild on master `5a5e5e2` (or later)
  and one run; then confirm the job carries both objects and that `reconciles == true`.

## 7. iOS audio regression (tracked separately, not a P0 planner issue) `[OPEN]`

- **EditPlan is correct:** all segments `native_audio: keep` + music asset set → the render mixes audio.
- **Exported MP4 has audio** (owner: plays with sound once downloaded) — so the RENDER is correct.
- **In-app result preview is silent** — an iOS player issue, not backend/renderer. Root cause (confirmed by
  reading `StoryResultView`): the result `AVPlayer(url:)` was created with no `AVAudioSession` configuration;
  the app records video, leaving the shared session in a capture category that does not route playback to the
  speaker.
- **Status:** a candidate fix exists on the branch (commit `1d573a8`, sets `.playback`/`.moviePlayback` + active
  before the player, releases on disappear) but is **NOT merged** and **NOT device-verified** — audible output
  can only be confirmed on a device. P0 did NOT change the renderer or player; this is an unrelated regression
  filed for a separate change.

## 8. Explicitly NOT done

- No beta/gamma/prod deploy. No Organizations/IAM/secrets/quota changes. No provider-routing change.
- No editorial UX redesign (P1). No frozen-prompt/contract change. No Anthropic inference
  (`STORY_LLM_FALLBACK_MODEL=us.anthropic…` is a stale env LABEL; `STORY_MODEL_PROVIDER=direct` refuses Anthropic
  and never fails over — flagged for a future config cleanup, not a regression).

## 9. Carry-forward into P1

1. Rebuild device app on master and confirm `evidence_accounting` + `build_provenance` arrive and reconcile.
2. Add the `GitCommitSHA` Xcode Run Script so provenance reports a real SHA (documented in the P0 report).
3. Decide the audio-regression fix path (merge `1d573a8` + device-verify, or a dedicated ticket).
4. Dead code deferred: unreachable `preservation_violation` worker mapping + iOS `.preservationViolation`.
