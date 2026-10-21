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
    // Global Moments (Capture Anywhere + Library)
    func addStandaloneMoment(source: MomentSource, asset: AssetModel, caption: String?) throws -> MomentModel
    func link(_ moment: MomentModel, to story: StoryModel) throws
    func deleteMomentFromLibrary(_ moment: MomentModel) throws
    func deleteStory(_ story: StoryModel) throws
    func allMoments() throws -> [MomentModel]
    func save() throws
}

// R1 — the active account whose content this repository instance reads/writes. Resolved from AuthStore's
// `story_user_id` at the call site (never a client-trusted value for backend authz; this is the device-side
// visibility scope). `.anonymous` means no signed-in account: Story creation is REFUSED (owner Decision 2 —
// Stories are always account-owned, created only after authentication), while local-only Moments stay visible.
enum ActiveOwner: Equatable {
    case account(String)   // a resolved story_user_id
    case anonymous         // signed out / not yet resolved

    var accountId: String? { if case let .account(id) = self { return id }; return nil }
    var isAuthenticated: Bool { accountId != nil }
}

/// Raised when persistent Story creation is attempted without an authenticated account (owner Decision 2).
struct StoryCreationRequiresAuth: Error, LocalizedError {
    var errorDescription: String? { "Sign in to create a Story." }
}

@MainActor
final class StoryRepository: StoryRepositoryProtocol {
    private let context: ModelContext
    /// The account this repository reads/writes for (R1 account isolation). Defaults to `.anonymous` so legacy
    /// call sites + tests that do not pass an owner keep compiling; those paths cannot create a Story (which now
    /// requires auth) but can still read/link Moments. Production Story-creation call sites MUST pass a resolved
    /// account.
    private let owner: ActiveOwner

    init(context: ModelContext, owner: ActiveOwner = .anonymous) {
        self.context = context
        self.owner = owner
    }

    func createStory(title: String, intent: CreativeIntent) throws -> StoryModel {
        // Owner Decision 2: a persistent Story is created ONLY after authentication and is stamped with the
        // active account's resolved story_user_id. No anonymous Story; no legacy `dev` fallback.
        guard case let .account(accountId) = owner else { throw StoryCreationRequiresAuth() }
        let story = StoryModel(
            title: title,
            status: .active,
            intentRawText: intent.rawText,
            intentTheme: intent.theme,
            intentTone: intent.tone,
            intentSummary: intent.summary
        )
        story.ownerAccountId = accountId
        context.insert(story)
        try context.save()
        return story
    }

    /// Stories owned by the ACTIVE account only (R1 isolation). An anonymous owner sees none (there are no
    /// anonymous Stories). A Story with a nil owner (pre-R1, pre-backfill) is NOT visible to any account — the
    /// dev-only backfill stamps those to the designated account so they surface correctly.
    func fetchStories() throws -> [StoryModel] {
        guard case let .account(accountId) = owner else { return [] }
        // Bind as Optional so the #Predicate compares String? == String? (avoids an optional-vs-nonoptional
        // type mismatch in the SwiftData predicate macro).
        let want: String? = accountId
        let descriptor = FetchDescriptor<StoryModel>(
            predicate: #Predicate { $0.ownerAccountId == want },
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
    func deleteMomentFromLibrary(_ moment: MomentModel) throws {        // Delete the Moment-scoped AU record (keyed by momentId) if present.
        let mid = moment.id
        if let au = try context.fetch(FetchDescriptor<MomentUnderstandingModel>(
            predicate: #Predicate { $0.momentId == mid })).first {
            context.delete(au)
        }
        context.delete(moment)   // cascades asset + links
        try context.save()
    }

    func allMoments() throws -> [MomentModel] {
        try context.fetch(FetchDescriptor<MomentModel>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    /// Delete a Story and its OWN dependents (links, generated outputs, guide/coverage) via cascade.
    /// Independent global Moments are NOT touched — a StoryMomentLink is only a join row, so cascading
    /// the Story's links removes the associations while the Moments + their media survive in the library.
    /// Used to clean up a Story-setup wizard that is cancelled before confirmation (no orphan Story).
    func deleteStory(_ story: StoryModel) throws {
        context.delete(story)
        try context.save()
    }

    func addGeneratedOutput(to story: StoryModel, plan: GeneratedOutputPlan) throws -> GeneratedOutputModel {
        let output = GeneratedOutputModel(
            title: plan.title,
            durationSeconds: plan.durationSeconds,
            momentIds: plan.momentIds
        )
        output.story = story
        output.ownerAccountId = story.ownerAccountId   // R1: inherit the parent Story's owner.
        context.insert(output)
        story.generatedOutputs.append(output)
        story.updatedAt = .now
        // INVARIANT: Create != Complete. Status is deliberately unchanged.
        try context.save()
        return output
    }

    func save() throws { try context.save() }
}
