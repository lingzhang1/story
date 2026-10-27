# Editorial Pipeline v2 — P1-D: Simplified Highlights / Full Story Create Experience

## Status: **IMPLEMENTED — OFFLINE PARSE-CLEAN — DEVICE ⌘U / MERGE / DEPLOY PENDING**

Redesigns the **Customize Your Story** sheet around two consumer Video Types (Highlights / Full Story),
removes the legacy Editing-Approach and Story-Length pickers, and makes Editing v2 reliably ON across normal
launches. Branch `feat/editorial-p1d-create-ux` off master `306ab69`. Backend planner, AU, renderer, provider
routing UNCHANGED. NOT merged, NOT deployed, NOT device-verified.

Evidence legend: `[CONFIRMED]` code · `[PARSE]` swiftc -parse only · `[PENDING]` device/CI.

---

## 1. Screen structure (§3) `[CONFIRMED]`
`CustomizeYourStoryView` body reordered: Header → **Video Type** → Creative Direction → Feeling presets →
collapsible **More Options** → persistent safe-area Create. The dynamic summary + Create live in a
`safeAreaInset(.bottom)` so they stay visible with the keyboard open, More Options expanded, and across
iPhone sizes. Default path needs no Advanced interaction.

## 2. Video Type — primary (§4) `[CONFIRMED]`
Two cards (`VideoType.highlights` / `.full`), gold-ring + check selected state.
- Highlights — "The best visual moments, beautifully cut."
- Full Story — "More of the journey, people, and atmosphere."
- **Default Highlights** for an unselected new Original (`seedVideoType`). **Owner decision (option B, 2026-10-26):
  the sheet ALWAYS opens on Highlights regardless of the Story's persisted `editorialMode`** — a prior Full
  Story generation does NOT pre-select Full Story on re-open; the user opts into Full Story per attempt. This
  intentionally overrides prior-choice prefill for TYPE only (duration/sound prefill unchanged); historical
  records are never rewritten. Historical `custom` and old `visual_first`/`storytelling` also open Highlights.
- Per-card approximate estimate via `cardEstimate(for:)` (type-aware Duration Intelligence point); shown only
  when a recommendation exists — **no fabricated estimate**. Selecting a type updates the estimate + summary
  with **no AI call**. A type is NOT a duration preset.

## 3. Removed controls (§5) `[CONFIRMED]`
Editing-Approach UI (`approachSection`/`approachRow`, Storytelling / Visual-first, speed/analysis copy) and the
old Story-Length picker (`lengthSection`, H/F/Custom) are DELETED from the sheet. Replaced by the primary
Video Type + an independent Recommended/Custom duration. `approach` state is retained and forced
`.storytelling` at init (the submitted `onCreate` arg is unchanged, so no data-model break); underlying
`EditingApproach` type + legacy decode paths are untouched (old Stories still read).

## 4. Creative Direction (§6) `[CONFIRMED]`
Natural-language field directly below Video Type ("Anything you want to include?" + the mountain-reveal
placeholder). All existing behavior preserved (free-form, Moment references, mention insertion, include/
exclude/order/opening/ending directives, precedence, interpretation lifecycle, Retry). Suggestion chips: 2–3
type-adapted phrases (Highlights: "Beautiful views first / Follow the music / Keep original audio"; Full
Story: "Show the whole journey / …"), each **appends** via `appendSuggestion` (never replaces typed text).
Moment-reference picker stays accessible as a compact chip. No new interpretation service.

## 5. Feeling / Style (§7) `[CONFIRMED]`
Initial four (Cinematic / Energetic / Emotional / Playful) with a "More feels" reveal for the rest
(Nostalgic, Dreamy, Romantic, Epic, Calm, Dramatic, Minimal, Upbeat — all preserved). Multi-select,
independent of Video Type, folded per-output only. Any H/F × style combination is allowed.

