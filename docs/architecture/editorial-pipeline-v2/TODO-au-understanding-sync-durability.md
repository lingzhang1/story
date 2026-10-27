# TODO (pre-beta) — Asset Understanding (AU) sync/push durability gap

**Status:** OPEN — needs prioritization. Discovered 2026-10-26 during P1-C EditPlan v5.3 dev acceptance.
**Scope:** Asset Understanding sync pipeline. NOT an EditPlan v5.3 defect. Do not fold into P1-C.
**Owner decision needed:** schedule as its own pre-beta task.

## Summary

AU v2 understanding (`moment_understanding/2`, `au_prompt/3`) is produced correctly on-device and used
correctly by EditPlan v5.3 (which reads the device's LOCAL `MomentUnderstandingModel`). But the AU results
are **not reliably pushed to the account-level understanding store**, so they exist only in local SwiftData.

If the app is deleted/reinstalled (or the user signs in on a new device) before a successful push, the AU v2
understanding is **lost** and must be re-run — a paid re-analysis and a poor UX.

## Evidence (dev, account 989088054552)

- Backend AU is v2: `asset_understanding_resolved` logs show `schema_version: moment_understanding/2`,
  `prompt_version: au_prompt/3`, `success: true`. (Confirmed via App Runner logs.)
- `story-development-understanding` table held **0 `moment_understanding/2` rows** throughout testing — only
  15 stale `moment_understanding/1` rows from earlier.
- **Zero `PUT /v1/understanding` (push)** observed across multiple sign-ins and foreground transitions during
  testing, despite the triggers firing (confirmed other account activity: `GET /v1/stories`, `GET /v1/media`,
  story reconcile all fired on the same foregrounds).

## Root cause (from code reading)

1. **Push cadence is foreground/sign-in only** — `UnderstandingSync.push()` is called from `StoryApp.swift`
   at (a) the auth→signed-in transition and (b) every `scenePhase == .active` while signed in. There is **no
   push hook when the AU queue finishes analyzing a Moment**. So understanding produced *during* a foreground
   session is not pushed until the *next* foreground.
2. **Eligibility gate skips non-cloud-backed media** — `push()` only pushes an understanding whose Moment
   media has a `content_sha256` (sourced from a completed `MediaUploadJobModel`). If the media upload has not
   yet recorded a sha, the understanding is silently skipped (pushes 0 records). During testing this gate was
   not satisfied, so even the foreground pushes sent nothing.

## Restore side (already built)

`UnderstandingSync.restore()` (pull-when-missing) already exists and is wired at
`CreateStoryPreviewView.swift:270` and `StorySyncCoordinator.swift:205`. It pulls cloud understanding for
Moments missing locally, gated on `content_sha256` / `cloudMediaId` match (restore-first, no re-analysis).
So the PULL half is done; the gap is purely the PUSH half not populating the cloud.

## Proposed fix (smallest compatible)

1. **Push at end of `AssetUnderstandingQueue.drain()`** — one coalesced `UnderstandingSync.push(...)` call
   after a drain batch completes (idempotent PUT; coalesced so N Moments → 1 push, not N). Inject the active
   owner + token seam the same way the queue already injects `isAuthed`.
2. **Also push on upload-complete** — fire push when `MediaUploadQueue` records a `content_sha256`, so an
   understanding that was skipped (media not yet cloud-backed at AU time) gets pushed once its media is backed.
3. Keep the existing foreground/sign-in pushes as the backstop.

This closes the durability gap with minimal surface. No schema change; `push()`/`restore()` already exist and
are idempotent.

## Related findings (track separately)

- **Gemini→OpenAI AU fallback** — AU calls log `requested_model: gemini-3.8-flash`, `served_provider: openai`,
  `used_fallback: true`. AU still succeeds as v2 via OpenAI. Separate pre-beta operational issue; do NOT change
  routing/timeouts here.
- **Stale cross-pool token → 401** — switching beta→dev left a stale beta Cognito token; AU calls 401'd until
  sign-out/in on dev. Same family as this (auth/session correctness around account-scoped data).

## Explicitly out of scope for the fix

- No change to the AU engine, frame sampling, provider routing, or the EditPlan planner.
- No new remote-config system.
