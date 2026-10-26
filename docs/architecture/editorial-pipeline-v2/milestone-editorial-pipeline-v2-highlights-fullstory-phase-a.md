# Editorial Pipeline v2 — Highlights, Full Story, Revise & Explore
## Phase A — Architecture Audit, Design, and Evaluation Plan (READ-ONLY)

**Status:** Phase A design for owner review. No code/contract/prompt change. No AI inference. No deploy.
**Author:** audit synthesized from current `master` code + live backend evidence (dev), 2026-10-25.
**Evidence legend used throughout:**
`[CONFIRMED]` = verified in current code · `[RUNTIME]` = live backend/job data ·
`[HYPOTHESIS]` = plausible, not yet proven · `[DESIGN]` = proposed future work.

---

## 0. Executive summary

- The system already has **three clean dimensions in the data model but they are entangled in behavior**: operation (`original`/`revision`/`another_version`), length/editorial (`editorialMode = highlights|full|custom`), and editing approach (`storytelling|visual_first`). `[CONFIRMED]`
- **The single most important correctness finding is evidence loss, not planning quality.** Visual evidence (contact sheets) is lost **non-deterministically** before the planner ever reasons, and the *count the owner expected* vs *what was planned* diverge at **two compounding upstream stages** (eligibility gate, then frame extraction). `[CONFIRMED + RUNTIME]`
- **Highlights/Full Story should become the primary axis**, with Storytelling/Visual-first removed from ordinary UI and folded into *per-mode evidence strategy* (both modes may need pixels). `[DESIGN]`
- The `original create → mode=revise` workaround for directive adherence is real and should be replaced by a first-class **`editorial_intent` + `preservation_intent`** separation, done backward-compatibly. `[CONFIRMED → DESIGN]`
- Directive adherence ("Start with Moment 21" opened elsewhere) is a **selection gap, not a placement-repair gap**: `repair_directive_placement` cannot introduce a Moment the planner never selected. `[CONFIRMED mechanism; RUNTIME symptom]`

---

## 1. Verified AU → Sizing → EditPlan data flow `[CONFIRMED]`

Three stages, strict responsibility boundaries:

1. **Asset Understanding (AU)** — per Moment, async, on capture. On-device `MomentFrameExtractor` samples **24 evenly-spaced frames** (768px, JPEG ~0.6, timestamped) → model → `moment_understanding/1` text (`summary`, `subjects`, ordered `events[]` with timestamps, `temporal_order_note`, `useful_segments[]`, `story_context`). **Frames are then discarded** — no frame store persists.
   - File: `packages/asset_engine/__init__.py`, `prompts/asset_understanding/v1`, iOS `MomentFrameExtractor` (`au_frames/1`), contract `contracts/schemas/ai_contracts.py`.

2. **Sizing (Duration Intelligence)** — at create time (`packages/duration_planner/__init__.py`).
   - Layer 1 `compute_duration_evidence(moments)` — **deterministic, no model**: unions each Moment's `useful_segments` (no double-count), longest continuous span, conservative feasible band `[floor, ceil]` where `floor = min(total_useful, max(4, n*2))`, `ceil = total_useful`. A Moment with no AU falls back to its whole clip as one usable span.
   - Layer 2 `RealDurationPlannerEngine.recommend` — **one model call** (frozen `duration_recommendation/1`) → `{recommended_range, highlights_range, feasible_ceiling, rationale}`; a deterministic `_clamp_to_ceiling` enforces the ceiling. `highlights_range` → Highlights point, `recommended_range` → Full Story point; Custom = user-typed.

3. **Edit Plan** — convergence point (`packages/edit_planner/__init__.py`, prompt **v5.2** `prompts/edit_plan/5.2`). Selects Moments from AU **text**; `editorial_mode` modulates breadth; `images[]` (contact sheets) add the visual layer when visual-first; deterministic `validate_plan()` is the hard gate; a trim = `[source_start, source_end]` window inside a `useful_segment`.

**Live-version note `[CONFIRMED]`:** code default `_EDIT_PLAN_DEFAULT = "5"`, but CDK sets `STORY_EDIT_PLAN_VERSION=5.2` on App Runner **and** the worker. For async jobs the worker env governs → **live prompt is v5.2** (contains the EDITORIAL MODE clause). Anyone reading the code constant would wrongly conclude highlights/full isn't wired.

---

## 2. Verified Original / Revise / Explore orchestration `[CONFIRMED]`

