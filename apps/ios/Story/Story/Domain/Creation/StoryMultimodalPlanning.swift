import Foundation

// StoryMultimodalPlanning — MVP feature flag + versioned creative brief for multimodal visual edit planning.
//
// OFF by default: the create flow uses the frozen text-only /v1/edit-plan path until the owner's physical
// device acceptance (Phases 4-5) passes. When enabled, the coordinator builds bounded Tier-1 contact sheets,
// runs the adaptive visual-budget preflight, and plans via /v1/edit-plan-mm with graceful text-only fallback.
//
// The creative brief string + version MUST stay in sync with the backend (apps/api MM_CREATIVE_BRIEF /
// MM_CREATIVE_BRIEF_VERSION). It is injected into the Edit Planner USER message only — never the frozen body.
enum StoryMultimodalPlanning {
    /// Master switch. Flip to true only after device acceptance. Can be overridden at launch for on-device
    /// testing via the STORY_MULTIMODAL_PLANNING=1 environment/launch argument.
    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["STORY_MULTIMODAL_PLANNING"] == "1" { return true }
        return _enabledDefault
    }
    private static let _enabledDefault = false

    static let creativeBriefVersion = "shortform_mvp/1"
    static let creativeBrief = """
    When user intent does not require chronology, prioritize visually engaging and meaningful footage. \
    Find a compelling opening, construct coherent visual progression, preserve important actions and \
    payoffs, and choose shot durations appropriate to the material. Do not force a conventional \
    travel-diary structure.
    """
}

/// Per-run multimodal planning diagnostics (NO image bytes/content) — surfaced for device-acceptance
/// verification so a device run can PROVE whether multimodal or text-only planning was used, which tier, and
/// why any fallback happened.
struct StoryPlanningDiagnostics {
    let usedMultimodal: Bool
    let sheetCount: Int
    let imageBytes: Int
    let momentsTextOnly: Int
    let selectedTier: String
    let appliedSteps: [String]
    let fallbackReason: String?
    let creativeBriefVersion: String?
}
