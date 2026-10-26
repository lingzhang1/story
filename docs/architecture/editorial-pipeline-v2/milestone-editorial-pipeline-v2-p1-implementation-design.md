# Editorial Pipeline v2 — P1 Implementation-Ready Design

**Status:** P1 design for owner review. READ-ONLY planning — no code/prompt/schema/infra/deploy change.
**Builds on:** Phase A audit + P0 (merged `5a5e5e2`/`50cbacd`, dev-accepted). Phase A is NOT repeated here.
**Evidence legend:** `[CODE]` verified in current master · `[DESIGN]` proposed · `[OPEN]` owner decision.

---

## 1. Confirmed product semantics

Two primary video **products** replace the two independent legacy choices (Story Length {highlights/full/custom}
× Editing Approach {storytelling/visual_first}):

- **Highlights** — concise, visually compelling (Reels/TikTok-grade): strongest visual moments, best
  sub-ranges, brisk purposeful pacing, shot variety/contrast, music-aware cuts, strong open/close, preserve
  meaningful actions. Favors shorter clips but **no fixed clip-length rule**.
- **Full Story** — authentic narrative (vlog/documentary): events, interactions, conversations, context,
  temporal+emotional progression, B-roll support, natural audio, actions/dialogue allowed to unfold, no padding.
  **Not a longer Highlights montage.**

**Both may need visual evidence.** Do NOT equate Highlights≡multimodal / Full Story≡text-only.
**Custom duration** survives as an optional numeric override, NOT a third editorial type.

## 2. Three independent dimensions — and the current overloaded field `[CODE]`

| Dimension | Values | Current representation (master) | Problem |
|---|---|---|---|
| **A. Editorial type** | highlights / full_story | `StoryModel.editorialMode` (`highlights`/`full`/`custom`) → `EditPlanRequestDTO.editorial_mode` → `EditPlanInputs.editorial_mode` → planner `_edit_mode_directive()` | `custom` conflates a *duration* fact with an editorial *type* |
| **B. Operation** | original / revision / another_version | `pendingOperationType` + `revision_context.mode` (`revise`/`explore`) | `mode=revise` is OVERLOADED: an original-create-with-directives sends `mode=revise` just to force directive adherence |
| **C. Creative instructions** | NL + opening/ending/include/exclude/order + duration + sound + music | `revision_context.{directives,soft_direction}`, `sound_preference`, `music_*` | rides inside the same `revision_context` object as the operation `mode` |

**Root entanglement:** operation (B) and editorial type (A) and preservation intent all collapse onto
`revision_context.mode`. P1 must separate them. (`composeRevisionContext` already documents the 2026-10-22
decision that a *directed Explore stays explore* — P1 must not regress that.)

## 3. Existing → new field mapping `[DESIGN]`

**Additive, no wire break.** Introduce two typed concepts; keep `editorial_mode` as the transport the planner
reads for one release.

| New concept | Source of truth | Wire | Planner reads |
|---|---|---|---|
| `editorial_type` = `highlights` \| `full_story` | `StoryModel.editorialType` (new, additive) | reuse existing `editorial_mode` string on the DTO (`highlights`→highlights, `full_story`→`full`) | `_edit_mode_directive()` (unchanged mapping) |
| `duration_choice` = `ai_recommended` \| `user_exact(seconds)` | `story.editorialMode=="custom"` → `user_exact`; else `ai_recommended` | existing `revision_context.duration_target_source` (already present) | `_duration_target_source()` |
| `operation` = original / revision / another_version | `pendingOperationType` (unchanged) | existing `operation_type` form field + `revision_context.mode` | existing |
| `preservation_intent` = none / targeted / broad | derived from operation (original→none, revise→targeted unless `allow_broad_replan`, explore→none) | existing (device sets `mode`/`base_plan` from it) | existing continuity logic |

**Key point:** `custom` is decomposed — it becomes `editorial_type` (whatever the user picked) **+**
`duration_choice=user_exact`. It is never silently mapped to Full Story. Legacy `editorialMode` decoding stays
for back-compat: a persisted `custom` keeps rendering; on the next create it resolves type from the user's
explicit pick and exact duration from the stored number.

## 4. Exact code components requiring change `[CODE→DESIGN]`

Minimal set, grouped by milestone. **One common EditPlan contract; no second engine.**

**iOS (`apps/ios/Story`):**
- `Data/Persistence/Models.swift` — add `StoryModel.editorialType: String?` (additive; nil → infer from
  legacy `editorialMode`). Keep `editorialMode` for back-compat decode.
