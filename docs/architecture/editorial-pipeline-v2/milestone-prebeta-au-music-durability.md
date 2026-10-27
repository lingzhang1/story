# Milestone — Pre-beta: AU Sync Durability + My Music Persistence & Preview (P1-E)

## Status: **IMPLEMENTED — OFFLINE TESTED (backend run green; iOS parse-clean) — NOT MERGED — NOT DEPLOYED — NOT REINSTALL-VERIFIED**

Branch `fix/prebeta-au-music-durability` off master `dca1d62`.
Commits: AU durability `2e0c114` (part A); My Music durability + preview `4a1f841` (parts B/C/D);
tests + this doc (this commit). AU and music changes are in separate commits per the milestone's §2.

Evidence legend: `[CONFIRMED]` code · `[RAN]` test executed here · `[PARSE]` swiftc -parse only (iOS device-⌘U
gate) · `[PENDING]` device/reinstall.

Owner gate: **stop before PR merge, development deployment, live cloud-media uploads, and destructive
reinstall testing.** The next approval covers merge + dev deploy + controlled device verification.

---

## 1. Root causes (all three traced end-to-end)

### A. AU v2 not reaching the cloud — `[CONFIRMED]`
- `UnderstandingSync.push()` was invoked from exactly two places (`StoryApp.swift`): the auth→signed-in
  transition and `scenePhase == .active`. **No push when the AU queue finishes a Moment**, so understanding
  produced mid-session was not pushed until the next foreground.
- `push()` only pushes an understanding whose Moment media has a `content_sha256` (from a completed
  `MediaUploadJobModel`). If the upload had not recorded a sha yet, the understanding was silently skipped.
- `restore()` / `batchGet` already existed and were wired (restore-first, no re-analysis). The gap was
  **push-side only**.

### B. Saved catalog tracks disappear — `[CONFIRMED]`
- `MyMusicStore.saveProviderFavorite()` writes a **local-only SwiftData row** (`provider:<trackId>`, no bytes).
  There was **no account sync** for the saved library; reinstall wiped it. No account-KV/favorites endpoint
  existed.

### C. Imported music disappears — `[CONFIRMED]`
- `MyMusicStore` is **LOCAL-FIRST, bytes never uploaded** (copied under `<Documents>/mymusic/`). Reinstall
  deletes the app container → imported audio bytes were permanently lost. Metadata sync alone cannot recover
  them.

### D. Preview doesn't work — `[CONFIRMED]`
- The player existed and was correct. Imported preview failed after reinstall because the local file was gone
  (a symptom of C). Saved-favorite preview was **intentionally disabled** (`.disabled(isProviderFavorite)`) —
  favorites store no bytes and no preview URL.

---

## 2. Current vs corrected data flow

| Area | Before | After |
|---|---|---|
| AU push | foreground/sign-in only; sha-gated skip silently dropped | + push on AU-drain completion + push on media-upload-verified; foreground/sign-in kept as backstop |
| Saved catalog | local SwiftData only | `GET/PUT /v1/music/favorites` (references only), union-merge reconcile at sign-in/foreground + on save/unsave |
| Imported audio | local bytes only, never uploaded | opt-in cloud backup via existing `/v1/media` (`media_kind="music"`), restore-after-reinstall by `device_asset_id` |
| Preview | imported only if local; favorite disabled | imported plays local/restored bytes; favorite re-resolves authorized audio on demand (existing provider path) |

---

## 3. Storage / contract decisions (owner-approved)

- **`media_kind="music"`** added to `media_store` (`MEDIA_KIND_MUSIC`) + iOS `CloudMediaKind.music`. Additive;
  no new bucket/table/CDK/IAM. Reuses the exact R4 upload / R6 verified-download pipeline (the `AIArtifactStore`
  pattern). **ONLY user-imported files** are uploaded — provider/catalog audio is never uploaded (licensing).
- **`GET/PUT /v1/music/favorites`** (new endpoint, owner-approved). Optimistic concurrency (base_revision +
  server revision), R7 reconcile semantics. Backed by the **existing R7-E understanding table** under a
  reserved sentinel sort key (`__music_favorites__`) — **no new table/CDK/IAM**. References only.
- **No change** to AU (`moment_understanding/2`, `au_prompt/3`), EditPlan, frame sampling, provider routing,
  renderer, or Cognito/IAM.

## 4. Retry & restore behavior

