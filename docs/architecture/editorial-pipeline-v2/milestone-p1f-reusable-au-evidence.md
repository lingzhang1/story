# Milestone — P1-F: Reusable AU Visual Evidence & Editorially-Aligned Planner Frames

**Status: IMPLEMENTED — OFFLINE-TESTED — DEVICE / MERGE / DEV-PERFORMANCE VERIFICATION PENDING.**
Persistent caching is DISABLED (double-gated, see §10). NOT merged, NOT deployed, NOT device-built, NOT performance-verified.
**Branch:** `feat/p1f-reusable-au-evidence` (base `05750d9`). **Design:** R1. See `preflight-p1f-reusable-au-evidence.md`.

---

## 1. Implemented architecture

AU already extracts 24 frames per Moment and the server accepts them for inference, then discarded them. P1-F persists those **exact accepted frames** once as a durable, account-scoped package so editing reuses them — eliminating, on a valid cache hit, both the pre-planning full-video restore and the duplicate on-device re-extraction.

- **Backend-created (Option B).** Frames are packed + persisted at the AU accept point from the bytes already in hand (zero extra device egress).
- **R1 race fix.** The device sends a source-SHA **claim** in the AU request so a package can be written even when AU completes before upload. The claim is **never** trusted as identity — authority is established at **retrieval** by matching the account's verified cloud-media record.
- **Device Option 8-i.** At Create, a valid cache hit builds the contact sheet from cached frames (no restore, no `MomentFrameExtractor`); misses fall back to today's restore+extract. Behind flag `STORY_REUSABLE_EVIDENCE` (**OFF by default**).
- **Worker-side tiling (Option 8-ii) is DEFERRED** (not implemented); the packed format is self-describing so it remains possible without a redesign.

## 2. Evidence package format — `evidence_package/1`

`contracts/schemas/ai_contracts.py :: EvidencePackageContract`. Manifest only; the packed JPEG bytes live as ONE concat-jpeg blob in object storage, referenced by `frames_ref`. Fields: `schema_version`, `moment_id`, `owner` (server-derived), `content_sha256` (source fingerprint + invalidation anchor), `frame_extraction_version`, `frame_count`, `frame_encoding`/`frame_longest_edge`, `sampled_frame_ms` (server-minted accepted timestamps), `frames[]` (index/t_ms/offset/length into the blob), `frames_ref` (cloud_media_id/bytes/sha256/layout), `created_at`, `retention`. A `model_validator` enforces count/timestamp/order consistency. The AU `observed`/`editorial` JSON is **not** duplicated (it stays in the understanding store, keyed by the same moment_id).

## 3. Storage identity & ownership model

`packages/evidence_store/__init__.py`. Reuses `media_store` identity primitives: content-addressed blob id `uuid5(owner + blob_sha)`, account-scoped S3 key `evidence/{owner}/{blob_cmid}/frames.pack`, SSE, full-file sha256 integrity. Server-side byte write via `put_object` (the proven `edit_plan_jobs.JobStore.stage_request` pattern) — **no new bucket, table, or IAM** (reuses `STORY_MEDIA_BUCKET` / `STORY_MEDIA_TABLE`). Manifest row keyed `(story_user_id, evidence_id=moment_id)`. Writes are ordered + idempotent (blob first, then manifest); a partial write reads as a cache **miss**, never a valid package. S3+DynamoDB are **not** claimed atomic.

## 4. AU / media-upload lifecycle (the R1 race)

AU analyzes the LOCAL file and persists the understanding locally, independent of upload — so AU frequently completes **before** `cloud_verified`. Handling:
- **AU before upload:** device computes the source sha256 off-main (reusing `MediaUploadService.sha256Hex`, best-effort — AU survives a hash failure) and sends `meta.content_sha256`; the server writes a **provisional** package. Retrieval returns `source_not_verified` (a benign miss) until the upload's media record exists; then it matches and becomes usable **with no second AU call and no re-extraction**.
- **Upload before AU:** the package is immediately eligible once written (the verified media record already exists).
- No promotion job: retrieval-time verification resolves provisional→usable.

