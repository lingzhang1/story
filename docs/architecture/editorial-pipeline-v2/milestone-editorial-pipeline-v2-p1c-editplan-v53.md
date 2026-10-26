# Editorial Pipeline v2 — P1-C: EditPlan v5.3 + Mode-Aware Sizing

## Status: **IMPLEMENTED — OFFLINE TESTED — MERGE/DEVICE/LIVE QUALITY PENDING**

One EditPlan v5.3 engine consumes Rich AU v2 evidence to plan meaningfully different Highlights and Full
Story edits, with mode-aware sizing and Original/Revise/Explore preserved. Offline-tested (backend pytest +
iOS swiftc -parse; iOS logic unit tests added). NOT merged, NOT deployed, NOT device/video-quality verified.
EditPlan v5.2 is preserved as a technical rollback. Gated behind `STORY_EDITORIAL_TYPE_V2` + `STORY_EDIT_PLAN_VERSION=5.3`.

Evidence legend: `[CONFIRMED]` code/CI · `[PENDING]` not yet done.

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
- **Backend: 507 pytest pass** (`test_edit_plan_v53.py`: distinct type directives, type-in-message, untrusted
  evidence stripped, missing-block valid, extra-keys lenient, v5.2 request compat, v5.2 rollback strips all
  v5.3 fields, v5.3-active keeps them). CI (CDK/jest/ruff) expected green on PR.
- **iOS: `EditPlanV53ModeAwareTests`** (type resolution: Original Highlights-default, explicit H/F, custom≠Full
  Story, wire values; sizing: Highlights/Full/nil selection + graceful fallback). `swiftc -parse` clean.
  `[PENDING]` the full async Original/Revise/Explore submit→resume→persist matrix runs on-device via ⌘U (the
  SwiftData @Model macro can't execute in the parse sandbox).

## 9. Known limitations / remaining `[PENDING]`
- Device ⌘U (StoryTests) + merge + dev deploy + a small rendered-video quality check (Highlights vs Full Story
  are substantively different, Revise/Explore guarantees hold, both playable) — all still required.
- The UI type-picker surfacing (which attempt sets `requestedEditorialType`/`story.editorialMode`) is P1-D Create UX, not this milestone.
- AU peak timing stays advisory (~1–2s early on human turns); planner treats it as a hint by design.

## 10. Deferred (tracked, not in P1-C)
Gemini-primary AU fallback/latency; `GitCommitSHA=unknown`; duration-aware frame sampling; audio/speech
understanding; P1-D Create UX; caching/latency/provider optimization.
