import AVFoundation
import SwiftData
import XCTest
@testable import Story

// R-c Batch D — failure & regression coverage. DETERMINISTIC: injected planner/renderer fakes, no network, no
// real AVFoundation. Fills the gaps left by Batch A/B/C (transport failure, retry-after-failure, bad native_audio
// orchestration, cancel source-preservation, stale-keeps-output, failed-recreate-keeps-output, and the
// cross-cutting "no failure path deletes AssetModel/MomentModel"). Mirrors the fakes proven in
// StoryCreationCoordinatorTests. Device-gated items (actual export/partial-file deletion inside MediaEngineV1,
// real playback/Photos/share) are NOT asserted here.
@MainActor
final class StoryCreationFailureTests: XCTestCase {

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

    // MARK: - Fakes (same shape as StoryCreationCoordinatorTests)

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

    /// A planner that fails on the FIRST call and succeeds on the SECOND (for retry()).
    private final class FlakyPlanner: EditPlanning, @unchecked Sendable {
        let firstError: EditPlannerServiceError
        let thenPlan: EditPlanV2
        private(set) var calls = 0
        init(firstError: EditPlannerServiceError, thenPlan: EditPlanV2) {
            self.firstError = firstError; self.thenPlan = thenPlan
        }
        func plan(_ request: EditPlanRequestDTO) async throws -> EditPlanV2 {
            calls += 1
            if calls == 1 { throw firstError }
            return thenPlan
        }
    }

    private final class FakeRenderer: StoryRendering, @unchecked Sendable {
        enum Behavior { case ok(RenderResult), fail(MediaEngineError), blockUntilCancel }
        let behavior: Behavior
        private(set) var callCount = 0
        var called: Bool { callCount > 0 }
        init(_ b: Behavior) { behavior = b }
        func render(_ inputs: MediaEngineInputs,
                    progress: ((Float) -> Void)?,
                    shouldCancel: (() -> Bool)?) async throws -> RenderResult {
            callCount += 1
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

    private func newStory() -> StoryModel {
        let s = StoryModel(title: "Learning Guitar", intentRawText: "x", intentTheme: "growth",
                           intentTone: "warm", intentSummary: "y")
        s.intentTargetDurationSeconds = 9
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
        ctx.insert(asset)
        let m = MomentModel(source: .directed, asset: asset); ctx.insert(m); if let _lnk = story.attach(m) { ctx.insert(_lnk) }
        return m
    }

    private func completeAU(_ moment: MomentModel) {
        let json = """
        {"moment_id":"\(moment.id.uuidString)","observed":{"summary":"a","subjects":[],"events":[],
         "temporal_order_note":"","useful_segments":[{"start_time":0.0,"end_time":3.0,"why_useful":"x"}]}}
        """
        ctx.insert(MomentUnderstandingModel(momentId: moment.id, schemaVersion: "moment_understanding/1",
            framePolicy: "p", promptVersion: "au/1", modelId: "x", nFrames: 24, understandingJSON: json))
    }

    private func validPlan(_ moments: [MomentModel]) -> EditPlanV2 {
        var segs: [EditSegmentV2] = []
        for (i, m) in moments.enumerated() {
            let out = min(3.0, max(1.0, m.asset?.durationSeconds ?? 5))
            segs.append(EditSegmentV2(order: i, assetId: m.id.uuidString, sourceStartSeconds: 0,
                                      sourceEndSeconds: out, outputDurationSeconds: out,
                                      speed: 1.0, nativeAudio: "keep", musicAlignment: nil))
        }
        let total = segs.reduce(0) { $0 + $1.outputDurationSeconds }
        return EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: total,
                          outputFormat: "vertical", musicAssetId: nil, feasible: true, segments: segs)
    }

    private func okResult() -> RenderResult {
        RenderResult(relativePath: "rendered/\(UUID().uuidString).mp4", url: URL(fileURLWithPath: "/dev/null"),
                     durationSeconds: 6.0, renderSize: CGSize(width: 1080, height: 1920))
    }

    private func awaitSettled(_ c: StoryCreationCoordinator, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while c.isCreating && Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    /// Count of persisted AssetModel + MomentModel (source-preservation assertion).
    private func counts() -> (assets: Int, moments: Int) {
        let a = (try? ctx.fetch(FetchDescriptor<AssetModel>()))?.count ?? -1
        let m = (try? ctx.fetch(FetchDescriptor<MomentModel>()))?.count ?? -1
        return (a, m)
    }

    // MARK: - 1. Transport failure (the gap: 503/422 were covered, transport was not)

    func test_transportFailure_failsHonestly_noOutput_sourcePreserved() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/bd-transport.mov", dur: 6); completeAU(m)
        let before = counts()
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .fail(.transport(underlying))),
                                             renderer: FakeRenderer(.ok(okResult())), context: ctx)
        coord.create(for: s)
        await awaitSettled(coord)

