import Foundation

// CaptureContext — the SINGLE distinction between the two capture entry points (Capture Anywhere milestone).
// Everything else (camera, scene scan, AI shot idea, recording, persistence) is SHARED; only the creative
// context fed to AI and the Story association after save differ.
//
//   • standalone : launched from Home. No Story, no StoryGuide, no StoryMomentLink. AI Ideas use ONLY the
//                  current scene evidence + optional user-typed direction — NEVER a previously-opened Story's
//                  CreativeIntent (no stale-context leak).
//   • story      : launched from inside a Story. AI Ideas use that Story's CreativeIntent/Guide/coverage;
//                  each saved Moment gets exactly one StoryMomentLink (capture order preserved).
enum CaptureContext {
    case standalone(direction: String?)   // optional free-text the user typed for a scene-only idea
    case story(StoryModel)

    /// The Story to associate a saved Moment with, or nil for standalone (library-only).
    var associatedStory: StoryModel? {
        if case .story(let s) = self { return s }
        return nil
    }

    /// The CreativeIntent the Director should use. For standalone this is a NEUTRAL, scene-only intent built
    /// from the user's optional direction — it carries NO Story identity, so no prior Story can leak in.
    func directorIntent() -> CreativeIntentContractDTO {
        switch self {
        case .story(let s):
            return CreativeIntentContractDTO(from: s)
        case .standalone(let direction):
            let text = (direction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return CreativeIntentContractDTO(
                id: UUID(),                       // ephemeral; never persisted, never a Story id
                sourceInputs: [],
                summary: text.isEmpty ? "A single standalone moment." : text,
                subject: nil, desiredFeeling: [], styleTags: [],
                pace: nil, emphasis: [], creativeConstraints: [],
                targetDurationSeconds: nil, targetFormat: nil,
                rawUserDescription: text.isEmpty ? nil : text,
                createdAt: Date())
        }
    }

    var targetDurationSeconds: Double? { associatedStory?.intentTargetDurationSeconds }
    var isStandalone: Bool { associatedStory == nil }
}