## 6. More Options (§8) `[CONFIRMED]`
Collapsed by default, labelled "Duration · Sound · Music". Expanded:
- **Duration** — Recommended (type-aware: Highlights→highlights range, Full Story→recommended range) or
  Custom (explicit for either type). Highlights/Full are NEVER duration choices. Custom seconds clamped to the
  feasible band. `p1dChosenSeconds` submits the type-aware point or the explicit value.
- **Sound** — Immersive / Balanced / Music-led preserved; default Balanced unless persisted intent says
  otherwise; video-type changes never reset it.
- **Music** — no dedicated picker exists on this sheet; existing MusicDirection→MusicPlan behavior is left
  untouched (§8: keep existing, don't redesign).

## 7. Dynamic summary + Create (§9) `[CONFIRMED]`
`directionSummary` = "Highlights · About 23 seconds · Balanced sound" (+ feel when chosen), live from state;
duration shown as approximate, omitted when unknown, never presented as guaranteed output length. Create CTA
"Create my video" in the pinned safe-area region. `onCreate` submits `p1dMode` (= Video Type wire) + the
independent duration; internal Story/GeneratedOutput naming + operations unchanged.

## 8. Operation behavior (§10) `[CONFIRMED]`
Type ⟂ operation ⟂ directives preserved (P1-C). The sheet's Video Type drives the Original attempt's type via
`story.editorialMode` → coordinator attempt-boundary resolution. Revise inherits the base output's type;
Explore supports all four H/F transitions and stays Explore; historical unspecified types never rewritten.
(No coordinator changes in P1-D — it reuses the P1-C contract.)

## 9. Editing v2 activation (§11) `[CONFIRMED]`
`EditorialTypeFlag.enabled` default flipped **OFF → ON** (P1-C accepted on dev). Resolution: env `=1/=0` →
UserDefaults override → **default ON**. So a normal detached / home-screen / TestFlight launch gets Editing
v2 with no Xcode attach. We deliberately do NOT auto-persist the scheme bool (avoids a stale dev toggle
contaminating a later beta build); `setOverride(_:Bool?)` now accepts nil to CLEAR an override. Client-only;
the independent v5.2 BACKEND rollback (`STORY_EDIT_PLAN_VERSION`) is unchanged. No new flag service, no infra.

## 10. Tests (§14)
- `CreateUXP1DTests` `[PARSE]`: Video Type seeding (Highlights default, custom≠Full Story, approach≠type),
  duration independence seed, Video Type wire values, flag default-ON + override precedence + clearable.
- `swiftc -parse` clean on `CustomizeYourStoryView.swift` + `EditorialType.swift`.
- `[PENDING]` device ⌘U: full matrix (type switch updates estimate, chip insertion, Moment reference, More
  Options expand/collapse, Revise inherit, Explore switch, no Revise↔Explore confusion, type survives
  submit/resume, historical decode, no duplicate output, normal-launch v2 on). SwiftData @Model can't run in
  the parse sandbox.

## 11. Compatibility (§12) `[CONFIRMED by design]`
No AU/EditPlan schema change. Historical custom length ≠ Full Story; old approach ≠ a type; unselected
Original → Highlights. Legacy records decoded read-only; pending ops + GeneratedOutput types + R7 untouched.

## 12. Known limitations / remaining `[PENDING]`
- Device ⌘U + merge + dev deploy + on-device UX pass (first-screen fit, VoiceOver, Dynamic Type, keyboard,
  missing-recommendation) — required before beta.
- Vestigial `length` / `showAdvanced` / `visualFirstAvailable` state remain (harmless; can be pruned).
- AU understanding sync/push durability — separate pre-beta blocker, tracked in
  `TODO-au-understanding-sync-durability.md`. NOT in P1-D scope.
- Gemini-primary AU fallback — separate pre-beta operational issue; routing untouched.

## 13. Cleanup done
- Reverted the temporary P1-C acceptance worker diagnostics (`edit_plan_v53_proof` / `_editorial_sample`) from
  the source AND redeployed the clean worker asset to the dev Lambda (§15). Master was never touched by them.
