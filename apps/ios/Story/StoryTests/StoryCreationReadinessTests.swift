import SwiftData
import XCTest
@testable import Story

// StoryCreationReadiness tests (R-c Batch C §5). DETERMINISTIC. Two layers:
//   * classify(usable:withFile:total:) — the PURE predicate, no SwiftData.
//   * evaluate(story:context:)         — same inputs EditPlanRequestBuilder uses (resolvable file + completed AU),
//                                        via in-memory SwiftData (same harness as StoryCreationCoordinatorTests).
// Asserts the Home/Preview gate (isPlannable) matches EditPlanRequestBuilder's ">=1 usable Moment" rule.
@MainActor
final class StoryCreationReadinessTests: XCTestCase {

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

    // MARK: - Pure classifier

    func test_classify_noMoments() {
        XCTAssertEqual(StoryCreationReadiness.classify(usable: 0, withFile: 0, total: 0), .noMoments)
    }

    func test_classify_momentsButNoFile() {
        XCTAssertEqual(StoryCreationReadiness.classify(usable: 0, withFile: 0, total: 3),
                       .noUsableMedia(totalMoments: 3))
    }

    func test_classify_filesButNoAU_isAnalyzing() {
        // files present, none analyzed -> not plannable, honest "being analyzed".
        let r = StoryCreationReadiness.classify(usable: 0, withFile: 2, total: 2)
        XCTAssertEqual(r, .analyzing(totalMoments: 2))
        XCTAssertFalse(r.isPlannable)
    }

    func test_classify_noFiles_isMediaGone() {
        // moment RECORDS exist but NO file resolves -> media gone (not analyzing). Honest recovery copy.
        let r = StoryCreationReadiness.classify(usable: 0, withFile: 0, total: 3)
        XCTAssertEqual(r, .noUsableMedia(totalMoments: 3))
        XCTAssertFalse(r.isPlannable)
        XCTAssertTrue(r.copy.lowercased().contains("no longer on this device"))
    }

    func test_classify_mixReadyAndPending() {
        let r = StoryCreationReadiness.classify(usable: 2, withFile: 5, total: 5)
        XCTAssertEqual(r, .pendingAnalysis(ready: 2, pending: 3))
        XCTAssertTrue(r.isPlannable)   // planner uses the ready ones
    }

    func test_classify_allReady() {
        let r = StoryCreationReadiness.classify(usable: 4, withFile: 4, total: 4)
        XCTAssertEqual(r, .ready(usableCount: 4, totalMoments: 4))
        XCTAssertTrue(r.isPlannable)
    }

    func test_isPlannable_matrix() {
        XCTAssertTrue(StoryCreationReadiness.ready(usableCount: 1, totalMoments: 1).isPlannable)
        XCTAssertTrue(StoryCreationReadiness.pendingAnalysis(ready: 1, pending: 9).isPlannable)
        XCTAssertFalse(StoryCreationReadiness.noMoments.isPlannable)
        XCTAssertFalse(StoryCreationReadiness.noUsableMedia(totalMoments: 3).isPlannable)
    }

    func test_copy_isHonestAndNeverComingLater() {
        for r: StoryCreationReadiness in [.ready(usableCount: 2, totalMoments: 3),
                                          .pendingAnalysis(ready: 1, pending: 2),
                                          .noMoments, .noUsableMedia(totalMoments: 2),
                                          .analyzing(totalMoments: 2)] {
            XCTAssertFalse(r.copy.lowercased().contains("coming later"))
            XCTAssertFalse(r.copy.lowercased().contains("later update"))
            XCTAssertFalse(r.copy.isEmpty)
        }
    }

    // MARK: - Context-driven evaluation (matches EditPlanRequestBuilder's rule)

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
        let m = MomentModel(source: .directed, asset: asset); ctx.insert(m); if let _lnk = story.attach(m) { ctx.insert(_lnk) }
        return m
    }

    @discardableResult
    private func momentNoFile(_ story: StoryModel) -> MomentModel {
        let asset = AssetModel(relativePath: "media/missing-\(UUID()).mov", durationSeconds: 5, source: .directed)
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

    func test_evaluate_noMoments() {
        XCTAssertEqual(StoryCreationReadiness.evaluate(story: newStory(), context: ctx), .noMoments)
    }

    func test_evaluate_fileButNoAU_notPlannable() {
        let s = newStory()
        momentWithFile(s, rel: "media/rd-nofileau-1.mov", dur: 6)   // file, NO AU
        let r = StoryCreationReadiness.evaluate(story: s, context: ctx)
        XCTAssertFalse(r.isPlannable)
        XCTAssertEqual(r, .noUsableMedia(totalMoments: 1))
    }

    func test_evaluate_auButNoFile_notPlannable() {
        let s = newStory()
        let m = momentNoFile(s)                                      // AU but NO resolvable file
        completeAU(m)
        let r = StoryCreationReadiness.evaluate(story: s, context: ctx)
        XCTAssertFalse(r.isPlannable)                                // no resolvable media -> not plannable
    }

    func test_evaluate_mixReadyAndPending_isPlannable() {
        let s = newStory()
        let ready1 = momentWithFile(s, rel: "media/rd-mix-1.mov", dur: 6); completeAU(ready1)
        let ready2 = momentWithFile(s, rel: "media/rd-mix-2.mov", dur: 6); completeAU(ready2)
        momentWithFile(s, rel: "media/rd-mix-3.mov", dur: 6)         // file, no AU -> pending
        let r = StoryCreationReadiness.evaluate(story: s, context: ctx)
        XCTAssertEqual(r, .pendingAnalysis(ready: 2, pending: 1))
        XCTAssertTrue(r.isPlannable)
    }

    func test_evaluate_allReady_isPlannable() {
        let s = newStory()
        let a = momentWithFile(s, rel: "media/rd-all-1.mov", dur: 6); completeAU(a)
        let b = momentWithFile(s, rel: "media/rd-all-2.mov", dur: 6); completeAU(b)
        let r = StoryCreationReadiness.evaluate(story: s, context: ctx)
        XCTAssertEqual(r, .ready(usableCount: 2, totalMoments: 2))
        XCTAssertTrue(r.isPlannable)
    }

    /// The gate must agree with EditPlanRequestBuilder: plannable iff build() succeeds (>=1 usable Moment).
    func test_evaluate_gate_agreesWithEditPlanRequestBuilder() throws {
        let s = newStory()
        let ready = momentWithFile(s, rel: "media/rd-agree-1.mov", dur: 6); completeAU(ready)
        momentWithFile(s, rel: "media/rd-agree-2.mov", dur: 6)       // pending (no AU)
        // readiness says plannable...
        XCTAssertTrue(StoryCreationReadiness.evaluate(story: s, context: ctx).isPlannable)
        // ...and EditPlanRequestBuilder actually builds (does not throw noUsableMoments), using only the ready one.
        let build = try EditPlanRequestBuilder.build(story: s, context: ctx)
        XCTAssertEqual(build.includedMedia.map(\.momentId), [ready.id])

        // A Story with files but zero AU: readiness NOT plannable AND build throws.
        let s2 = newStory()
        momentWithFile(s2, rel: "media/rd-agree-x.mov", dur: 6)
        XCTAssertFalse(StoryCreationReadiness.evaluate(story: s2, context: ctx).isPlannable)
        XCTAssertThrowsError(try EditPlanRequestBuilder.build(story: s2, context: ctx))
    }
}