        guard case .failed = coord.state else { return XCTFail("expected .failed, got \(coord.state)") }
        XCTAssertTrue(s.generatedOutputs.isEmpty)              // no fabricated montage, nothing persisted
        XCTAssertEqual(counts().assets, before.assets)        // source Asset untouched
        XCTAssertEqual(counts().moments, before.moments)      // source Moment untouched
    }

    // MARK: - 2. 503 -> retry() allowed, no partial

    func test_503_thenRetrySucceeds() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/bd-503retry.mov", dur: 6); completeAU(m)
        let planner = FlakyPlanner(firstError: .unavailable, thenPlan: validPlan([m]))
        let coord = StoryCreationCoordinator(planner: planner, renderer: FakeRenderer(.ok(okResult())), context: ctx)

        coord.create(for: s)
        await awaitSettled(coord)
        guard case .failed = coord.state else { return XCTFail("expected .failed first, got \(coord.state)") }
        XCTAssertTrue(s.generatedOutputs.isEmpty)              // no partial output after 503

        coord.retry()                                         // retry() is allowed from .failed
        await awaitSettled(coord)
        guard case .completed = coord.state else { return XCTFail("expected .completed after retry, got \(coord.state)") }
        XCTAssertEqual(planner.calls, 2)
        XCTAssertEqual(s.generatedOutputs.count, 1)
    }

    func test_retry_isNoOp_whenNotFailed() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/bd-retrynoop.mov", dur: 6); completeAU(m)
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))),
                                             renderer: FakeRenderer(.ok(okResult())), context: ctx)
        coord.retry()                                         // state is .idle -> no-op
        XCTAssertFalse(coord.isCreating)
        XCTAssertEqual(coord.state, .idle)
    }

    // MARK: - 4. invalid plan: bad native_audio (orchestration) -> failed at validating, renderer not called

    func test_invalidPlan_badNativeAudio_failsAtValidating_rendererNotCalled() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/bd-badaudio.mov", dur: 10); completeAU(m)
        let bad = EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: 3, outputFormat: "vertical",
                             musicAssetId: nil, feasible: true,
                             segments: [EditSegmentV2(order: 0, assetId: m.id.uuidString, sourceStartSeconds: 0,
                                                      sourceEndSeconds: 3, outputDurationSeconds: 3, speed: 1.0,
                                                      nativeAudio: "boost", musicAlignment: nil)])
        let renderer = FakeRenderer(.ok(okResult()))
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(bad)), renderer: renderer, context: ctx)
        coord.create(for: s)
        await awaitSettled(coord)
        guard case .failed = coord.state else { return XCTFail("expected .failed, got \(coord.state)") }
        XCTAssertFalse(renderer.called)                       // validator ran before AVFoundation
        XCTAssertTrue(s.generatedOutputs.isEmpty)
    }

    // MARK: - 5/10. cancel during rendering -> cancelled, source (Asset + Moment) preserved

    func test_cancelDuringRendering_preservesSourceAssetsAndMoments() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/bd-cancel.mov", dur: 8); completeAU(m)
        let before = counts()
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))),
                                             renderer: FakeRenderer(.blockUntilCancel), context: ctx)
        coord.create(for: s)
        try? await Task.sleep(nanoseconds: 20_000_000)        // let it enter rendering
        coord.cancel()
        await awaitSettled(coord)

        XCTAssertEqual(coord.state, .cancelled)
        XCTAssertTrue(s.generatedOutputs.isEmpty)             // no completed output
        XCTAssertEqual(counts().assets, before.assets)        // AssetModel preserved
        XCTAssertEqual(counts().moments, before.moments)      // MomentModel preserved
        XCTAssertNotNil(s.moments.first?.asset)               // the Moment still owns its asset
    }

    // MARK: - 8. staleness does NOT delete the prior successful output

    func test_staleOutput_isNotDeleted() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/bd-stale.mov", dur: 8); completeAU(m)
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))),
                                             renderer: FakeRenderer(.ok(okResult())), context: ctx)
        coord.create(for: s)
        await awaitSettled(coord)
        guard case let .completed(output) = coord.state else { return XCTFail("expected .completed") }
        XCTAssertEqual(s.generatedOutputs.count, 1)
        XCTAssertFalse(StoryCreationCoordinator.isOutputStale(output: output, story: s))

        // Replace the media under the SAME Moment id -> output becomes stale, but is NOT removed.
        m.asset?.relativePath = "media/bd-stale-REPLACED.mov"
        XCTAssertTrue(StoryCreationCoordinator.isOutputStale(output: output, story: s))
        XCTAssertEqual(s.generatedOutputs.count, 1)           // still present
        XCTAssertTrue(s.generatedOutputs.contains { $0.id == output.id })
    }

    // MARK: - 9. a FAILED re-create keeps the old successful output

    func test_failedRecreate_keepsPriorSuccess() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/bd-recreate.mov", dur: 8); completeAU(m)
        // First: a successful create.
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))),
                                             renderer: FakeRenderer(.ok(okResult())), context: ctx)
        coord.create(for: s)
        await awaitSettled(coord)
        guard case let .completed(first) = coord.state else { return XCTFail("expected first .completed") }
        XCTAssertEqual(s.generatedOutputs.count, 1)

        // Re-create with a planner that now fails (503). The prior success MUST survive.
        let coord2 = StoryCreationCoordinator(planner: FakePlanner(behavior: .fail(.unavailable)),
                                              renderer: FakeRenderer(.ok(okResult())), context: ctx)
        coord2.create(for: s)
        await awaitSettled(coord2)
        guard case .failed = coord2.state else { return XCTFail("expected re-create .failed, got \(coord2.state)") }
        XCTAssertEqual(s.generatedOutputs.count, 1)           // old output not replaced on failed re-create
        XCTAssertTrue(s.generatedOutputs.contains { $0.id == first.id })
    }

    // MARK: - 9b. a SUCCESSFUL re-create ADDS a new output (prior success retained)

    func test_successfulRecreate_addsNewOutput_keepsOld() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/bd-recreate2.mov", dur: 8); completeAU(m)
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))),
                                             renderer: FakeRenderer(.ok(okResult())), context: ctx)
        coord.create(for: s)
        await awaitSettled(coord)
        guard case let .completed(first) = coord.state else { return XCTFail("expected first .completed") }

        let coord2 = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))),
                                              renderer: FakeRenderer(.ok(okResult())), context: ctx)
        coord2.create(for: s)
        await awaitSettled(coord2)
        guard case let .completed(second) = coord2.state else { return XCTFail("expected second .completed") }
        XCTAssertEqual(s.generatedOutputs.count, 2)           // ADD, not overwrite
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(s.generatedOutputs.contains { $0.id == first.id })
    }

    // MARK: - 10. source preservation across EVERY planner failure mode

    func test_sourcePreserved_acrossAllPlannerFailures() async throws {
        let failures: [EditPlannerServiceError] = [
            .unavailable, .infeasible("no footage"),
            .transport(NSError(domain: "x", code: -1)), .badStatus(500),
        ]
        for (i, err) in failures.enumerated() {
            let s = newStory()
            let m = momentWithFile(s, rel: "media/bd-src-\(i).mov", dur: 6); completeAU(m)
            let before = counts()
            let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .fail(err)),
                                                 renderer: FakeRenderer(.ok(okResult())), context: ctx)
            coord.create(for: s)
            await awaitSettled(coord)
            guard case .failed = coord.state else { return XCTFail("expected .failed for \(err), got \(coord.state)") }
            XCTAssertTrue(s.generatedOutputs.isEmpty, "no output for \(err)")
            XCTAssertEqual(counts().assets, before.assets, "Asset deleted on \(err)")
            XCTAssertEqual(counts().moments, before.moments, "Moment deleted on \(err)")
            XCTAssertNotNil(s.moments.first?.asset, "Moment lost its asset on \(err)")
        }
    }

    // MARK: - 10b. source preservation on a RENDER failure (post-validation)

    func test_sourcePreserved_onRenderFailure() async throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/bd-renderfail.mov", dur: 8); completeAU(m)
        let before = counts()
        let coord = StoryCreationCoordinator(planner: FakePlanner(behavior: .ok(validPlan([m]))),
                                             renderer: FakeRenderer(.fail(.exportFailed("boom"))), context: ctx)
        coord.create(for: s)
        await awaitSettled(coord)
        guard case .failed = coord.state else { return XCTFail("expected .failed, got \(coord.state)") }
        XCTAssertTrue(s.generatedOutputs.isEmpty)
        XCTAssertEqual(counts().assets, before.assets)
        XCTAssertEqual(counts().moments, before.moments)
    }
}
