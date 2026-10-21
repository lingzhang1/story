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

    func testBackfill_stampsNilOwnerStoriesToDesignatedAccount() throws {        // Two pre-R1 Stories with nil owner (as if created before R1).
        let s1 = StoryModel(title: "legacy1", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s")
        let s2 = StoryModel(title: "legacy2", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s")
        ctx.insert(s1); ctx.insert(s2)
        // An already-owned Story must NOT be overwritten.
        let owned = StoryModel(title: "ownedByB", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s")
        owned.ownerAccountId = accountB
        ctx.insert(owned)
        try ctx.save()

        let designatedSub = DevOwnershipBackfill.designatedAccountSub
        let canonical = "canonical-designated-id"
        #if DEBUG
        let stamped = DevOwnershipBackfill.runIfDesignatedAccount(
            signedInSub: designatedSub, canonicalId: canonical, context: ctx)
        XCTAssertEqual(stamped, 2)
        XCTAssertEqual(s1.ownerAccountId, canonical)
        XCTAssertEqual(s2.ownerAccountId, canonical)
        XCTAssertEqual(owned.ownerAccountId, accountB, "explicit owner must never be overwritten")

        // Idempotent: a second run stamps nothing (no nil-owner Stories remain).
        XCTAssertEqual(DevOwnershipBackfill.runIfDesignatedAccount(
            signedInSub: designatedSub, canonicalId: canonical, context: ctx), 0)

        // A NON-designated account signing in triggers no backfill.
        let s3 = StoryModel(title: "legacy3", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s")
        ctx.insert(s3); try ctx.save()
        XCTAssertEqual(DevOwnershipBackfill.runIfDesignatedAccount(
            signedInSub: "some-other-sub", canonicalId: "other-canonical", context: ctx), 0)
        XCTAssertNil(s3.ownerAccountId, "non-designated sign-in must not stamp")
        #endif
    }

    // MARK: - R1.1 sub -> canonical re-key

    func testRekey_subToCanonical_preservesOutputs() throws {
        #if DEBUG
        let sub = "cognito-sub-A"
        let canonical = "canonical-A"
        // A Story stamped with the legacy sub (as R1 did), with an output also on the sub.
        let repoSub = StoryRepository(context: ctx, owner: .account(sub))
        let story = try repoSub.createStory(title: "A1", intent: intent())
        let out = try repoSub.addGeneratedOutput(
            to: story, plan: GeneratedOutputPlan(title: "v1", durationSeconds: 5, momentIds: []))
        XCTAssertEqual(story.ownerAccountId, sub)
        XCTAssertEqual(out.ownerAccountId, sub)

        let n = DevOwnershipBackfill.rekeySubToCanonical(legacySub: sub, canonicalId: canonical, context: ctx)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(story.ownerAccountId, canonical, "Story re-keyed to canonical id")
        XCTAssertEqual(out.ownerAccountId, canonical, "GeneratedOutput re-keyed with its Story")

        // Now visible under the canonical account, not the sub.
        let canonFetch = try StoryRepository(context: ctx, owner: .account(canonical)).fetchStories()
        XCTAssertEqual(canonFetch.map(\.title), ["A1"])
        let subFetch = try StoryRepository(context: ctx, owner: .account(sub)).fetchStories()
        XCTAssertTrue(subFetch.isEmpty, "no Story remains under the old sub")

        // Idempotent: re-running moves nothing.
        XCTAssertEqual(DevOwnershipBackfill.rekeySubToCanonical(legacySub: sub, canonicalId: canonical, context: ctx), 0)
        #endif
    }

    func testRekey_neverTouchesAnotherAccount() throws {
        #if DEBUG
        let subA = "cognito-sub-A", canonicalA = "canonical-A"
        let subB = "cognito-sub-B"
        _ = try StoryRepository(context: ctx, owner: .account(subA)).createStory(title: "A1", intent: intent())
        let bStory = try StoryRepository(context: ctx, owner: .account(subB)).createStory(title: "B1", intent: intent())

        // Re-key only account A's sub.
        let n = DevOwnershipBackfill.rekeySubToCanonical(legacySub: subA, canonicalId: canonicalA, context: ctx)
        XCTAssertEqual(n, 1)
        // B's Story is untouched — never re-keyed by A's migration (owner Decision 6).
        XCTAssertEqual(bStory.ownerAccountId, subB)
        #endif
    }

    func testRekey_noopWhenSubEqualsCanonicalOrNil() throws {
        #if DEBUG
        _ = try StoryRepository(context: ctx, owner: .account("same-id")).createStory(title: "A1", intent: intent())
        XCTAssertEqual(DevOwnershipBackfill.rekeySubToCanonical(legacySub: "same-id", canonicalId: "same-id", context: ctx), 0)
        XCTAssertEqual(DevOwnershipBackfill.rekeySubToCanonical(legacySub: nil, canonicalId: "x", context: ctx), 0)
        XCTAssertEqual(DevOwnershipBackfill.rekeySubToCanonical(legacySub: "", canonicalId: "x", context: ctx), 0)
        #endif
    }
}
