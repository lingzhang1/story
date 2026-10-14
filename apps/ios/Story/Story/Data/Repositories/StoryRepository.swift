import Foundation
import SwiftData

// StoryRepository — abstracts SwiftData persistence from the UI and
// use-cases (spec 03: "Repositories abstract persistence"). The UI never
// touches ModelContext directly.

@MainActor
protocol StoryRepositoryProtocol {
    func createStory(title: String, intent: CreativeIntent) throws -> StoryModel
    func fetchStories() throws -> [StoryModel]
    func addMoment(to story: StoryModel, source: MomentSource,
                   asset: AssetModel, caption: String?) throws -> MomentModel
    func removeMoment(_ moment: MomentModel, from story: StoryModel) throws
    func addGeneratedOutput(to story: StoryModel, plan: GeneratedOutputPlan) throws -> GeneratedOutputModel
    func save() throws
}

@MainActor
final class StoryRepository: StoryRepositoryProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func createStory(title: String, intent: CreativeIntent) throws -> StoryModel {
        let story = StoryModel(
            title: title,
            status: .active,
            intentRawText: intent.rawText,
            intentTheme: intent.theme,
            intentTone: intent.tone,
            intentSummary: intent.summary
        )
        context.insert(story)
        try context.save()
        return story
    }

    func fetchStories() throws -> [StoryModel] {
        let descriptor = FetchDescriptor<StoryModel>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Create a Moment (independent, global) and LINK it to a Story. Does not make the Story own the Moment.
    func addMoment(to story: StoryModel, source: MomentSource,
                   asset: AssetModel, caption: String?) throws -> MomentModel {
        context.insert(asset)
        let moment = MomentModel(source: source, caption: caption, asset: asset)
        context.insert(moment)
        try link(moment, to: story)   // creates the StoryMomentLink (dup-prevented, next order), saves
        return moment
    }

    /// Create a STANDALONE Moment with no Story association (Capture Anywhere → global library).
    func addStandaloneMoment(source: MomentSource, asset: AssetModel, caption: String?) throws -> MomentModel {
        context.insert(asset)
        let moment = MomentModel(source: source, caption: caption, asset: asset)
        context.insert(moment)
        try context.save()
        return moment
    }

    /// Link an existing (possibly already-used) Moment into a Story. Idempotent: a duplicate (story,moment)
    /// link is NOT created (SwiftData has no composite-unique constraint, so we guard here). New links get the
    /// next per-Story orderIndex so selection order is preserved.
    func link(_ moment: MomentModel, to story: StoryModel) throws {
        guard let lnk = story.attach(moment) else { return }   // nil = already linked (dup prevented)
        context.insert(lnk)
        story.updatedAt = .now
        try context.save()
    }

    /// Remove a Moment FROM ONE Story: delete the link only. The Moment, its media and its AU SURVIVE and
    /// remain in the global library / other Stories. (Was: delete the Moment — that behavior is now the
    /// explicit library deletion below.)
    func removeMoment(_ moment: MomentModel, from story: StoryModel) throws {
        for lnk in story.momentLinks where lnk.moment?.id == moment.id {
            context.delete(lnk)
        }
        story.updatedAt = .now
        try context.save()
    }

    /// EXPLICIT library deletion: destroy the Moment, its owned media (asset cascade) and — via the caller —
    /// its AU record. Cascade removes all its links, so it disappears from every Story that used it. The
    /// caller is expected to have warned the user if the Moment is still linked anywhere.
    func deleteMomentFromLibrary(_ moment: MomentModel) throws {
        // Delete the Moment-scoped AU record (keyed by momentId) if present.
        let mid = moment.id
        if let au = try context.fetch(FetchDescriptor<MomentUnderstandingModel>(
            predicate: #Predicate { $0.momentId == mid })).first {
            context.delete(au)
        }
        context.delete(moment)   // cascades asset + links
        try context.save()
    }

    func addGeneratedOutput(to story: StoryModel, plan: GeneratedOutputPlan) throws -> GeneratedOutputModel {        let output = GeneratedOutputModel(
            title: plan.title,
            durationSeconds: plan.durationSeconds,
            momentIds: plan.momentIds
        )
        output.story = story
        context.insert(output)
        story.generatedOutputs.append(output)
        story.updatedAt = .now
        // INVARIANT: Create != Complete. Status is deliberately unchanged.
        try context.save()
        return output
    }

    func save() throws { try context.save() }
}
