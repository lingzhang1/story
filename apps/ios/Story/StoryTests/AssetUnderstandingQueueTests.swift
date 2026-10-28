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

    // =====================================================================================================
    // Pre-beta AU-429 hardening: a TEMPORARY rate limit is retried (honoring Retry-After + jitter); an
    // EXHAUSTED allowance is NOT retried this session (deferred to the next UTC day); a HARD error is bounded.
    // All state uses the existing persisted fields, so these also prove retry state survives a restart.
    // =====================================================================================================

    func testRateLimited429ReturnsToPendingAndRetries() async {
        // A 429 rate_limited -> PENDING with a future nextEligibleAt (>= server Retry-After), NOT a terminal
        // failure and NOT a fabricated understanding. Then a later eligible drain succeeds.
        let fa = FakeAnalyzer()
        fa.error = AssetUnderstandingServiceError.rateLimited(retryAfter: 30)
        let q = queue(fa)
        let m = UUID()
        enqueueTestJob(q, moment: m)
        let t0 = Date()
        await q.drain()
        let job = jobs().first { $0.momentId == m }!
        XCTAssertEqual(job.state, .pending)
        XCTAssertTrue(understandings().isEmpty)
        // Honored Retry-After: eligible no sooner than ~Retry-After/2 (full-jitter lower bound of base=30).
        XCTAssertGreaterThanOrEqual(job.nextEligibleAt.timeIntervalSince(t0), 15 - 1)
        // Now simulate the window passing and the rate limit clearing -> completes.
        fa.error = nil
        job.nextEligibleAt = .distantPast
        try? ctx.save()
        await q.drain()
        XCTAssertEqual(jobs().first { $0.momentId == m }?.state, .complete)
        XCTAssertEqual(understandings().filter { $0.momentId == m }.count, 1)
    }

    func testRateLimited429WithoutRetryAfterStillUsesBackoff() async {
        // No Retry-After header -> fall back to our own exponential backoff (never 0, so it can't hot-loop).
        let fa = FakeAnalyzer()
        fa.error = AssetUnderstandingServiceError.rateLimited(retryAfter: nil)
        let q = queue(fa)
        let m = UUID()
        enqueueTestJob(q, moment: m)
        let t0 = Date()
        await q.drain()
        let job = jobs().first { $0.momentId == m }!
        XCTAssertEqual(job.state, .pending)
        XCTAssertGreaterThan(job.nextEligibleAt.timeIntervalSince(t0), 0)  // bounded, non-zero
    }

    func testQuotaExhausted429IsNotRetriedThisSession() async {
        // 429 quota_exceeded -> PENDING but deferred to the NEXT UTC DAY (the daily allowance reset), NOT
        // retried immediately, and WITHOUT burning a hard-error attempt. Retrying a spent cap can never
        // succeed until the period rolls over, so an immediate re-drain must NOT call the analyzer again.
        let fa = FakeAnalyzer()
        fa.error = AssetUnderstandingServiceError.quotaExhausted(scope: "user_daily_gens")
        let q = queue(fa)
        let m = UUID()
        enqueueTestJob(q, moment: m)
        await q.drain()
        let callsAfterFirst = fa.calls
        let job = jobs().first { $0.momentId == m }!
        XCTAssertEqual(job.state, .pending)
        XCTAssertEqual(job.attempts, 0, "a spent allowance must not count as a work-failure attempt")
        XCTAssertEqual(job.nextEligibleAt, AssetUnderstandingQueue.nextUtcDayBoundary(after: job.updatedAt))
        XCTAssertTrue(understandings().isEmpty)
        // Immediate re-drain: still deferred (eligibility is tomorrow) -> analyzer NOT called again.
        await q.drain()
        XCTAssertEqual(fa.calls, callsAfterFirst, "exhausted-quota job must not be retried this session")
    }

    func testHardErrorIsBoundedByAttempts() async {
        // A non-retryable hard error (badStatus) retries a bounded number of times then parks far out, so the
        // queue never hammers a permanently-bad job. Each eligible drain advances attempts; after the ceiling
        // the next-eligible jumps to the long park interval.
        let fa = FakeAnalyzer()
        fa.error = AssetUnderstandingServiceError.badStatus(400)
        let q = queue(fa)
        let m = UUID()
        enqueueTestJob(q, moment: m)
        for _ in 0..<AssetUnderstandingQueue.maxHardAttempts {
            let job = jobs().first { $0.momentId == m }!
            job.nextEligibleAt = .distantPast   // force eligible each iteration
            try? ctx.save()
            await q.drain()
        }
        let job = jobs().first { $0.momentId == m }!
        XCTAssertGreaterThanOrEqual(job.attempts, AssetUnderstandingQueue.maxHardAttempts)
        // Parked far out (>= ~ the hard-error park interval), not re-firing immediately.
        XCTAssertGreaterThan(job.nextEligibleAt.timeIntervalSinceNow,
                             AssetUnderstandingQueue.hardErrorParkInterval - 60)
        XCTAssertTrue(understandings().isEmpty)
    }

    func testRetryStateSurvivesRestart() async {
        // A rate-limited job's PENDING + nextEligibleAt persists; a FRESH queue over the SAME store (models an
        // app restart) sees it and does not lose it or re-run it before it is eligible.
        let fa = FakeAnalyzer()
        fa.error = AssetUnderstandingServiceError.rateLimited(retryAfter: 60)
        let q1 = queue(fa)
        let m = UUID()
        enqueueTestJob(q1, moment: m)
        await q1.drain()
        let before = jobs().first { $0.momentId == m }!
        XCTAssertEqual(before.state, .pending)
        let eligibleAt = before.nextEligibleAt

        // "Restart": a brand-new queue instance over the same ModelContext/store.
        let fa2 = FakeAnalyzer()   // would succeed, but the job is not yet eligible
        let q2 = AssetUnderstandingQueue(context: ctx, service: fa2, extractFrames: fakeFrames(),
                                         isAuthed: { true })
        q2.recoverOrphans()
        await q2.drain()
        let after = jobs().first { $0.momentId == m }!
        XCTAssertEqual(after.state, .pending)                 // preserved, not lost
        XCTAssertEqual(after.nextEligibleAt, eligibleAt)      // same scheduled time
        XCTAssertEqual(fa2.calls, 0, "not retried before its persisted nextEligibleAt")
    }

    // Pure deterministic helpers / classifier (no SwiftData needed).

    func testErrorIsRetryableClassification() {
        XCTAssertTrue(AssetUnderstandingServiceError.rateLimited(retryAfter: 1).isRetryable)
        XCTAssertTrue(AssetUnderstandingServiceError.unavailableRetryable.isRetryable)
        XCTAssertTrue(AssetUnderstandingServiceError.transport(URLError(.timedOut)).isRetryable)
        XCTAssertFalse(AssetUnderstandingServiceError.quotaExhausted(scope: "user_daily_gens").isRetryable)
        XCTAssertFalse(AssetUnderstandingServiceError.badStatus(400).isRetryable)
    }

    func testWithJitterStaysInHalfToFullRange() {
        for base in [4.0, 30.0, 600.0] {
            for _ in 0..<50 {
                let j = AssetUnderstandingQueue.withJitter(base)
                XCTAssertGreaterThanOrEqual(j, base / 2 - 0.0001)
                XCTAssertLessThanOrEqual(j, base + 0.0001)
            }
        }
        XCTAssertEqual(AssetUnderstandingQueue.withJitter(0), 0)
    }

    func testNextUtcDayBoundaryIsStrictlyAfterAndMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let b = AssetUnderstandingQueue.nextUtcDayBoundary(after: now)
        XCTAssertGreaterThan(b, now)
        let comps = cal.dateComponents([.hour, .minute, .second], from: b)
        XCTAssertEqual(comps.hour, 0); XCTAssertEqual(comps.minute, 0); XCTAssertEqual(comps.second, 0)
        XCTAssertLessThanOrEqual(b.timeIntervalSince(now), 24 * 60 * 60 + 1)
    }
}
