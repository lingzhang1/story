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
    /// Master availability switch for the Visual-first editing approach (contact-sheet planning).
    ///
    /// DEFAULT ON (device-accepted on girl_with_dress + hiking: 36 / 32 sheets reached the planner, valid
    /// plans). No launch argument or scheme env var is required anymore — Visual-first is simply offered on the
    /// Customize screen, and the per-Story Editing Approach choice decides the path. Storytelling creates stay
    /// fully text-only (no sheets built, no images sent), so default-ON adds ZERO cost to a Storytelling run.
    ///
    /// A single OPTIONAL kill-switch remains for incident response — set env `STORY_MULTIMODAL_PLANNING=0` or
    /// UserDefaults bool `STORY_MULTIMODAL_PLANNING=false` to force it OFF without a rebuild (hides Visual-first
    /// and routes everything text-only). Absent any override, it is ON.
    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["STORY_MULTIMODAL_PLANNING"] == "0" { return false }
        if UserDefaults.standard.object(forKey: flagKey) != nil {
            return UserDefaults.standard.bool(forKey: flagKey)   // explicit override (true or false) wins
        }
        return _enabledDefault
    }
    /// UserDefaults / override key for the kill-switch (persists across launches).
    static let flagKey = "STORY_MULTIMODAL_PLANNING"
    /// Force the feature on/off at runtime without a rebuild (incident kill-switch / debug toggle).
    static func setPersistentOverride(_ on: Bool) { UserDefaults.standard.set(on, forKey: flagKey) }
    private static let _enabledDefault = true

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
    // Phase-4 fallback transparency: the user's REQUESTED editing approach vs what ACTUALLY ran. When
    // Visual-first falls back to text-only, requested stays .visualFirst while actual becomes .storytelling,
    // and usedMultimodal is false — so we never claim the footage was visually analyzed when it was not.
    var requestedApproach: EditingApproach = .storytelling
    var actualApproach: EditingApproach = .storytelling
}
