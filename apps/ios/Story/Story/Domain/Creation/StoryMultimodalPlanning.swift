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
    /// Master switch. Flip to true only after device acceptance. For on-device testing it can be enabled in
    /// THREE ways, in priority order:
    ///   1. Env var STORY_MULTIMODAL_PLANNING=1 — ONLY present when Xcode's debugger launches the app
    ///      (a scheme env var is NOT injected for a standalone/home-screen/TestFlight launch — this is why a
    ///      run tapped from the home screen silently reverted to text-only).
    ///   2. UserDefaults bool "STORY_MULTIMODAL_PLANNING" — PERSISTS across launches. Set it once and every
    ///      subsequent standalone launch stays multimodal. The standard launch argument
    ///      `-STORY_MULTIMODAL_PLANNING YES` is read into UserDefaults automatically by the system, so an
    ///      Xcode scheme "Arguments Passed On Launch" entry survives a detach the way an env var does not.
    ///   3. compiled default (false).
    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["STORY_MULTIMODAL_PLANNING"] == "1" { return true }
        if UserDefaults.standard.object(forKey: flagKey) != nil {
            return UserDefaults.standard.bool(forKey: flagKey)
        }
        return _enabledDefault
    }
    /// UserDefaults / launch-argument key for the persisted override (survives non-attached launches).
    static let flagKey = "STORY_MULTIMODAL_PLANNING"
    /// Persist the override so a home-screen / TestFlight launch keeps multimodal on. Call from a debug toggle.
    static func setPersistentOverride(_ on: Bool) { UserDefaults.standard.set(on, forKey: flagKey) }
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
