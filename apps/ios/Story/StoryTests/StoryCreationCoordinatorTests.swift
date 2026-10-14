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
    @MainActor
    private final class FakeJobClient: EditPlanJobClienting {
        enum Behavior { case ok(EditPlanV2), failInfeasible(String), failUnavailable, throwTransport }
        var behavior: Behavior
        private(set) var submitCount = 0
        private(set) var lastRequest: EditPlanRequestDTO?
        init(_ b: Behavior) { behavior = b }

        func submit(_ request: EditPlanRequestDTO, operationId: String, owner: String,
                    approach: EditingApproach, sheets: [MomentContactSheet], creativeBrief: String?,
                    critiqueRevision: Bool) async throws -> String {
            submitCount += 1
            lastRequest = request
            return "fake-job-\(operationId)"
        }

        func pollUntilTerminal(jobId: String, maxSeconds: Int,
                               shouldCancel: @MainActor () -> Bool,
                               onState: @MainActor (EditPlanJobState) -> Void) async throws -> EditPlanJobState {
            if shouldCancel() { throw CancellationError() }
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
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(plan)), jobClient: FakeJobClient(.ok(plan)),
                                             renderer: renderer, context: ctx)
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

    // MARK: - Planner failures (never fabricate a plan)

    func test_planner503_failsWithoutFabricating() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/rc-503.mov", dur: 6); completeAU(m, useful: [(0, 4)])
        let renderer = FakeRenderer(.ok(okResult()))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .fail(.unavailable)), jobClient: FakeJobClient(.failUnavailable),
                                             renderer: renderer, context: ctx)
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
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(bad)), jobClient: FakeJobClient(.ok(bad)), renderer: renderer, context: ctx)
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
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(bad)), jobClient: FakeJobClient(.ok(bad)), renderer: renderer, context: ctx)
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
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(bad)), jobClient: FakeJobClient(.ok(bad)), renderer: renderer, context: ctx)
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
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))), jobClient: FakeJobClient(.ok(validPlan([m]))),
                                             renderer: renderer, context: ctx)
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
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))), jobClient: FakeJobClient(.ok(validPlan([m]))),
                                             renderer: renderer, context: ctx)
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
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([]))), jobClient: FakeJobClient(.ok(validPlan([]))),
                                             renderer: renderer, context: ctx)
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

    // MARK: - Music-ready seam

    func test_noMusic_threadsNilSoundtrack() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/rc-nomusic.mov", dur: 8); completeAU(m, useful: [(0, 5)])
        let renderer = FakeRenderer(.ok(okResult()))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))), jobClient: FakeJobClient(.ok(validPlan([m]))),
                                             renderer: renderer, context: ctx)   // no music params -> all nil
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
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))), jobClient: FakeJobClient(.ok(validPlan([m]))),
                                             renderer: renderer, context: ctx,
                                             musicAnalysis: analysis, soundtrackURL: soundtrack)
        coord.create(for: s)
        await awaitSettled(coord)
        guard case .completed = coord.state else { return XCTFail("expected .completed, got \(coord.state)") }
        XCTAssertEqual(renderer.seenSoundtrackURL, soundtrack)      // future-music seam threads through
        XCTAssertNotNil(renderer.seenMusicAnalysis)
    }
}
