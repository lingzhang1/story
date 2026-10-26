import Foundation

// DurationFeasibility — R-c duration-feasibility preflight (deterministic, no model, no AVFoundation).
//
// WHY: the Edit Planner correctly rejects a plan whose total output duration is >20% off the Story target
// (the frozen ±20% tolerance). When the Story simply does not have enough usable material to reach the
// target's lower bound, calling Opus is wasted — it will plan, the deterministic validator (and the server)
// will refuse, and the user sees a dead-end "Try again". This preflight estimates, on-device and for free,
// the MAXIMUM honest duration the Story's material can support, so we can:
//   (a) skip the planner call entirely when the current target is infeasible, and
//   (b) offer the user a concrete, evidence-based shorter target to accept.
//
// CONSERVATIVE BY DESIGN. We never inflate what is achievable:
//   - 1.0x speed ONLY. We do NOT count slowing clips down to pad the timeline (the task forbids auto-slowing
//     merely to reach a target; slow-mo is a creative choice the planner may still make, not a feasibility crutch).
//   - De-duplicated per Moment: overlapping useful_segments of the SAME Moment are merged, so footage is never
//     counted twice. Different Moments are summed (they are distinct material).
//   - Transition overlaps only REDUCE a real timeline (a dissolve overlaps its neighbours), so ignoring them
//     keeps the estimate an upper-ish bound; we then apply a small safety margin before SUGGESTING a target.
//   - Clamped to the clip length: a useful_segment can't exceed its source duration.
//
// This is an ESTIMATE, not a guaranteed executable plan. The planner + the deterministic validator remain
// authoritative — the preflight only decides "don't bother asking for the impossible, offer this instead".

enum DurationFeasibility {

    /// One Moment's usable material: its source duration and its useful spans (as [start,end] pairs).
    struct MomentMaterial: Equatable {
        let durationSeconds: Double
        /// Useful spans in SOURCE time. Empty => the whole clip is usable (matches the request builder's
        /// whole-clip fallback when AU produced no explicit segments).
        let usefulSegments: [(start: Double, end: Double)]

        init(durationSeconds: Double, usefulSegments: [(start: Double, end: Double)] = []) {
            self.durationSeconds = durationSeconds
            self.usefulSegments = usefulSegments
        }

        static func == (l: MomentMaterial, r: MomentMaterial) -> Bool {
            l.durationSeconds == r.durationSeconds &&
            l.usefulSegments.count == r.usefulSegments.count &&
            zip(l.usefulSegments, r.usefulSegments).allSatisfy { $0.start == $1.start && $0.end == $1.end }
        }

        /// Merged, clamped usable seconds for THIS Moment at 1.0x — overlapping spans counted once.
        var usableSeconds: Double {
            let clip = max(0, durationSeconds)
            // No explicit spans => whole clip is usable.
            let raw = usefulSegments.isEmpty ? [(0.0, clip)] : usefulSegments
            // Clamp each span to [0, clip] and drop empties.
            let clamped = raw
                .map { (max(0, min($0.start, clip)), max(0, min($0.end, clip))) }
                .filter { $0.1 > $0.0 }
                .sorted { $0.0 < $1.0 }
            // Merge overlaps so duplicated footage isn't double-counted.
            var merged: [(Double, Double)] = []
            for s in clamped {
                if var last = merged.last, s.0 <= last.1 {
                    last.1 = max(last.1, s.1)
                    merged[merged.count - 1] = last
                } else {
                    merged.append(s)
                }
            }
            return merged.reduce(0) { $0 + ($1.1 - $1.0) }
        }
    }

    /// The frozen planner tolerance: a plan's total output may be within ±20% of target. A target is reachable
    /// only if the material can fill at least the LOWER bound.
    static let tolerance = 0.20

    /// Safety margin applied when SUGGESTING a shorter target, so the suggestion itself is comfortably
    /// plannable (not sitting exactly on the achievable edge where a dissolve/validator rounding could tip it).
    static let suggestionSafety = 0.90

    /// The smallest positive usable material (seconds) we treat as "there is something to render". This is NOT
    /// an editorial floor and NOT a fixed Story-length minimum — it is an epsilon above zero that separates
    /// "genuinely no usable footage" (a technical no-material failure) from "a very short but real clip".
    /// Any usable material above it is FEASIBLE; the planner/renderer decide the actual length.
    static let zeroMaterialEpsilonSeconds = 0.05

    /// Verdict of the preflight.
    enum Verdict: Equatable {
        /// The current target is reachable with the available material (>= lower tolerance bound).
        case feasible(achievableSeconds: Double)
        /// Not enough material for the target, but a shorter Story IS possible. `suggestedSeconds` is a
        /// conservative, evidence-based target the user can accept. (No longer returned — retained for
        /// back-compat of the enum + any caller that pattern-matches it.)
        case shorterPossible(achievableSeconds: Double, suggestedSeconds: Double, requestedSeconds: Double)
        /// Genuinely NO usable footage — a technical no-material failure (nothing to render). This is the only
        /// non-feasible verdict now; length is never a block.
        case insufficient(achievableSeconds: Double, requestedSeconds: Double)
    }

    /// Pure classifier. `materials` are the INCLUDED Moments only (resolvable file + completed AU), matching
    /// EditPlanRequestBuilder's `included` set. `targetSeconds` is the resolved Story target.
    ///
    /// OWNER POLICY (2026-10-25, final): length is NEVER a blocking constraint, and there is NO arbitrary
    /// Story-length floor (the former 5s editorial minimum is removed; we do NOT substitute a fixed 0.8s or any
    /// other fixed threshold). The ONLY non-feasible verdict is GENUINELY NO USABLE FOOTAGE — a technical
    /// no-material failure, since a Story with zero renderable material cannot produce any video. Any positive
    /// usable material is FEASIBLE: the planner produces the best cut it can (even a very short one) and the
    /// renderer decides what it can export. The user's requested duration is preserved as an OBJECTIVE, never a
    /// gate. Genuinely-unusable source (no resolvable/renderable material) is caught upstream in build() as an
    /// eligibility drop; here we guard the "every eligible Moment yielded ~0 usable seconds" tail.
    static func evaluate(materials: [MomentMaterial], targetSeconds: Double) -> Verdict {
        let achievable = materials.reduce(0) { $0 + $1.usableSeconds }
        // Any real usable material -> FEASIBLE, regardless of how far below the requested target it is.
        if achievable > zeroMaterialEpsilonSeconds {
            return .feasible(achievableSeconds: round1(achievable))
        }
        // Zero usable footage -> a genuine technical no-material failure (nothing to render).
        return .insufficient(achievableSeconds: round1(achievable), requestedSeconds: targetSeconds)
    }

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
