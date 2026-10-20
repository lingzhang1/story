import XCTest
import SwiftData
@testable import Story

// Capture Anywhere persistence tests (Priority 3). Exercises the SHARED
// persistence path the continuous camera uses (StoryUseCases + AU enqueue) and
// the exactly-once / no-duplication guarantees — WITHOUT camera hardware, which
// only the device acceptance pass can cover. Camera-hardware items (consecutive
// recordings, interruption, permissions, failed media capture) are device-only
// and are listed in the Priority-4 acceptance steps.
@MainActor
final class CaptureAnywherePersistenceTests: XCTestCase {

    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }
    private var useCases: StoryUseCases!
    private var repo: StoryRepository!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
            configurations: config)
        repo = StoryRepository(context: ctx, owner: .account("test-acct-A"))
        useCases = StoryUseCases(repository: repo)
    }

    private func makeStory(_ title: String) -> StoryModel {
        let s = StoryModel(title: title, intentRawText: "t", intentTheme: "th",
                           intentTone: "to", intentSummary: "su")
        ctx.insert(s); return s
    }
    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try ctx.fetch(FetchDescriptor<T>()).count
    }

    // 1. Five standalone captures → five independent Moments, zero links, five assets.
    func test_fiveStandaloneCaptures_fiveIndependentMoments() throws {
        for i in 0..<5 {
            _ = try useCases.shootStandaloneMoment(relativePath: "media/s\(i).mov", durationSeconds: 3)
        }
        XCTAssertEqual(try count(MomentModel.self), 5)
        XCTAssertEqual(try count(AssetModel.self), 5, "no media duplication — one asset per clip")
        XCTAssertEqual(try count(StoryMomentLink.self), 0, "standalone creates zero Story links")
    }

    // 2. Five Story-associated captures → five Moments AND exactly five links, in order.
    func test_fiveStoryCaptures_exactlyFiveLinksInOrder() throws {
        let story = makeStory("S")
        var ids: [UUID] = []
        for i in 0..<5 {
            let m = try useCases.shootMoment(for: story, relativePath: "media/t\(i).mov", durationSeconds: 3)
            ids.append(m.id)
        }
        XCTAssertEqual(try count(MomentModel.self), 5)
        XCTAssertEqual(try count(StoryMomentLink.self), 5, "exactly one link per captured Moment")
        XCTAssertEqual(story.moments.map { $0.id }, ids, "capture order preserved in the Story")
    }

    // 3. Standalone vs Story association are distinct on the same container.
    func test_standaloneAndStoryCoexist() throws {
        let story = makeStory("S")
        _ = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)
        _ = try useCases.shootMoment(for: story, relativePath: "media/b.mov", durationSeconds: 3)
        XCTAssertEqual(try count(MomentModel.self), 2)
        XCTAssertEqual(try count(StoryMomentLink.self), 1, "only the Story capture is linked")
        XCTAssertEqual(story.moments.count, 1)
    }

    // 4. AU enqueue is idempotent — a double callback for the same Moment makes ONE job
    //    (mirrors the model's exactly-once guard at the AU layer).
    func test_auEnqueue_idempotentPerMoment() throws {
        let m = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)
        let q = AssetUnderstandingQueue(context: ctx)
        q.enqueue(momentId: m.id, relativeMediaPath: "media/a.mov", sourceCaptureId: nil, captureContext: nil)
        q.enqueue(momentId: m.id, relativeMediaPath: "media/a.mov", sourceCaptureId: nil, captureContext: nil)
        XCTAssertEqual(try count(AssetUnderstandingJobModel.self), 1, "no duplicate AU job per Moment")
    }

    // 5. allMoments() returns every library Moment (standalone + Story), newest first.
    func test_allMoments_global() throws {
        let story = makeStory("S")
        _ = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)
        _ = try useCases.shootMoment(for: story, relativePath: "media/b.mov", durationSeconds: 3)
        XCTAssertEqual(try useCases.allMoments().count, 2)
    }

    // 6. App-restart persistence: reopen a NEW context on a shared on-disk store and
    //    confirm the Moments + links are still there (simulates force-quit + relaunch).
    func test_restartPersistence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("captest-\(UUID().uuidString).store")
        let cfg = ModelConfiguration(url: url)
        let models: [any PersistentModel.Type] = [
            StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
            GeneratedOutputModel.self, LocalIdentityModel.self,
            MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
            StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self]
        let schema = Schema(models)

        do {
            let c1 = try ModelContainer(for: schema, configurations: cfg)
            let ctx1 = c1.mainContext
            let uc1 = StoryUseCases(repository: StoryRepository(context: ctx1, owner: .account("test-acct-A")))
            let story = StoryModel(title: "S", intentRawText: "t", intentTheme: "th",
                                   intentTone: "to", intentSummary: "su")
            ctx1.insert(story)
            for i in 0..<3 { _ = try uc1.shootStandaloneMoment(relativePath: "media/r\(i).mov", durationSeconds: 3) }
            _ = try uc1.shootMoment(for: story, relativePath: "media/rs.mov", durationSeconds: 3)
            try ctx1.save()
        }

        // Fresh container on the SAME file = relaunch.
        let c2 = try ModelContainer(for: schema, configurations: cfg)
        let ctx2 = c2.mainContext
        XCTAssertEqual(try ctx2.fetch(FetchDescriptor<MomentModel>()).count, 4,
                       "all captured Moments survive a relaunch")
        XCTAssertEqual(try ctx2.fetch(FetchDescriptor<StoryMomentLink>()).count, 1,
                       "the Story link survives a relaunch")

        try? FileManager.default.removeItem(at: url)
    }
}
