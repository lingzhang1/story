import Foundation

// EditorialType — Editorial Pipeline v2, P1-A.
//
// The TWO consumer video products. This is dimension A of the three independent dimensions (A editorial type,
// B operation, C creative instructions) — it must NEVER be conflated with operation (`another_version`/revise)
// or with the duration choice (AI-recommended vs user-exact). P1-A introduces the clean representation + the
// backward-compatible mapping from the legacy `StoryModel.editorialMode` string; it does NOT change any planner
// behavior (that is P1-B, behind EditPlan v5.3). All of this is additive and gated by `EditorialTypeFlag`.
//
// OWNERSHIP (owner decision 2026-10-25):
//   • A GeneratedOutput's editorial type is AUTHORITATIVE for that output — it records what that attempt
//     actually produced. Highlights + Full Story + Highlights outputs COEXIST on one Story with correct
//     lineage. (GeneratedOutputModel.editorialTypeRaw, additive.)
//   • A Story carries only a PREFERRED DEFAULT (StoryModel.editorialMode, the existing field) — a seed for the
//     next create, never an enforcer across outputs.
//   • The creation REQUEST carries the type chosen for THIS attempt. On success it is copied to the output.
// So there is exactly one authoritative value per layer and they never fight: Story=default-seed,
// request=this-attempt, output=what-happened.

enum EditorialType: String, Equatable, CaseIterable {
    case highlights
    case fullStory = "full_story"

    /// The default when the user has made NO explicit choice (owner decision 4: default to Highlights).
    static let defaultType: EditorialType = .highlights

    /// Human label for UI/diagnostics (UI itself is P1-C).
    var displayName: String { self == .highlights ? "Highlights" : "Full Story" }

    /// The value sent on the existing `EditPlanRequestDTO.editorial_mode` wire field, so NO new wire contract
    /// is needed in P1-A: highlights -> "highlights", full_story -> "full" (the exact strings the live v5.2
    /// prompt's `editorial_mode` clause already understands). This is the one place the new type meets the
    /// unchanged backend.
    var legacyEditorialModeWire: String { self == .highlights ? "highlights" : "full" }
}

/// How a legacy `StoryModel.editorialMode` string (or a persisted output) resolves to the new model. Kept as a
/// SEPARATE result type because the legacy `custom` value is NOT an editorial type — it is a DURATION fact —
/// so resolving it yields an UNSPECIFIED type (never silently Full Story) plus a user-exact duration signal.
struct ResolvedEditorial: Equatable {
    /// The editorial type, or nil when it genuinely cannot be reconstructed (legacy `custom` / missing). nil is
    /// handled by the explicit compatibility behavior below, NOT by guessing.
    let type: EditorialType?
    /// True when the legacy value was `custom` — i.e. the user fixed an EXACT duration. This is the duration
    /// choice (dimension E), surfaced here only so a caller never mistakes `custom` for an editorial type.
    let isUserExactDuration: Bool
    /// True when there was no reconstructable editorial type (legacy custom / missing / unknown) — the caller
    /// uses the compatibility default (EditorialType.defaultType) for a NEW attempt while leaving historical
    /// records labeled legacy/unspecified.
    var isUnspecified: Bool { type == nil }

    /// Map a legacy `editorialMode` string. Back-compat rules (owner):
    ///   "highlights" -> highlights
    ///   "full"       -> full_story
    ///   "custom"     -> UNSPECIFIED type + isUserExactDuration=true  (NEVER Full Story)
    ///   nil / "" / unknown -> UNSPECIFIED type (legacy/unspecified)
    static func fromLegacy(_ editorialMode: String?) -> ResolvedEditorial {
        switch (editorialMode ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "highlights": return ResolvedEditorial(type: .highlights, isUserExactDuration: false)
        case "full":       return ResolvedEditorial(type: .fullStory, isUserExactDuration: false)
        case "custom":     return ResolvedEditorial(type: nil, isUserExactDuration: true)
        default:           return ResolvedEditorial(type: nil, isUserExactDuration: false)
        }
    }

    /// The type to USE for a NEW generation attempt given a legacy value: the reconstructed type, else the
    /// compatibility default (Highlights). Historical records keep their unspecified label — this is only for a
    /// fresh attempt that inherits a legacy Story default.
    var typeForNewAttempt: EditorialType { type ?? EditorialType.defaultType }
}

