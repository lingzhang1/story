import XCTest
import SwiftData
@testable import Story

// GLOBAL MOMENTS persistence correctness (Capture Anywhere milestone, Phase 3).
// Verifies the StoryMomentLink association model: independent Moments, reuse across Stories, and the critical
// deletion semantics — deleting a Story must NEVER delete a shared Moment or its media. In-memory SwiftData,
// same harness as the other persistence tests.
@MainActor
final class GlobalMomentsPersistenceTests: XCTestCase {

    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }
    private var repo: StoryRepository!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
            configurations: config)
        repo = StoryRepository(context: ctx)
    }

    private func makeStory(_ title: String) -> StoryModel {
        let s = StoryModel(title: title, intentRawText: "t", intentTheme: "th",
                           intentTone: "to", intentSummary: "su")
        ctx.insert(s); return s
    }
    private func makeAsset(_ path: String) -> AssetModel {
        AssetModel(relativePath: path, durationSeconds: 5, source: .directed)
    }
    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try ctx.fetch(FetchDescriptor<T>()).count
    }

    // 1. Standalone Moment creation (no Story).
    func test_standaloneMomentCreation() throws {
        let m = try repo.addStandaloneMoment(source: .directed, asset: makeAsset("media/a.mov"), caption: "x")
        XCTAssertEqual(try count(MomentModel.self), 1)
        XCTAssertEqual(try count(StoryMomentLink.self), 0, "standalone Moment has no links")
        XCTAssertNotNil(m.asset)
    }

    // 2. Reuse ONE Moment across TWO Stories (one media file, two links).
    func test_momentReuseAcrossStories() throws {
        let m = try repo.addStandaloneMoment(source: .directed, asset: makeAsset("media/a.mov"), caption: nil)
        let s1 = makeStory("S1"); let s2 = makeStory("S2")
        try repo.link(m, to: s1)
        try repo.link(m, to: s2)
        XCTAssertEqual(try count(MomentModel.self), 1, "no media duplication")
        XCTAssertEqual(try count(AssetModel.self), 1)
        XCTAssertEqual(try count(StoryMomentLink.self), 2)
        XCTAssertEqual(s1.moments.map { $0.id }, [m.id])
        XCTAssertEqual(s2.moments.map { $0.id }, [m.id])
    }

    // 3+4. Deleting a Story preserves shared Moments and their media.
    func test_storyDeletionPreservesSharedMomentAndMedia() throws {
        let m = try repo.addStandaloneMoment(source: .directed, asset: makeAsset("media/a.mov"), caption: nil)
        let s1 = makeStory("S1"); let s2 = makeStory("S2")
        try repo.link(m, to: s1); try repo.link(m, to: s2); try ctx.save()

        ctx.delete(s1); try ctx.save()

        XCTAssertEqual(try count(MomentModel.self), 1, "Moment survives a Story delete")
        XCTAssertEqual(try count(AssetModel.self), 1, "media survives a Story delete")
        XCTAssertEqual(try count(StoryMomentLink.self), 1, "only S1's link removed")
        XCTAssertEqual(s2.moments.map { $0.id }, [m.id], "the other Story still has the Moment")
    }

    // 5. Remove a Moment from ONE Story = delete the link only, Moment survives.
    func test_removeMomentFromOneStory() throws {
        let m = try repo.addStandaloneMoment(source: .directed, asset: makeAsset("media/a.mov"), caption: nil)
        let s1 = makeStory("S1"); let s2 = makeStory("S2")
        try repo.link(m, to: s1); try repo.link(m, to: s2)
        try repo.removeMoment(m, from: s1)
        XCTAssertEqual(try count(MomentModel.self), 1)
        XCTAssertTrue(s1.moments.isEmpty)
        XCTAssertEqual(s2.moments.map { $0.id }, [m.id])
    }

    // 6. Explicit library deletion: Moment + media + links + AU gone.
    func test_explicitLibraryDeletion() throws {
        let m = try repo.addStandaloneMoment(source: .directed, asset: makeAsset("media/a.mov"), caption: nil)
        let s1 = makeStory("S1"); try repo.link(m, to: s1)
        let au = MomentUnderstandingModel(momentId: m.id, schemaVersion: "1", framePolicy: "p",
                                          promptVersion: "pv", modelId: nil, nFrames: nil, understandingJSON: "{}")
        ctx.insert(au); try ctx.save()

        try repo.deleteMomentFromLibrary(m)

        XCTAssertEqual(try count(MomentModel.self), 0)
        XCTAssertEqual(try count(AssetModel.self), 0, "owned media cascaded")
        XCTAssertEqual(try count(StoryMomentLink.self), 0, "links cascaded")
        XCTAssertEqual(try count(MomentUnderstandingModel.self), 0, "AU removed")
        XCTAssertTrue(s1.moments.isEmpty)
    }

    // 7. Duplicate link prevention.
    func test_duplicateLinkPrevented() throws {
        let m = try repo.addStandaloneMoment(source: .directed, asset: makeAsset("media/a.mov"), caption: nil)
        let s1 = makeStory("S1")
        try repo.link(m, to: s1)
        try repo.link(m, to: s1)   // dup
        XCTAssertEqual(try count(StoryMomentLink.self), 1, "no duplicate (story,moment) link")
        XCTAssertEqual(s1.moments.count, 1)
    }

    // 8. Per-Story ordering preserved via orderIndex.
    func test_perStoryOrdering() throws {
        let a = try repo.addStandaloneMoment(source: .directed, asset: makeAsset("media/a.mov"), caption: nil)
        let b = try repo.addStandaloneMoment(source: .directed, asset: makeAsset("media/b.mov"), caption: nil)
        let c = try repo.addStandaloneMoment(source: .directed, asset: makeAsset("media/c.mov"), caption: nil)
        let s1 = makeStory("S1")
        try repo.link(a, to: s1); try repo.link(b, to: s1); try repo.link(c, to: s1)
        XCTAssertEqual(s1.moments.map { $0.id }, [a.id, b.id, c.id], "link order (a,b,c) preserved")
    }

    // 9. AU is global (keyed by momentId) and survives a Story delete.
    func test_auGlobalAndPreservedAcrossStoryDelete() throws {
        let m = try repo.addStandaloneMoment(source: .directed, asset: makeAsset("media/a.mov"), caption: nil)
        let s1 = makeStory("S1"); try repo.link(m, to: s1)
        let au = MomentUnderstandingModel(momentId: m.id, schemaVersion: "1", framePolicy: "p",
                                          promptVersion: "pv", modelId: nil, nFrames: nil, understandingJSON: "{}")
        ctx.insert(au); try ctx.save()
        ctx.delete(s1); try ctx.save()
        let mid = m.id
        let found = try ctx.fetch(FetchDescriptor<MomentUnderstandingModel>(
            predicate: #Predicate { $0.momentId == mid }))
        XCTAssertEqual(found.count, 1, "AU keyed by momentId survives the Story delete")
    }

    // 10. GeneratedOutput stays Story-owned (cascades with the Story, not with Moments).
    func test_generatedOutputOwnedByStory() throws {
        let m = try repo.addStandaloneMoment(source: .directed, asset: makeAsset("media/a.mov"), caption: nil)
        let s1 = makeStory("S1"); try repo.link(m, to: s1)
        let out = GeneratedOutputModel(title: "v1", durationSeconds: 20, momentIds: [m.id])
        out.story = s1; ctx.insert(out); try ctx.save()
        XCTAssertEqual(try count(GeneratedOutputModel.self), 1)
        ctx.delete(s1); try ctx.save()
        XCTAssertEqual(try count(GeneratedOutputModel.self), 0, "output cascades with its Story")
        XCTAssertEqual(try count(MomentModel.self), 1, "but the Moment survives")
    }
}
