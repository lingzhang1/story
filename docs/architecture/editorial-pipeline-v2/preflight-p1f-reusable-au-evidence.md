# P1-F Preflight — Reusable AU Visual Evidence & Editorially-Aligned Planner Frames

**Status:** READ-ONLY architecture proposal. No code written, no branch, no contract/infra change. Awaiting owner approval before any implementation (§15).
**Base:** `master` @ `05750d9` (P1-E AU-sync + My Music already MERGED, PR #62).
**Author:** default · 2026-10-27

---

## 0. Headline findings (what the audit actually proved)

1. **Frames are extracted twice.** AU extracts 24 frames per Moment on-device; at Create the device extracts them **again** (restoring the full source video first if evicted) to build contact sheets. The two extractions use the *same* `MomentFrameExtractor` with the *same* `au_frames/1` policy — the second is pure duplication.
2. **The server already holds the exact accepted frames in one place.** `packages/asset_engine/__init__.py:218` mints `sampled_frame_ms` from `frames: list[AUFrame]` — the JPEG bytes **and** their accepted timestamps exist together at a single accept point, then are discarded (`main.py:1196` *"Frames discarded here — not persisted"*). This makes **backend caching (Option B) strictly cheaper than device caching** — the bytes are already server-side.
3. **The storage contract an evidence package needs already exists.** `media_store` has a content-addressed, account-scoped, SHA256-verified, non-deleting `ai_artifact` kind with presigned PUT/GET and no TTL — **no new bucket, table, or IAM is required**.
4. **Pre-planning full-video restore exists ONLY to feed the contact-sheet builder.** `StoryCreationCoordinator.swift:621` restores evicted originals *before planning* solely so `MomentContactSheetBuilder` can read local bytes. A separate **pre-render** restore (`:864`) is legitimately needed and is out of scope. Eliminating the pre-planning restore is therefore safe **iff** cached evidence replaces the contact-sheet source.
5. **The worker already does S3 + DynamoDB I/O under its own IAM**, loading sheets from S3 staging (`worker.py` `store.load_request`). A worker-side fetch of cached evidence is architecturally in-reach.

**Recommendation: Option B (backend-created evidence package), stored as a new `media_kind` reusing `ai_artifact` mechanics, retrieved by the worker.** Rationale and the full design follow.

---

## 1. Current AU & EditPlan image flow (code references)

### 1a. AU path — where the 24 JPEGs live and die
| Step | Location | Note |
|---|---|---|
| Extract 24 frames | `apps/ios/.../MomentFrameExtractor.swift:40` `extract(from:)` | `au_frames/1`: 24 evenly-spaced, 768px, JPEG ~0.6, `extractionPolicy="au_extract/2"`. Needs a **local** `url`. |
| Serialize to multipart | `apps/ios/.../AssetUnderstandingService.swift` `makeBody` | `meta` + `frames_meta`([{t_ms}]) + 24 `frames` JPEG parts. |
| Endpoint accept | `apps/api/app/main.py:1074` `asset_understanding()` | Validates exactly 24, monotonic t_ms; builds `au_frames: list[AUFrame]`. |
| **Single accept point (bytes+t_ms together)** | `packages/asset_engine/__init__.py:169-218` `analyze()` | `sampled_frame_ms = [int(f.t_ms) for f in frames]` — server-minted, model cannot author it. |
| Model invocation | `model_gateway` (direct OpenAI/Gemini or Bedrock) | Ephemeral image inputs. |
| Persist understanding | DynamoDB via `understanding_store.put()` + iOS `MomentUnderstandingModel` | JSON only — `understandingJSON`, `schemaVersion`, `framePolicy`, `promptVersion`, `contentSha256`, `modelId`. **No pixels.** |
| **Frame disposal** | `main.py:1196` *"Frames discarded here (not persisted) — ephemeral inference input."* | The one line to change for Option B. |

### 1b. Editing path — Create → planner inference
| Step | Location | Note |
|---|---|---|
| Build request (eligibility gate) | `RenderSupport.swift:EditPlanRequestBuilder.build` | Cloud-aware: eligible iff AU + duration + renderable. `editorialV53Fields` forwards candidates/events/`sampled_frame_ms` (flag-gated). |
| **Restore-before-extract (the waste)** | `StoryCreationCoordinator.swift:621` `resolveEnsuringLocal(...)` | Restores evicted originals **only** so sheets can be built. |
| Build contact sheets | `MomentContactSheetBuilder.build` → `MomentFrameExtractor.extract` (**2nd extraction**) | Re-extracts 24, evenly subsamples to `max(4,min(9,round(dur/8)))`, tiles one labeled JPEG/Moment. |
| Adaptive budget | `MultimodalVisualBudget.build` | 5-step degradation ladder; 16 MB total / 900 KB/sheet device target; ranks by `richness()` (useful_segments·2 + events + dur/30). |
| Submit (async) | `EditPlanJobClient.submit` → S3 staging | Sheets uploaded as multipart; staged in `story-development-edit-plan-staging-*`; deleted at job-terminal. |
| Worker exec | `apps/api/app/worker.py` `_run_edit_plan` | `store.load_request(prefix, order)` → `ImageInput` list → `engine.generate`. **No durable frame store read.** |
| Model image input | `/v1/edit-plan-mm` validation mirror (`main.py:1537`) | `_MM_EDIT_MAX_*` ceilings; one sheet per Moment by `sheet_order`. |

### 2. Exact duplicate-extraction points
- **Extraction #1:** `MomentFrameExtractor.extract` during AU (`asset_understanding.analyze` input).
- **Extraction #2:** `MomentFrameExtractor.extract` inside `MomentContactSheetBuilder.build` at Create.
Same policy, same device, same clip — **#2 is fully redundant when #1's frames are cached.**

### 3. Actual pre-planning media dependencies
Traced `resolveEnsuringLocal` at `:621`. The restored local bytes feed **only** `visualBudgetInputs(fromMedia:)` → `MomentContactSheetBuilder`. Confirmed NOT needed pre-plan for:
- **Duration** — `MomentResolver.plannerDuration` uses `AssetModel.durationSeconds` (cloud metadata) when no local file.
- **Eligibility** — cloud-aware (`isRenderableSource` accepts `cloud_verified`).
- **useful_segments / summary / evidence / candidates** — all from persisted AU JSON.
- **Audio / validation / security** — none at planning; audio RMS (`CreativeRefinementV2b`) is OFF and runs post-plan pre-render anyway.
**Conclusion:** the pre-planning restore at `:621` is eliminable with cached evidence. The pre-render restore at `:864` stays (renderer needs originals). §10 "restore selected media after planning" is already how `:864` works.

---

## 4. Recommendation — **Option B (backend evidence package)**

| Criterion | A (device uploads frames) | **B (backend packages accepted frames)** |
|---|---|---|
| Implementation | New device uploader + upload-state tracking | Package the `AUFrame` list already in hand at `analyze()`; reuse `ai_artifact` PUT path |
| Network | **Extra** device→S3 upload of ~1-3 MB/Moment | **Zero extra** device egress (bytes already uploaded to the AU endpoint) |
| Client dependency | High (device must succeed post-AU) | Low (server owns it; device only reads on cache-miss fallback) |
| Account ownership | Device supplies owner → re-verify | `principal.story_user_id` already trusted at the endpoint |
| Durability | Gated on a second device success | Written transactionally with the AU result |
| Storage cost | Same blob either way | Same |
| API/worker access | Worker fetch identical | Worker fetch identical |
| Retry/idempotency | New idempotency surface | Content-addressed (`uuid5(owner+sha)`) — idempotent for free |
| AU-sync integration | Parallel to the merged push/restore | **Rides the same `content_sha256` reuse key** |

**Option B wins on every axis that differs.** The frames are already server-side at a single accept point; persisting them there is the smallest reliable change. Device caching (A) would re-upload bytes the server just received — strictly worse.

**Caveat (honest):** the AU endpoint is `optional_user` (anonymous AU allowed on dev). Evidence caching requires a signed-in owner (same gate as `understanding_store.push`). Anonymous AU simply produces no cached package → graceful text-only/local-extract fallback. This is a real limit, not a blocker.

---

## 5. Minimal evidence manifest (new `moment_understanding` sibling — versioned)

Store **one package per (owner, moment_id, content_sha256, frame_extraction_version)**. Do NOT duplicate AU `observed`/`editorial` — reference them by key.

```jsonc
// evidence_package/1  — stored as media_kind="au_evidence" blob metadata + a manifest record
{
  "schema": "evidence_package/1",
  "moment_id": "…", "owner": "…",            // account scope (never client-trusted)
  "content_sha256": "…",                      // MUST match the Moment media sha (invalidation anchor)
  "frame_extraction_version": "au_extract/2", // invalidates on extractor policy change
  "frame_count": 24,
  "frame_dims": {"longest_edge": 768, "encoding": "jpeg", "q": 0.6},
  "sampled_frame_ms": [0,1385,…],             // the SERVER-MINTED accepted timestamps (provenance)
  "frames_ref": {                             // bytes in S3 as ONE packed blob (not 24 objects)
    "cloud_media_id": "…", "bytes": 1234567, "sha256": "…", "layout": "concat-jpeg+index"
  },
  "created_at": 1730000000,
  "retention": "tied-to-source-media"         // deleted with the Moment media / account
}
```

### Four INDEPENDENT versions (explicitly separated per §5)
| Version | Invalidates cached **frames**? | Owner |
|---|---|---|
| `frame_extraction_version` (`au_extract/2`) | **Yes** — different pixels | Extractor |
| AU `prompt_version` (`au_prompt/3`) | **No** — same pixels, re-interpret text only | AU prompt |
| `candidate_mapping_version` | No (frames) — remap selection | P1-F mapper |
| `sheet_selection_version` | No (frames) — re-tile | P1-F planner-sheet builder |
> **A new AU prompt must NOT invalidate cached frames.** Only a changed `content_sha256` or `frame_extraction_version` invalidates the pixels.

---

## 6. Candidate-to-frame mapping (deterministic; timestamps advisory)

Given cached frames at `sampled_frame_ms` (24 evenly-spaced) + AU candidates, select the per-Moment sheet frames **deterministically**:

```
map(candidate interval [s,e], peak p?):
  context = [s - CTX, e + CTX]           // CTX ≈ 1.5s bounded temporal padding (peaks can be wrong — IMG_9091)
  pick nearest sampled frame to s, to e, and to midpoint
  if p present: also pick nearest frame to p  (ADVISORY — never assume it is the true apex)
  always KEEP whole-Moment overview: first, last, and evenly-spaced coverage frames
dedupe by t_ms; preserve order; clamp to budget
```

Hard rules (from the learned IMG_9091 regression):
- Nearest-to-`peak_time` is **not** assumed to be the apex; include neighbors.
- Candidate intervals are **not** visibility constraints — always add overview frames.
- Use `sampled_frame_ms` as **provenance only**, never semantic proof.
- **Never** parse model `evidence` `frames@…ms` strings (already stripped in `_build_user` and `editorialV53Fields`).

### Highlights selection (per §6)
Prioritize, per visual candidate: before-reveal, approximate-reveal, after-reveal, payoff, plus other distinctive candidates and overall context. Cover the top-N **distinct** candidates (by count/diversity, **not** raw confidence).

### Full Story selection (per §6)
Prioritize narrative opening, event progression (from `observed.events` timestamps), interactions, complete actions, environmental context, transitions, resolution. Favor **even narrative coverage** across the whole clip over clustering on one candidate.

### Concrete examples (same frame budget as today)
- **30s dress-turn, multiple reveals:** before/at/after for each of 2 reveals (6) + opening + closing context (2) ≈ 8 frames (vs today's blind even 8). The reveals are now *guaranteed represented*.
- **Scenic mountain pan:** few/no visual candidates → fall back to even overview (today's behavior) — 5-6 frames.
- **Egypt human-interaction:** interaction event windows + wide establishing + resolution — 7 frames weighted to the interaction.
- **No strong candidate:** identical to today — even overview, no regression.

---

## 7. Planner visual budget (unchanged envelope)
Keep today's `max(4,min(9,round(dur/8)))` per-Moment, one sheet/Moment, and the `MultimodalVisualBudget` 5-step ladder + 16 MB/900 KB ceilings **untouched**. P1-F changes **which** of the 24 cached frames get tiled (the mapping above), **not** the count or payload. Never forward all 24. Selection balances overview + candidate coverage + payoff + diversity + narrative completeness; ties break by distinct-candidate count, never confidence.

---

## 8. Eliminating pre-planning downloads
**Desired sequence (achievable):** AU → evidence package durable → user picks type → **worker builds editorially-selected sheets from cached frames** (device sends sheet selection *intent*, not bytes, on cache-hit) → plan → **pre-render restore of only selected Moments** (`:864`, unchanged).

Two viable splits (owner to choose at implementation approval):
- **8-i (smaller, device-side):** device fetches cached frame blobs (presigned GET) instead of restoring+re-extracting full videos, tiles sheets locally. Eliminates full-video restore + re-extraction; keeps today's submit path. *Lowest risk.*
- **8-ii (bigger, worker-side):** device sends only `{moment_id, selected_frame_indices}`; worker fetches cached frames from S3 and tiles. Eliminates device image egress entirely. *Larger worker change; defer to a later phase.*

**Latency eliminated (must be measured, not claimed):** full-video restore for evicted Moments + the 2nd `AVAssetImageGenerator` pass. **Not** eliminated: model inference, pre-render restore, first-ever AU extraction. See §12.

---

## 9. Security / privacy / deletion
- Reuse `ai_artifact` mechanics: account-scoped key `media/{owner}/{cmid}/…`, `uuid5(owner+sha)`, SHA256-verified, **private** (no public URLs — §9), short-TTL presigned GET only.
- Worker access = existing worker IAM to the media bucket (already reads S3 staging) — **no new IAM in this preflight**.
- **Deletion:** cached frames MUST be deleted when the source Moment media or account is deleted. Current `media_store` is explicitly non-deleting ("reference-safe deletion is a later increment") — so P1-F needs a **deletion hook** tied to Moment/account teardown. This is the one place new infra *may* be required; flagged for owner approval, not built here.
- Orphan cleanup: a sweep for evidence blobs whose Moment no longer exists (mirror the quota-orphan sweep pattern in `worker.py`).
- Encryption: inherit bucket SSE (same as originals).

---

## 10. Invalidation & fallback
Invalidate frames iff `content_sha256` mismatch OR `frame_extraction_version` mismatch. Never on AU prompt change. Fallback ladder (preserve today's behavior exactly):
`cached package present+valid` → use it; else `local original present` → extract today's way; else `cloud-restorable` → restore+extract (today's `:621` path, retained as fallback); else **text-only** (never fabricate). Handles: no-cache legacy Moments, upload/storage failure, partial cache, expired/missing object, reinstall/new device (re-fetch by sha), auth unavailable (text-only), sha mismatch (invalidate), AU re-analysis same media (reuse frames), **multiple Stories sharing a Moment** (package is per-moment, shared — a win). Preserves P0 evidence accounting + never-block-playable-video.

---

## 11. Integration with the ACTIVE AU-sync / music session
P1-E is **merged** (`#62`); the live follow-up is `origin/fix/prebeta-au-music-durability`. **Boundary:**
- **Do NOT edit:** `UnderstandingSync.swift`, `MomentModel`/`MomentUnderstandingModel`, `understanding_store`, `music_favorites`, and the `/v1/understanding` contract while that session is active.
- **P1-F owns a SEPARATE surface:** frame-pixel durability (new `au_evidence` blob + manifest), the AU endpoint frame-disposal line, the contact-sheet source, and the candidate→frame mapper.
- **Shared, read-only dependency:** both use `content_sha256` as the reuse key — P1-F consumes it, never redefines it.
- **Do not start a branch** until the durability milestone lands or a non-overlapping scope is explicitly approved (§11/§15).

---

## 12. Baseline measurement plan (measure BEFORE claiming savings)
Instrument (beacons already exist): videos downloaded pre-plan, bytes restored, frame-extraction ms, sheet-build ms, Create→submit ms, planner image count+bytes, cache hit rate, model latency, final render downloads, storage/network cost. **Separate measured baseline from projected savings.** Target metrics to prove: (a) pre-plan full-video restores → ~0 on cache-hit; (b) 2nd-extraction ms → ~0 on cache-hit; (c) model image count/bytes unchanged. No speedup number asserted until (a)/(b) are measured on-device.

---

## 13. Acceptance plan (offline + device)
Offline: frame-timestamp provenance stored correctly; sha ties frames to source; Highlights gets candidate-aligned frames; Full Story gets narrative-aligned frames; whole-Moment context preserved; cache-hit skips re-extraction; invalidation on sha/extractor change but NOT on prompt change; mapping deterministic. Device: cloud-only Moment plans without full restore; cached evidence restores on reinstall/other device; cache-miss falls back safely; evidence accounting intact; Original/Revise/Explore + version history work; rendered MP4 valid. **Fixture: IMG_9091** — assert the mapper includes frames bracketing the true ~16.62s reveal via bounded context even though `peak_time` was mislocated.

---

## 14. Frozen contracts & approvals required
- **No** change to `au_frames/1`, `moment_understanding/2`, `edit_plan/2`, `au_prompt/*` (§15).
- `evidence_package/1` is a **new additive** schema — not a frozen-contract edit.
- **Owner approval needed for:** (1) the deletion hook / orphan sweep for cached frames (the only possible new infra), (2) choosing split 8-i vs 8-ii, (3) starting implementation after the AU-sync milestone lands.

## 15. Recommended phased implementation (post-approval)
- **P1-F.1** Backend: persist the accepted `AUFrame` list as an `au_evidence` package at the AU accept point (Option B); manifest record; invalidation by sha+extractor. Offline tests. *(No device change; no behavior change — pure durability.)*
- **P1-F.2** Candidate→frame mapper + Highlights/Full-Story selection; unit tests incl. IMG_9091.
- **P1-F.3** Device split 8-i: fetch cached frames instead of restore+re-extract; keep submit path; measure §12.
- **P1-F.4 (optional/deferred)** Worker-side tiling (8-ii) to remove device image egress.
- **P1-F.5** Deletion hook + orphan sweep (needs §14 approval).

**Success:** AU frames become reusable, the planner receives editorially-aligned evidence, and pre-planning full-video downloads + duplicate extraction are eliminated on cache-hit — with no frozen-contract change and a safe fallback to today's behavior everywhere.
