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
    /// Milestone A path: local mock intent (offline / tests).
    func startStory(title: String, direction: String) throws -> StoryModel {
        let intent = storyEngine.deriveCreativeIntent(from: direction)
        return try repository.createStory(title: title, intent: intent)
    }

    /// Milestone C1 path: resolve CreativeIntent via the REAL backend
    /// (POST /v1/creative-intent -> Model Gateway -> model), then create the
    /// Story. Throws on backend failure so the UI can show a recoverable retry
    /// — we never silently fabricate an intent (approved design §9).
    func startStoryWithRealIntent(
        title: String,
        direction: String,
        service: CreativeIntentService = CreativeIntentService()
    ) async throws -> StoryModel {
        let dto = try await service.resolve(rawText: direction)
        let intent = Self.mapIntent(dto, rawText: direction)
        let story = try repository.createStory(title: title, intent: intent)
        // Carry the FULL resolved intelligence onto the Story so Story Home can
        // show what the model actually understood (not just theme/tone).
        story.intentSubject = dto.subject
        story.intentDesiredFeeling = dto.desiredFeeling
        story.intentStyleTags = dto.styleTags
        story.intentEmphasis = dto.emphasis
        story.intentConstraints = dto.creativeConstraints
        story.intentPace = dto.pace?.rawValue
        story.intentTargetDurationSeconds = dto.targetDurationSeconds
        try repository.save()
        return story
    }

    /// Map the canonical CreativeIntent DTO onto the Milestone-A flattened local
    /// value type (documented mapping, 02 §0a): summary 1:1; the local `theme`/
    /// `tone` are seeded from style_tags / desired_feeling until the local model
    /// carries the full structured intent.
    static func mapIntent(_ dto: CreativeIntentContractDTO, rawText: String) -> CreativeIntent {
        let tone = dto.desiredFeeling.first ?? ""
        let theme = dto.styleTags.first ?? (dto.subject ?? "")
        return CreativeIntent(
            rawText: dto.rawUserDescription ?? rawText,
            theme: theme,
            tone: tone,
            summary: dto.summary
        )
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

    // MARK: - C3.5 cheap lifecycle / media capabilities (local, mechanical)

    /// Complete Story — a LIFECYCLE action only (02 §: Complete != Create).
    /// Flips status to completed; the Story keeps all Moments/outputs and can be
    /// reopened. Completed Stories sort below active ones in Home.
    func completeStory(_ story: StoryModel) throws {
        story.status = .completed
        try repository.save()
    }

    /// Reopen a completed Story back to active.
    func reopenStory(_ story: StoryModel) throws {
        story.status = .active
        try repository.save()
    }

    /// Add existing phone media (picked via PHPicker, already copied into
    /// MediaStore) to the Story as existing-media Moments. No AI analysis — that
    /// is the AssetUnderstanding path, which stays disabled (ui-capability-matrix).
    @discardableResult
    func addExistingMedia(
        to story: StoryModel,
        relativePaths: [(path: String, duration: Double)]
    ) throws -> [MomentModel] {
        var created: [MomentModel] = []
        for item in relativePaths {
            let asset = AssetModel(relativePath: item.path,
                                   durationSeconds: item.duration,
                                   source: .existingMedia)
            created.append(try repository.addMoment(
                to: story, source: .existingMedia, asset: asset, caption: nil))
        }
        return created
    }

    /// Remove a Moment from a Story (local/mechanical — Moments management screen,
    /// Figma ScreenMoments). Does not change Story status.
    func removeMoment(_ moment: MomentModel, from story: StoryModel) throws {
        try repository.removeMoment(moment, from: story)
    }
}
