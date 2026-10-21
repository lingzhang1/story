import XCTest
import SwiftData
@testable import Story

// P0 Beta Auth Increment 4 — gating + background-defer logic (pure/mockable; the device paths are Phase 6).
//
// Covers the two correction-critical invariants:
//  1. Background Asset Understanding is DEFERRED while signed out — the Moment + its PENDING job are preserved
//     and NO paid analyze() is called — then RESUMES exactly once when a session exists (idempotent upsert).
//  2. AuthGate preserves the user's action across sign-in and resumes it EXACTLY ONCE (no duplicate inference).
@MainActor
final class AuthGatingTests: XCTestCase {

    // A fake analyzer that counts paid calls. Throws a benign error so the test needs no full DTO — the point
    // is WHETHER analyze was invoked, which is the defer boundary.
    final class CountingAnalyzer: AUAnalyzing {
        var calls = 0
        func analyze(frames: [AUExtractedFrame], momentId: UUID, sourceCaptureId: UUID?,
                     captureContext: [String: Any]?) async throws -> MomentUnderstandingDTO {
            calls += 1
            throw MomentFrameExtractorError.noFrames   // benign; defer behavior is about the call count
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
            configurations: config)
    }

    // 1a. Signed OUT: enqueue persists the job (Moment preserved) but drain() does NOT call analyze.
    func test_au_deferred_when_signed_out() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let analyzer = CountingAnalyzer()
        let queue = AssetUnderstandingQueue(
            context: ctx, service: analyzer,
            extractFrames: { _ in [AUExtractedFrame(jpeg: Data([0xFF]), tMs: 0)] },
            isAuthed: { false })                       // signed out

        let mid = UUID()
        queue.enqueue(momentId: mid, relativeMediaPath: "media/x.mov", sourceCaptureId: nil, captureContext: nil)
        // Job persisted (Moment's AU is pending, not lost).
        let jobsAfterEnqueue = try ctx.fetch(FetchDescriptor<AssetUnderstandingJobModel>())
        XCTAssertEqual(jobsAfterEnqueue.count, 1)

        await queue.drain()
        XCTAssertEqual(analyzer.calls, 0, "no paid analyze while signed out")
        let job = try XCTUnwrap(try ctx.fetch(FetchDescriptor<AssetUnderstandingJobModel>()).first)
        XCTAssertEqual(job.stateRaw, "pending", "job stays PENDING — recoverable, no backoff burned")
        XCTAssertEqual(job.attempts, 0, "a deferred drain must not count as a failed attempt")
    }

    // 1b. Signed IN: the same pending job is processed (analyze IS called) — resume after sign-in.
    func test_au_resumes_when_authed() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let analyzer = CountingAnalyzer()
        var authed = false
        let queue = AssetUnderstandingQueue(
            context: ctx, service: analyzer,
            extractFrames: { _ in [AUExtractedFrame(jpeg: Data([0xFF]), tMs: 0)] },
            isAuthed: { authed })

        let mid = UUID()
        queue.enqueue(momentId: mid, relativeMediaPath: "media/x.mov", sourceCaptureId: nil, captureContext: nil)
        await queue.drain()
        XCTAssertEqual(analyzer.calls, 0)              // deferred

        authed = true                                  // sign-in happens
        await queue.drain()
        XCTAssertEqual(analyzer.calls, 1, "pending AU resumes exactly once after sign-in")
    }

    // 1c. Enqueue is idempotent — a second enqueue for the same Moment never creates a duplicate job
    //     (so a resume cannot fan out into duplicate AU work).
    func test_au_enqueue_is_idempotent() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let queue = AssetUnderstandingQueue(context: ctx, service: CountingAnalyzer(),
                                            extractFrames: { _ in [] }, isAuthed: { true })
        let mid = UUID()
        queue.enqueue(momentId: mid, relativeMediaPath: "media/x.mov", sourceCaptureId: nil, captureContext: nil)
        queue.enqueue(momentId: mid, relativeMediaPath: "media/x.mov", sourceCaptureId: nil, captureContext: nil)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<AssetUnderstandingJobModel>()).count, 1)
    }

    // 2. AuthGate: signed out -> stores the action, presents sign-in, resumes EXACTLY ONCE on success.
    func test_authgate_resumes_pending_action_once() {
        let auth = AuthStore()                          // starts .signedOut
        let gate = AuthGate(auth: auth)
        var runCount = 0
        gate.run { runCount += 1 }
        XCTAssertEqual(runCount, 0, "signed out: action is deferred, not run")
        XCTAssertTrue(gate.presentingSignIn)

        gate.didSignIn()
        XCTAssertEqual(runCount, 1, "action resumes once after sign-in")
        gate.didSignIn()                                // a re-presented sheet / refresh race
        XCTAssertEqual(runCount, 1, "never a duplicate run (no duplicate inference)")
    }

    // 2b. AuthGate: a cancelled sign-in drops the pending action (no run on dismissal).
    func test_authgate_cancel_drops_action() {
        let auth = AuthStore()
        let gate = AuthGate(auth: auth)
        var runCount = 0
        gate.run { runCount += 1 }
        gate.cancel()
        XCTAssertEqual(runCount, 0)
        XCTAssertFalse(gate.presentingSignIn)
    }

    // 3. Invite-only (Option D): the inviteOnly error carries a non-enumerating message — it never reveals
    //    whether the account exists, and points the user at the invite / request-access path.
    func test_inviteOnly_message_does_not_enumerate() {
        let msg = CognitoAuthError.inviteOnly.errorDescription ?? ""
        XCTAssertFalse(msg.isEmpty)
        XCTAssertTrue(msg.lowercased().contains("invite"), "should state it's invite-only")
        // Must NOT confirm existence/absence of an account (no enumeration wording).
        for leak in ["no account", "not found", "doesn't exist", "does not exist", "already exists", "unregistered"] {
            XCTAssertFalse(msg.lowercased().contains(leak), "invite message must not enumerate (\(leak))")
        }
    }
}
