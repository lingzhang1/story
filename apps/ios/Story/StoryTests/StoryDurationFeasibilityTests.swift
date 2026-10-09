import SwiftData
import XCTest
@testable import Story

// Duration-feasibility & recovery tests (R-c "Duration Feasibility and Recovery" §6). DETERMINISTIC:
// no network, no real render. Two layers:
//   (1) PURE unit tests of DurationFeasibility.evaluate(...) and FailureRecovery.from(...) — the on-device
//       preflight math and the UI-affordance mapping.
//   (2) INTEGRATION through StoryCreationCoordinator with a call-counting FakePlanner, proving the planner is
//       NEVER called with an infeasible target, that accepting a shorter target DOES call it (with the shorter
//       value) and renders, and that the Story's saved target is never silently mutated.
@MainActor
final class StoryDurationFeasibilityTests: XCTestCase {

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

    // MARK: - Builders (match StoryCreationCoordinatorTests)

    private func newStory(target: Double?) -> StoryModel {
        let s = StoryModel(title: "Learning Guitar", intentRawText: "guitar",
                           intentTheme: "growth", intentTone: "warm", intentSummary: "practice")
        s.intentTargetDurationSeconds = target
        ctx.insert(s)
        return s
    }

    @discardableResult
    private func momentWithFile(_ story: StoryModel, rel: String, dur: Double) -> MomentModel {
        let abs = MediaStore.shared.absoluteURL(for: rel)
        try? FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: abs.path, contents: Data([0x00]))
        let asset = AssetModel(relativePath: rel, durationSeconds: dur, source: .directed)
        let m = MomentModel(source: .directed, asset: asset)
        m.story = story
        ctx.insert(m)
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

    /// A call-counting planner that returns a canned feasible plan and records how many times it was called
    /// and the target it last saw. NEVER a real network call.
    private final class CountingPlanner: EditPlanning, @unchecked Sendable {
        private(set) var callCount = 0
        private(set) var lastTargetSeen: Double?
        let cannedPlan: EditPlanV2
        init(plan: EditPlanV2) { self.cannedPlan = plan }
        func plan(_ request: EditPlanRequestDTO) async throws -> EditPlanV2 {
            callCount += 1
            if case let .object(ci) = request.creativeIntent, case let .number(t)? = ci["target_duration_seconds"] {
                lastTargetSeen = t
            }
            return cannedPlan
        }
    }

    private final class OKRenderer: StoryRendering, @unchecked Sendable {
        private(set) var called = false
        func render(_ inputs: MediaEngineInputs, progress: ((Float) -> Void)?, shouldCancel: (() -> Bool)?) async throws -> RenderResult {
            called = true
            progress?(1.0)
            return RenderResult(relativePath: "rendered/\(UUID().uuidString).mp4",
                                url: URL(fileURLWithPath: "/dev/null"),
                                durationSeconds: 10.0,
                                renderSize: CGSize(width: 720, height: 1280))
        }
    }