Entry points on `StoryCreationCoordinator` (`apps/ios/Story/Story/Domain/Creation/StoryCreationCoordinator.swift`). Each mints a **fresh `operation_id`** and is **additive** (new `GeneratedOutputModel` appended; prior versions preserved).

| Op | iOS entry | `operation_type` | `mode` sent | base_plan? | Summaries? |
|---|---|---|---|---|---|
| Original | `createWithMusic` | `original` | `revise` *(if directives/soft)* else none | No | No |
| Create Another Version | `createAnotherVersion` | `another_version` | `explore` | No | Compact (≤4) |
| Revise | `reviseVersion` | `revision` | `revise` | **Yes (exact)** | No |

**`composeRevisionContext` (confirmed rules):**
- Original folds persisted Stage-2 Customize directives + soft text; if any exist, **mode=revise** so the planner treats pins as HARD requirements, not an explore nudge. *(This is the workaround §3 addresses.)*
- Create Another Version → `explore` context with compact parent + recent summaries (moment ids in order, opening/ending, shot-duration distribution). A **directed** CAV (`directedByCustomize=true`) folds its directives but **stays `mode=explore`** (owner decision 2026-10-22 removed the former explore→revise reroute, which conflated "honor my pins" with "stay similar").
- Revise → `mode=revise` + exact `base_plan` + resolved hard directives + soft text.
- Stamps `duration_target_source`: `custom`→`user_exact`; `highlights`/`full`→`ai_recommended`.

**`edit_planner.generate()` cost-ordered cascade (confirmed):**
0. Unsupported-op preflight (revise only) → `unsupported_operation` kept-version.
0a. Timing-only deterministic retime (revise + base_plan + NO directives + parseable clip length) → **0 model calls**, trim at speed 1.0, never falls through to a model replan.
0b. Structural deterministic revision (revise + base_plan + directives + NO soft) → **0 model calls**, reorder+prune.
Safe-fallback boundary: a targeted revise reaching the model is preservation-checked; only original/explore/`allow_broad_replan` may re-pick everything.
1–3. Model call + `validate_plan` + normalize.
3b. `repair_directive_placement` — **0 model calls**, reorder to satisfy opening/ending/adjacency/after, never adds content.
4–5. Strict model repair budget: **Create/Explore ≤1, Revise 0** (exception 1 for an unrenderable HARD defect); carries HARD errors only; `best_valid` retained.
6. Verdict: `invalid_after_repair` (iOS maps to `directivesUnsatisfiable` only if the request had hard directives, else `invalidPlanOutput`).
6a. Editorial-continuity gate (targeted revise): rejects `noop` and `wholesale` (continuity `< CONTINUITY_FLOOR = 0.5` and not authorized); otherwise continuity is an *objective*, not a rejection.
6b. Critique→revision (OFF by default; Explore gated by `critiqueExploreEnabled` default false).
7. Partial-success disclosure via `assess_creative_intent` → `completion = complete|partial` + `material_unmet` + `partial_disclosure`. **Partial still ships as success.**

**Explore diversity `[CONFIRMED]`:** `RevisionContextBuilder.diversity` / backend `diversity_diagnostics` compute moment-set Jaccard, opening/ending/order changed, shot-count delta, `near_identical` (Jaccard ≥ 0.999 + same opening+ending+order). Advisory only — human judgment decides worth; `near_identical` steers the UI away from presenting an identical "alternative".

**Confirmation of the prior audit's table — all three rows correct as written.**

---

## 3. Corrected Moment eligibility evidence (the owner's key question) `[CONFIRMED + RUNTIME]`

**Do NOT infer AU completion from `cloud_verified` or positive duration** — the eligibility gate reads a *local* `MomentUnderstandingModel`, which is separate state.

### The 10-stage funnel, with the exact exclusion source for each

Gate code: `EditPlanRequestBuilder.build()` in `apps/ios/Story/Story/Media/Render/RenderSupport.swift`.

