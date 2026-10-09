import XCTest
import SwiftData
@testable import Story

// Imported-video Asset Understanding lifecycle tests (R-c.1 §11). Reuse the FROZEN AssetUnderstandingQueue
// via its import extension (enqueueImportedVideos / backfillImports). FAKE analyzer + fake frame extractor —
// no network, no real media decode. Verifies the lifecycle contract, NOT device playback.
@MainActor
final class ImportedVideoUnderstandingTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
            configurations: config)
    }

    // MARK: - Fakes (match AssetUnderstandingQueueTests)

    private final class FakeAnalyzer: AUAnalyzing {
        var error: Error?
        private(set) var calls = 0
        private(set) var lastContext: [String: Any]?
        func analyze(frames: [AUExtractedFrame], momentId: UUID,
                     sourceCaptureId: UUID?, captureContext: [String: Any]?) async throws -> MomentUnderstandingDTO {
            calls += 1
            lastContext = captureContext
            if let error { throw error }
            return MomentUnderstandingDTO(
                momentId: momentId, sourceCaptureId: sourceCaptureId,
                schemaVersion: "moment_understanding/1", framePolicy: "au_frames/1",
                promptVersion: "au_prompt/1", modelId: "fake", nFrames: frames.count,
                observed: MomentObservedDTO(summary: "imported clip", subjects: [], events: [],
                                            temporalOrderNote: "", usefulSegments: []),
                storyContext: MomentStoryContextDTO(storyUtility: "useful_elsewhere",
                                                    requestedShotContribution: nil,
                                                    requestedBeatContribution: nil),
                createdAt: nil)
        }
    }

    private func fakeFrames(_ n: Int = 24) -> (URL) async throws -> [AUExtractedFrame] {
        { _ in (0..<n).map { AUExtractedFrame(jpeg: Data([0xFF, 0xD8]), tMs: $0 * 100) } }
    }

    private func queue(_ analyzer: AUAnalyzing = FakeAnalyzer()) -> AssetUnderstandingQueue {
        AssetUnderstandingQueue(context: ctx, service: analyzer, extractFrames: fakeFrames())
    }

    // MARK: - Builders

    private func newStory() -> StoryModel {
        let s = StoryModel(title: "Imports", intentRawText: "x", intentTheme: "t",
                           intentTone: "warm", intentSummary: "s")
        s.intentTargetDurationSeconds = 9
        ctx.insert(s)
        return s
    }

    /// Create a durable local media file so isAnalyzableVideo's file-existence guard passes.
    private func makeFile(_ rel: String) {
        let abs = MediaStore.shared.absoluteURL(for: rel)
        try? FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: abs.path, contents: Data([0x00]))
    }

    @discardableResult
    private func importedVideo(_ story: StoryModel, rel: String, dur: Double, source: MomentSource = .existingMedia) -> MomentModel {
        makeFile(rel)
        let asset = AssetModel(relativePath: rel, durationSeconds: dur, source: source)
        let m = MomentModel(source: source, asset: asset)
        m.story = story
        ctx.insert(m)
        try? ctx.save()
        return m
    }

    /// An imported STILL (future photo path): duration 0.
    @discardableResult
    private func importedPhoto(_ story: StoryModel, rel: String) -> MomentModel {
        makeFile(rel)
        let asset = AssetModel(relativePath: rel, durationSeconds: 0, source: .existingMedia)
        let m = MomentModel(source: .existingMedia, asset: asset)
        m.story = story
        ctx.insert(m)
        try? ctx.save()
        return m
    }

    private func jobs() -> [AssetUnderstandingJobModel] { (try? ctx.fetch(FetchDescriptor<AssetUnderstandingJobModel>())) ?? [] }
    private func understandings() -> [MomentUnderstandingModel] { (try? ctx.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? [] }

    // MARK: - §11 cases

    func test_videoImport_enqueuesAU() {
        let story = newStory()
        let v1 = importedVideo(story, rel: "media/v1.mov", dur: 8)
        let v2 = importedVideo(story, rel: "media/v2.mp4", dur: 6, source: .cameraImport)
        let n = queue().enqueueImportedVideos([v1, v2])
        XCTAssertEqual(n, 2)
        XCTAssertEqual(jobs().count, 2)
    }

    func test_photoImport_doesNotEnqueue() {
        let story = newStory()
        let photo = importedPhoto(story, rel: "media/pic.heic")
        let n = queue().enqueueImportedVideos([photo])
        XCTAssertEqual(n, 0, "a still (duration 0) must NOT enter the video AU pipeline")
        XCTAssertEqual(jobs().count, 0)
    }

    func test_mixedBatch_onlyVideosEnqueued() {
        let story = newStory()
        let v = importedVideo(story, rel: "media/v.mov", dur: 5)
        let p = importedPhoto(story, rel: "media/p.heic")
        let n = queue().enqueueImportedVideos([v, p])
        XCTAssertEqual(n, 1)
        XCTAssertEqual(jobs().first?.momentId, v.id)
    }

    func test_contextlessRequest_noFabricatedShotOrBeat() async {
        let story = newStory()
        let v = importedVideo(story, rel: "media/v.mov", dur: 7)
        let analyzer = FakeAnalyzer()
        let q = AssetUnderstandingQueue(context: ctx, service: analyzer, extractFrames: fakeFrames())
        q.enqueueImportedVideos([v])
        await q.drain()
        XCTAssertEqual(analyzer.calls, 1)
        XCTAssertNil(analyzer.lastContext, "imported-video AU must be contextless (no requested Shot/Beat)")
        let job = jobs().first { $0.momentId == v.id }
        XCTAssertNil(job?.sourceCaptureId)
    }

    func test_duplicateEnqueue_protected() {
        let story = newStory()
        let v = importedVideo(story, rel: "media/v.mov", dur: 5)
        let q = queue()
        q.enqueueImportedVideos([v])
        q.enqueueImportedVideos([v])      // re-import / re-call must not duplicate
        XCTAssertEqual(jobs().filter { $0.momentId == v.id }.count, 1)
    }

    func test_runToComplete_upsertsMomentUnderstanding() async {
        let story = newStory()
        let v = importedVideo(story, rel: "media/v.mov", dur: 6)
        let q = queue()
        q.enqueueImportedVideos([v])
        await q.drain()
        XCTAssertEqual(jobs().first { $0.momentId == v.id }?.state, .complete)
        XCTAssertEqual(understandings().filter { $0.momentId == v.id }.count, 1)
    }

    func test_legacyBackfill_enqueuesUnanalyzedImports_once() {
        let story = newStory()
        let v1 = importedVideo(story, rel: "media/old1.mov", dur: 8)
        let v2 = importedVideo(story, rel: "media/old2.mov", dur: 7)
        let q = queue()
        let first = q.backfillImports(for: story, context: ctx)
        XCTAssertEqual(first, 2, "both legacy imports should enqueue once")
        let second = q.backfillImports(for: story, context: ctx)
        XCTAssertEqual(second, 0, "re-open must NOT re-enqueue (idempotent)")
        XCTAssertEqual(jobs().count, 2)
        _ = v1; _ = v2
    }

    func test_backfill_skipsAlreadyUnderstood() async {
        let story = newStory()
        let v = importedVideo(story, rel: "media/u.mov", dur: 6)
        let q = queue()
        q.enqueueImportedVideos([v])
        await q.drain()                   // v now has a completed MU + a complete job
        XCTAssertEqual(understandings().filter { $0.momentId == v.id }.count, 1)
        let n = q.backfillImports(for: story, context: ctx)
        XCTAssertEqual(n, 0, "an already-understood import must not be re-analyzed")
    }

    func test_backfill_skipsPhotos() {
        let story = newStory()
        _ = importedPhoto(story, rel: "media/p.heic")
        let n = queue().backfillImports(for: story, context: ctx)
        XCTAssertEqual(n, 0)
    }

    func test_deletedMoment_jobDiscardedOnDrain() async {
        // File gone (Moment deleted) under a media/ path -> the queue drops the job, no retry, no crash.
        let story = newStory()
        let v = importedVideo(story, rel: "media/gone.mov", dur: 5)
        let q = queue()
        q.enqueueImportedVideos([v])
        // Simulate deletion: remove the file.
        try? FileManager.default.removeItem(at: MediaStore.shared.absoluteURL(for: "media/gone.mov"))
        await q.drain()
        XCTAssertTrue(jobs().isEmpty, "a deleted Moment's job is safely discarded")
        XCTAssertTrue(understandings().isEmpty)
    }

    func test_importedVideo_becomesPlannable_afterAU() async {
        // After AU completes, the import satisfies the EXACT readiness rule (file + completed MU) — no source gate.
        let story = newStory()
        let v = importedVideo(story, rel: "media/plannable.mov", dur: 6)
        let q = queue()
        q.enqueueImportedVideos([v])
        let before = StoryCreationReadiness.evaluate(story: story, context: ctx)
        XCTAssertFalse(before.isPlannable, "pending AU -> not yet plannable (honest)")
        await q.drain()
        let after = StoryCreationReadiness.evaluate(story: story, context: ctx)
        XCTAssertTrue(after.isPlannable, "imported video with a completed MU + local file is plannable")
    }

    func test_sourcePreservation_enqueueDoesNotMutateMomentOrAsset() {
        let story = newStory()
        let v = importedVideo(story, rel: "media/keep.mov", dur: 9)
        let originalPath = v.asset?.relativePath
        let originalSource = v.source
        queue().enqueueImportedVideos([v])
        XCTAssertEqual(v.asset?.relativePath, originalPath)
        XCTAssertEqual(v.source, originalSource)
        XCTAssertEqual(story.moments.count, 1, "no moment added or removed by enqueue")
    }
}