- AU push: idempotent PUT; coalesced (N Moments → 1 push); media-not-yet-backed understandings are retried on
  upload-complete; foreground/sign-in backstop remains. A 401/5xx leaves local AU intact and retries later.
- Imported backup: 30 MB cap, audio content-types; content-addressed (idempotent, no dup); honest state
  `local_only → backing_up → cloud_verified`, `restore_pending` (metadata only), `unavailable` (owned but
  bytes unfetchable). An empty remote never clears local.
- Favorites: union merge (local ∪ cloud); empty-local never wipes populated-cloud; a 409 re-pulls + re-merges;
  401/transport recoverable (local intact).

## 5. Security / ownership

- Every sync op is account-scoped to the server-derived `story_user_id`; a wrong owner finds nothing
  (no cross-account leak). Media/favorites records are never cross-account readable.
- Imported audio is private to the owner (account-scoped S3 key + presigned, time-limited URLs). No public
  read. Provider audio is never uploaded.
- Dev/beta account separation is unchanged (sync uses the current environment's authenticated account; a stale
  cross-pool token 401s and defers, never a false success).

## 6. Music preview behavior

- Imported: play local/restored managed file via the existing `AVPlayer` + `.playback` session.
- Saved catalog favorite: re-resolve authorized audio on demand (`MusicCandidatesService.downloadSoundtrack`),
  then play; an unavailable track shows an honest message rather than silently failing. No new player/provider.
- Play/pause, switch-track-stops-previous, leave-view-cleanup, and audio-session release are preserved.

## 7. Automated tests

### Backend — `[RAN]` green here (no AWS)
- `apps/api/tests/test_music_favorites_api.py` (8 tests): empty-get = revision 0 (not error); unauth 401;
  put/get roundtrip; stale-base 409 carrying current; correct-base advance; account isolation; unsave
  propagation; sentinel-key isolation. Plus an in-process favorites-store smoke test.
- Existing `test_media_api.py` + `test_story_api.py` (46) still green (additive `MEDIA_KIND_MUSIC` + endpoint).

### iOS — `[PARSE]` (device-⌘U gate; sandbox cannot run the SwiftData `@Model` build)
- `StoryTests/MusicDurabilityTests.swift`: saving pushes reference; restore-adopts-cloud; empty-cloud never
  clears local; two-device union; local-metadata-wins merge; backup default/verified state; backup refuses a
  provider favorite; audio content-type mapping; preview eligibility; honest subtitle states.
- `StoryTests/AssetUnderstandingQueueTests.swift` (added): drain-completion fires the push seam exactly once
  (coalesced); a drain with no completion does not push.

## 8. Reinstall acceptance checklist (device — PENDING, owner-run)

**AU:** sign in (dev) → import/link a Moment → complete AU v2 → confirm the understanding is durably in the
account store → delete/reinstall → sign in (same account) → restore → confirm the original v2 result is reused
with **no new AI call**.

**Saved catalog:** save a track → appears in My Music → confirm account-side persistence → delete/reinstall →
sign in → saved track reappears → preview (re-resolved) → select for an edit.

**Imported audio:** import a supported file → appears in My Music, state → `Backed up` → preview → delete/
reinstall → restore → confirm the **underlying playable bytes** are recovered (not just the name) → preview +
select.

Do not run destructive reinstall testing until disposable test content / safe backups are confirmed. Do not
treat real music as proof of backup without verifying stored bytes or a valid authorized retrieval path.

## 9. Known limitations / follow-ups

- **iOS correctness is device-gated:** `swiftc -parse` clean ≠ a successful Xcode build (SwiftData macro). The
  `MusicDurabilityTests` + AU push tests must be confirmed green on the owner's ⌘U.
- **Backend `media_kind="music"` + `/v1/music/favorites` are not deployed** — they ship on the dev deploy the
  owner authorizes next. Until then the iOS client's backup/favorites calls will 404 against the current dev
  backend (handled gracefully: local bytes remain usable; favorites stay local).
- **Explicit cloud deletion** of a backed-up import is deferred (reference-safe retention today; a removed
  local row simply stops being restored). A future increment can add owner-initiated cloud delete.
- **Favorites unsave across two devices** uses last-writer-wins on the merged set with optimistic concurrency;
  a simultaneous unsave + save on two devices resolves to the union (save wins) — acceptable for references.
- **Gemini→OpenAI AU fallback** remains a separate operational item (untouched here).
