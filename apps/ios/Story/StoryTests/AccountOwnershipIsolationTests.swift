import XCTest
import SwiftData
@testable import Story

// R1 — Account Ownership & Local Isolation tests.
//
// Lock the trigger-bug fix: two accounts on one device must see DISJOINT Stories, while local-only Moments
// stay SHARED across accounts (owner Decision 1/2). Also cover the pure AccountScope rules, owner stamping at
// creation, the anonymous-creation refusal, and the dev-only designated-account backfill.
@MainActor
final class AccountOwnershipIsolationTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    private let accountA = "acct-A"
    private let accountB = "acct-B"

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
                 MyMusicAssetModel.self, PendingOperationModel.self,
                 MusicPlanCacheModel.self, DurationRecCacheModel.self,
            configurations: config
        )
    }

    private func intent() -> CreativeIntent {
        CreativeIntent(rawText: "x", theme: "t", tone: "o", summary: "s")
    }

    // MARK: - Pure scope rules

    func testScope_storyVisibleOnlyToOwner() {
        XCTAssertTrue(AccountScope.canSeeStory(ownerAccountId: accountA, activeAccountId: accountA))
        XCTAssertFalse(AccountScope.canSeeStory(ownerAccountId: accountA, activeAccountId: accountB))
        XCTAssertFalse(AccountScope.canSeeStory(ownerAccountId: accountA, activeAccountId: nil))
        // A nil-owner Story is visible to no one (must be backfilled to surface).
        XCTAssertFalse(AccountScope.canSeeStory(ownerAccountId: nil, activeAccountId: accountA))
    }

    func testScope_localOnlyMomentSharedAcrossAccounts() {
        // Local-only (nil owner) → visible to A, B, and signed-out.
        XCTAssertTrue(AccountScope.canSeeMoment(ownerAccountId: nil, isLocalOnly: true, activeAccountId: accountA))
        XCTAssertTrue(AccountScope.canSeeMoment(ownerAccountId: nil, isLocalOnly: true, activeAccountId: accountB))
        XCTAssertTrue(AccountScope.canSeeMoment(ownerAccountId: nil, isLocalOnly: true, activeAccountId: nil))
    }

    func testScope_ownedMomentOnlyToOwner() {
        XCTAssertTrue(AccountScope.canSeeMoment(ownerAccountId: accountA, isLocalOnly: false, activeAccountId: accountA))
        XCTAssertFalse(AccountScope.canSeeMoment(ownerAccountId: accountA, isLocalOnly: false, activeAccountId: accountB))
        XCTAssertFalse(AccountScope.canSeeMoment(ownerAccountId: accountA, isLocalOnly: false, activeAccountId: nil))
    }

    // MARK: - Creation binds owner; anonymous refused

    func testCreateStory_bindsActiveOwner() throws {
        let repoA = StoryRepository(context: ctx, owner: .account(accountA))
        let story = try repoA.createStory(title: "A1", intent: intent())
        XCTAssertEqual(story.ownerAccountId, accountA)
    }

    func testCreateStory_anonymousRefused() {
        let anon = StoryRepository(context: ctx, owner: .anonymous)
        XCTAssertThrowsError(try anon.createStory(title: "nope", intent: intent())) { err in
            XCTAssertTrue(err is StoryCreationRequiresAuth)
        }
    }

    // MARK: - Repository fetch isolation (the trigger-bug fix)

    func testFetchStories_disjointByAccount() throws {
        let repoA = StoryRepository(context: ctx, owner: .account(accountA))
        let repoB = StoryRepository(context: ctx, owner: .account(accountB))
        _ = try repoA.createStory(title: "A1", intent: intent())
        _ = try repoA.createStory(title: "A2", intent: intent())
        _ = try repoB.createStory(title: "B1", intent: intent())

        let aStories = try repoA.fetchStories()
        let bStories = try repoB.fetchStories()
        XCTAssertEqual(Set(aStories.map(\.title)), ["A1", "A2"])
        XCTAssertEqual(Set(bStories.map(\.title)), ["B1"])
        // No overlap — the exact property that was broken.
        XCTAssertTrue(Set(aStories.map(\.id)).isDisjoint(with: Set(bStories.map(\.id))))
    }

    func testFetchStories_anonymousSeesNone() throws {
        let repoA = StoryRepository(context: ctx, owner: .account(accountA))
        _ = try repoA.createStory(title: "A1", intent: intent())
        let anon = StoryRepository(context: ctx, owner: .anonymous)
        XCTAssertEqual(try anon.fetchStories().count, 0)
    }

    // MARK: - Local-only Moments stay shared

    func testStandaloneMoment_isLocalOnlyAndShared() throws {
        let repoA = StoryRepository(context: ctx, owner: .account(accountA))
        let asset = AssetModel(relativePath: "media/x.mov", durationSeconds: 3, source: .directed)
        let m = try repoA.addStandaloneMoment(source: .directed, asset: asset, caption: nil)
        XCTAssertTrue(m.isLocalOnly)
        XCTAssertNil(m.ownerAccountId)
        // Visible to both accounts and signed-out via the in-memory filter.
        let all = try repoA.allMoments()
        XCTAssertEqual(all.visible(to: accountA).count, 1)
        XCTAssertEqual(all.visible(to: accountB).count, 1)
        XCTAssertEqual(all.visible(to: nil).count, 1)
    }

    // MARK: - GeneratedOutput inherits owner

    func testGeneratedOutput_inheritsStoryOwner() throws {
        let repoA = StoryRepository(context: ctx, owner: .account(accountA))
        let story = try repoA.createStory(title: "A1", intent: intent())
        let out = try repoA.addGeneratedOutput(
            to: story, plan: GeneratedOutputPlan(title: "v1", durationSeconds: 10, momentIds: []))
        XCTAssertEqual(out.ownerAccountId, accountA)
    }

    // MARK: - Dev-only designated-account backfill

    func testBackfill_stampsNilOwnerStoriesToDesignatedAccount() throws {
        // Two pre-R1 Stories with nil owner (as if created before R1).
        let s1 = StoryModel(title: "legacy1", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s")
        let s2 = StoryModel(title: "legacy2", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s")
        ctx.insert(s1); ctx.insert(s2)
        // An already-owned Story must NOT be overwritten.
        let owned = StoryModel(title: "ownedByB", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s")
        owned.ownerAccountId = accountB
        ctx.insert(owned)
        try ctx.save()

        let designated = DevOwnershipBackfill.designatedAccountId
        #if DEBUG
        let stamped = DevOwnershipBackfill.runIfDesignatedAccount(signedInAccountId: designated, context: ctx)
        XCTAssertEqual(stamped, 2)
        XCTAssertEqual(s1.ownerAccountId, designated)
        XCTAssertEqual(s2.ownerAccountId, designated)
        XCTAssertEqual(owned.ownerAccountId, accountB, "explicit owner must never be overwritten")

        // Idempotent: a second run stamps nothing.
        XCTAssertEqual(DevOwnershipBackfill.runIfDesignatedAccount(signedInAccountId: designated, context: ctx), 0)

        // A NON-designated account signing in triggers no backfill.
        let s3 = StoryModel(title: "legacy3", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s")
        ctx.insert(s3); try ctx.save()
        XCTAssertEqual(DevOwnershipBackfill.runIfDesignatedAccount(signedInAccountId: accountA, context: ctx), 0)
        XCTAssertNil(s3.ownerAccountId, "non-designated sign-in must not stamp")
        #endif
    }
}
