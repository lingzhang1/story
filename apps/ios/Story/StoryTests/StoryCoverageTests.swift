import XCTest
import SwiftData
@testable import Story

// StoryCoverage/2 + StoryGuide lifecycle tests (Milestone E2-c). Groups:
//   1. Contract decode: StoryGuide/1, StoryCoverage/2 (dimension_coverage keyed by Guide id,
//      represented_possibility_ids, nullable idea + target dimension).
//   2. Guide lifecycle: generate-once, migration (CreativeIntent present, Guide absent), failure
//      preserves Story (no fabrication).
//   3. Coverage/2 lifecycle: zero completed AU -> no call; pending-only -> no call; cached-current
//      -> no call; guide-fingerprint staleness; AU completion stales; failed recompute preserves.
//   4. Presentation mapping (V2 minimal, Batch 1): sufficient -> ENOUGH; pending line; null idea.
@MainActor
final class StoryCoverageTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self,
            configurations: config)
    }

    // MARK: - Fakes

    private final class FakeGuide: StoryGuideGenerating {
        var calls = 0
        var error: Error?
        init(error: Error? = nil) { self.error = error }
        func generate(_ request: StoryGuideRequestDTO) async throws -> StoryGuideDTO {
            calls += 1
            if let error { throw error }
            return StoryGuideDTO(
                schemaVersion: "story_guide/1", storyId: request.storyId,
                sourceCreativeIntentVersion: nil, framingSummary: "For this Story: scale.",
                dimensions: [StoryGuideDimensionDTO(id: "dim_01", label: "Scale", purpose: "enormous",
                    capturePossibilities: [CapturePossibilityDTO(id: "dim_01_cp_01", label: "wide", semanticPurpose: nil)])],
                generatedAt: nil)
        }
    }

    private final class FakeCoverageV2: StoryCoverageV2Computing {
        var result: StoryCoverageV2DTO?
        var error: Error?
        var calls = 0
        var lastRequest: StoryCoverageV2RequestDTO?
        init(result: StoryCoverageV2DTO? = nil, error: Error? = nil) { self.result = result; self.error = error }
        func compute(_ request: StoryCoverageV2RequestDTO) async throws -> StoryCoverageV2DTO {
            calls += 1; lastRequest = request
            if let error { throw error }
            return result ?? Self.minimal(storyId: request.storyId,
                moments: request.momentUnderstandings.count, pending: request.pendingCount)
        }
        static func minimal(storyId: UUID, moments: Int, pending: Int,
                            sufficiency: SufficiencyStatusDTO = .workable,
                            idea: CoverageStoryIdeaV2DTO? = nil) -> StoryCoverageV2DTO {
            StoryCoverageV2DTO(
                schemaVersion: "story_coverage/2", storyId: storyId, storyGuideId: "guide-1",
                storyGuideVersion: "story_guide/1", momentCount: moments, pendingCount: pending,
                sourceUnderstandingIds: [],
                dimensionCoverage: [DimensionCoverageDTO(storyGuideDimensionId: "dim_01", state: .strong,
                    note: nil, evidenceMomentIds: [], representedPossibilityIds: [])],
                strengths: ["Strong sense of place"], redundancies: [],
                sufficiency: CoverageSufficiencyDTO(status: sufficiency, reason: "r"),
                storyIdea: idea, generatedAt: nil)
        }
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeStory(intent: String = "the beauty of the mountains") -> StoryModel {
        let s = StoryModel(title: "T", intentRawText: intent, intentTheme: "", intentTone: "", intentSummary: intent)
        ctx.insert(s); try? ctx.save(); return s
    }

    @discardableResult
    private func addUnderstoodMoment(to story: StoryModel, summary: String = "a mountain",
                                     usefulStart: Double = 0, usefulEnd: Double = 10) -> UUID {
        let m = MomentModel(source: .directed); ctx.insert(m); if let _lnk = story.attach(m) { ctx.insert(_lnk) }
        let json = """
        {"moment_id":"\(m.id.uuidString)","schema_version":"moment_understanding/1",
         "observed":{"summary":"\(summary)","subjects":[],"events":[],"temporal_order_note":"",
         "useful_segments":[{"t_start_s":\(usefulStart),"t_end_s":\(usefulEnd),"why_useful":"x"}]},
         "story_context":{"story_utility":"useful"}}
        """
        ctx.insert(MomentUnderstandingModel(
            momentId: m.id, schemaVersion: "moment_understanding/1", framePolicy: "au_frames/1",
            promptVersion: "au_prompt/1", modelId: "x", nFrames: 24, understandingJSON: json))
        try? ctx.save(); return m.id
    }

    @discardableResult
    private func addPendingMoment(to story: StoryModel) -> UUID {
        let m = MomentModel(source: .directed); ctx.insert(m); if let _lnk = story.attach(m) { ctx.insert(_lnk) }; try? ctx.save(); return m.id
    }

    private func guideReady(_ story: StoryModel, _ fake: FakeGuide = FakeGuide()) async -> (StoryGuideDTO, String) {
        let coord = StoryGuideCoordinator(context: ctx, service: fake)
        let g = await coord.ensureGuide(for: story)!
        return (g, coord.guideFingerprint(for: story.id))
    }

    // MARK: - 1. Contract decode

    func testDecodeStoryGuide() throws {
        let json = """
        {"schema_version":"story_guide/1","story_id":"\(UUID().uuidString)",
         "framing_summary":"For this Story: scale and stillness.",
         "dimensions":[{"id":"dim_01","label":"Scale","purpose":"enormous",
           "capture_possibilities":[{"id":"dim_01_cp_01","label":"person beneath mountains"}]}]}
        """
        let g = try StoryContractCoding.decoder().decode(StoryGuideDTO.self, from: Data(json.utf8))
        XCTAssertEqual(g.dimensions[0].id, "dim_01")
        XCTAssertEqual(g.dimensions[0].capturePossibilities[0].id, "dim_01_cp_01")
    }

    func testDecodeCoverageV2() throws {
        let json = """
        {"schema_version":"story_coverage/2","story_id":"\(UUID().uuidString)","story_guide_id":"g1",
         "story_guide_version":"story_guide/1","moment_count":2,"pending_count":0,"source_understanding_ids":[],
         "dimension_coverage":[{"story_guide_dimension_id":"dim_01","state":"strong","note":null,
           "evidence_moment_ids":[],"represented_possibility_ids":[]}],
         "strengths":["Strong scale"],"redundancies":[],
         "sufficiency":{"status":"workable","reason":"ok"},
         "story_idea":{"title":"A moment together","description":"warmth","rationale":"r","target_story_guide_dimension_id":"dim_01"}}
        """
        let d = try StoryContractCoding.decoder().decode(StoryCoverageV2DTO.self, from: Data(json.utf8))
        XCTAssertEqual(d.dimensionCoverage[0].storyGuideDimensionId, "dim_01")
        XCTAssertEqual(d.dimensionCoverage[0].state, .strong)
        XCTAssertTrue(d.dimensionCoverage[0].representedPossibilityIds.isEmpty)   // strong w/ zero represented
        XCTAssertEqual(d.storyIdea?.targetStoryGuideDimensionId, "dim_01")
    }

    // MARK: - 2. Guide lifecycle

    func testGuideGeneratedOnceAndPersisted() async {
        let s = makeStory()
        let fake = FakeGuide()
        let coord = StoryGuideCoordinator(context: ctx, service: fake)
        XCTAssertFalse(coord.hasGuide(for: s.id))
        _ = await coord.ensureGuide(for: s)
        XCTAssertTrue(coord.hasGuide(for: s.id))
        XCTAssertEqual(fake.calls, 1)
        _ = await coord.ensureGuide(for: s)                 // second call -> NO regeneration
        XCTAssertEqual(fake.calls, 1)
    }

    func testExistingStoryMigrationGeneratesGuideFromIntent() async {
        // A Story created before Guides existed: CreativeIntent present, no Guide.
        let s = makeStory(intent: "our TMB trek")
        _ = addUnderstoodMoment(to: s)                      // has old-world material, no guide
        let coord = StoryGuideCoordinator(context: ctx, service: FakeGuide())
        XCTAssertFalse(coord.hasGuide(for: s.id))
        let g = await coord.ensureGuide(for: s)             // migration path = same ensureGuide
        XCTAssertNotNil(g)
        XCTAssertTrue(coord.hasGuide(for: s.id))
    }

    func testGuideFailurePreservesStoryNoFabrication() async {
        let s = makeStory()
        let coord = StoryGuideCoordinator(context: ctx, service: FakeGuide(error: StoryGuideServiceError.unavailable))
        let g = await coord.ensureGuide(for: s)
        XCTAssertNil(g)                                     // no Guide
        XCTAssertFalse(coord.hasGuide(for: s.id))           // nothing fabricated/persisted
    }

    // MARK: - 3. Coverage/2 lifecycle

    func testZeroCompletedAUMeansNoCoverageCall() async {
        let s = makeStory()                                 // no moments at all
        let (g, fp) = await guideReady(s)
        let fake = FakeCoverageV2()
        let eng = StoryCoverageEngine(context: ctx, service: fake)
        _ = await eng.recomputeIfNeeded(for: s, guide: g, guideFingerprint: fp, force: true)
        XCTAssertEqual(fake.calls, 0)                       // Guide supplies content; NO Mapper/Judge
    }

    func testPendingOnlyMeansNoCoverageCall() async {
        let s = makeStory()
        _ = addPendingMoment(to: s); _ = addPendingMoment(to: s)   // only pending
        let (g, fp) = await guideReady(s)
        let fake = FakeCoverageV2()
        let eng = StoryCoverageEngine(context: ctx, service: fake)
        _ = await eng.recomputeIfNeeded(for: s, guide: g, guideFingerprint: fp, force: true)
        XCTAssertEqual(fake.calls, 0)                       // pending = unknown, not a gap
    }

    func testRecomputeCachesAndSendsGuideAndMoments() async {
        let s = makeStory(); _ = addUnderstoodMoment(to: s)
        let (g, fp) = await guideReady(s)
        let fake = FakeCoverageV2()
        let eng = StoryCoverageEngine(context: ctx, service: fake)
        let cov = await eng.recomputeIfNeeded(for: s, guide: g, guideFingerprint: fp, force: true)
        XCTAssertNotNil(cov)
        XCTAssertEqual(fake.calls, 1)
        XCTAssertEqual(fake.lastRequest?.momentUnderstandings.count, 1)
        XCTAssertEqual(fake.lastRequest?.storyGuideVersion, "story_guide/1")
        XCTAssertNotNil(eng.cachedCoverage(for: s.id))
    }

    func testCachedCurrentMeansNoCall() async {
        let s = makeStory(); _ = addUnderstoodMoment(to: s)
        let (g, fp) = await guideReady(s)
        let fake = FakeCoverageV2()
        let eng = StoryCoverageEngine(context: ctx, service: fake)
        _ = await eng.recomputeIfNeeded(for: s, guide: g, guideFingerprint: fp, force: true)
        XCTAssertEqual(fake.calls, 1)
        XCTAssertFalse(eng.isStale(for: s, guideFingerprint: fp))
        _ = await eng.recomputeIfNeeded(for: s, guide: g, guideFingerprint: fp)
        XCTAssertEqual(fake.calls, 1)                       // current -> no second call
    }

    func testAUCompletionStalesCoverage() async {
        let s = makeStory(); _ = addUnderstoodMoment(to: s)
        let (g, fp) = await guideReady(s)
        let eng = StoryCoverageEngine(context: ctx, service: FakeCoverageV2())
        _ = await eng.recomputeIfNeeded(for: s, guide: g, guideFingerprint: fp, force: true)
        XCTAssertFalse(eng.isStale(for: s, guideFingerprint: fp))
        _ = addUnderstoodMoment(to: s, summary: "a river")  // new understood moment
        XCTAssertTrue(eng.isStale(for: s, guideFingerprint: fp))
    }

    func testGuideFingerprintChangeStalesCoverage() async {
        let s = makeStory(); _ = addUnderstoodMoment(to: s)
        let (g, fp) = await guideReady(s)
        let eng = StoryCoverageEngine(context: ctx, service: FakeCoverageV2())
        _ = await eng.recomputeIfNeeded(for: s, guide: g, guideFingerprint: fp, force: true)
        XCTAssertFalse(eng.isStale(for: s, guideFingerprint: fp))
        XCTAssertTrue(eng.isStale(for: s, guideFingerprint: "a-different-guide-fingerprint"))
    }

    func testFailedRecomputePreservesPreviousValidCoverage() async {
        let s = makeStory(); _ = addUnderstoodMoment(to: s)
        let (g, fp) = await guideReady(s)
        let good = FakeCoverageV2(result: FakeCoverageV2.minimal(storyId: s.id, moments: 1, pending: 0, sufficiency: .sufficient))
        _ = await StoryCoverageEngine(context: ctx, service: good).recomputeIfNeeded(for: s, guide: g, guideFingerprint: fp, force: true)
        let eng2 = StoryCoverageEngine(context: ctx, service: FakeCoverageV2(error: StoryCoverageServiceError.unavailableRetryable))
        _ = addUnderstoodMoment(to: s, summary: "x")        // make stale
        let result = await eng2.recomputeIfNeeded(for: s, guide: g, guideFingerprint: fp, force: true)
        XCTAssertEqual(result?.sufficiency.status, .sufficient)   // previous valid preserved
    }

    // MARK: - 4. Presentation (V2 minimal, Batch 1)

    func testSufficientShowsEnoughAndNoOpportunities() {
        let cov = FakeCoverageV2.minimal(storyId: UUID(), moments: 3, pending: 0, sufficiency: .sufficient)
        XCTAssertTrue(StoryCoveragePresentation.opportunityLines(cov).isEmpty)
        XCTAssertFalse(StoryCoveragePresentation.enoughLine(cov).isEmpty)
    }

    func testPendingLineOnlyWhenPending() {
        XCTAssertNil(StoryCoveragePresentation.pendingLine(FakeCoverageV2.minimal(storyId: UUID(), moments: 2, pending: 0)))
        let some = StoryCoveragePresentation.pendingLine(FakeCoverageV2.minimal(storyId: UUID(), moments: 2, pending: 3))
        XCTAssertNotNil(some)
        XCTAssertFalse(some!.contains("missing"))
    }

    func testStrengthLinesUseStrengthsNoIds() {
        let lines = StoryCoveragePresentation.strengthLines(FakeCoverageV2.minimal(storyId: UUID(), moments: 2, pending: 0))
        XCTAssertEqual(lines.first, "Strong sense of place")
        XCTAssertFalse(lines.contains("dim_01"))
    }
}
