import Foundation
import SwiftData

// Use-cases (Domain): the operations named in spec 03 §8. They compose
// engines + repository. UI calls these, not the repository or engines
// directly.

@MainActor
final class StoryUseCases {
    private let repository: StoryRepositoryProtocol
    private let storyEngine: StoryEngineProtocol
    private let directorEngine: DirectorEngineProtocol
    private let editEngine: EditEngineProtocol

    init(
        repository: StoryRepositoryProtocol,
        storyEngine: StoryEngineProtocol = MockStoryEngine(),
        directorEngine: DirectorEngineProtocol = MockDirectorEngine(),
        editEngine: EditEngineProtocol = MockEditEngine()
    ) {
        self.repository = repository
        self.storyEngine = storyEngine
        self.directorEngine = directorEngine
        self.editEngine = editEngine
    }

    /// Start a Story from the user's free-text creative direction.
    func startStory(title: String, direction: String) throws -> StoryModel {
        let intent = storyEngine.deriveCreativeIntent(from: direction)
        return try repository.createStory(title: title, intent: intent)
    }

    /// Story-level guidance for the next Moment (no scene understanding — mock).
    func directNextMoment(for story: StoryModel) -> ShotSuggestion {
        directorEngine.directNextMoment(
            storyTitle: story.title,
            existingMomentCount: story.moments.count
        )
    }

    /// Persist a shot Moment. `relativePath` comes from MediaStore after capture.
    func shootMoment(
        for story: StoryModel,
        relativePath: String,
        durationSeconds: Double
    ) throws -> MomentModel {
        let asset = AssetModel(
            relativePath: relativePath,
            durationSeconds: durationSeconds,
            source: .directed
        )
        return try repository.addMoment(
            to: story, source: .directed, asset: asset, caption: nil)
    }

    /// Create My Story — produces + persists a mock GeneratedOutput.
    /// Does NOT complete the Story (Create != Complete).
    func createStoryOutput(for story: StoryModel) throws -> GeneratedOutputModel {
        let plan = editEngine.planOutput(
            storyTitle: story.title,
            momentIds: story.moments.map(\.id)
        )
        return try repository.addGeneratedOutput(to: story, plan: plan)
    }
}