| # | Stage | What it is | Exclusion source |
|---|---|---|---|
| 1 | **Linked** | `story.momentLinks` → `story.moments` (per-Story join rows, NOT the global library) | user "Add Moments" |
| 2 | **AU-ready** | a completed local `MomentUnderstandingModel` exists (`muByMoment[m.id] != nil`) | async AU not synced to device yet |
| 3 | **Known duration** | `plannerDuration(for:) > 0` (local probe OR cloud metadata) | no duration anywhere |
| 4 | **Renderable/restorable** | `isRenderableSource(m)` (bytes local OR cloud-restorable) | neither local nor R6-restorable |
| 5 | **Planner-eligible** | passed 2+3+4 → appended to `moments[]` | union of the above |
| 6 | **Serialized into request** | all of `moments[]` (there is **no cap, no top-N**; `maxSheets=120`) | — (no reduction here) |
| 7 | **Has contact sheet** | `MultimodalVisualBudget.build` produced a tiled sheet | **frame-extraction gap** |
| 8 | **Frame-extraction failures** | sheet build returned empty for a Moment | device `AVAssetImageGenerator` / eviction |
| 9 | **Selected in EditPlan** | planner model chose it into `plan.segments` | editorial choice within budget |
| 10 | **Rendered** | survived pre-render R6 restore + validate | genuinely unrestorable bytes |

**The critical correction to earlier contradictory claims:** the reduction the owner saw (e.g. "35 linked → fewer planned") happens at **stage 2 (AU-ready)**, *not* at a planner cap. And the visual-first weakness happens at **stage 7 (frame extraction)**, a *different* stage from eligibility. These are two independent, compounding losses.

### Live reconciliation — new girl-in-dress run `[RUNTIME]`

Job `1e1f2c1c…`, completed, `planning_mode: multimodal`, mode `revise` (opening + must_include), gpt-5.1, 3 model calls, critique applied:

| Set | Count | Note |
|---|---|---|
| Linked | **35** (`doc.moment_refs`, all `cloud_verified`, all have duration) | not 16 |
| Sent to planner (≥) | **≥25** | you cannot cut what wasn't sent; cut used 25 distinct |
| Got a sheet | **19** | 54% visual coverage |
| No sheet (planned blind) | **16** of 35 | the frame-extraction gap |
| In the cut | **25 distinct** | planner editorial selection |
| Cut WITHOUT a sheet | **9 of 25** | **36% of the final video composed blind** |

- **Zero AU/eligibility drops this run** (all 35 `cloud_verified` + duration). **The entire visual-first loss was stage-7 frame extraction (16 of 35 got no sheet).** `[RUNTIME]`
- **Method caveat `[CONFIRMED]`:** the server-side `understanding` table held only **15** AU records for the whole user while the plan referenced 25+ Moments → **AU is sent inline from the device's local store, not read from that server table at plan time.** So "which lacked AU" cannot be answered from the server; the sheet/cut/linked reconciliation settles it instead.
- Earlier runs: 16-moment story got **7 sheets** then **16 sheets** on rerun — same intermittent stage-7 gap.

### The 7/16 vs 16/16 root cause `[CONFIRMED code; HYPOTHESIS for remaining 19/35]`

- `visualBudgetInputs(from:)` historically did `guard fileExists(...) else { continue }` → **silently skipped any Moment whose local bytes were evicted (R5) or not-yet-restored**, planning it text-only. Nondeterministic because eviction state varies between runs.
- Commit **`19f9640`** adds a pre-budget **R6 restore** (`MomentResolver.resolveEnsuringLocal`) of included Moments before building the budget, plus a beacon counting unrestorable ones. **This is present in current `master`** (confirmed in the live coordinator source: the `wantMultimodal` block restores first, then builds `visualBudgetInputs(fromMedia:)`).
- **Open `[HYPOTHESIS]`:** the new run still produced 19/35 sheets *with the restore code present*. Two possibilities, not yet separated:
  1. the device build that produced this run **predates `19f9640`** (build-provenance unknown — no DEBUG build-id surfaced in the job), **or**
  2. the restore is insufficient and the extraction itself fails for some Moments (sync `AVAssetImageGenerator` returning empty on certain codecs/orientations — the prior `no_sheets` class). This matches the earlier hiking-footage `no_sheets` beacon finding.
- **This cannot be resolved from backend data alone** — it needs a device build carrying a visible build-id + a per-Moment extraction-failure beacon (see §4 diagnostics).

---

## 4. Visual extraction root-cause assessment + permanent diagnostics `[CONFIRMED + DESIGN]`

**Confirmed mechanism:** a Moment reaches the planner as **text whenever** (a) it is eligible but evicted/unrestorable at budget-build, or (b) frame extraction returns empty. Both degrade it to text-only silently (counted only in `momentsTextOnly`, which does not persist past job cleanup).