/// Duration choice (dimension E) — kept explicitly separate from editorial type so `custom` is never an
/// editorial type. P1-A only REPRESENTS it; sizing behavior is unchanged (P1-B owns mode-aware sizing).
enum DurationChoice: String, Equatable {
    case aiRecommended = "ai_recommended"
    case userExact = "user_exact"

    /// Derived from the legacy editorial mode: `custom` => user_exact, else ai_recommended. Matches the
    /// existing `revision_context.duration_target_source` semantics already in the backend.
    static func fromLegacy(_ editorialMode: String?) -> DurationChoice {
        ResolvedEditorial.fromLegacy(editorialMode).isUserExactDuration ? .userExact : .aiRecommended
    }
}

/// P1-A feature flag. OFF by default: when off, nothing new influences planning and the pipeline behaves
/// EXACTLY as v5.2 today (the new fields are recorded for provenance but never change a request's
/// `editorial_mode`, which keeps flowing from the legacy `StoryModel.editorialMode` as before). When on, the
/// new EditorialType becomes the source the request derives `editorial_mode` from. P1-A shipped it OFF;
/// P1-D (post device/dev acceptance of EditPlan v5.3, PR #60 / master 306ab69) flips the DEFAULT ON so a
/// normal detached / home-screen / TestFlight launch gets Editing v2 WITHOUT any Xcode scheme attach.
///
/// Resolution order (highest precedence first) — overrides are preserved, the baseline default changed:
///   1. env `STORY_EDITORIAL_TYPE_V2` == "1"/"0"  — explicit per-launch override (attached dev run).
///   2. UserDefaults override (setOverride) — incident control / dev toggle, survives relaunch.
///   3. DEFAULT ON — normal launch with no override. Editing v2 is the product default.
///
/// WHY default-ON rather than persisting the scheme bool: the P1-C finding was that the scheme env is only
/// present on an attached ⌘R launch and was never persisted, so detached/TestFlight launches silently
/// reverted to OFF. We deliberately do NOT auto-persist the scheme value (that would let a stale dev toggle
/// contaminate a later beta build on the same device). Instead the baseline is ON, and env=0 / an explicit
/// UserDefaults override remain the ways to force v5.2-shaped client behavior for testing. This is a CLIENT
/// activation only; the independent v5.2 BACKEND rollback is `STORY_EDIT_PLAN_VERSION` (unchanged).
enum EditorialTypeFlag {
    static let key = "STORY_EDITORIAL_TYPE_V2"
    static var enabled: Bool {
        if ProcessInfo.processInfo.environment[key] == "1" { return true }
        if ProcessInfo.processInfo.environment[key] == "0" { return false }
        if UserDefaults.standard.object(forKey: key) != nil { return UserDefaults.standard.bool(forKey: key) }
        return true   // P1-D default ON — Editing v2 is the product default (v5.3 accepted on dev)
    }
    /// Explicit override (incident control / dev v5.2 testing). Pass nil to CLEAR it and fall back to the
    /// default-ON baseline, so a stale dev toggle never persists unintentionally.
    static func setOverride(_ on: Bool?) {
        if let on { UserDefaults.standard.set(on, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

// MARK: - Model read accessors (additive, non-mutating)

extension GeneratedOutputModel {
    /// The AUTHORITATIVE editorial type this output actually was, or nil for a legacy/unspecified output
    /// (historical, or a `custom`-duration one whose type was not recorded). Never guesses.
    var editorialType: EditorialType? {
        guard let raw = editorialTypeRaw else { return nil }
        return EditorialType(rawValue: raw)
    }
}

extension StoryModel {
    /// The Story's PREFERRED DEFAULT editorial type for the NEXT attempt — resolved from the legacy
    /// `editorialMode` seed, falling back to the compatibility default (Highlights) for a legacy `custom` /
    /// missing value. This is a SEED, never an enforcer: each GeneratedOutput still records its own type.
    var preferredEditorialType: EditorialType {
        ResolvedEditorial.fromLegacy(editorialMode).typeForNewAttempt
    }
    /// The Story's duration choice derived from the legacy seed (custom => user_exact).
    var durationChoice: DurationChoice { DurationChoice.fromLegacy(editorialMode) }
}