- `Features/Create/CustomizeYourStoryView.swift` — replace the Length×Approach controls with the two-product
  selector (Highlights / Full Story) + advanced (NL, feeling preset, custom duration, sound, music). Remove
  the Storytelling/Visual-first consumer toggle; `EditingApproach` becomes an internal evidence decision.
- `Domain/Creation/StoryCreationCoordinator.swift` — `wantMultimodal` stops being a user choice; it is derived
  per editorial_type (see §6). `composeRevisionContext` keeps its directed-Explore semantics.
- `Domain/Creation/EditingApproach.swift` — demote to an internal "evidence strategy" enum (not UI-bound).

**Backend (`packages/edit_planner`, `apps/api`):**
- `prompts/edit_plan/5.2/system.md` — the `editorial_mode` clause already distinguishes highlights vs full.
  P1 ENRICHES that one clause (see §5) — still **one versioned prompt**, no new system body.
- `packages/duration_planner/__init__.py` — mode-aware recommendation inputs (see §7).
- No schema change to `edit_plan/2` or `moment_understanding/1`.

## 5. Prompt-change proposal (one clause, versioned) `[DESIGN]`

Current v5.2 `editorial_mode` clause is breadth-only (highlights=concise/fewer, full=broader). P1 makes each
type a richer **editorial brief** — same contract, same invariants, no clip quota, no fixed duration:

- **highlights:** "Select the most visually striking, distinct moments and the strongest sub-range within each.
  Favor shot variety and visual contrast; build a compelling opening and a strong closing shot; coordinate cuts
  with music structure where present; keep clips concise but never cut a meaningful action mid-payoff; drop
  visually weak or redundant material."
- **full_story:** "Tell what happened: select moments that carry events, interactions, conversations and
  context, ordered as a coherent temporal/emotional progression. Let important actions and dialogue unfold at
  their natural length; use scenery/B-roll to support the narrative; preserve natural audio where it carries
  meaning. Avoid padding and near-duplicate repetition. Breadth and length are earned by meaning, not quota."

Versioned as **`edit_plan/5.3`** (additive candidate dir; default stays 5.2 until the device quality gate — same
freeze discipline the 5.2 header documents). **Reconcile the stale header:** v5.2 is ALREADY the live default
(`STORY_EDIT_PLAN_VERSION=5.2`) and P0 removed the ±20% bands the prompt still describes as "hard tolerance" —
P1's 5.3 copy should update that wording to match the never-block policy (duration is an aim, not a gate).

## 6. Mode-specific editing behavior (implementable spec) `[DESIGN]`

Both types run the SAME pipeline (select-from-AU-text → optional contact sheets → validate → render). The type
sets priorities, not a separate engine.

| Lever | Highlights | Full Story |
|---|---|---|
| Candidate Moment selection | highest visual-distinctiveness + variety; drop weak/redundant | event/interaction/context coverage; chronology-bearing moments |
| Source-interval selection | tightest sub-range on the visual payoff (uses AU `useful_segments`; §10 event-timestamps experiment tightens this) | longer coherent spans; complete actions/utterances |
| Opening / ending | strongest visual hook / strong closing shot | scene-setting open / resolving close |
| Ordering | visual rhythm + music; chronology optional | chronological/emotional progression preferred |
| Clip-duration allocation | shorter, more cuts; significance-weighted | longer holds where meaning supports; significance-weighted |
| Shot variety | maximize distinct compositions | variety in service of narrative, not for its own sake |
| Music-aware timing | cut on beats/downbeats; payoff near highlight | lighter alignment; never override dialogue/native audio |
| Native audio | keep ambience that adds energy; music-led OK | **keep by default**; preserve conversation/natural sound |
| Evidence need (visual) | high (pixels drive trim+composition) | medium-high (scene grounding; still benefits) |

**Evidence strategy (replaces the UI toggle):** default **both** types to visual-first (contact sheets) using
the P0-reliable extraction (35/35 sheets on `f0dd7eca`). A kill-switch (`STORY_MULTIMODAL_PLANNING`) stays for
incident response. This is an internal decision, not a consumer choice.

## 7. Mode-aware Duration Intelligence `[CODE→DESIGN]`

Keep the three separate layers `[CODE]`: (1) deterministic technical feasibility
(`compute_duration_evidence`), (2) AI recommendation (`RealDurationPlannerEngine`, returns both
`highlights_range` and `recommended_range`), (3) user choice.

- **Highlights duration:** choose `highlights_range`; feed the recommender a mode hint + visual-variety signal
  (count of distinct strong beats).
