import Foundation
import SwiftData

// StoryCreationReadiness — R-c Batch C. The authoritative "can this Story be created?" gate.
//
// A Story is PLANNABLE iff it has >=1 Moment with BOTH a resolvable local media file AND a completed
// MomentUnderstanding — EXACTLY what `EditPlanRequestBuilder.build(story:context:)` enforces when it builds its
// `included` set and throws `BuildError.noUsableMoments`. We reuse the SAME inputs (not a parallel rule):
//   - resolvable media: `MomentResolver.resolve(moments:)` (RenderSupport.swift)
//   - completed AU:      `MomentUnderstandingModel` rows whose momentId is in the Story's moment ids
// so a Moment counts as "ready" only when BOTH hold for the same Moment id.
//
// This drives the Home button enabled-state AND the honest explanatory copy. No developer diagnostics, no raw
// EditPlan, no model/backend names in any string here.

enum StoryCreationReadiness: Equatable {
    /// >=1 Moment is fully ready (file + completed AU). usableCount of totalMoments can be planned.
    case ready(usableCount: Int, totalMoments: Int)
    /// Some Moments are ready, others still lack a completed AU. ready>=1 so a plan IS possible using the ready ones.
    case pendingAnalysis(ready: Int, pending: Int)
    /// No Moments at all.
    case noMoments
    /// Moments exist, but NONE has a resolvable local file (so none can be planned, regardless of AU).
    case noUsableMedia(totalMoments: Int)

    /// Can the Create action be launched? GATE DECISION: `.ready` OR `.pendingAnalysis` (ready>=1) are plannable —
    /// the planner only consumes the ready Moments, so a mix is fine. `.noMoments` / `.noUsableMedia` are not.
    var isPlannable: Bool {
        switch self {
        case .ready: return true
        case .pendingAnalysis(let ready, _): return ready >= 1
        case .noMoments, .noUsableMedia: return false
        }
    }

    /// Honest one-line copy for the Create affordance (enabled or disabled). Never "coming later".
    var copy: String {
        switch self {
        case .ready(let usable, let total):
            return usable == total
                ? "Ready to create your Story."
                : "\(usable) of \(total) moments ready."
        case .pendingAnalysis(let ready, let pending):
            return "\(ready) ready · \(pending) still being analyzed."
        case .noMoments:
            return "Shoot or add a moment first."
        case .noUsableMedia:
            return "Your moments are still being analyzed."
        }
    }

    // MARK: - Pure classifier (unit-testable without SwiftData)

    /// Classify from the three counts the two inputs produce. `usable` = Moments with BOTH a resolvable file AND a
    /// completed AU; `withFile` = Moments with a resolvable file (regardless of AU); `total` = all Moments.
    /// pending (file present, AU not complete) = withFile - usable.
    static func classify(usable: Int, withFile: Int, total: Int) -> StoryCreationReadiness {
        if total == 0 { return .noMoments }
        if withFile == 0 { return .noUsableMedia(totalMoments: total) }
        let pending = max(0, withFile - usable)
        if usable == 0 {
            // Files exist but none analyzed yet -> not plannable; honest "being analyzed".
            return .noUsableMedia(totalMoments: total)
        }
        if pending > 0 { return .pendingAnalysis(ready: usable, pending: pending) }
        return .ready(usableCount: usable, totalMoments: total)
    }

    // MARK: - Context-driven evaluation (same inputs as EditPlanRequestBuilder)

    @MainActor
    static func evaluate(story: StoryModel, context: ModelContext) -> StoryCreationReadiness {
        let total = story.moments.count
        guard total > 0 else { return .noMoments }

        // (a) resolvable local media — the exact resolver EditPlanRequestBuilder uses.
        let media = MomentResolver.resolve(moments: story.moments)
        let fileIds = Set(media.map { $0.momentId })

        // (b) completed MomentUnderstanding for THIS Story's moments — same fetch EditPlanRequestBuilder does.
        let momentIds = Set(story.moments.map { $0.id })
        let allMUs = (try? context.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? []
        let auIds = Set(allMUs.map { $0.momentId }).intersection(momentIds)

        // A Moment is READY iff it has BOTH a file AND a completed AU (same Moment id).
        let usable = fileIds.intersection(auIds).count
        return classify(usable: usable, withFile: fileIds.count, total: total)
    }
}
