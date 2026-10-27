# Milestone — P1-F: Reusable AU Visual Evidence & Editorially-Aligned Planner Frames

**Status: IMPLEMENTED / OFFLINE-TESTED.** NOT merged, NOT deployed, NOT device-built, NOT performance-verified.
**Branch:** `feat/p1f-reusable-au-evidence` (base `05750d9`). **Design:** R1 (device supplies source-SHA claim; authority established at retrieval). See `preflight-p1f-reusable-au-evidence.md`.

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

## 10. Deletion & orphan handling

- **Moment deletion:** `DELETE /v1/evidence/{moment_id}` (require_user, account-scoped, idempotent) → `EvidenceStore.delete_for_moment` removes manifest + packed blob. Reuses existing infra; **no new IAM**. The per-Moment evidence blob is distinct per `(owner, moment, source-sha)`, so deleting one Moment's evidence can never strand another's (shared-source safety).
- **Orphans / interrupted writes:** a manifest with a missing blob reads as a miss; a blob with no manifest is unreferenced. (A periodic sweep is a small future add; `delete_for_moment`/`delete_for_owner` are the primitives.)
- **Account deletion:** `EvidenceStore.delete_for_owner` exists and is offline-tested, **but is UNWIRED** — see Known limitations.

## 11. Tests (offline)

- `packages/evidence_store/tests/` — **13**: pack/unpack exact bytes, content-addressed idempotency, source+extractor invalidation, "prompt change does NOT invalidate", oversize refusal, account isolation, missing-blob miss, Moment/account deletion.
- `packages/evidence_mapper/tests/` — **11**: determinism, budget compliance, overview floor, distinct-candidate coverage, Highlights≠Full Story, uncertain peak, no-candidate fallback, **IMG_9091 bracket-not-collapse** (asserts selected timestamps).
- `apps/api/tests/test_evidence_r1_lifecycle.py` — **13**: AU-before-upload→verify→hit, upload-before-AU, sha_mismatch, no-upload, anonymous (no cache + 401), cross-account, repeat-idempotent, no-sha legacy caller, extractor-mismatch, missing-blob, Moment delete, cross-account delete, account delete.
- `apps/ios/Story/StoryTests/EvidenceReuseTests.swift` — Swift mapper determinism/IMG_9091/budget + service unpack integrity + `buildFromFrames`. **Runs under the owner's device ⌘U** (not runnable in the sandbox — SwiftData-linked target).
- **37 backend/package tests green**; existing AU/media/edit-plan suites unaffected (101 green in the combined run).

## 12. Performance measurement plan (baselines TBD on device)

Measure, baseline vs cache-hit separately: AU-time hash duration; cache hit/miss rate; cached-package download bytes; pre-planning source-video restore COUNT + bytes; duplicate frame-extraction count; contact-sheet build latency; Create→planner-submission latency; planner image count + payload bytes; pre-render restore count. Beacons exist (`MediaEngineV1.beacon`: "evidence cache: N of M served", "evidence-accounting…"). **No latency gain is claimed yet** — the key acceptance criterion (a normally imported+uploaded Moment has reusable evidence for its FIRST Create without a second extraction) must be measured on dev after enablement.

## 13. Known limitations / remaining gates

- **Device build pending.** iOS parse-clean only (`swiftc -parse`); the authoritative Xcode ⌘U + device acceptance is the owner's gate.
- **`STORY_REUSABLE_EVIDENCE` is OFF by default** — the device path is inert until enabled (correct for a new path; enabling can only remove duplicate work, never reduce coverage).
- **Account-deletion hook is UNWIRED.** `delete_for_owner` exists + is tested, but the repo has **no account-deletion path** to call it from. Wiring one is new surface (a §7 stop item) — flagged for a future increment, not built here.
- **Orphan sweep** is a primitive, not a scheduled job yet.
- **Performance not verified** (see §12).

## 14. Frozen contracts / infra

No change to `au_frames/1`, `moment_understanding/2`, `au_prompt/3`, `edit_plan/5.3`, the renderer, music, or AU sync. `meta.content_sha256` + `meta.frame_extraction_version` are **additive optional** AU request fields (legacy callers unaffected). `evidence_package/1` is a new additive schema. No new bucket/table/IAM. Remaining owner approvals: merge + dev deploy; and (separately) authorizing an account-deletion endpoint to wire `delete_for_owner`.

## 15. Phased status

- P1-F.1 backend persistence — **done, offline-tested.**
- P1-F.2 mapper + Highlights/Full-Story + IMG_9091 — **done, offline-tested.**
- P1-F.3 device 8-i retrieval + cache-hit skip — **done, parse-clean; device ⌘U pending.**
- P1-F.4 worker-side tiling (8-ii) — **deferred** (format compatible).
- P1-F.5 deletion — Moment delete **done**; account delete **unwired**; sweep **primitive only**.