- **Full Story duration:** choose `recommended_range`; feed event/interaction/complete-action counts.
- **No universal default.** Custom stays an override.
- **No extra model call** — reuse the single recommendation call, pass editorial_type in its payload.

**Operation-aware:**
- Original → mode-appropriate recommendation.
- Revise → **derive from the selected base video's duration** unless the user changes it (never a stale
  Story-level number). Keep zero-model retime.
- Explore → reuse source evidence; MAY recommend a new duration when the editorial type changes. **Never
  re-run AU** for a type switch.

**Flag:** `duration_planner` still hardcodes `MODEL_ID = us.anthropic…` `[CODE]` — reconcile with direct-provider
routing (confirm it routes via the gateway; the constant is cosmetic if so). Fold into P1-B.

## 8. Operation × type behavior matrix `[DESIGN]`

| Operation | Editorial type source | Preservation | Duration | Evidence | Terminal only if |
|---|---|---|---|---|---|
| Original | user pick | none | mode-recommended or custom | per type | no renderable plan / no material |
| Revise (targeted) | **inherit base's type** | preserve unaffected; exact base_plan; 0-model fast paths | base video's duration unless changed | reuse; analyze only new moments | technically unrenderable |
| Revise (broad, `allow_broad_replan`) | inherit unless changed | substantial change allowed; prior preserved | recompute | reuse | technically unrenderable |
| Explore (same type) | keep current | none (fresh alt) | may recommend new | reuse source understanding | technically unrenderable |
| **Explore (type switch H↔FS)** | **new type** | none → **broader re-plan** (not a targeted revise) | **new mode-recommended** | reuse AU; reconsider selection | technically unrenderable |

Never-block (§4 of brief) holds across all rows; noop/wholesale/retime-infeasible ship with honest disclosure
(P0 `ea7bee4`). **Directed Explore stays Explore** — do not re-introduce the removed explore→revise reroute.

## 9. UX wireflow `[DESIGN]` (no UI built)

Create My Story → **two cards: Highlights | Full Story** (the screenshot concept) + one-line "what you'll get".
Advanced (collapsed): NL "anything to emphasize", feeling/style preset, custom duration, sound, music.
Type × style are orthogonal → "Cinematic Highlights", "Emotional Full Story" all expressible (style = preset/NL,
type = the card). Default: a sensible AI type recommendation can be offered but the two-tap path is the baseline.
- **Revise:** inherits the version's type; shows "Editing Full Story / Highlights"; focused change.
- **Create Another Version:** offers keep-type or switch-type (switch = materially different, triggers §8 broad
  Explore). Compatible with the previously approved Customize redesign.

## 10. AU event-timestamps experiment (independent, minimal) `[CODE→DESIGN]`

`[CODE]` `Build.auActionTimestamps` returns `[:]` — AU `events[]` are not threaded into the plan request; only
`useful_segments` + `summary` reach the planner; the overlap-only validation lets a window miss the action peak.
- **Data flow:** `RenderSupport.build()` → populate `auActionTimestamps` from the AU JSON `events[]` (field
  already exists on `Build`); pass through the request to the planner USER message as an advisory
  "action timestamps per Moment" line.
- **Reuse:** existing `moment_understanding/1.events[]`; **no AU schema change**.
- **Change surface:** `RenderSupport.build()` (populate), request builder (carry), planner `_build_user`
  (render advisory line). ~1 small change each.
- **Tests:** unit — events populate + serialize; planner selects a tighter window when a peak is named.
- **Quality measure:** trim-accuracy A/B (does the cut land on the action vs a loose region) on girl-in-dress +
  hiking.
- **Rollback:** feature-flag the advisory line; empty = exactly today.
- **Run it ALONE**, not bundled with P1-B.

## 11. Quality experiments `[DESIGN]`

Fixtures: girl-in-dress, TMB/Iceland hiking, Egypt travel+conversations. Each → 4 rendered MP4s: baseline
Highlights, baseline Full Story, P1 Highlights, P1 Full Story. Hold constant: Moments, AU, sheet completeness,
provider, music, NL, duration. Measure Highlights (visual appeal / best-moment / trim accuracy / variety /
pacing / music / preference) and Full Story (coherence / event inclusion / interaction preservation / action
completeness / native-audio / emotional progression / preference). Record per run: selected count, source
intervals, clip-duration distribution, final duration, model calls, latency, tokens, cost, visual-evidence
completeness. **Human-evaluate the rendered MP4s, not planner JSON.** Explicitly flag quality ceilings that need
**AU v2 or audio understanding** (e.g. Egypt conversation selection) — out of P1 scope.