**Design — permanent, privacy-safe diagnostics that survive job cleanup `[DESIGN]`:**
1. **Completed-job diagnostic (backend, persisted on `Item.diagnostics.M`):** record `linked_count`, `sent_count`, `sheet_count`, `sheet_moment_ids` (hashed or index-only, never media), `moments_text_only`, and `extraction_failures` with a coarse reason bucket (`evicted` / `unrestorable` / `extract_empty` / `codec` / `orientation`). These already partly exist (`sheet_count`, `planning_mode`); add the counts + reason buckets. Survives the staging-body TTL because it lives on the persisted item, not the staged request.
2. **Device build-id beacon:** surface the short git sha in `StoryPlanningDiagnostics` and stamp it on the job so a run's build provenance is provable (matches the existing lesson: "committed in HEAD ≠ running app executed it").
3. **Per-Moment extraction-failure beacon** (`/health?music=editplan`-style, already prototyped per prior work `fd6cbde`): mm/sheets/budgetSheets/tier/fb + reason.

**Owner principle honored:** *no silent loss of intended visual evidence is acceptable for Highlights.* Diagnostics make every drop visible; the fix (reliable extraction) is P0.

**Likely permanent fix `[HYPOTHESIS]`:** replace the sync `AVAssetImageGenerator` path with **async `load(.tracks)` / `load(.duration)`** before extraction (the prior hiking finding). Device-build gated.

---

## 5. Two editorial-mode specifications `[DESIGN]`

**Principle (owner):** Highlights vs Full Story are **editorial objectives**, not duration presets or clip-length rules. **Both may require visual evidence.** Do NOT make Highlights≡contact-sheets or Full Story≡text-only.

### Highlights
- **Selection:** visually distinctive segments; action peaks; reveals; strong compositions; shot variety; avoid redundant compositions.
- **Source window:** tight trims to the visual payoff inside a `useful_segment`; music-aware beat placement.
- **Ordering:** strong opening + strong ending; purposeful pacing; not "every shot short".
- **Duration allocation:** shorter total; more cuts; but natural action preserved when it *is* the highlight.
- **Audio:** music-led acceptable; native audio kept where it carries the moment.
- **Evidence need:** **high** — pixels matter most for trim precision and composition.

### Full Story
- **Selection:** central events, narrative progression, interactions, dialogue, cultural/contextual shots.
- **Source window:** longer coherent spans; complete actions; sentence/utterance boundaries (future, §11/§14).
- **Ordering:** chronology where meaningful.
- **Duration allocation:** longer total where meaning supports it; never pad.
- **Audio:** preserve important original audio; dialogue-aware.
- **Evidence need:** **medium-high** — needs event/temporal/audio evidence more than per-frame beauty, but still benefits from pixels for scene grounding.

**Both modes share** one EditPlan contract + one deterministic renderer. The mode changes **prompt context, candidate-selection priorities, source-window strategy, duration allocation, audio treatment, and evaluation criteria** — not the output schema.

---

## 6. Editorial AU v2 design `[DESIGN]`

**Additive, versioned `moment_understanding/2`** — never a second pipeline, never a single beauty score; preserve identity + sync semantics and the existing `moment_understanding/1` render/decode path.

