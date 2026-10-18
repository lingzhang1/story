import Foundation

// Revision scope classifier (latency Phase 2). Decides HOW MUCH planning a revise needs, from the ACTUAL
// scope of the requested change — NOT merely whether hard directives or a soft_direction are present (owner
// rule). The three paths trade cost for creative latitude:
//
//   A. deterministic  — pure structural edit of the exact base plan (reorder / prune / set opening-ending-
//                        order). ZERO planning-model calls. Only when hard directives are present AND there is
//                        no creative/soft ask at all. (The backend deterministic_revision fast path realizes
//                        this; this classifier just says "A is eligible".)
//   B. targeted       — a bounded AI change that preserves unaffected edits: a pacing tweak, a single-shot
//                        swap, a localized "make the opening punchier". ONE text-light call (base plan +
//                        directives + relevant evidence); send visual evidence ONLY when the ask is about what
//                        a shot LOOKS like. Critique off.
//   C. full re-edit   — a broad reinterpretation ("rebuild", "completely redo", "totally different vibe").
//                        Bounded multimodal planning. Hard directives (e.g. a fixed opening) are still enforced.
//
// This is deterministic text analysis, not a model call. When unsure it prefers the SAFER-for-quality choice
// (B over A, C over B) so we never under-plan a change the user cares about.
enum RevisionScope: Equatable {
    case deterministic          // A
    case targeted(needsImages: Bool)   // B — needsImages when the ask is visual ("most beautiful shot")
    case fullReedit             // C

    var sendsSheets: Bool {
        switch self {
        case .deterministic: return false
        case .targeted(let needsImages): return needsImages
        case .fullReedit: return true
        }
    }
}

enum RevisionScopeClassifier {

    // A BROAD reinterpretation — the user wants the whole edit redone, so cost is justified (Path C).
    private static let broadCues = [
        "rebuild", "completely redo", "completely rebuild", "redo the whole", "redo everything",
        "start over", "from scratch", "totally different", "completely different", "reimagine",
        "re-imagine", "re-edit the whole", "whole new", "entirely new", "different vibe",
        "different feel", "different style", "different mood", "change everything"
    ]

    // The ask is about how footage LOOKS, so Path B must carry visual evidence (needsImages) rather than a
    // purely text-light call.
    private static let visualCues = [
        "beautiful", "pretty", "stunning", "striking", "best shot", "best looking", "best-looking",
        "most beautiful", "prettiest", "scenic", "cinematic shot", "which looks", "that looks",
        "colorful", "vibrant", "nicest", "best frame", "best moment visually", "photogenic",
        "aesthetic", "gorgeous"
    ]

    /// Classify by ACTUAL change scope.
    /// - hasHardDirectives: resolved opening/ending/include/exclude/order present.
    /// - softDirection: the free-text creative/pacing ask (may be empty).
    /// - hasBasePlan: a base EditPlan is available to edit in place (required for A/B to preserve edits).
    static func classify(hasHardDirectives: Bool, softDirection: String, hasBasePlan: Bool) -> RevisionScope {
        let soft = softDirection.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasSoft = !soft.isEmpty

        // A broad "rebuild" cue ALWAYS means Path C — even combined with a hard directive the directive is just
        // enforced on top of a full re-edit ("Start with Moment 5 and completely rebuild" -> C, opening kept).
        if broadCues.contains(where: { soft.contains($0) }) { return .fullReedit }

        // No base plan to edit in place -> we cannot preserve unaffected edits; a creative ask is a full plan.
        if !hasBasePlan { return hasSoft ? .fullReedit : .targeted(needsImages: false) }

        // Hard directives + NO creative ask -> pure structural edit -> deterministic (Path A).
        if hasHardDirectives && !hasSoft { return .deterministic }

        // Otherwise it is a BOUNDED change over the base plan (Path B). Carry images only when the ask is
        // about visual appearance.
        let needsImages = visualCues.contains { soft.contains($0) }
        return .targeted(needsImages: needsImages)
    }
}
