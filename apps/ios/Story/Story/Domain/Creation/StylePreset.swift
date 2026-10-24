import Foundation

// StylePreset — OPTIONAL creative-direction presets for Create My Story (Phase B / owner decisions 2B–2E).
//
// A preset is INSPIRATION, never a deterministic editing rule and never a new taxonomy. It reuses the
// EXISTING style/feeling + music semantics and is applied PER OUTPUT ATTEMPT only:
//   • its style phrase is appended to the per-attempt `soft_direction` (revision_context) — NOT written to
//     the Story's durable CreativeIntent (desired_feeling/style_tags/pace). So TMB can be Cinematic for one
//     output and Energetic for the next without changing the Story's creative identity (decision 2E).
//   • its mood tags seed the per-attempt music preference (ParsedMusicIntent.preference), which flows into the
//     EXISTING MusicDirection -> MusicPlan -> Epidemic pipeline (no second music selector, decision 4/B).
//
// PRECEDENCE (decision 2D): an explicit natural-language instruction wins. A preset only FILLS what the user
// did not already say — so its phrase is appended to (never replaces) the user's soft text, and its moods are
// used only when the user's own text carried no music preference. Length and sound stay authoritative on their
// own controls; a preset never touches them.
//
// Pure + deterministic: no model call, no persistence of its own. The caller decides where the outputs go.
enum StylePreset: String, CaseIterable, Identifiable, Equatable {
    case cinematic
    case energetic
    case emotional
    case playful
    case calm
    case nostalgic
    case dramatic
    case dreamy
    case upbeat
    case romantic
    case epic
    case minimal

    var id: String { rawValue }

    /// User-facing chip label.
    var label: String {
        switch self {
        case .cinematic: return "Cinematic"
        case .energetic: return "Energetic"
        case .emotional: return "Emotional"
        case .playful:   return "Playful"
        case .calm:      return "Calm"
        case .nostalgic: return "Nostalgic"
        case .dramatic:  return "Dramatic"
        case .dreamy:    return "Dreamy"
        case .upbeat:    return "Upbeat"
        case .romantic:  return "Romantic"
        case .epic:      return "Epic"
        case .minimal:   return "Minimal"
        }
    }

    /// The short creative-direction phrase appended to the per-attempt soft_direction. Plain, non-technical,
    /// reads as a feel — never a deterministic cut rule.
    var directionPhrase: String {
        switch self {
        case .cinematic: return "Give it a cinematic feel"
        case .energetic: return "Make it energetic"
        case .emotional: return "Make it emotional and heartfelt"
        case .playful:   return "Keep it playful and fun"
        case .calm:      return "Keep it calm and unhurried"
        case .nostalgic: return "Give it a warm, nostalgic feel"
        case .dramatic:  return "Make it dramatic and bold"
        case .dreamy:    return "Give it a dreamy, atmospheric feel"
        case .upbeat:    return "Keep it upbeat and lively"
        case .romantic:  return "Make it romantic and tender"
        case .epic:      return "Make it epic and sweeping"
        case .minimal:   return "Keep it simple and understated"
        }
    }

    /// Mood tags used to SEED music (per-attempt), aligned to the deterministic MusicDirection keyword
    /// vocabulary (packages/music_direction _MOOD_KEYWORDS) so the existing pipeline recognizes them.
    var musicMoodTags: [String] {
        switch self {
        case .cinematic: return ["cinematic"]
        case .energetic: return ["energetic"]
        case .emotional: return ["emotional"]
        case .playful:   return ["playful"]
        case .calm:      return ["calm"]
        case .nostalgic: return ["emotional"]      // maps to the "emotional" mood keyword (nostalgic is in it)
        case .dramatic:  return ["cinematic"]      // closest recognized mood
        case .dreamy:    return ["atmospheric"]
        case .upbeat:    return ["energetic"]
        case .romantic:  return ["emotional"]
        case .epic:      return ["cinematic"]
        case .minimal:   return ["calm"]
        }
    }

    /// Pace mapped ONLY when unambiguous (decision 2C): Energetic/Upbeat->fast, Calm/Minimal->slow; the rest
    /// force no pace. Returned as the PaceDTO raw string, or nil for "do not force a pace".
    var forcedPace: String? {
        switch self {
        case .energetic, .upbeat: return "fast"
        case .calm, .minimal:     return "slow"
        case .cinematic, .emotional, .playful, .nostalgic, .dramatic, .dreamy, .romantic, .epic: return nil
        }
    }
}

/// The per-attempt creative contribution of a selected preset set, composed deterministically. The caller
/// folds `directionSuffix` into the soft_direction and `musicMoodTags` into the music preference; neither
/// touches durable Story CreativeIntent.
struct StylePresetContribution: Equatable {
    /// Phrase(s) to APPEND to the user's soft direction (empty when no preset selected). Multiple presets are
    /// joined; the user's own text, when present, always precedes this (precedence 2D is the caller's job).
    let directionSuffix: String
    /// Mood tags to seed music, de-duplicated + order-stable (empty when no preset or when the user already
    /// expressed a music preference — the caller passes `userHasMusicPreference` to suppress these).
    let musicMoodTags: [String]
    /// A single unambiguous pace ("fast"/"slow") when exactly one is implied and they do not conflict; nil
    /// otherwise (ambiguous, none, or conflicting presets -> do not force a pace).
    let forcedPace: String?

    static let none = StylePresetContribution(directionSuffix: "", musicMoodTags: [], forcedPace: nil)

    /// Compose the contribution from the selected presets (order-stable by StylePreset.allCases).
    /// `userHasMusicPreference` suppresses the music seed so an explicit user music ask always wins (2D).
    static func from(_ selected: Set<StylePreset>, userHasMusicPreference: Bool) -> StylePresetContribution {
        guard !selected.isEmpty else { return .none }
        let ordered = StylePreset.allCases.filter { selected.contains($0) }
        let phrases = ordered.map { $0.directionPhrase }
        var moods: [String] = []
        for p in ordered { for m in p.musicMoodTags where !moods.contains(m) { moods.append(m) } }
        // Pace only when exactly one unambiguous pace is implied AND no conflict (e.g. Energetic + Calm -> nil).
        let paces = Set(ordered.compactMap { $0.forcedPace })
        let pace = paces.count == 1 ? paces.first : nil
        return StylePresetContribution(
            directionSuffix: phrases.joined(separator: ". "),
            musicMoodTags: userHasMusicPreference ? [] : moods,
            forcedPace: pace)
    }
}