Proposed additive fields, with a **hard 3-way provenance split**:
- **Objective observation** (same policy as v1): `events[]` (timestamped), `useful_segments[]`, `subjects`, `temporal_order_note`, plus new `audio_events[]` (onset/offset of speech/ambient), `shot_boundaries[]` (cut points), `approx_visual_peaks[]` (timestamps).
- **Model editorial interpretation** (new, clearly labeled, confidence-scored): `visual_candidates[]` (short strong beats, for Highlights), `narrative_candidates[]` (coherent event spans, for Full Story), `candidate_roles[]` (opening / closing / b-roll / dialogue / payoff), `representative_frame_refs[]`.
- **Story-specific importance** (request-dependent, as today's `story_context`).

**Same Moment, two readings:** a clip yields a 2s visual beat for Highlights AND a 20s coherent event for Full Story — both from one v2 record, selected differently by mode.

### Temporal evidence gap — CONFIRMED and critical `[CONFIRMED]`
- `Build.auActionTimestamps` returns **`[:]` (empty)** today — AU `events[]` are **NOT** threaded into the plan request. The planner receives only `{id, duration_seconds, useful_segments, summary, evidence}`.
- `CreativeRefinementV2b` is the only consumer that *would* use event timestamps, and it is **OFF by default**.
- **Minimum change to pass event timing:** populate `auActionTimestamps` from the AU JSON `events[]` in `build()` (additive; no contract change — the field already exists on `Build`). This immediately helps trim precision and opening/closing candidate selection.
- **Overlap-only validation gap `[CONFIRMED]`:** `validate_plan` requires a source range to *overlap* a `useful_segment`, but a `useful_segment` is a coarse region — a window can overlap it yet miss the actual action peak. Threading `events[]` + `approx_visual_peaks[]` lets selection target the peak, not just the region. **No new creative validation/repair loop** — this is evidence enrichment, not a gate.

---

## 7. Visual evidence & frame reuse `[DESIGN]`

**Baseline to beat:** rich editorial AU + **complete** contact sheets (every eligible Moment sheeted) — the owner's A/B evidence shows full-sheets changes output substantially vs text-only, on girl-in-dress and TMB+Iceland.

Options to evaluate (owner's A/B/C/D), with the guardrail *do not assume a sparse first pass finds every short visual event*:
- **A** existing AU + complete sheets (reliable baseline).
- **B** rich editorial AU, no planner images (cheapest; likely regresses trim precision).
- **C** rich editorial AU + **reusable representative frames** (reuse AU-extracted frames via a versioned sidecar instead of re-extracting — removes the stage-7 re-extraction gap entirely).
- **D** rich editorial AU + targeted high-detail frames only where a candidate is ambiguous.

Sampling strategies: 24-frame uniform (today) vs adaptive temporal vs shot-boundary-aware. **Persist a safe versioned visual sidecar** (regenerable, content/version-keyed) so Highlights never loses evidence to eviction and Explore/Revise reuse it with zero re-extraction. Native-video inference = deferred experiment.

**Experiments must measure:** visual quality, trim precision, cost, latency — against baseline A. Preserve whole-video coverage.

---

## 8. Mode-aware Duration Intelligence `[CONFIRMED gaps → DESIGN]`

Current (`compute_duration_evidence` + `RealDurationPlannerEngine`) already separates **(1) technical feasibility** (deterministic band), **(2) editorial recommendation** (model), **(3) user choice** (Custom). Keep that boundary.

**Confirmed flags:**
- `duration_planner` still hardcodes `MODEL_ID = "us.anthropic.claude-opus-4-6-v1"` — reconcile with the direct-provider migration (confirm it's routed via the gateway; the constant is misleading/diagnostic-only if routed, but should be fixed).

**Design — mode-aware recommendation:**
- **Highlights:** recommend from visually-compelling + diverse material and pacing (shorter, denser).
- **Full Story:** recommend from meaningful events, progression, complete actions, conversations, context (longer where meaning supports it).
- The existing prompt already returns both `highlights_range` and `recommended_range`; the **mode-aware step is choosing which band + feeding mode-specific evidence** (e.g. count of distinct narrative candidates for Full Story vs count of strong visual beats for Highlights). **No extra model call** — reuse the single recommendation call with mode in the payload.

**Operation-aware sizing (new requirement):**
- **Original:** compute mode-appropriate recommendation.
- **Explore:** reuse material evidence; may recommend a *different* duration for a requested type; **do not repeat AU**.
- **Revise:** start from the **selected base video's** duration; never silently replace with a stale Story-level recommendation; preserve exact user duration; keep zero-model retime. Compatible with existing `duration_target_source` (`user_exact` vs `ai_recommended`).

---

## 9. Revise fast-path preservation plan `[CONFIRMED → DESIGN]`

**Confirmed paths to preserve:** timing-only retime (0 model), structural revision (0 model), targeted model revise (base plan + preservation + continuity gate). All must survive the editorial-v2 work.

**Design — reuse rich AU + cached evidence for targeted Revise without recomputing unrelated Moments. Invalidation rules:**
| Change | Reuse | Re-compute |
|---|---|---|
| Timing-only | base plan + evidence | nothing (0 model) |
| Ordering-only | base plan + evidence | nothing (0 model) |
| New source Moment requested | base plan + evidence | **only the missing Moment's** AU/sheet |
| Major editorial-type change | — | broader replan (treat as near-Explore) |
| Unchanged source media | AU + visual evidence | nothing |

A **content/version-keyed evidence cache** (see §16) is the enabler: a mechanical change never re-infers.

---

## 10. Explore diversity & type-switching plan `[CONFIRMED → DESIGN]`

Explore reuses Moment understanding, cached visual/audio evidence, Story context, **compact** parent/recent summaries (not full historical EditPlans). It must NOT reuse the previous output's clip selection/order. Confirmed diversity diagnostics (§2) stay advisory — **no mandatory diversity quota**, no extra repair loop.

**Type-switching through Explore `[DESIGN]`:** Original = Highlights → New = Full Story:
- Same underlying Moments; reuse editorial evidence where possible.
- Re-run **selection + narrative structure** under the new mode's priorities (a type change *should* materially change selection — the continuity gate must **not** apply to a type-switch Explore).
- Preserve the original output; produce a materially different interpretation.
- Lineage: fresh `operation_id`, `operation_type = another_version`, `parentVersionId` = selected version; the new output records its own `editorialMode`.

**Open design question:** how to keep meaningful diversity when both versions are the *same* type (today only `near_identical` flags it; no re-roll). Candidate: feed the parent summary as an explicit "avoid this emphasis" and vary opening/source-range emphasis — without a hard quota.

---

## 11. Directive adherence assessment ("Start with Moment 21") `[CONFIRMED mechanism; RUNTIME symptom]`

Live run: `opening` directive requested Moment 21 (eligible, **sheeted**), final opened elsewhere; `rev_diag.opening_honored:false`, `completion:partial`, `creative_satisfaction:0.667`.

**Determination:** this is a **selection gap, not a placement gap.**
- `repair_directive_placement` is explicitly **reorder-only** — it returns `None` if the opening Moment is **absent from the plan's segments** (confirmed: `if opening is not None and opening not in present_set: return None`). *A placement-only repair cannot introduce a missing source Moment.*
- So either (a) the planner **did not select** Moment 21 into any segment (placement then can't help — the miss is recorded as an *objective*, shipped partial), or (b) it selected but mis-placed it (placement *should* have fixed it; if it didn't, that's a bug in the reorder path).
- The partial disclosure path (§2 step 7) treats an unmet `opening` as an objective, not a hard error → ships a valid video with a note. This is by design for over-constrained requests, but **masks a satisfiable directive that was simply not selected**.

**Bounded improvement proposals (no unrestricted retries):**
1. **Pre-selection pin:** when `opening`/`ending`/`must_include` names an eligible Moment, inject it as a *guaranteed candidate* so the planner cannot drop it from selection (the deterministic structural path already does this for revise-with-base; extend the principle to the directed first-create selection).
2. **One targeted re-ask (within the existing Create/Explore ≤1 budget):** if a *satisfiable* opening/ending directive is unmet after placement, spend the one allowed repair to force inclusion — not a new unbounded loop.
3. **Diagnostic:** record whether the named Moment was *selected* vs *mis-placed* so the two causes never blur again.

Preserve: unsupported-op preflight, deterministic fast paths, best-valid retention, technical validation, partial disclosure, limited repair budgets. **Do not redesign Creative Freedom v2.**

---

## 12. Preservation & operation-specific constraints `[CONFIRMED → DESIGN]`

Confirmed: exact base plan, `noop`/`wholesale` detection, `CONTINUITY_FLOOR=0.5`, `allow_broad_replan`, targeted-vs-broad. **Design — separate editing STYLE (mode) from operation CONTINUITY:**
- **Targeted Revise:** keep the current video type; preserve unaffected portions; existing continuity protections.
- **Broad re-edit:** permit substantial change when explicitly requested (`allow_broad_replan`); preserve the previous output; clearly distinguished from a small revise.
- **Explore:** no targeted-revision preservation constraint; major selection/order/**type** differences allowed.

**Do not conflate mode-specific style with operation-specific continuity** — e.g. a Full-Story Revise still preserves; a Highlights→Full-Story Explore does not.

---

## 13. Audio & dialogue understanding gaps `[CONFIRMED gaps → DESIGN]`

**Confirmed present:** native audio policy per segment (`keep|duck|mute`), MusicPlan, sound preferences (`immersive|balanced|music_led` → native-audio bias), renderer mixing. **Confirmed ABSENT:** timestamped transcription, speaker turns, audio events, dialogue-aware selection, sentence-boundary cutting, multilingual speech.

**Design (Full Story, future — not Phase A):** add `audio_events[]` + `dialogue_intervals[]` to AU v2; dialogue-aware source windows that cut on utterance boundaries; preserve conversation meaning. **Egypt use case:** market haggling, cooking, village life — the video must communicate *meaning*, not just attractive footage. Transcription is **not** implemented in Phase A.

---

## 14. Latency & caching opportunities `[CONFIRMED stages → DESIGN]`

Pipeline stages (per op): cloud restore → frame extract → encode → AU infer → duration infer → sheet gen → upload → planner infer → critique/revise → render.

**Duplicated work identified:**
- Frames are extracted for AU, **discarded**, then **re-extracted** for contact sheets → the stage-7 gap *and* wasted work. **Reusable frame sidecar (§7 option C) removes both.**
- Explore/Revise re-extract + (sometimes) re-AU Moments that are unchanged.

**Zero-model paths already present:** timing-only retime, structural revision, placement repair. **Preserve and extend.**

**Design:** **content/version-keyed evidence cache** (keyed by moment-id + media fingerprint + AU/sheet version) with safe invalidation (§9 rules). Never confuse a **source-analysis cache** with an **output-specific EditPlan** (§15). No new model calls without a measured quality benefit.

---

## 15. Recovery, idempotency, persistence `[CONFIRMED → DESIGN]`

**Confirmed intact:** fresh `operation_id` per op; `PendingOperationModel`; `planning → plan_ready → rendering`; stored EditPlan JSON; resume-without-reinference; lineage; `markPendingFailed` marks abandoned (no infinite resume loop); exactly-once finalize.

**Design requirements for editorial-v2 + caching:**
- Force-quit must not restart completed inference (preserved — plan_ready renders from saved JSON).
- A new Explore gets a new `operation_id` (preserved).
- **AU v2 + evidence cache is a SOURCE cache, versioned separately from the output EditPlan** — a cache miss re-analyzes source, never re-renders an output.
- Existing revisions remain interpretable after contract evolution → `moment_understanding/2` is additive; `editorial_intent` migration (below) defaults existing rows.
- Previous outputs never silently replaced (preserved).

---

## 16. Backward-compatible UX / contract migration `[DESIGN]`

### Contract separation (replaces the `original→mode=revise` workaround)
Introduce, **additively**:
- `editorial_intent` = `highlights | full_story` (replaces the overloaded `editorial_mode = highlights|full|custom`; `custom` becomes "explicit user duration" = a *duration* fact, not an editorial type).
- `preservation_intent` = `none | targeted | broad` (derived from operation; today implicit in `mode`+`base_plan`).
- Keep `operation_type` as-is.
- `mode` (revise/explore) stays for one release as the transport the planner reads; the device sets it *from* `preservation_intent` so the `original→mode=revise` hack is no longer needed for adherence — adherence comes from first-class directive pinning (§11).

### UX simplification (the screenshot concept)
- Primary choice: **Highlights** / **Full Story** (with a sensible AI recommendation).
- **Remove Storytelling/Visual-first from ordinary UI** — fold into per-mode evidence strategy (§5/§7). Keep optional: NL direction, feeling presets, custom duration, sound preference, music.
- **Revise** inherits the selected video's type; keep changes focused.
- **Create Another Version** offers *keep current type* or *switch type* (type-switch = materially different, not a minor revise).

### Migration of existing state
| Field | Migration |
|---|---|
| `editorialMode = highlights` | → `editorial_intent = highlights` |
| `editorialMode = full` | → `editorial_intent = full_story` |
| `editorialMode = custom` | → `editorial_intent = full_story` (default) + `duration_target_source = user_exact` |
| `editorialMode = nil` | infer at create (back-compat path) |
| `requestedApproach/actualApproach` | retained for diagnostics; no longer a user choice |
| existing `GeneratedOutput` | unchanged; renders on `moment_understanding/1` path |
| saved customization drafts | map `editorialMode` as above |
| revise/explore context | unchanged wire; device derives `preservation_intent` |

**No contract change in Phase A.** This is the smallest backward-compatible migration for P1+.

---

## 17. Evaluation plan & regression fixtures `[DESIGN]`

**Fixtures (identical source across runs):** girl-in-dress, TMB+Iceland hiking, Egypt travel+conversations, wedding, ordinary weekend.

**Highlights metrics:** visual appeal, peak selection, pacing, shot variety, cut precision, music sync, share-desire.
**Full Story metrics:** narrative coherence, meaningful-event inclusion, dialogue preservation, audio continuity, emotional progression, context, keep/share-desire.
**Revise metrics:** change fulfilled, unrelated preserved, no unnecessary replan, latency, model calls.
**Explore metrics:** meaningfully different, creative quality, no accidental continuity constraint, directive adherence, AU reuse.

**Record per run:** quality (rubric), latency (per stage §14), tokens, provider usage, cost, **evidence completeness** (sheet_count / eligible / cut — the §3 funnel). Controlled A/B against baseline A (complete sheets).

---

## 18. Milestone roadmap `[DESIGN]`

**P0 — Evidence completeness & baseline reliability** *(correctness; highest priority)*
- Components: `RenderSupport.build()`, `MultimodalVisualBudget`, `visualBudgetInputs`, backend `worker.py` diagnostics, device build-id beacon.
- Deliver: accurate eligibility/submission counts persisted on the job; **reliable frame extraction** (async load fix); no silent evidence loss; reproducible fixtures.
- Contract: none (additive diagnostics).
- Risk: device-only extraction fix needs owner Xcode build (SwiftData gate). Rollback: diagnostics-only is inert; extraction fix behind a flag.
- Gate: owner confirms sheet_count == eligible on a fresh first-run create.

**P1 — Two editorial types**
- Components: `edit_planner` prompt mode clauses, `composeRevisionContext`, Customize UI, `editorial_intent` additive field.
- Deliver: Highlights vs Full Story objectives; operation-aware compatibility; UX simplification; planner/renderer preserved.
- Contract: additive `editorial_intent` (+ migration §16). Risk: mode clause regressions → device acceptance + regression tests. Rollback: `editorial_intent` falls back to `editorialMode`.

**P2 — Editorial AU v2**
- Components: `asset_engine`, `moment_understanding/2`, `RenderSupport` (`auActionTimestamps` population), reusable frame sidecar.
- Deliver: segment-level visual/narrative evidence; timestamp propagation; reusable visual evidence.
- Contract: additive `moment_understanding/2`; v1 render path preserved. Risk: sync/identity — additive only. Rollback: planner ignores v2 fields.

**P3 — Audio-aware Full Story**
- Components: AU audio events + dialogue intervals; planner dialogue-aware windows.
- Deliver: conversation preservation (Egypt case). Contract: additive. Deferred past Phase A implementation.

**P4 — Latency & quality optimization**
- Evidence cache (content/version-keyed), sampling improvements, contact-sheet reduction experiments, critique-call reduction, mode-aware sizing.
- Risk: cache invalidation correctness → §9 rules + tests. Rollback: cache is a pure accelerator; miss = recompute.

Each milestone ships with: automated regression tests, device acceptance tests, quality eval, rollback, **owner approval gate**. Beta functionality protected throughout (additive contracts, flags off by default).

---

## 19. Unresolved owner decisions

1. **Build provenance of the 19/35 run** — was it pre-`19f9640`, or is restore insufficient? Needs a device build with a visible build-id. *(Blocks P0 root-cause closure.)*
2. **`editorial_mode` → `editorial_intent` rename** vs keeping `custom` as a third value. Recommended: demote `custom` to a duration fact.
3. **Type-switch Explore continuity** — confirm the continuity gate is bypassed for a Highlights↔Full-Story Explore.
4. **Reusable frame sidecar storage** — where persisted, retention, privacy (regenerable vs stored).
5. **Opening/ending pin strategy** — pre-selection guarantee vs one targeted repair (§11); owner's tolerance for the one extra model call.
6. **Full Story audio scope** — how far into transcription/dialogue (P3) for the first release.
7. **`duration_planner` Anthropic constant** — confirm routed off Anthropic; fix the misleading `MODEL_ID`.

---

## 20. What is confirmed vs proposed

- **Confirmed code behavior:** §1, §2, §3 funnel, §4 mechanism, §6 `auActionTimestamps=[:]` + overlap-only validation, §8 hardcoded MODEL_ID, §9 fast paths, §11 placement-is-reorder-only.
- **Runtime evidence:** §3 live run (35/≥25/19/16/9), earlier 7/16→16/16, server AU table = 15 (inline-AU proof).
- **Hypothesis:** §4 remaining 19/35 cause (build provenance vs extraction), §11 selection-vs-placement for Moment 21.
- **Proposed design:** §5–§18.

**Success:** one coherent architecture that creates excellent Highlights *and* Full Story, revises efficiently (zero-model where mechanical), and explores genuinely different versions — without losing source evidence, repeating expensive work, or regressing beta.
