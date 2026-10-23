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

    /// Phase 1 (pre-beta simplified creation): create the account-owned Story IMMEDIATELY from a title and an
    /// OPTIONAL free-text event description, with NO blocking AI call. A sensible default title is used when
    /// blank. The Story is seeded with a cheap LOCAL mock intent so it is fully valid offline; the REAL
    /// CreativeIntent (and then the Guide) are resolved ASYNCHRONOUSLY afterwards (enrichCreativeIntent +
    /// the Guide coordinator), never on the create path. Returns the created Story so the UI can navigate to
    /// Story Home right away.
    func createStoryImmediately(title rawTitle: String, description rawDescription: String) throws -> StoryModel {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty ? Self.defaultStoryTitle() : title
        // Local, offline mock intent from whatever description we have (may be empty). Never blocks.
        let intent = storyEngine.deriveCreativeIntent(from: desc)
        let story = try repository.createStory(title: resolvedTitle, intent: intent)
        // Preserve the user's raw description verbatim so the async resolver can enrich WITHOUT re-prompting,
        // and so a thin/empty description is detectable (don't fabricate a specific Guide from nothing).
        story.intentRawText = desc
        try repository.save()
        return story
    }

    /// A sensible default Story title when the user leaves it blank (owner Phase 1 "sensible default if blank").
    static func defaultStoryTitle() -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return "My Story · \(f.string(from: Date()))"
    }

    /// Whether there is ENOUGH event context to generate a non-generic Guide. A very thin/empty description
    /// (and a default-ish title) should NOT trigger expensive Guide inference — instead the UI invites the
    /// user to add detail. Heuristic: a description with a few meaningful words is sufficient.
    static func hasSufficientGuideContext(title: String, description: String) -> Bool {
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = d.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
        if wordCount >= 4 { return true }           // a real event description
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A specific (non-default) multi-word title can also carry enough intent (e.g. "Maya's 5th Birthday").
        return !t.isEmpty && !t.hasPrefix("My Story ·") && t.split(separator: " ").count >= 2
    }

    /// ASYNC enrichment: resolve the REAL CreativeIntent for an already-created Story via the backend and
    /// fold the richer fields onto it. Fire-and-forget off the create path; a failure leaves the Story valid
    /// with its local mock intent (the Guide can still be attempted, or retried later). Never fabricates.
    @discardableResult
    func enrichCreativeIntent(for story: StoryModel,
                              service: CreativeIntentService = CreativeIntentService()) async -> Bool {
        let desc = story.intentRawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty else { return false }   // nothing to resolve from; keep the local intent
        guard let dto = try? await service.resolve(rawText: desc) else { return false }
        let intent = Self.mapIntent(dto, rawText: desc)
        story.intentTheme = intent.theme
        story.intentTone = intent.tone
        story.intentSummary = intent.summary
        story.intentSubject = dto.subject
        story.intentDesiredFeeling = dto.desiredFeeling
        story.intentStyleTags = dto.styleTags
        story.intentEmphasis = dto.emphasis
        story.intentConstraints = dto.creativeConstraints
        story.intentPace = dto.pace?.rawValue
        story.intentTargetDurationSeconds = dto.targetDurationSeconds
        try? repository.save()
        return true
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

    // MARK: - Global Moments (Capture Anywhere + Library)

    /// Capture a STANDALONE Moment into the global library (no Story). Mirrors shootMoment's asset creation.
    func shootStandaloneMoment(relativePath: String, durationSeconds: Double) throws -> MomentModel {
        let asset = AssetModel(relativePath: relativePath, durationSeconds: durationSeconds, source: .directed)
        return try repository.addStandaloneMoment(source: .directed, asset: asset, caption: nil)
    }

    /// Every Moment in the global library, newest first.
    func allMoments() throws -> [MomentModel] {
        try repository.allMoments()
    }

    /// Create a NEW Story and link the selected global Moments into it (per-selection order preserved).
    /// Reuses the existing Story creation + the StoryMomentLink association — no media duplication.
    func createStoryFromMoments(title: String, direction: String, moments: [MomentModel]) throws -> StoryModel {
        let intent = storyEngine.deriveCreativeIntent(from: direction)
        let story = try repository.createStory(title: title, intent: intent)
        for m in moments { try repository.link(m, to: story) }
        return story
    }

    /// Remove a Moment from one Story (deletes the link only; Moment + media survive).
    func unlinkMoment(_ moment: MomentModel, from story: StoryModel) throws {
        try repository.removeMoment(moment, from: story)
    }

    /// Link already-existing global Moments into a Story ("Add Moments → From Story Moments").
    /// No media duplication (reuses the Moment + its AU). The repository's `link` is idempotent —
    /// a Moment already linked to this Story is skipped, so re-adding never creates a duplicate
    /// StoryMomentLink. New links take the next per-Story orderIndex, preserving selection order.
    /// Returns the Moments that were newly linked this call (already-linked ones are excluded).
    @discardableResult
    func addExistingMoments(_ moments: [MomentModel], to story: StoryModel) throws -> [MomentModel] {
        let alreadyLinked = Set(story.momentLinks.compactMap { $0.moment?.id })
        var newlyLinked: [MomentModel] = []
        for m in moments where !alreadyLinked.contains(m.id) {
            try repository.link(m, to: story)
            newlyLinked.append(m)
        }
        return newlyLinked
    }

    /// Explicit library deletion: destroy the Moment, its owned media, and its AU (cascades its links).
    func deleteMomentFromLibrary(_ moment: MomentModel) throws {
        try repository.deleteMomentFromLibrary(moment)
    }

    /// Delete a Story and its own dependents (links/outputs/guide). Independent global Moments survive.
    /// Used to discard a cancelled, unconfirmed Story-setup wizard so no orphan Story is left behind.
    func deleteStory(_ story: StoryModel) throws {
        try repository.deleteStory(story)
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
        relativePaths: [ImportedMedia]
    ) throws -> [MomentModel] {
        var created: [MomentModel] = []
        for item in relativePaths {
            // Camera Metadata P0: carry the ORIGINAL capture time + recovered location (nil = unknown) onto
            // the imported asset. capturedAt is the file's own creation date, kept separate from createdAt
            // (import time). Location recovered from embedded metadata; never fabricated.
            let asset = AssetModel(relativePath: item.path,
                                   durationSeconds: item.duration,
                                   source: .existingMedia,
                                   capturedAt: item.capturedAt,
                                   latitude: item.latitude,
                                   longitude: item.longitude,
                                   locationAccuracyMeters: nil)
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
