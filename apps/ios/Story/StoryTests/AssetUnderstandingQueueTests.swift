import XCTest
import SwiftData
@testable import Story

// Asset Understanding queue tests (Milestone D §6-7, §9). Drive the persistent
// state machine with a FAKE analyzer + fake frame extractor — no network, no media.
@MainActor
final class AssetUnderstandingQueueTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
            configurations: config)
    }

    private var ctx: ModelContext { container.mainContext }

    // A fake analyzer: succeeds with a canned DTO, or throws a scripted error.
    private final class FakeAnalyzer: AUAnalyzing {
        var error: Error?
        var calls = 0
        func analyze(frames: [AUExtractedFrame], momentId: UUID,
                     sourceCaptureId: UUID?, captureContext: [String: Any]?,
                     contentSha256: String?) async throws -> MomentUnderstandingDTO {
            calls += 1
            if let error { throw error }
            return MomentUnderstandingDTO(
                momentId: momentId, sourceCaptureId: sourceCaptureId,
                schemaVersion: "moment_understanding/1", framePolicy: "au_frames/1",
                promptVersion: "au_prompt/1", modelId: "fake", nFrames: frames.count,
                observed: MomentObservedDTO(summary: "s", subjects: [], events: [],
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

    private func queue(_ analyzer: AUAnalyzing) -> AssetUnderstandingQueue {
        // relativeMediaPath will be set to a non-"media/" path so the existence guard
        // is bypassed and the injected extractor runs.
        // isAuthed:{true} — these tests drive the drain state machine directly; the shared auth gate
        // (sharedIsAuthed defaults to {false}, added with the sign-out defer behavior) would otherwise
        // silently defer every job (pending, attempts=0, no understanding). The two push-seam tests set
        // sharedIsAuthed globally instead; this helper opts in locally.
        AssetUnderstandingQueue(context: ctx, service: analyzer, extractFrames: fakeFrames(),
                                isAuthed: { true })
    }

    private func enqueueTestJob(_ q: AssetUnderstandingQueue, moment: UUID) {
        q.enqueue(momentId: moment, relativeMediaPath: "test/\(moment).mov",
                  sourceCaptureId: nil, captureContext: nil)
    }

    private func jobs() -> [AssetUnderstandingJobModel] {
        (try? ctx.fetch(FetchDescriptor<AssetUnderstandingJobModel>())) ?? []
    }
    private func understandings() -> [MomentUnderstandingModel] {
        (try? ctx.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? []
    }

    func testEnqueueIsIdempotent() {
        let q = queue(FakeAnalyzer())
        let m = UUID()
        enqueueTestJob(q, moment: m)
        enqueueTestJob(q, moment: m)   // second enqueue must NOT duplicate
        XCTAssertEqual(jobs().filter { $0.momentId == m }.count, 1)
    }

    func testRunToCompleteAndUpsert() async {
        let q = queue(FakeAnalyzer())
        let m = UUID()
        enqueueTestJob(q, moment: m)
        await q.drain()
        let job = jobs().first { $0.momentId == m }
        XCTAssertEqual(job?.state, .complete)
        XCTAssertEqual(understandings().filter { $0.momentId == m }.count, 1)
    }

    func testFailureReturnsToPendingWithBackoff() async {
        let fa = FakeAnalyzer()
        fa.error = AssetUnderstandingServiceError.unavailableRetryable
        let q = queue(fa)
        let m = UUID()
        enqueueTestJob(q, moment: m)
        await q.drain()
        let job = jobs().first { $0.momentId == m }
        XCTAssertEqual(job?.state, .pending)             // back to pending, not complete
        XCTAssertEqual(job?.attempts, 1)
        XCTAssertNotNil(job?.lastError)
        XCTAssertGreaterThan(job?.nextEligibleAt ?? .distantPast, Date())  // backoff in the future
        XCTAssertTrue(understandings().isEmpty)          // no fabricated understanding
    }

    func testOrphanRecoveryResetsRunningToPending() {
        let q = queue(FakeAnalyzer())
        let m = UUID()
        enqueueTestJob(q, moment: m)
        let job = jobs().first { $0.momentId == m }!
        job.state = .running                              // simulate app killed mid-run
        try? ctx.save()
        q.recoverOrphans()
        XCTAssertEqual(jobs().first { $0.momentId == m }?.state, .pending)
    }

    func testUpsertDoesNotDuplicateOnRerun() async {
        let q = queue(FakeAnalyzer())
        let m = UUID()
        enqueueTestJob(q, moment: m)
        await q.drain()                                   // completes once
        // Force a re-run of the same moment: reset job to pending and drain again.
        let job = jobs().first { $0.momentId == m }!
        job.state = .pending
        job.nextEligibleAt = .distantPast
        try? ctx.save()
        await q.drain()
        XCTAssertEqual(understandings().filter { $0.momentId == m }.count, 1)  // still ONE record
    }

    func testBackedOffJobIsNotYetEligible() async {
        let fa = FakeAnalyzer()
        fa.error = AssetUnderstandingServiceError.unavailableRetryable
        let q = queue(fa)
        let m = UUID()
        enqueueTestJob(q, moment: m)
        await q.drain()                                   // fails -> pending + future backoff
        let callsAfterFirst = fa.calls
        await q.drain()                                   // immediately: still backed off
        XCTAssertEqual(fa.calls, callsAfterFirst)         // not retried before nextEligibleAt
    }

    // P1-E (§9) — AU completion QUEUES synchronization: a drain batch that completes at least one
    // understanding fires the push seam exactly once (coalesced), so a mid-session result is pushed without
    // waiting for the next foreground/sign-in. A drain with NO completion fires nothing.
    func testDrainCompletionFiresPushSeamOnce() async {
        let prevAuthed = AssetUnderstandingQueue.sharedIsAuthed
        let prevPush = AssetUnderstandingQueue.sharedPushUnderstanding
        defer { AssetUnderstandingQueue.sharedIsAuthed = prevAuthed
                AssetUnderstandingQueue.sharedPushUnderstanding = prevPush }
        AssetUnderstandingQueue.sharedIsAuthed = { true }
        var pushCount = 0
        AssetUnderstandingQueue.sharedPushUnderstanding = { pushCount += 1 }

        let q = queue(FakeAnalyzer())
        enqueueTestJob(q, moment: UUID())
        enqueueTestJob(q, moment: UUID())
        await q.drain()
        XCTAssertEqual(pushCount, 1, "two completed understandings coalesce into ONE push, not two")

        // A second drain with nothing eligible completes nothing -> no extra push.
        await q.drain()
        XCTAssertEqual(pushCount, 1)
    }

    func testDrainWithNoCompletionDoesNotPush() async {
        let prevAuthed = AssetUnderstandingQueue.sharedIsAuthed
        let prevPush = AssetUnderstandingQueue.sharedPushUnderstanding
        defer { AssetUnderstandingQueue.sharedIsAuthed = prevAuthed
                AssetUnderstandingQueue.sharedPushUnderstanding = prevPush }
        AssetUnderstandingQueue.sharedIsAuthed = { true }
        var pushCount = 0
        AssetUnderstandingQueue.sharedPushUnderstanding = { pushCount += 1 }

        let fa = FakeAnalyzer()
        fa.error = AssetUnderstandingServiceError.unavailableRetryable   // every job fails -> no completion
        let q = queue(fa)
        enqueueTestJob(q, moment: UUID())
        await q.drain()
        XCTAssertEqual(pushCount, 0, "a drain that completes nothing must not push")
    }
}
