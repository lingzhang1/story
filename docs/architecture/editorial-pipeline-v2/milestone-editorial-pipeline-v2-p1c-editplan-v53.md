# Editorial Pipeline v2 — P1-C: EditPlan v5.3 + Mode-Aware Sizing

## Status: **IMPLEMENTED — OFFLINE TESTED — MERGED — DEV-DEPLOYED — DEVICE-TESTED — VIDEO-QUALITY-VERIFIED (dev)**

One EditPlan v5.3 engine consumes Rich AU v2 evidence to plan meaningfully different Highlights and Full
Story edits, with mode-aware sizing and Original/Revise/Explore preserved. Offline-tested (backend pytest +
iOS swiftc -parse + iOS logic unit tests), owner device ⌘U PASSED, **merged to master `306ab69`** ([PR #60](https://github.com/lingzhang1/story/pull/60)),
**deployed to dev** (App Runner + worker Lambda, `STORY_EDIT_PLAN_VERSION=5.3`), and **verified end-to-end on
device** (see §8). EditPlan v5.2 is preserved as a technical rollback. Gated behind client
`STORY_EDITORIAL_TYPE_V2` + backend `STORY_EDIT_PLAN_VERSION=5.3`.

**Scope boundary:** verified on DEV only. NOT promoted to beta/gamma/prod. The device/dev video-quality check
covered plan-level differentiation + playable MP4; a larger A/B quality evaluation was explicitly NOT run.

Evidence legend: `[CONFIRMED]` code/CI · `[VERIFIED-DEV]` proven on the dev deployment via device generation · `[PENDING]` not yet done.

---

## 1. Request contract (`edit_plan/5.3`, additive) `[CONFIRMED]`
`edit_plan/5.2` unchanged. v5.3 adds, all optional (omit-when-absent ⇒ a v5.2 request is byte-identical):
- top-level `editorial_type: "highlights" | "full_story"`
- per-Moment `editorial.{visual_candidates[], narrative_candidates[]}`, `events[]`, `sampled_frame_ms[]`
- EXCLUDED: `editorial.visual_candidates[].evidence` (untrusted model free text; stripped backend + iOS).

## 2. Editorial-type resolution (attempt boundary) `[CONFIRMED]`
Resolved ONCE per generation attempt into `pendingEditorialType`, owned through the whole async lifecycle
(request build → submit → worker → resume → GeneratedOutput), never re-derived from mutable Story state:
- **Original:** explicit Story selection → that type; none → **Highlights default** (never model-inferred; custom ≠ Full Story).
- **Revise:** inherit the base GeneratedOutput's `editorialType`; a legacy base with no stamped type stays nil (not silently Full Story).
- **Explore:** requested switch → new type; else inherit the parent's type. All four H/F transitions. Directed Explore stays Explore.
- Persisted on `PendingOperationModel.editorialTypeRaw` (additive optional, no migration) so a cold resume restores the attempt's type.
- Stamped on `GeneratedOutputModel.editorialTypeRaw` (per-output ownership; append-only history; historical outputs never rewritten).

## 3. Mode-aware Sizing `[CONFIRMED]`
Reuses existing Duration Intelligence (no new sizing model call). `DurationRecommendation.pointSeconds(forEditorialType:)`
selects Highlights → `highlights_range_seconds`, Full Story → `recommended_range_seconds`, nil → recommended
(v5.2 default); graceful fallback to the other point then nil (caller keeps its safe band fallback).
`DurationChoiceView` seeds from the type-appropriate point. Explicit custom duration, feasibility ceiling, no
fixed bands, no minimum clip count, no creative-only rejection, and no "Highlights must be shorter" rule — all preserved.

## 4. Evidence trust hierarchy `[CONFIRMED]`
- **Technical authority (hard):** source identity, technical duration, renderable bounds, media availability.
- **Input provenance:** server-minted `sampled_frame_ms` (what AU saw, not semantic truth).
- **Advisory (model-estimated):** useful_segments, events, visual/narrative candidates, candidate intervals, peak_time, roles, confidence. The planner may shorten/extend/shift/combine/omit a candidate and select OUTSIDE its interval; a soft timestamp never invalidates a renderable clip. (The IMG_9091 regression proved a real reveal can fall outside a candidate window.)
- **Direct visual:** complete timestamped contact sheets (never truncated because candidates exist).
- **Never-block preserved:** no terminal failure on creative/candidate/duration/diversity/continuity/feasibility-opinion grounds; hard technical validation + truthful disclosures retained.

## 5. Highlights vs Full Story strategy `[CONFIRMED]`
Distinct `_editorial_type_directive` injected into the USER message (frozen v5.2 system body untouched).
Highlights = visually compelling, selective, NOT a compressed Full Story. Full Story = coherent event
progression + context + native audio, NOT a longer-cut Highlights. Speech is not understood (no invented dialogue).
v5.3 prompt body = the approved creative-freedom 5.3-cand (promoted to `prompts/edit_plan/5.3/`).

## 6. Rollback mechanism (`STORY_EDIT_PLAN_VERSION` flip) `[CONFIRMED]`
`_v53_active()` (version ≥ 5.3) gates ALL v5.3 evidence. When a v5.2 version is configured on the deployed
image — including an already-installed v5.3 client still sending the optional fields — every v5.3-only moment
key (editorial/events/sampled_frame_ms) and `editorial_type` + its directive are STRIPPED, so v5.2 planning
is behaviorally identical to pre-P1-C. Submit parses `editorial_type` as a known optional field (no 422 on
this image). Per-Moment extras are lenient (planner reads via `.get()`). No app-store release needed to
roll back; pending jobs resume from their persisted metadata; no destructive migration. (Rolling the container
image back to a pre-P1-C build is NOT the intended path; the env flip on the current image is.)

## 7. Original / Revise / Explore `[CONFIRMED]`
Three independent dimensions (type ⟂ operation ⟂ directives). Revise preserves base plan, deterministic
zero-model retime, targeted change, preservation-first, truthful no-op/unmet disclosures, lineage, and no
forced AU for mechanical revises. Explore stays append-only and never becomes a targeted Revise. Original-create
directive adherence unchanged. Renderer unchanged; no second planning engine.

## 8. Test results

### 8.1 Offline `[CONFIRMED]`
- **Backend: 507 pytest pass** (`test_edit_plan_v53.py`: distinct type directives, type-in-message, untrusted
  evidence stripped, missing-block valid, extra-keys lenient, v5.2 request compat, v5.2 rollback strips all
  v5.3 fields, v5.3-active keeps them). CI (CDK/jest/ruff) green on [PR #60](https://github.com/lingzhang1/story/pull/60).
- **iOS: `EditPlanV53ModeAwareTests`** (type resolution + sizing selection + graceful fallback). `swiftc -parse` clean.

### 8.2 Device gate `[VERIFIED-DEV]`
- Owner ran the full Xcode `StoryTests` suite on device — **PASSED** (coordinator attempt-boundary resolution,
  pending-operation persistence, GeneratedOutput persistence, revision/explore).

### 8.3 Merge + deploy `[VERIFIED-DEV]`
- Merged `feat/editplan-v53-mode-aware` → master **`306ab69`** via protected-branch PR. CI green.
- Dev App Runner `story-development-api`: `STORY_EDIT_PLAN_VERSION=5.3`, digest `git-306ab69`, `/health` 200,
  OpenAPI exposes `editorial_type` + `MomentUnderstandingContract.editorial`.
- Dev worker Lambda `story-development-edit-plan-worker`: `STORY_EDIT_PLAN_VERSION=5.3`.
- Provider routing unchanged (`direct`, gpt-5.1 / gemini-3.8-flash); no Anthropic invocation; no new infra.

### 8.4 End-to-end v5.3 engagement `[VERIFIED-DEV]`
Proven by a temporary worker diagnostic (`edit_plan_v53_proof`, to be removed — see §10) on a device
generation from a freshly AU-v2-analyzed Story:
```
resolved_prompt_version: edit_plan/5.3        # planner provably on v5.3 (bundled prompt, fallback applied)
editorial_type:          highlights           # attempt-boundary type resolved + sent
moment_count:            37
moments_with_editorial:  37                    # 100% of moments carried v2 editorial evidence
moments_with_events:     37
moments_with_sampled_frame_ms: 37
```
On-device flag diagnostic confirmed the client resolution: `env=1 enabled=true resolvedType=highlights`.

### 8.5 Clean Highlights vs Full Story A/B (same footage, no directives) `[VERIFIED-DEV]`
Two no-direction Originals on the same 14-Moment footage produced substantively different plans — not merely
different length:
- **Mode-aware sizing:** Highlights target **21.0s** (5 segments), Full Story **47.5s** (7 segments).
- **Different selection:** Full Story adds contextual Moments and drops a Highlights-only closing — not a subset.
- **Different trims** on shared clips; **different narrative roles** (Highlights: opening→progression→
  interaction→payoff→closing; Full Story: opening→reflection→progression→payoff→progression→closing→closing).
- Both `feasible: true`; both exported MP4s **played correctly on device** (owner-confirmed).
Original / Revise ("add more clips" → 5→6 segments, base duration preserved) / Explore (type-switch, stays
`mode=explore`) all behaved per §2/§7.

### 8.6 Real AU v2 editorial evidence reaching the planner `[VERIFIED-DEV]`
Captured verbatim from a generation's request (`edit_plan_v53_editorial_sample`, job `7c765fdb`), one Moment:
- `visual_candidates` (timed, role-tagged, confidence-scored): `opening` 0.86 [0–3.5, peak 2.5]; `payoff`
  0.83 [6–10.5, peak 9.5]; `establishing` 0.90 [10.5–15.5, peak 13.5]; `b_roll` 0.80 [19–23.5, peak 22].
- `narrative_candidates` with `what_happens`/`why_matters`/`role`: opening 0.88, establishing 0.90, closing 0.84.
- `events`: 5 timed shot descriptions; `sampled_frame_ms` present; `analysis_version: au_editorial/1`.
- Untrusted free-text `evidence` absent (stripped upstream, per §4).
AU resolved as `moment_understanding/2` / `au_prompt/3` (confirmed in API logs).

## 9. Known limitations / findings `[CONFIRMED]`
- **`EditorialTypeFlag` is not persisted (pre-beta BLOCKER).** `EditorialTypeFlag.enabled` reads
  `ProcessInfo.environment` → UserDefaults → default OFF, and nothing captures the scheme value to
  UserDefaults (unlike `StoryLaunchConfig`, which persists backend config). So the flag is ON only on an
  attached ⌘R launch; on a detached / home-screen / TestFlight launch it defaults **OFF** and no editorial
  type/evidence is sent. **Beta has no Xcode attach → Editing v2 would be OFF for every tester.** Fix: capture
  `STORY_EDITORIAL_TYPE_V2` into UserDefaults at `StoryApp.init` via `EditorialTypeFlag.setOverride(...)`
  (mirror `StoryLaunchConfig.captureLaunchOverrides`), or flip the dev/beta default ON. Must land before beta.
- **AU understanding sync/push durability gap.** AU v2 is produced + used locally, but `UnderstandingSync.push()`
  (fires only on sign-in/foreground, and only for cloud-backed media with a `content_sha256`) was not observed
  populating the account store during testing (0 v2 rows server-side). A reinstall before a successful push
  would currently lose local AU v2. Pull/restore is already built. Full writeup + fix location in
  `TODO-au-understanding-sync-durability.md`. Not an EditPlan v5.3 defect; separate pre-beta task.
- **AU-completion-under-auth, not upload date, determines v2 editorial.** A stale cross-pool (beta) token after
  a dev switch 401'd AU; those Moments' local understanding lacked the `editorial` block (→ `moments_with_editorial=0`
  on an older Story) until a sign-out/in re-ran AU authenticated. Diagnosis confirmed via distinct story/moment
  sets + timestamps; resolved by re-auth. Operational, not a code defect.
- Device ⌘U + dev video-quality are DONE on dev; a larger rendered-video A/B quality evaluation was intentionally
  NOT run (bounded to the 4-operation acceptance).
- The UI type-picker surfacing is **P1-D Create UX**, not this milestone.
- AU peak timing stays advisory (~1–2s early on human turns); planner treats it as a hint by design.

## 10. Deferred / cleanup (tracked, not in P1-C)
- **Temporary dev diagnostics to remove before any further merge:** worker `edit_plan_v53_proof` +
  `edit_plan_v53_editorial_sample` log lines (`apps/api/app/worker.py`). They were deployed to the dev worker
  only for this acceptance and are not committed to master.
- **Gemini-primary AU fallback** still fires (`requested gemini-3.8-flash → served openai`, `used_fallback:true`);
  AU still succeeds as v2 via OpenAI. Separate pre-beta operational issue; routing deliberately untouched here.
- `GitCommitSHA=unknown` in build provenance; duration-aware frame sampling; audio/speech understanding;
  P1-D Create UX; caching/latency/provider optimization.
