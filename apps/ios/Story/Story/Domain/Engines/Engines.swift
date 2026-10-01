import Foundation

// Engine PROTOCOLS + deterministic MOCK implementations.
//
// The UI and use-cases depend on these protocols, never on the concrete
// Mock classes (spec Part 5). A real AI implementation (AIStoryEngine,
// AIDirectorEngine, AIEditEngine) is swapped in later with no UI change.
//
// Milestone A: MOCK ONLY. No Bedrock, no network AI. Outputs are
// deterministic (derived from inputs) so the flow is easy to test.

// MARK: - Value types (Domain-facing, not persistence, not DTO)

struct CreativeIntent: Equatable {
    let rawText: String
    let theme: String
    let tone: String
    let summary: String
}

struct ShotSuggestion: Equatable {
    let guidance: String
    let suggestedSeconds: Double
}

struct GeneratedOutputPlan: Equatable {
    let title: String
    let durationSeconds: Double
    let momentIds: [UUID]
}

// MARK: - Protocols

protocol StoryEngineProtocol {
    func deriveCreativeIntent(from rawText: String) -> CreativeIntent
}

protocol DirectorEngineProtocol {
    /// Story-level guidance for the next Moment. Deterministic in the mock.
    func directNextMoment(storyTitle: String, existingMomentCount: Int) -> ShotSuggestion
}

protocol EditEngineProtocol {
    /// Plan a GeneratedOutput from the story's moments. Mock = metadata only.
    func planOutput(storyTitle: String, momentIds: [UUID]) -> GeneratedOutputPlan
}

// MARK: - Deterministic mocks

struct MockStoryEngine: StoryEngineProtocol {
    private let themes = ["reunion", "adventure", "everyday", "celebration", "journey"]
    private let tones = ["emotional", "playful", "reflective", "energetic"]

    func deriveCreativeIntent(from rawText: String) -> CreativeIntent {
        // Deterministic pick from a stable hash of the input.
        let h = abs(rawText.stableHash)
        let theme = themes[h % themes.count]
        let tone = tones[(h / 7) % tones.count]
        return CreativeIntent(
            rawText: rawText,
            theme: theme,
            tone: tone,
            summary: "A \(tone) \(theme) story derived from your direction."
        )
    }
}

struct MockDirectorEngine: DirectorEngineProtocol {
    private let prompts = [
        "Open on a wide establishing shot — let the place breathe.",
        "Get in close on a detail: hands, faces, texture.",
        "Capture motion — follow someone moving through the scene.",
        "Hold a quiet beat. Steady, a few seconds, no talking.",
        "Grab a reaction — the moment someone responds to something.",
    ]

    func directNextMoment(storyTitle: String, existingMomentCount: Int) -> ShotSuggestion {
        let guidance = prompts[existingMomentCount % prompts.count]
        return ShotSuggestion(guidance: guidance, suggestedSeconds: 6)
    }
}

struct MockEditEngine: EditEngineProtocol {
    func planOutput(storyTitle: String, momentIds: [UUID]) -> GeneratedOutputPlan {
        // Deterministic: duration scales with moment count (mock).
        let duration = max(8.0, Double(momentIds.count) * 4.0)
        return GeneratedOutputPlan(
            title: "\(storyTitle) — Cut \(momentIds.count)",
            durationSeconds: duration,
            momentIds: momentIds
        )
    }
}

// Stable, platform-independent hash so mock output is reproducible in tests.
private extension String {
    var stableHash: Int {
        var hash = 5381
        for byte in self.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return hash
    }
}
