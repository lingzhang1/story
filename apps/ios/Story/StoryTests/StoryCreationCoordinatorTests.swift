import AVFoundation
import SwiftData
import XCTest
@testable import Story

// StoryCreationCoordinator tests (R-c Batch A §d). DETERMINISTIC: no network, no real render.
//
// The planner and the renderer are injected FAKES — the real EditPlannerService (network) and
// MediaEngineV1 (AVAssetExportSession, device/Xcode-gated) never run here. We assert the exact state
// sequence, the typed failure handling (503/422 -> failed, never a fabricated plan), that the renderer
// is NEVER reached on an invalid plan, the duplicate-job guard, cancellation, the staleness fingerprint
// semantics, and the music-ready seam threading. Style follows MediaEngineV1Tests / EditPlannerCaseGTests.
@MainActor
final class StoryCreationCoordinatorTests: XCTestCase {

    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
                 PendingOperationModel.self,
            configurations: config)
    }

    // MARK: - Fakes

    /// A planner that returns a canned plan or throws a canned EditPlannerServiceError.
    private struct FakePlanner: EditPlanning {
        enum Behavior { case ok(EditPlanV2), fail(EditPlannerServiceError) }
        let behavior: Behavior
        func plan(_ request: EditPlanRequestDTO) async throws -> EditPlanV2 {
            switch behavior {
            case .ok(let p): return p
            case .fail(let e): throw e
            }
        }
    }

    /// A job client that resolves the ASYNC create path synchronously in tests (the coordinator plans via the
    /// job client now, not the sync planner). Mirrors FakePlanner.Behavior into a terminal EditPlanJobState so
    /// the coordinator reaches .completed/.failed without any network. `.transport` throws so the poll surfaces
    /// a transport error (used by the 503/retry test).
    private final class FakeJobClient: EditPlanJobClienting {
        enum Behavior { case ok(EditPlanV2), failInfeasible(String), failUnavailable, throwTransport, staleThenOk(EditPlanV2) }
        var behavior: Behavior
        private(set) var submitCount = 0
        private(set) var pollCount = 0
        private(set) var lastRequest: EditPlanRequestDTO?
        private(set) var lastEvidenceAccounting: [String: Any]?
        private(set) var lastBuildProvenance: [String: Any]?
        init(_ b: Behavior) { behavior = b }

        func submit(_ request: EditPlanRequestDTO, operationId: String, owner: String,
                    approach: EditingApproach, sheets: [MomentContactSheet], creativeBrief: String?,
                    critiqueRevision: Bool, evidenceAccounting: [String: Any]?,
                    buildProvenance: [String: Any]?) async throws -> String {
            submitCount += 1
            lastRequest = request
            lastEvidenceAccounting = evidenceAccounting
            lastBuildProvenance = buildProvenance
            return "fake-job-\(operationId)-\(submitCount)"
        }

        func pollUntilTerminal(jobId: String, maxSeconds: Int,
                               shouldCancel: @MainActor () -> Bool,
                               onState: @MainActor (EditPlanJobState) -> Void) async throws -> EditPlanJobState {
            if await shouldCancel() { throw CancellationError() }
            pollCount += 1
            switch behavior {
            case .ok(let p):
                return EditPlanJobState(jobId: jobId, status: .completed, plan: p,
                                        failure: nil, failureDetail: nil, diagnostics: nil)
            case .failInfeasible(let r):
                return EditPlanJobState(jobId: jobId, status: .failed, plan: nil,
                                        failure: .materialInfeasible, failureDetail: r, diagnostics: nil)
            case .failUnavailable:
                return EditPlanJobState(jobId: jobId, status: .failed, plan: nil,
                                        failure: .providerError, failureDetail: "unavailable", diagnostics: nil)
            case .throwTransport:
                throw EditPlanJobError.transport(URLError(.timedOut))
            case .staleThenOk(let p):
                // First poll (the REUSED stale job) 404s; after the coordinator resubmits, the next poll ok's.
                if pollCount == 1 { throw EditPlanJobError.badStatus(404) }
                return EditPlanJobState(jobId: jobId, status: .completed, plan: p,
                                        failure: nil, failureDetail: nil, diagnostics: nil)
            }
        }

        func cancel(jobId: String) async { /* no-op in tests */ }
    }

    /// A renderer that records whether it was called + the inputs it saw, and returns a canned result
    /// (or throws, or blocks until cancel). NEVER touches AVFoundation. Reference type so flags survive.
    private final class FakeRenderer: StoryRendering, @unchecked Sendable {
        enum Behavior { case ok(RenderResult), fail(MediaEngineError), blockUntilCancel }
        let behavior: Behavior
        private(set) var called = false
        private(set) var seenSoundtrackURL: URL?
        private(set) var seenMusicAnalysis: MusicAnalysisV1?
        init(_ b: Behavior) { behavior = b }
        func render(_ inputs: MediaEngineInputs,
                    progress: ((Float) -> Void)?,
                    shouldCancel: (() -> Bool)?) async throws -> RenderResult {
            called = true
            seenSoundtrackURL = inputs.soundtrackURL
            seenMusicAnalysis = inputs.musicAnalysis
            switch behavior {
            case .ok(let r): progress?(1.0); return r
            case .fail(let e): throw e
            case .blockUntilCancel:
                while shouldCancel?() == false {
                    try await Task.sleep(nanoseconds: 2_000_000)
                    if Task.isCancelled { break }
                }
                throw MediaEngineError.exportFailed("cancelled")
            }
        }
    }

    // MARK: - Builders

    private func newStory(target: Double? = 9.0) -> StoryModel {
        let s = StoryModel(title: "Learning Guitar", intentRawText: "my guitar journey",
                           intentTheme: "growth", intentTone: "warm", intentSummary: "learning to play")
        s.intentTargetDurationSeconds = target
        ctx.insert(s)
        return s
    }

    @discardableResult
    private func momentWithFile(_ story: StoryModel, rel: String, dur: Double) -> MomentModel {
        let abs = MediaStore.shared.absoluteURL(for: rel)
        try? FileManager.default.createDirectory(at: abs.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: abs.path, contents: Data([0x00]))
        let asset = AssetModel(relativePath: rel, durationSeconds: dur, source: .directed)
        let m = MomentModel(source: .directed, asset: asset)
        ctx.insert(m)
        if let _lnk = story.attach(m) { ctx.insert(_lnk) }
        return m
    }

    private func completeAU(_ moment: MomentModel, useful: [(Double, Double)]) {
        let segs = useful.map { "{\"start_time\":\($0.0),\"end_time\":\($0.1),\"why_useful\":\"x\"}" }
            .joined(separator: ",")
        let json = """
        {"moment_id":"\(moment.id.uuidString)","observed":{"summary":"a moment",
         "subjects":[],"events":[],"temporal_order_note":"","useful_segments":[\(segs)]}}
        """
        ctx.insert(MomentUnderstandingModel(
            momentId: moment.id, schemaVersion: "moment_understanding/1",
            framePolicy: "p", promptVersion: "au/1", modelId: "x", nFrames: 24, understandingJSON: json))
    }

    /// A valid, renderable plan over the given Moments: each a straight cut, speed 1.0, keep audio,
    /// output duration <= its source clip length so the deterministic validator passes.
    private func validPlan(_ moments: [MomentModel], format: String = "vertical") -> EditPlanV2 {
        var segs: [EditSegmentV2] = []
        for (i, m) in moments.enumerated() {
            let dur = m.asset?.durationSeconds ?? 5
            let out = min(3.0, max(1.0, dur))
            segs.append(EditSegmentV2(order: i, assetId: m.id.uuidString, sourceStartSeconds: 0,
                                      sourceEndSeconds: out, outputDurationSeconds: out,
                                      speed: 1.0, nativeAudio: "keep", musicAlignment: nil))
        }
        let total = segs.reduce(0) { $0 + $1.outputDurationSeconds }
        return EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: total,
                          outputFormat: format, musicAssetId: nil, feasible: true, segments: segs)
    }

    private func okResult(_ format: String = "vertical") -> RenderResult {
        let (rel, url) = ("rendered/\(UUID().uuidString).mp4", URL(fileURLWithPath: "/dev/null"))
        return RenderResult(relativePath: rel, url: url, durationSeconds: 6.0,
                            renderSize: CGSize(width: 1080, height: 1920))
    }

    /// Pump the main run loop until the coordinator leaves `isCreating` (terminal state reached) or we time out.
    private func awaitSettled(_ coord: StoryCreationCoordinator, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while coord.isCreating && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - Happy path

    func test_happyPath_reachesCompleted_withRealPersistedOutput() async throws {
        let s = newStory()
        let m1 = momentWithFile(s, rel: "media/rc-happy-1.mov", dur: 8); completeAU(m1, useful: [(0, 5)])
        let m2 = momentWithFile(s, rel: "media/rc-happy-2.mov", dur: 8); completeAU(m2, useful: [(0, 5)])

        let plan = validPlan([m1, m2])
        let renderer = FakeRenderer(.ok(okResult()))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(plan)),
                                             renderer: renderer, context: ctx, jobClient: FakeJobClient(.ok(plan)))
        coord.create(for: s)
        await awaitSettled(coord)

        guard case let .completed(output) = coord.state else {
            return XCTFail("expected .completed, got \(coord.state)")
        }
        XCTAssertTrue(renderer.called)
        XCTAssertFalse(coord.isCreating)
        // A REAL persisted output: relative file path + fingerprint + provenance + source ids.
        XCTAssertEqual(output.relativeFilePath?.hasPrefix("rendered/"), true)
        XCTAssertFalse(output.sourceFingerprint.isEmpty)
        XCTAssertEqual(Set(output.sourceMomentIds), Set([m1.id, m2.id]))
        XCTAssertEqual(output.outputFormat, "vertical")
        XCTAssertEqual(output.renderWidth, 1080)
        XCTAssertEqual(output.renderHeight, 1920)
        XCTAssertTrue(output.editPlanProvenance.contains("edit_plan/2"))
        // Persisted onto the Story and status unchanged (Create != Complete).
        XCTAssertTrue(s.generatedOutputs.contains { $0.id == output.id })
        XCTAssertEqual(s.status, .active)
    }

    // A STALE persisted planJobId (server-side job gone -> poll 404) must NOT dead-end: the coordinator clears
    // the stale handle, resubmits ONE fresh job for the same operation_id, and reaches .completed. Regression
    // for "Couldn't reach the Edit Planner: unexpected status 404".
    func test_staleJobId_404_resubmitsAndCompletes() async throws {
        let s = newStory()
        let m1 = momentWithFile(s, rel: "media/rc-stale-1.mov", dur: 8); completeAU(m1, useful: [(0, 5)])
        let m2 = momentWithFile(s, rel: "media/rc-stale-2.mov", dur: 8); completeAU(m2, useful: [(0, 5)])
        // Simulate a prior session that left a persisted (now-stale) job handle on the Story.
        s.planOperationId = "op-stale"; s.planJobId = "stale-job-gone"; try ctx.save()

        let plan = validPlan([m1, m2])
        let renderer = FakeRenderer(.ok(okResult()))
        let fake = FakeJobClient(.staleThenOk(plan))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(plan)),
                                             renderer: renderer, context: ctx, jobClient: fake)
        coord.create(for: s)          // reuses the stale planJobId first (reusedExistingJob == true)
        await awaitSettled(coord)

        guard case .completed = coord.state else {
            return XCTFail("expected .completed after stale-job recovery, got \(coord.state)")
        }
        XCTAssertEqual(fake.submitCount, 1, "exactly one fresh submit after the stale 404 (no duplicate)")
        XCTAssertGreaterThanOrEqual(fake.pollCount, 2, "first poll 404'd, second poll on the resubmitted job")
        XCTAssertTrue(renderer.called)
    }

    // MARK: - Planner failures (never fabricate a plan)

    func test_planner503_failsWithoutFabricating() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/rc-503.mov", dur: 6); completeAU(m, useful: [(0, 4)])
        let renderer = FakeRenderer(.ok(okResult()))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .fail(.unavailable)),
                                             renderer: renderer, context: ctx, jobClient: FakeJobClient(.failUnavailable))
        coord.create(for: s)
        await awaitSettled(coord)

        guard case .failed = coord.state else { return XCTFail("expected .failed, got \(coord.state)") }
        XCTAssertFalse(renderer.called)                 // no render on a 503
        XCTAssertTrue(s.generatedOutputs.isEmpty)       // nothing persisted — no fabricated montage
    }

    func test_planner422_failsWithReason() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/rc-422.mov", dur: 6); completeAU(m, useful: [(0, 4)])
        let coord = StoryCreationCoordinator(
            planner: FakePlanner(behavior: .fail(.infeasible("not enough usable footage"))),
            renderer: FakeRenderer(.ok(okResult())), context: ctx)
        coord.create(for: s)
        await awaitSettled(coord)

        guard case let .failed(message) = coord.state else { return XCTFail("expected .failed, got \(coord.state)") }
        XCTAssertTrue(message.contains("not enough usable footage"))   // carries the server reason
        XCTAssertTrue(s.generatedOutputs.isEmpty)
    }

    // MARK: - Invalid plan -> fails at validating, renderer NEVER called

    func test_invalidPlan_missingMoment_failsAtValidating_rendererNotCalled() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/rc-inv-missing.mov", dur: 6); completeAU(m, useful: [(0, 4)])
        // A plan referencing an id that resolves to no local file.
        let bad = EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: 3, outputFormat: "vertical",
                             musicAssetId: nil, feasible: true,
                             segments: [EditSegmentV2(order: 0, assetId: UUID().uuidString, sourceStartSeconds: 0,
                                                      sourceEndSeconds: 3, outputDurationSeconds: 3,
                                                      speed: 1.0, nativeAudio: "keep", musicAlignment: nil)])
        let renderer = FakeRenderer(.ok(okResult()))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(bad)), renderer: renderer, context: ctx, jobClient: FakeJobClient(.ok(bad)))
        coord.create(for: s)
        await awaitSettled(coord)

        guard case .failed = coord.state else { return XCTFail("expected .failed, got \(coord.state)") }
        XCTAssertFalse(renderer.called)                 // validator ran BEFORE AVFoundation
    }

    func test_invalidPlan_speedOutOfRange_failsAtValidating() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/rc-inv-speed.mov", dur: 10); completeAU(m, useful: [(0, 6)])
        let bad = EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: 2, outputFormat: "vertical",
                             musicAssetId: nil, feasible: true,
                             segments: [EditSegmentV2(order: 0, assetId: m.id.uuidString, sourceStartSeconds: 0,
                                                      sourceEndSeconds: 4, outputDurationSeconds: 2,
                                                      speed: 3.0, nativeAudio: "keep", musicAlignment: nil)])
        let renderer = FakeRenderer(.ok(okResult()))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(bad)), renderer: renderer, context: ctx, jobClient: FakeJobClient(.ok(bad)))
        coord.create(for: s)
        await awaitSettled(coord)
        guard case .failed = coord.state else { return XCTFail("expected .failed, got \(coord.state)") }
        XCTAssertFalse(renderer.called)
    }

    func test_invalidPlan_unsupportedTransition_failsAtValidating() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/rc-inv-trans.mov", dur: 10); completeAU(m, useful: [(0, 6)])
        let bad = EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: 3, outputFormat: "vertical",
                             musicAssetId: nil, feasible: true,
                             segments: [EditSegmentV2(order: 0, assetId: m.id.uuidString, sourceStartSeconds: 0,
                                                      sourceEndSeconds: 3, outputDurationSeconds: 3, speed: 1.0,
                                                      nativeAudio: "keep", musicAlignment: nil,
                                                      transition: Transition(type: "wipe", durationSeconds: 0.3))])
        let renderer = FakeRenderer(.ok(okResult()))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(bad)), renderer: renderer, context: ctx, jobClient: FakeJobClient(.ok(bad)))
        coord.create(for: s)
        await awaitSettled(coord)
        guard case .failed = coord.state else { return XCTFail("expected .failed, got \(coord.state)") }
        XCTAssertFalse(renderer.called)
    }

    /// Direct unit coverage of the static validator (no async orchestration).
    func test_validator_direct_cases() {
        let id = UUID()
        let media = [MomentMedia(momentId: id, relativePath: "media/x.mov", durationSeconds: 6)]
        let resolver: (String) -> URL? = { $0.lowercased() == id.uuidString.lowercased() ? URL(fileURLWithPath: "/x") : nil }
        func plan(_ seg: EditSegmentV2, feasible: Bool = true) -> EditPlanV2 {
            EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: seg.outputDurationSeconds,
                       outputFormat: "vertical", musicAssetId: nil, feasible: feasible, segments: [seg])
        }
        // valid
        XCTAssertNil(StoryCreationCoordinator.validate(
            plan: plan(EditSegmentV2(order: 0, assetId: id.uuidString, sourceStartSeconds: 0, sourceEndSeconds: 3,
                                     outputDurationSeconds: 3, speed: 1.0, nativeAudio: "keep", musicAlignment: nil)),
            resolver: resolver, includedMedia: media))
        // infeasible flag
        XCTAssertNotNil(StoryCreationCoordinator.validate(
            plan: plan(EditSegmentV2(order: 0, assetId: id.uuidString, sourceStartSeconds: 0, sourceEndSeconds: 3,
                                     outputDurationSeconds: 3, speed: 1.0, nativeAudio: "keep", musicAlignment: nil),
                       feasible: false),
            resolver: resolver, includedMedia: media))
        // bad source range
        XCTAssertNotNil(StoryCreationCoordinator.validate(
            plan: plan(EditSegmentV2(order: 0, assetId: id.uuidString, sourceStartSeconds: 3, sourceEndSeconds: 1,
                                     outputDurationSeconds: 2, speed: 1.0, nativeAudio: "keep", musicAlignment: nil)),
            resolver: resolver, includedMedia: media))
        // bad native audio
        XCTAssertNotNil(StoryCreationCoordinator.validate(
            plan: plan(EditSegmentV2(order: 0, assetId: id.uuidString, sourceStartSeconds: 0, sourceEndSeconds: 3,
                                     outputDurationSeconds: 3, speed: 1.0, nativeAudio: "boost", musicAlignment: nil)),
            resolver: resolver, includedMedia: media))
    }

    // MARK: - Duplicate-job guard

    func test_duplicateGuard_refusesSecondConcurrentCreation() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/rc-dup.mov", dur: 8); completeAU(m, useful: [(0, 5)])
        let renderer = FakeRenderer(.blockUntilCancel)      // keep the first run in-flight
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))),
                                             renderer: renderer, context: ctx, jobClient: FakeJobClient(.ok(validPlan([m]))))
        coord.create(for: s)
        // let it get into the blocking render
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(coord.isCreating)
        // second call must be refused — it does not start a second job
        coord.create(for: s)
        XCTAssertTrue(coord.isCreating)
        // clean up: cancel the blocked run
        coord.cancel()
        await awaitSettled(coord)
        XCTAssertEqual(coord.state, .cancelled)
    }

    // MARK: - Cancellation

    func test_cancellation_landsInCancelled_withNoCompletedOutput() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/rc-cancel.mov", dur: 8); completeAU(m, useful: [(0, 5)])
        let renderer = FakeRenderer(.blockUntilCancel)
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))),
                                             renderer: renderer, context: ctx, jobClient: FakeJobClient(.ok(validPlan([m]))))
        coord.create(for: s)
        try? await Task.sleep(nanoseconds: 20_000_000)
        coord.cancel()
        await awaitSettled(coord)

        XCTAssertEqual(coord.state, .cancelled)
        XCTAssertFalse(coord.isCreating)
        XCTAssertTrue(s.generatedOutputs.isEmpty)       // Moments preserved; no completed output persisted
        XCTAssertEqual(s.moments.count, 1)
    }

    // MARK: - Missing prerequisite -> honest failure

    func test_noUsableMoments_failsHonestly() async throws {
        let s = newStory()   // no Moments at all
        let renderer = FakeRenderer(.ok(okResult()))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([]))),
                                             renderer: renderer, context: ctx, jobClient: FakeJobClient(.ok(validPlan([]))))
        coord.create(for: s)
        await awaitSettled(coord)
        guard case .failed = coord.state else { return XCTFail("expected .failed, got \(coord.state)") }
        XCTAssertFalse(renderer.called)                 // never even reached planning's render
    }

    // MARK: - Staleness fingerprint

    func test_fingerprint_equalForSameSet_orderIndependent() {
        let s = newStory()
        let a = momentWithFile(s, rel: "media/fp-a.mov", dur: 5)
        let b = momentWithFile(s, rel: "media/fp-b.mov", dur: 5)
        let f1 = StoryCreationCoordinator.fingerprint(for: [a.id, b.id], story: s)
        let f2 = StoryCreationCoordinator.fingerprint(for: [b.id, a.id], story: s)   // reversed order
        XCTAssertEqual(f1, f2)                                                        // sorted set -> order-independent
    }

    func test_fingerprint_differsWhenAssetRelativePathChanges() {
        let s = newStory()
        let a = momentWithFile(s, rel: "media/fp-rel-1.mov", dur: 5)
        let before = StoryCreationCoordinator.fingerprint(for: [a.id], story: s)
        // Replace the media under the SAME Moment id (new relativePath) -> must invalidate.
        a.asset?.relativePath = "media/fp-rel-2.mov"
        let after = StoryCreationCoordinator.fingerprint(for: [a.id], story: s)
        XCTAssertNotEqual(before, after)
    }

    func test_fingerprint_differsWhenAssetDurationChanges() {
        let s = newStory()
        let a = momentWithFile(s, rel: "media/fp-dur.mov", dur: 5)
        let before = StoryCreationCoordinator.fingerprint(for: [a.id], story: s)
        a.asset?.durationSeconds = 9.0                 // re-trim under an unchanged Moment id
        let after = StoryCreationCoordinator.fingerprint(for: [a.id], story: s)
        XCTAssertNotEqual(before, after)
    }

    func test_fingerprint_differsOnAddAndRemoveMoment() {
        let s = newStory()
        let a = momentWithFile(s, rel: "media/fp-set-a.mov", dur: 5)
        let f1 = StoryCreationCoordinator.fingerprint(for: [a.id], story: s)
        let b = momentWithFile(s, rel: "media/fp-set-b.mov", dur: 5)
        let f2 = StoryCreationCoordinator.fingerprint(for: [a.id, b.id], story: s)   // added
        XCTAssertNotEqual(f1, f2)
        let f3 = StoryCreationCoordinator.fingerprint(for: [b.id], story: s)         // removed a
        XCTAssertNotEqual(f2, f3)
        XCTAssertNotEqual(f1, f3)
    }

    func test_isOutputStale_tracksCurrentStory() {
        let s = newStory()
        let a = momentWithFile(s, rel: "media/stale-a.mov", dur: 5)
        let fp = StoryCreationCoordinator.fingerprint(for: [a.id], story: s)
        let output = GeneratedOutputModel(title: "t", durationSeconds: 3, momentIds: [a.id],
                                          relativeFilePath: "rendered/x.mp4", sourceMomentIds: [a.id],
                                          sourceFingerprint: fp)
        XCTAssertFalse(StoryCreationCoordinator.isOutputStale(output: output, story: s))
        a.asset?.relativePath = "media/stale-a-REPLACED.mov"
        XCTAssertTrue(StoryCreationCoordinator.isOutputStale(output: output, story: s))
    }

    // R7 regression: "Moment N" numbering for Customize/Revise must come from the PLANNER-USABLE set (local
    // The PLANNER PAYLOAD set (usableNumberedMoments) is local-file + completed-AU only — a cloud-only shell or
    // an un-analyzed Moment is not in moments[]. (This is the planner input filter, NOT the picker numbering.)
    func test_usableNumbering_excludesCloudOnlyAndNoAUMoments() {
        let s = newStory()
        let m1 = momentWithFile(s, rel: "media/num-1.mov", dur: 6); completeAU(m1, useful: [(0, 4)])  // usable
        let m2 = momentWithFile(s, rel: "media/num-2.mov", dur: 6)                                    // file but NO AU
        // A cloud-only shell: asset present but NO local file on disk + evicted (R7-C shape).
        let shellAsset = AssetModel(relativePath: "media/evicted-shell.mov", durationSeconds: 6, source: .directed)
        shellAsset.localAvailability = .evicted
        let m3 = MomentModel(source: .directed, asset: shellAsset)
        ctx.insert(shellAsset); ctx.insert(m3)
        if let lnk = s.attach(m3) { ctx.insert(lnk) }
        completeAU(m3, useful: [(0, 4)])   // has AU but no local bytes -> still not usable
        try? ctx.save()

        let usable = EditPlanRequestBuilder.usableNumberedMoments(for: s, context: ctx)
        XCTAssertEqual(usable.map { $0.id }, [m1.id], "planner payload = only Moments with BOTH a local file AND completed AU")
        _ = m2
    }

    // Owner P0: the PICKER / "Moment N" numbering must include EVERY linked Moment — cloud-only included — by
    // stable StoryMomentLink order, with a localAvailable flag for the badge (never hidden, never renumbered by
    // availability). This is what makes "Moment N" the same Moment on every device.
    func test_pickerNumbering_includesAllLinkedMomentsWithAvailabilityFlag() {
        let s = newStory()
        let m1 = momentWithFile(s, rel: "media/all-1.mov", dur: 6); completeAU(m1, useful: [(0, 4)])  // local
        // Cloud-only shell (no local bytes) — must STILL be numbered.
        let shellAsset = AssetModel(relativePath: "media/all-cloud.mov", durationSeconds: 6, source: .directed)
        shellAsset.localAvailability = .evicted
        let m2 = MomentModel(source: .directed, asset: shellAsset)
        ctx.insert(shellAsset); ctx.insert(m2)
        if let lnk = s.attach(m2) { ctx.insert(lnk) }
        try? ctx.save()

        let numbering = StoryMomentNumbering(story: s.moments)
        XCTAssertEqual(numbering.count, 2, "ALL linked Moments are numbered, cloud-only included")
        XCTAssertEqual(numbering.id(forNumber: 1), m1.id)
        XCTAssertEqual(numbering.id(forNumber: 2), m2.id, "cloud-only Moment keeps its stable number")
        XCTAssertEqual(numbering.items.first { $0.id == m1.id }?.localAvailable, true)
        XCTAssertEqual(numbering.items.first { $0.id == m2.id }?.localAvailable, false, "cloud-only -> cloud badge")
    }

    // invalid_after_repair ROOT-CAUSE regression: a directive referencing a Moment NOT in the planner payload
    // (no AU yet, or cloud-only, or stale) is caught by the preflight so the app blocks honestly instead of
    // submitting a doomed request. Proven against the real validator that such a directive -> invalid_after_repair.
    func test_directiveEligibility_classifiesIneligibleReferences() throws {
        let s = newStory()
        let mOK = momentWithFile(s, rel: "media/elig-ok.mov", dur: 6); completeAU(mOK, useful: [(0, 4)])  // file+AU
        let mNoAU = momentWithFile(s, rel: "media/elig-noau.mov", dur: 6)                                 // file, NO AU
        // Cloud-only shell (no local bytes, backed up) -> restorable.
        let shell = AssetModel(relativePath: "media/elig-cloud.mov", durationSeconds: 6, source: .directed)
        shell.localAvailability = .evicted
        let mCloud = MomentModel(source: .directed, asset: shell); mCloud.cloudMediaId = "cm-x"
        ctx.insert(shell); ctx.insert(mCloud); if let l = s.attach(mCloud) { ctx.insert(l) }
        try ctx.save()

        var d = ResolvedDirectives(); d.opening = mNoAU.id; d.mustInclude = [mCloud.id]
        s.creativeDirectivesJSON = d.toWireJSON(); try ctx.save()
        let e = EditPlanRequestBuilder.directiveEligibility(for: s, context: ctx)
        XCTAssertFalse(e.allEligible)
        XCTAssertEqual(e.ineligibleNeedsAU, [mNoAU.id], "a local-but-unanalyzed referenced Moment needs AU")
        XCTAssertEqual(e.ineligibleNeedsRestore, [mCloud.id], "a cloud-only referenced Moment needs restore")

        var d2 = ResolvedDirectives(); d2.opening = mOK.id
        s.creativeDirectivesJSON = d2.toWireJSON(); try ctx.save()
        XCTAssertTrue(EditPlanRequestBuilder.directiveEligibility(for: s, context: ctx).allEligible)
    }

    // MARK: - Music-ready seam

    func test_noMusic_threadsNilSoundtrack() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/rc-nomusic.mov", dur: 8); completeAU(m, useful: [(0, 5)])
        let renderer = FakeRenderer(.ok(okResult()))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))),
                                             renderer: renderer, context: ctx, jobClient: FakeJobClient(.ok(validPlan([m]))))   // no music params -> all nil
        coord.create(for: s)
        await awaitSettled(coord)
        guard case .completed = coord.state else { return XCTFail("expected .completed, got \(coord.state)") }
        XCTAssertNil(renderer.seenSoundtrackURL)        // R-c: nil soundtrack threaded
        XCTAssertNil(renderer.seenMusicAnalysis)
    }

    func test_futureMusic_soundtrackURLThreadsIntoMediaEngineInputs() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/rc-music.mov", dur: 8); completeAU(m, useful: [(0, 5)])
        let soundtrack = URL(fileURLWithPath: "/tmp/soundtrack.m4a")
        let analysis = MusicAnalysisV1(durationSeconds: 20, bpm: 120, tempoReliable: true,
                                       beats: [0, 0.5], downbeats: [0], highlightWindow: nil)
        let renderer = FakeRenderer(.ok(okResult()))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))),
                                             renderer: renderer, context: ctx, jobClient: FakeJobClient(.ok(validPlan([m]))),
                                             musicAnalysis: analysis, soundtrackURL: soundtrack)
        coord.create(for: s)
        await awaitSettled(coord)
        guard case .completed = coord.state else { return XCTFail("expected .completed, got \(coord.state)") }
        XCTAssertEqual(renderer.seenSoundtrackURL, soundtrack)      // future-music seam threads through
        XCTAssertNotNil(renderer.seenMusicAnalysis)
    }

    // MARK: - P0 recovery (Phases 1-3, 5)

    /// A deliberate create writes ONE durable pending row (phase plan_ready->deleted on save) and leaves none
    /// behind on success (exactly-once). Covers Phase 1 persistence + Phase 3 finalize.
    func test_recovery_successDeletesPendingRow_exactlyOnce() async throws {
        let s = newStory()
        let m1 = momentWithFile(s, rel: "media/rec-1.mov", dur: 8); completeAU(m1, useful: [(0, 5)])
        let plan = validPlan([m1])
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(plan)),
                                             renderer: FakeRenderer(.ok(okResult())), context: ctx,
                                             jobClient: FakeJobClient(.ok(plan)))
        coord.create(for: s)
        await awaitSettled(coord)
        guard case .completed = coord.state else { return XCTFail("expected .completed, got \(coord.state)") }
        // Exactly-once: the saved output means NO recoverable pending row remains.
        let rows = try ctx.fetch(FetchDescriptor<PendingOperationModel>())
        XCTAssertTrue(rows.allSatisfy { !$0.isRecoverable } || rows.isEmpty,
                      "a saved operation must leave no recoverable pending row")
        XCTAssertFalse(coord.hasRecoverablePendingOperation(storyId: s.id))
        XCTAssertEqual(s.generatedOutputs.count, 1)
    }

    /// Phase 3 render-resume: a pending row at plan_ready with a saved plan renders DIRECTLY (no poll, no new
    /// submit) and produces exactly one version. Simulates reopen after the plan completed while backgrounded.
    func test_recovery_renderResumeFromSavedPlan_noNewInference() async throws {
        let s = newStory()
        let m1 = momentWithFile(s, rel: "media/rec-pr-1.mov", dur: 8); completeAU(m1, useful: [(0, 5)])
        let plan = validPlan([m1])
        let planJSON = String(data: try StoryContractCoding.encoder().encode(plan), encoding: .utf8)!
        // Seed a completed-but-unrendered operation, as a background completion would have left it.
        let op = PendingOperationModel(storyId: s.id, operationId: "op-pr", jobId: "job-pr",
                                       operationType: "another_version", phase: "plan_ready",
                                       jobStatus: "completed", planJSON: planJSON,
                                       outputFormat: "vertical")
        ctx.insert(op); try ctx.save()

        let jobClient = FakeJobClient(.failUnavailable)   // would FAIL if the resume (wrongly) re-polled/submitted
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .fail(.unavailable)),
                                             renderer: FakeRenderer(.ok(okResult())), context: ctx,
                                             jobClient: jobClient)
        XCTAssertTrue(coord.resumePendingOperation(for: s))
        await awaitSettled(coord)
        guard case .completed = coord.state else { return XCTFail("expected .completed, got \(coord.state)") }
        XCTAssertEqual(jobClient.submitCount, 0, "render-resume must NOT submit a new job")
        XCTAssertEqual(s.generatedOutputs.count, 1, "exactly one recovered version")
        XCTAssertFalse(coord.hasRecoverablePendingOperation(storyId: s.id))
    }

    /// Amendment: render-resume from a saved plan works for ALL THREE operation types (original /
    /// another_version / revision) — one shared lifecycle, keyed on operationType, not hardcoded to Explore.
    func test_recovery_renderResume_allOperationTypes() async throws {
        for opType in ["original", "another_version", "revision"] {
            let s = newStory()
            let m1 = momentWithFile(s, rel: "media/rec-\(opType)-1.mov", dur: 8); completeAU(m1, useful: [(0, 5)])
            let plan = validPlan([m1])
            let planJSON = String(data: try StoryContractCoding.encoder().encode(plan), encoding: .utf8)!
            let op = PendingOperationModel(storyId: s.id, operationId: "op-\(opType)", jobId: "job-\(opType)",
                                           operationType: opType, phase: "plan_ready",
                                           jobStatus: "completed", planJSON: planJSON, outputFormat: "vertical")
            ctx.insert(op); try ctx.save()
            let jobClient = FakeJobClient(.failUnavailable)   // fails if resume wrongly re-polls/submits
            let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .fail(.unavailable)),
                                                 renderer: FakeRenderer(.ok(okResult())), context: ctx,
                                                 jobClient: jobClient)
            XCTAssertTrue(coord.resumePendingOperation(for: s), "\(opType) should resume")
            await awaitSettled(coord)
            guard case .completed(let out) = coord.state else {
                return XCTFail("\(opType): expected .completed, got \(coord.state)")
            }
            XCTAssertEqual(jobClient.submitCount, 0, "\(opType): render-resume must not submit")
            XCTAssertEqual(out.operationType, opType, "\(opType): operationType preserved on the recovered output")
            XCTAssertEqual(s.generatedOutputs.count, 1, "\(opType): exactly one recovered version")
            XCTAssertFalse(coord.hasRecoverablePendingOperation(storyId: s.id))
        }
    }

    /// Amendment: a queued/running resume (no saved plan yet) RESUMES POLLING the existing job and never
    /// submits a second one — the directives/context already live in the server-side job.
    func test_recovery_queuedResume_reusesJob_noResubmit() async throws {
        let s = newStory()
        let m1 = momentWithFile(s, rel: "media/rec-q-1.mov", dur: 8); completeAU(m1, useful: [(0, 5)])
        let plan = validPlan([m1])
        // A pending op still at 'planning' with NO saved plan -> resume must poll the existing job.
        let op = PendingOperationModel(storyId: s.id, operationId: "op-q", jobId: "job-q",
                                       operationType: "revision", phase: "planning",
                                       jobStatus: "running", outputFormat: "vertical")
        ctx.insert(op); try ctx.save()
        s.planOperationId = "op-q"; s.planJobId = "job-q"; try ctx.save()   // recovery seam
        let jobClient = FakeJobClient(.ok(plan))   // the existing job completes when polled
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(plan)),
                                             renderer: FakeRenderer(.ok(okResult())), context: ctx,
                                             jobClient: jobClient)
        XCTAssertTrue(coord.resumePendingOperation(for: s))
        await awaitSettled(coord)
        guard case .completed = coord.state else { return XCTFail("expected .completed, got \(coord.state)") }
        XCTAssertEqual(jobClient.submitCount, 0, "queued-resume must poll the existing job, not submit a new one")
        XCTAssertEqual(s.generatedOutputs.count, 1)
    }

    /// Phase 5: a deliberate Create Another Version while a recoverable op exists ABANDONS the stale op (no two
    /// non-terminal operations -> no duplicate expensive jobs).
    func test_phase5_deliberateCreateAbandonsStalePending() async throws {
        let s = newStory()
        let m1 = momentWithFile(s, rel: "media/rec-ab-1.mov", dur: 8); completeAU(m1, useful: [(0, 5)])
        let parentPlan = validPlan([m1])
        // First, a completed original so there's a parent to Explore from.
        let c0 = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(parentPlan)),
                                          renderer: FakeRenderer(.ok(okResult())), context: ctx,
                                          jobClient: FakeJobClient(.ok(parentPlan)))
        c0.create(for: s); await awaitSettled(c0)
        guard case .completed(let parent) = c0.state else { return XCTFail("parent create failed") }

        // Seed a stale recoverable pending op (as if a prior another_version was interrupted).
        let stale = PendingOperationModel(storyId: s.id, operationId: "op-stale", jobId: "job-stale",
                                          operationType: "another_version", phase: "planning")
        ctx.insert(stale); try ctx.save()
        XCTAssertTrue(c0.hasRecoverablePendingOperation(storyId: s.id))

        // Deliberate new version must abandon the stale op.
        let c1 = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(parentPlan)),
                                          renderer: FakeRenderer(.ok(okResult())), context: ctx,
                                          jobClient: FakeJobClient(.ok(parentPlan)))
        c1.createAnotherVersion(for: s, from: parent)
        await awaitSettled(c1)
        let staleRows = try ctx.fetch(FetchDescriptor<PendingOperationModel>())
            .filter { $0.operationId == "op-stale" }
        XCTAssertTrue(staleRows.isEmpty, "the stale pending op must be abandoned by a deliberate new version")
    }

    /// Phase 5: a failed operation keeps its pending row (phase not saved) with a failure category, so reopen
    /// surfaces the failure honestly rather than silently losing it.
    func test_recovery_failureKeepsRowWithCategory() async throws {
        let s = newStory()
        let m1 = momentWithFile(s, rel: "media/rec-f-1.mov", dur: 8); completeAU(m1, useful: [(0, 5)])
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .fail(.unavailable)),
                                             renderer: FakeRenderer(.ok(okResult())), context: ctx,
                                             jobClient: FakeJobClient(.failInfeasible("too much material")))
        coord.create(for: s)
        await awaitSettled(coord)
        guard case .failed = coord.state else { return XCTFail("expected .failed, got \(coord.state)") }
        let rows = try ctx.fetch(FetchDescriptor<PendingOperationModel>()).filter { $0.storyId == s.id }
        XCTAssertEqual(rows.first?.failureCategory, "material_infeasible")
    }
}
