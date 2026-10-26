# AU v2 → EditPlan v5.3 — Planner-Consumption Handoff

Status: HANDOFF SPEC (v5.3 NOT implemented). Defines how EditPlan v5.3 should consume Rich Editorial
AU v2 evidence. Written from the P1-B live-validation + quality-correction findings.

## Core principle: all model-estimated timing is ADVISORY

The forensic validation (IMG_9091.MOV) proved that AU's candidate **intervals** and **peaks** are
model estimates, not technically verified boundaries:
- AU returned a visual candidate `9.5–14.5s`, peak `12.5s`.
- The actual clear face reveal was ~`16.62s` — **outside the candidate interval** — and that frame
  *was* supplied to the model.

Therefore v5.3 MUST treat the following as advisory, never as hard constraints:
- `editorial.visual_candidates[].{start_time, end_time}` — suggested regions, not clip boundaries.
- `editorial.visual_candidates[].peak_time` — an approximate hint; often null (honest uncertainty).
- `editorial.narrative_candidates[].{start_time, end_time}` — suggested context spans.
- `editorial.visual_candidates[].evidence` (`frames@…ms`) — **UNTRUSTED model free text.** Not
  source provenance. v5.3 MUST NOT use it as a technical source-window and MUST NOT let it override
  `sampled_frame_ms`. A small deterministic consumer-side filter SHOULD drop `evidence` from the
  planner input entirely.

The planner MAY adjust, expand, or select OUTSIDE a candidate interval when other evidence supports it.

## What IS authoritative
- **Actual source-media technical bounds** (duration, decodable ranges, speed 0.5–2.0×) — the only hard
  clip constraint. Final clips MUST stay within playable media boundaries.
- `observed.useful_segments` — the existing asset-grounded source windows (duration/EditPlan evidence).
- `observed.events[]` — ordered factual events with their own timestamps.
- `sampled_frame_ms` (NEW, server-minted) — the exact source-relative ms of the frames the server
  accepted. Means ONLY which frames existed as input; NOT that the source was verified, that the model
  attended each frame, or that any candidate/peak is correct. Useful to (a) know the temporal resolution
  of the evidence (e.g. ~1.4s spacing at 24 frames over 32s) and (b) snap/bound a soft peak to a real
  sampled instant rather than trusting an interpolated number.
- Complete visual **contact sheets** — remain available to planning (not reduced by AU v2).

## Highlights consumption
Planner receives: visual candidates (+ visual_value explanations, approx peaks), `sampled_frame_ms`,
useful_segments, events, contact sheets, source duration/bounds. Candidates indicate *promising footage*;
the planner chooses the actual cut, free to widen/shift around a candidate using the contact sheet and
useful_segments, within source bounds. ~2–5s is a common Highlights length, never a hard rule.

## Full Story consumption
Planner receives: narrative candidates (+ what_happens/why_matters, approx intervals), event ordering,
useful_segments, contact sheets, source metadata. Preserve longer meaningful actions and contextual
sequences. `spoken_meaning` is always "unknown" — never invent dialogue meaning (audio understanding is
a separate later milestone).

## Original / Revise / Explore (unchanged semantics)
- Original: fresh interpretation.
- Revise: inherits base output's editorial type; preserves existing revision guarantees.
- Explore: may use a different editorial type and reinterpret source material.
Editorial type stays independent of operation type.

## Technical rules (binding on v5.3)
- Candidate intervals are NOT validation constraints; peaks are NOT frame-perfect; `evidence` is NOT
  source authority.
- Missing editorial candidates MUST NOT cause a creative-only terminal failure.
- Preserve the never-block-playable-video policy: a renderable plan always ships.
- EditPlan v5.2 behavior is unchanged by this handoff.

## Smallest proposed v5.3 request-contract change (NOT implemented here)
Today's EditPlan request (`edit_plan/5.2`) carries per Moment only `{id, duration_seconds,
useful_segments, summary}` (+ evidence field). The editorial candidates and `sampled_frame_ms` are
NOT currently forwarded to the active planner — do not claim they are. v5.3 will need an **additive,
versioned** request contract (`edit_plan/5.3`) that adds, per Moment, an optional:
```
editorial: {
  visual_candidates:  [{start_time, end_time, peak_time?, visual_value, role?, confidence?}],
  narrative_candidates:[{start_time, end_time, what_happens, why_matters, role?, confidence?}]
},
sampled_frame_ms: [int]
```
— with `evidence` deliberately EXCLUDED (untrusted). This is a frozen-contract change and MUST be
proposed + approved at the start of the v5.3 milestone, not here. v5.2 keeps its exact current shape.

## Known limitations carried into v5.3
- Peak timing on human turn/reveal actions ran ~1–2s early (class B, model reasoning); `au_prompt/3`
  adds apex guidance but this needs live re-verification (prompt wording does not guarantee reasoning).
- Gemini-primary latency caused OpenAI fallback on most 24-image calls; diagnostics now observable,
  cause to be confirmed from live error evidence (not yet proven).
- Duration-aware sampling deferred until a real between-frames coverage miss is demonstrated.