## 12. Regression protection `[DESIGN]`

Preserve all P0 + prior tests: original-with-directives, targeted revise, deterministic retime + structural
revision, directed Explore + diversity diagnostics, explicit opening/ending, playable-but-imperfect +
truthful disclosure, GeneratedOutput lineage, operation idempotency, cloud-only eligibility, full visual
coverage, music/sound. **New type logic must not re-introduce the explore→revise routing regression.** Add:
type inheritance on revise, type-switch triggers broad Explore, custom→(type+user_exact) decomposition,
back-compat decode of legacy `editorialMode`.

## 13. Outstanding P0 follow-ups (tracked separately, NOT P1 code)

1. **evidence_accounting / build_provenance absent** `[OPEN]` — plausibly an outdated device build, **not
   proven** (no recorded device build-id on `f0dd7eca`). **Verification procedure (no backend change):** rebuild
   device on master `50cbacd`, add the `GitCommitSHA` Run Script, run one visual-first create, confirm the job
   carries both objects and `evidence_accounting.reconciles == true` and `build_provenance.commit_sha` == the
   built SHA. Only if they are STILL absent on a confirmed-new build is a serialization/persistence defect
   proven — then investigate iOS multipart emission.
2. **iOS audio regression** — candidate fix `1d573a8` was merged in PR #54 (`50cbacd`) at the owner's explicit
   request; **still device-unverified** (audible output needs a device). Track until the owner confirms sound in
   the in-app preview after rebuild. Not bundled into P1.
3. **specs/ gitignored** `[OPEN]` — the Phase A + P0 + this P1 doc live under the parent repo's gitignored
   `specs/`, so they are on disk but uncommitted. **Recommendation:** either (a) a separate docs repo/submodule,
   or (b) an un-ignored `docs/implementation-plan/` path in the main repo. Needs owner approval to un-ignore or
   relocate; until then these docs persist only on disk in the worktree.

## 14. Staged roadmap `[DESIGN]`

- **P1-A — Editorial semantics + back-compat** (no behavior change yet): add `editorial_type`, decompose
  `custom`, back-compat decode, operation×type matrix wiring, migration+rollback tests. Flag:
  `STORY_EDITORIAL_TYPE_V2` (off). Rollback: flag off = legacy `editorialMode`.
- **P1-B — Mode-aware planning + sizing**: enrich the one prompt clause (→ `edit_plan/5.3` candidate,
  default stays 5.2), mode-aware duration inputs, derive evidence strategy per type, reconcile
  `duration_planner` MODEL_ID. Flag: `STORY_EDIT_PLAN_VERSION=5.3` gated by device quality gate.
- **P1-C — Consumer UX**: two-product Create screen; demote EditingApproach to internal. Flag-gated UI.
- **P1-D — Quality eval + acceptance**: paired rendered-video A/B; latency/cost; owner gate before beta.
- **Independent side-experiment**: §10 AU event timestamps (own flag, own A/B, not bundled).

Dependencies: P1-B depends on P1-A's type field; P1-C depends on P1-A; P1-D gates all. Each milestone: its own
PR, regression tests, feature flag (default off), rollback = flag off. **No AU v2 / transcription / caching
until separately approved.**

## 15. Risks & latency `[DESIGN]`

- Prompt enrichment could regress one type while improving the other → the P1-D paired A/B is the gate; 5.3 is
  flag-gated behind the device quality gate exactly like 5.2.
- Making both types visual-first by default raises per-create cost/latency (contact sheets + larger payload) —
  measure in P1-D; the kill-switch covers incidents.
- Type-switch Explore triggering broad re-plan is more expensive than a targeted revise — correct by design,
  but surface it in UX so the user knows it is a fresh interpretation.
- Back-compat: the biggest risk is mis-decoding legacy `editorialMode` — covered by migration tests in P1-A.

## 16. Open owner decisions

1. Approve `edit_plan/5.3` as the P1-B prompt-enrichment vehicle (additive dir, default stays 5.2 until gate)?
2. Default both types to visual-first internally (cost/latency ↑) vs Highlights-only visual-first?
3. Durable specs location (un-ignore `docs/` vs separate repo) — needed before these docs are version-controlled.
4. `duration_planner` MODEL_ID reconciliation — confirm it routes via the direct-provider gateway.
5. Offer an AI "recommended type" on the Create screen, or always default to one (which)?
6. Run the §10 event-timestamps experiment before or in parallel with P1-B?
