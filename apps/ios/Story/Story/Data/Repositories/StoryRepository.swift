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

    func addMoment(to story: StoryModel, source: MomentSource,
                   asset: AssetModel, caption: String?) throws -> MomentModel {
        context.insert(asset)
        let moment = MomentModel(source: source, caption: caption, asset: asset)
        moment.story = story
        context.insert(moment)
        story.moments.append(moment)
        story.updatedAt = .now
        try context.save()
        return moment
    }

    func removeMoment(_ moment: MomentModel, from story: StoryModel) throws {
        // Local/mechanical: detach from the Story and delete the Moment. The
        // asset relationship is cascade-deleted; the on-disk media file is left
        // to MediaStore's own lifecycle (no cross-boundary change).
        story.moments.removeAll { $0.id == moment.id }
        context.delete(moment)
        story.updatedAt = .now
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