    private func validPlan(_ moments: [MomentModel]) -> EditPlanV2 {
        var segs: [EditSegmentV2] = []
        for (i, m) in moments.enumerated() {
            let dur = m.asset?.durationSeconds ?? 5
            let out = min(3.0, max(1.0, dur))
            segs.append(EditSegmentV2(
                order: i, assetId: m.id.uuidString, sourceStartSeconds: 0, sourceEndSeconds: out,
                outputDurationSeconds: out, speed: 1.0, nativeAudio: i == 0 ? "keep" : "duck", musicAlignment: nil))
        }
        let total = segs.reduce(0) { $0 + $1.outputDurationSeconds }
        return EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: total,
                          outputFormat: "vertical", musicAssetId: nil, feasible: true, segments: segs)
    }

    // MARK: - (1) Pure DurationFeasibility math

    private typealias M = DurationFeasibility.MomentMaterial

    func test_pure_enoughFootage_isFeasible() {
        // 14 + 12 + 12 = 38s usable, target 36s (lower bound 28.8s) -> feasible.
        let v = DurationFeasibility.evaluate(
            materials: [M(durationSeconds: 20, usefulSegments: [(0, 14)]),
                        M(durationSeconds: 16, usefulSegments: [(1, 13)]),
                        M(durationSeconds: 18, usefulSegments: [(2, 14)])],
            targetSeconds: 36)
        XCTAssertEqual(v, .feasible(achievableSeconds: 38))
    }

    func test_pure_insufficient_butShorterPossible() {
        // The observed device case: ~38s usable, 60s target (lower bound 48s) -> shorter possible.
        let v = DurationFeasibility.evaluate(
            materials: [M(durationSeconds: 20, usefulSegments: [(0, 14)]),
                        M(durationSeconds: 16, usefulSegments: [(1, 13)]),
                        M(durationSeconds: 18, usefulSegments: [(2, 14)])],
            targetSeconds: 60)
        guard case let .shorterPossible(achievable, suggested, requested) = v else {
            return XCTFail("expected shorterPossible, got \(v)")
        }
        XCTAssertEqual(achievable, 38, accuracy: 0.01)
        XCTAssertEqual(requested, 60, accuracy: 0.01)
        // Conservative suggestion: 38 * 0.90 = 34.2 -> floor 34. Comfortably below achievable.
        XCTAssertEqual(suggested, 34, accuracy: 0.01)
        XCTAssertLessThan(suggested, achievable)
    }

    func test_pure_tooLittleForEvenMinimum_isInsufficient() {
        // 3s usable; even the minimum (5s) can't be filled -> insufficient, NO suggestion.
        let v = DurationFeasibility.evaluate(materials: [M(durationSeconds: 4, usefulSegments: [(0, 3)])], targetSeconds: 60)
        XCTAssertEqual(v, .insufficient(achievableSeconds: 3, requestedSeconds: 60))
    }

    func test_pure_overlappingSegments_notDoubleCounted() {
        // Two useful spans of the SAME moment that overlap must merge (0-10) + (5-14) => 14, not 19.
        let m = M(durationSeconds: 20, usefulSegments: [(0, 10), (5, 14)])
        XCTAssertEqual(m.usableSeconds, 14, accuracy: 0.001)
    }

    func test_pure_segmentsClampedToClipLength() {
        // A span claiming beyond the clip is clamped to the clip length (no invented footage).
        let m = M(durationSeconds: 8, usefulSegments: [(0, 100)])
        XCTAssertEqual(m.usableSeconds, 8, accuracy: 0.001)
    }

    func test_pure_noExplicitSegments_usesWholeClip() {
        let m = M(durationSeconds: 7, usefulSegments: [])
        XCTAssertEqual(m.usableSeconds, 7, accuracy: 0.001)
    }

    func test_pure_doesNotSlowClipsToReachTarget() {
        // 10s usable vs 60s target. The estimate stays 10 (1.0x only) — we never pad via slow-mo to "reach" 60.
        let v = DurationFeasibility.evaluate(materials: [M(durationSeconds: 10, usefulSegments: [(0, 10)])], targetSeconds: 60)
        guard case let .shorterPossible(achievable, _, _) = v else { return XCTFail("expected shorterPossible") }
        XCTAssertEqual(achievable, 10, accuracy: 0.01)
    }

    // MARK: - FailureRecovery mapping

    func test_failureRecovery_insufficientWithSuggestion_offersShorter() {
        let r = FailureRecovery.from(.insufficientMaterial(achievable: 38, requested: 60, suggested: 34))
        XCTAssertEqual(r, .shorterStory(suggestedSeconds: 34))
    }

    func test_failureRecovery_insufficientNoSuggestion_keepShooting() {
        let r = FailureRecovery.from(.insufficientMaterial(achievable: 3, requested: 60, suggested: nil))
        XCTAssertEqual(r, .keepShooting)
    }

    func test_failureRecovery_technicalFailures_offerRetry() {
        XCTAssertEqual(FailureRecovery.from(.planUnavailable), .technical)
        XCTAssertEqual(FailureRecovery.from(.planTransport("x")), .technical)
        XCTAssertEqual(FailureRecovery.from(.renderFailed("x")), .technical)
        XCTAssertEqual(FailureRecovery.from(nil), .technical)
    }

    // MARK: - (2) Integration through the coordinator

    private func settle(_ coord: StoryCreationCoordinator, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        // Give the task a moment to flip isCreating=true, then wait for it to clear.
        try? await Task.sleep(nanoseconds: 5_000_000)
        while coord.isCreating && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func test_integration_infeasibleTarget_doesNotCallPlanner_offersShorter() async {
        // ~38s usable, 60s target -> preflight fails BEFORE the planner. Planner call count must be 0.
        let story = newStory(target: 60)
        let m1 = momentWithFile(story, rel: "media/a.mov", dur: 20); completeAU(m1, useful: [(0, 14)])
        let m2 = momentWithFile(story, rel: "media/b.mov", dur: 16); completeAU(m2, useful: [(1, 13)])
        let m3 = momentWithFile(story, rel: "media/c.mov", dur: 18); completeAU(m3, useful: [(2, 14)])
        try? ctx.save()

        let planner = CountingPlanner(plan: validPlan([m1]))
        let renderer = OKRenderer()
        let coord = StoryCreationCoordinator(planner: planner, renderer: renderer, context: ctx)
        coord.create(for: story)
        await settle(coord)

        XCTAssertEqual(planner.callCount, 0, "planner must NOT be called for an infeasible target")
        XCTAssertFalse(renderer.called)
        guard case .failed = coord.state else { return XCTFail("expected .failed, got \(coord.state)") }
        guard case let .insufficientMaterial(_, requested, suggested)? = coord.lastFailure else {
            return XCTFail("expected insufficientMaterial, got \(String(describing: coord.lastFailure))")
        }
        XCTAssertEqual(requested, 60, accuracy: 0.01)
        XCTAssertNotNil(suggested)
        // The user's saved target is untouched.
        XCTAssertEqual(story.intentTargetDurationSeconds, 60)
    }

    func test_integration_acceptShorter_callsPlannerWithShorterTarget_renders() async {
        let story = newStory(target: 60)
        let m1 = momentWithFile(story, rel: "media/a.mov", dur: 20); completeAU(m1, useful: [(0, 14)])
        let m2 = momentWithFile(story, rel: "media/b.mov", dur: 16); completeAU(m2, useful: [(1, 13)])
        let m3 = momentWithFile(story, rel: "media/c.mov", dur: 18); completeAU(m3, useful: [(2, 14)])
        try? ctx.save()

        let planner = CountingPlanner(plan: validPlan([m1, m2, m3]))
        let renderer = OKRenderer()
        let coord = StoryCreationCoordinator(planner: planner, renderer: renderer, context: ctx)
        coord.create(for: story)
        await settle(coord)
        XCTAssertEqual(planner.callCount, 0)
        guard case let .insufficientMaterial(_, _, suggested)? = coord.lastFailure, let shorter = suggested else {
            return XCTFail("expected a shorter suggestion")
        }

        // Accept the shorter target.
        coord.createShorter(targetSeconds: shorter)
        await settle(coord)

        XCTAssertEqual(planner.callCount, 1, "accepting shorter must call the planner exactly once")
        XCTAssertEqual(planner.lastTargetSeen ?? -1, shorter, accuracy: 0.01, "planner must receive the shorter target")
        XCTAssertTrue(renderer.called, "a feasible shorter plan must render")
        guard case .completed = coord.state else { return XCTFail("expected .completed, got \(coord.state)") }
        // The Story's ORIGINAL target is still 60 — accepting a shorter render does not silently rewrite intent.
        XCTAssertEqual(story.intentTargetDurationSeconds, 60, "original target must not be silently changed")
    }

    func test_integration_keepShooting_doesNotMutateStory_noPlannerCall() async {
        // 3s usable, 60s target -> insufficient, no suggestion -> "keep shooting". createShorter is a no-op.
        let story = newStory(target: 60)
        let m1 = momentWithFile(story, rel: "media/tiny.mov", dur: 4); completeAU(m1, useful: [(0, 3)])
        try? ctx.save()

        let planner = CountingPlanner(plan: validPlan([m1]))
        let coord = StoryCreationCoordinator(planner: planner, renderer: OKRenderer(), context: ctx)
        coord.create(for: story)
        await settle(coord)
        guard case let .insufficientMaterial(_, _, suggested)? = coord.lastFailure else {
            return XCTFail("expected insufficientMaterial")
        }
        XCTAssertNil(suggested, "3s of material should offer no shorter suggestion")

        // createShorter must refuse (no suggestion to honor); nothing re-planned, story untouched.
        coord.createShorter(targetSeconds: 2)
        await settle(coord)
        XCTAssertEqual(planner.callCount, 0)
        XCTAssertEqual(story.intentTargetDurationSeconds, 60)
        XCTAssertEqual(story.moments.count, 1, "no footage fabricated or removed")
    }

    func test_integration_enoughFootage_plansNormally_noPreflightBlock() async {
        // 38s usable, 30s target (lower bound 24s) -> feasible -> planner IS called, renders.
        let story = newStory(target: 30)
        let m1 = momentWithFile(story, rel: "media/a.mov", dur: 20); completeAU(m1, useful: [(0, 14)])
        let m2 = momentWithFile(story, rel: "media/b.mov", dur: 16); completeAU(m2, useful: [(1, 13)])
        let m3 = momentWithFile(story, rel: "media/c.mov", dur: 18); completeAU(m3, useful: [(2, 14)])
        try? ctx.save()

        let planner = CountingPlanner(plan: validPlan([m1, m2, m3]))
        let renderer = OKRenderer()
        let coord = StoryCreationCoordinator(planner: planner, renderer: renderer, context: ctx)
        coord.create(for: story)
        await settle(coord)

        XCTAssertEqual(planner.callCount, 1, "a feasible target must reach the planner")
        XCTAssertEqual(planner.lastTargetSeen ?? -1, 30, accuracy: 0.01)
        XCTAssertTrue(renderer.called)
        guard case .completed = coord.state else { return XCTFail("expected .completed, got \(coord.state)") }
    }
}