## 5. Candidate-to-frame mapper

`packages/evidence_mapper/__init__.py` (Python) + `EvidenceFrameMapper.swift` (device port, kept in lockstep). Deterministic. Over the **actual** sampled-frame timestamps: whole-Moment overview floor + **distinct-first round-robin** across candidates (never confidence-collapse; confidence is only a weak tiebreak) + **representative-first context** per candidate (region center, then setup/aftermath, peak **last** and advisory) + uniform full-budget fallback when no candidates. Highlights uses `visual_candidates`; Full Story uses `narrative_candidates` + `observed.events`. Candidate intervals/peaks are advisory; `sampled_frame_ms` is provenance only; the model `evidence` string is never consulted. Budget unchanged (today's `max(4,min(9,round(dur/8)))`; `MultimodalVisualBudget` ceilings intact).

## 6. Device retrieval path (Option 8-i)

`AUEvidenceService.swift` (GET `/v1/evidence/{moment}`, download packed blob over a 15-min presigned GET, validate size + full-file sha256, unpack with bounds checks) + `AUEvidenceCacheHit.buildSheet` (mapper select → `MomentContactSheetBuilder.buildFromFrames`, no extraction). Wired into `StoryCreationCoordinator` visual-first block: cached hits are built first and **excluded** from the restore+extract set; misses fall through unchanged. Pre-render restore (the renderer's source dependency) is **untouched**. Evidence accounting + image budget preserved; `sheets = cachedSheets + budget.sheets`.

## 7. Cache-hit vs cache-miss

- **Hit (verified):** skip full-video restore + `MomentFrameExtractor`; one sheet per eligible Moment from cached frames; editorial alignment + budget + timestamps preserved.
- **Miss** (absent / `source_not_verified` / `sha_mismatch` / `extractor_version_mismatch` / `blob_missing` / integrity / transport): the existing fallback runs — local original → extract; cloud-restorable → restore+extract; else existing degraded-evidence/technical behavior. Never reports missing evidence as complete; never uses a different source version.

## 8. Invalidation

Reusable iff `content_sha256` (source) AND `frame_extraction_version` match, enforced at retrieval against the verified media record. **An AU prompt-version change does NOT invalidate the pixels** (the manifest stores no prompt version). A changed/replaced source (sha differs) or extractor-policy change → cache miss → fallback. No bulk re-analysis.

## 9. Account security

require_user on retrieval + delete; account-scoped composite keys (a wrong owner finds nothing); no public URLs (short-lived presigned GET only, server-derived key under the owner prefix); no arbitrary-key access; anonymous AU persists no package and cannot retrieve. Privacy-safe metrics only (counts/flags — never image bytes or prose).

## 10. Deletion, retention & activation safety (§4 audit — VERIFIED against code)

**Activation is DOUBLE-GATED, and the server gate is authoritative:**
- **Backend persistence** is gated by server env `STORY_EVIDENCE_PERSIST_ENABLED` (**default OFF**). The iOS flag `STORY_REUSABLE_EVIDENCE` does NOT control server writes — verified: no backend reference to it. With the server flag OFF, an authed AU request with a SHA claim writes **nothing** (test: `test_server_persist_flag_off_writes_nothing`). This closes the §4 risk ("a disabled client flag must not allow server-side persistence").
- **iOS retrieval/cache-hit** is separately gated by `STORY_REUSABLE_EVIDENCE` (default OFF).
- So no durable personal-image package exists in any environment until the owner explicitly enables the server gate.

**Moment deletion (WIRED 2026-10-26):** the iOS **permanent** library-delete path (`StoryUseCases.deleteMomentFromLibrary` → `StoryRepository.deleteMomentFromLibrary`) now fires a best-effort `DELETE /v1/evidence/{moment}` for a cloud-backed Moment BEFORE the local cascade. It is account-scoped + idempotent server-side, fire-and-forget (a transport/auth failure never blocks the local delete and never falsely reports cloud deletion), and only fires on **permanent** deletion. The **unlink** path (`removeMoment` — removes a `StoryMomentLink` only) is untouched and deletes NO evidence, so removing a Moment from one Story never destroys shared evidence. Per-Moment evidence is not shared across Moments, so deletion strands no other Moment.

**Honest limitation (device-local delete):** `deleteMomentFromLibrary` is a local SwiftData cascade; it does NOT delete the Moment's cloud **source** original (no cloud-source-delete path exists in the app — `media_store` is non-deleting). P1-F deletes the cloud **evidence** on this action, which is strictly more cleanup than the source gets today. Nothing claims the cloud source is deleted.

**Account deletion:** `delete_for_owner` exists + is tested, but is UNWIRED — the repo has NO account-deletion orchestration (verified). Audit/design is in §5a; implementation is a separate future milestone (NOT built).

**Retention — DELIBERATE owner-approved trade-off (revised policy 2026-10-26):** there is intentionally NO automatic expiry of verified OR provisional evidence, NO DynamoDB TTL, NO S3 lifecycle rule, NO orphan sweep, NO background deletion. A never-verified provisional package and an interrupted-write orphan are RETAINED and simply read as a cache MISS until an explicit deletion or a future separately-approved retention policy. Storage may grow; provisional images are private + unverified + never served as planner evidence without authoritative media verification. This is an explicit decision, not an oversight.

## 11. Tests (offline)

- `packages/evidence_store/tests/` — **13**: pack/unpack exact bytes, content-addressed idempotency, source+extractor invalidation, "prompt change does NOT invalidate", oversize refusal, account isolation, missing-blob miss, Moment/account deletion.
- `packages/evidence_mapper/tests/` — **11**: determinism, budget compliance, overview floor, distinct-candidate coverage, Highlights≠Full Story, uncertain peak, no-candidate fallback, **IMG_9091 bracket-not-collapse** (asserts selected timestamps).
- `apps/api/tests/test_evidence_r1_lifecycle.py` — **13**: AU-before-upload→verify→hit, upload-before-AU, sha_mismatch, no-upload, anonymous (no cache + 401), cross-account, repeat-idempotent, no-sha legacy caller, extractor-mismatch, missing-blob, Moment delete, cross-account delete, account delete.
- `apps/ios/Story/StoryTests/EvidenceReuseTests.swift` — Swift mapper determinism/IMG_9091/budget + service unpack integrity + `buildFromFrames`. **Runs under the owner's device ⌘U** (not runnable in the sandbox — SwiftData-linked target).
- **37 backend/package tests green**; existing AU/media/edit-plan suites unaffected (101 green in the combined run).

## 12. Performance measurement plan (baselines TBD on device)

Measure, baseline vs cache-hit separately: AU-time hash duration; cache hit/miss rate; cached-package download bytes; pre-planning source-video restore COUNT + bytes; duplicate frame-extraction count; contact-sheet build latency; Create→planner-submission latency; planner image count + payload bytes; pre-render restore count. Beacons exist (`MediaEngineV1.beacon`: "evidence cache: N of M served", "evidence-accounting…"). **No latency gain is claimed yet** — the key acceptance criterion (a normally imported+uploaded Moment has reusable evidence for its FIRST Create without a second extraction) must be measured on dev after enablement.

## 13. Known limitations & remaining gates (revised policy)

**Safe to merge** with both gates OFF (production no-op). Under the revised retention policy, automatic expiry is explicitly NOT required, so provisional retention is no longer a release blocker — it is an accepted trade-off (§10).

**Remaining before enabling `STORY_EVIDENCE_PERSIST_ENABLED=1`:**
- **Device build + acceptance** — iOS is `swiftc -parse`-clean only; the owner's Xcode ⌘U is authoritative (SwiftData macro, cross-file/actor isolation).
- **On-dev performance measurement** (§12) — confirm the first-Create-no-second-extraction criterion.
- **Account-deletion** — audit/design only (§5a); a full workflow is a separate future milestone. Not a blocker for enabling reuse, but a pre-beta privacy dependency.

**NOT introduced (policy §6, verified):** no DynamoDB TTL, no S3 lifecycle rule, no orphan sweep, no cron/background deletion, no CDK/IAM change (infra diff since merge is empty). `sweep_orphans` is not a method — stale docstring references were corrected.

## 5a. Account-deletion — AUDIT & DESIGN ONLY (not implemented)

**Current state:** the repository has NO account-deletion workflow (no Delete-Account UI/API, no Cognito deletion, no account-wide cleanup). So no existing orchestration exists for evidence to join; `EvidenceStore.delete_for_owner` is a ready primitive with no caller.

**Account-owned data inventory** (what a future deletion must reach): Stories (`story_store`), Moments + source media (`media_store`, media_kind=moment), GeneratedOutputs + rendered MP4s (media_kind=generated), AU understanding JSON (`understanding_store`), **reusable AU frame packages (`evidence_store`, this milestone)**, saved catalog-music references + imported-music metadata/bytes (`music_favorites` + media_kind=music), AI artifacts (media_kind=ai_artifact), pending edit-plan/coverage jobs (`edit_plan_jobs`), rate-limit + quota rows, Cognito identity/claims.

**Proposed architecture (future milestone, for later approval):** reauthenticated user → an authenticated `DELETE /v1/account` that (1) authorizes against the trusted principal, (2) discovers all account-scoped rows by PK query per store (never a Scan), (3) deletes in dependency order (jobs/outputs → stories → links → moments → media + evidence + understanding → music → identity last), (4) is idempotent + resumable (a partial failure re-runs safely; each store's delete is account-scoped + idempotent), (5) cancels in-flight jobs first, (6) records a tombstone so a re-auth cannot resurrect, (7) honors any legal data-retention exception. Minimal additions: one endpoint + a per-store `delete_for_owner` (evidence already has one). Real-device acceptance: create data across every store, delete account, assert each store's PK query returns empty + S3 prefixes gone + a second delete is a no-op. **No part of this is built in this milestone.**

## 9a. Development activation checklist (do NOT enable in this task — both flags stay OFF)

1. Set server `STORY_EVIDENCE_PERSIST_ENABLED=1` (dev service) + client `STORY_REUSABLE_EVIDENCE=1` (Run scheme).
2. Normal Moment import → AU (now sends `meta.content_sha256`) → upload completes.
3. Confirm authoritative SHA verification: `GET /v1/evidence/{moment}` returns `available:true` only after the media record is `cloud_verified` with a matching sha.
4. First Create on that Story → confirm the beacon "evidence cache: N of M served", NO pre-planning full-video restore for served Moments, NO `MomentFrameExtractor` re-extraction.
5. Confirm one Highlights sheet + one Full Story sheet are editorially different (mapper).
6. Original / Revise / Explore all still work; rendered MP4 plays.
7. Permanent-delete a cached Moment → confirm `DELETE /v1/evidence` fired + the package is gone; unlink a Moment from a Story → confirm the package SURVIVES.
8. Record storage + latency (baseline vs cache-hit) per §12.

## 14. Frozen contracts / infra

No change to `au_frames/1`, `moment_understanding/2`, `au_prompt/3`, `edit_plan/5.3`, the renderer, music, or AU sync. `meta.content_sha256` + `meta.frame_extraction_version` are **additive optional** AU request fields (legacy callers unaffected). `evidence_package/1` is a new additive schema. No new bucket/table/IAM. Remaining owner approvals: merge + dev deploy; and (separately) authorizing an account-deletion endpoint to wire `delete_for_owner`.

## 15. Phased status

- P1-F.1 backend persistence — **done, offline-tested.**
- P1-F.2 mapper + Highlights/Full-Story + IMG_9091 — **done, offline-tested.**
- P1-F.3 device 8-i retrieval + cache-hit skip — **done, parse-clean; device ⌘U pending.**
- P1-F.4 worker-side tiling (8-ii) — **deferred** (format compatible).
- P1-F.5 deletion — Moment delete **done**; account delete **unwired**; sweep **primitive only**.
