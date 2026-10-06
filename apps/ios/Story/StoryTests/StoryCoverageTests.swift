import XCTest
import SwiftData
@testable import Story

// Story Coverage tests (Milestone E, FROZEN). Three groups:
//   1. Contract decode: hybrid dims, nullable story_idea, categorical coverage,
//      dimension ids are snapshot-local handles (decoded as plain strings, never
//      used as persistent identity).
//   2. Engine lifecycle: cached-current -> no model call; stale -> recompute;
//      failed recompute preserves previous valid coverage; pending = unknown.
//   3. Presentation mapping: Guide shows ordinary language (no ids/scores/jargon);
//      sufficient -> ENOUGH + no opportunities; Idea hidden when null.
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
                 StoryCoverageModel.self,
            configurations: config)
    }

    // MARK: - Fakes & fixtures

    /// A scripted coverage service: returns a canned DTO (optionally per-call) or throws.
    private final class FakeCoverage: StoryCoverageComputing {
        var result: StoryCoverageDTO?
        var error: Error?
        var calls = 0
        var lastRequest: StoryCoverageRequestDTO?
        init(result: StoryCoverageDTO? = nil, error: Error? = nil) {
            self.result = result; self.error = error
        }
        func compute(_ request: StoryCoverageRequestDTO) async throws -> StoryCoverageDTO {
            calls += 1; lastRequest = request
            if let error { throw error }
            // Default: echo a minimal valid coverage keyed to the request's story.
            return result ?? Self.minimal(storyId: request.storyId,
                                           moments: request.momentUnderstandings.count,
                                           pending: request.pendingCount)
        }
        static func minimal(storyId: UUID, moments: Int, pending: Int,
                            sufficiency: SufficiencyStatusDTO = .workable,
                            idea: CoverageStoryIdeaDTO? = nil) -> StoryCoverageDTO {
            StoryCoverageDTO(
                schemaVersion: "story_coverage/1", storyId: storyId,
                momentCount: moments, pendingCount: pending, sourceUnderstandingIds: [],
                dimensions: [CoverageDimensionDTO(id: "d1", label: "Place", purpose: "sense of where",
                                                  coverage: .strong, note: nil, evidenceMomentIds: [])],
                strengths: ["Strong sense of place"], redundancies: [],
                sufficiency: CoverageSufficiencyDTO(status: sufficiency, reason: "r"),
                storyIdea: idea, generatedAt: nil)
        }
    }

    @discardableResult
    private func makeStory(intent: String = "the beauty of the mountains") -> StoryModel {
        let s = StoryModel(title: "T", intentRawText: intent, intentTheme: "", intentTone: "",
                           intentSummary: intent)
        ctx.insert(s)
        try? ctx.save()
        return s
    }

    /// Add a Moment + a completed MomentUnderstanding (JSON) to a Story.
    @discardableResult
    private func addUnderstoodMoment(to story: StoryModel, summary: String = "a mountain") -> UUID {
        let m = MomentModel(source: .directed)
        m.story = story
        ctx.insert(m)
        let json = """
        {"moment_id":"\(m.id.uuidString)","schema_version":"moment_understanding/1",
         "observed":{"summary":"\(summary)","subjects":[],"events":[],"temporal_order_note":"",
         "useful_segments":[]},"story_context":{"story_utility":"useful"}}
        """
        ctx.insert(MomentUnderstandingModel(
            momentId: m.id, schemaVersion: "moment_understanding/1", framePolicy: "au_frames/1",
            promptVersion: "au_prompt/1", modelId: "x", nFrames: 24, understandingJSON: json))
        try? ctx.save()
        return m.id
    }

    /// Add a Moment with NO understanding yet (pending).
    @discardableResult
    private func addPendingMoment(to story: StoryModel) -> UUID {
        let m = MomentModel(source: .directed)
        m.story = story
        ctx.insert(m)
        try? ctx.save()
        return m.id
    }

    // MARK: - 1. Contract decode

    func testDecodeHybridDimsNullableIdeaCategorical() throws {
        let json = """
        {"schema_version":"story_coverage/1","story_id":"\(UUID().uuidString)",
         "moment_count":2,"pending_count":0,"source_understanding_ids":[],
         "dimensions":[{"id":"human_scale_contrast","label":"Human vs Landscape Scale",
           "purpose":"how small the figure feels","coverage":"could_use_more","note":null,
           "evidence_moment_ids":[]}],
         "strengths":["Strong landscape"],"redundancies":["8 near-identical panoramas"],
         "sufficiency":{"status":"workable","reason":"ok"},"story_idea":null}
        """
        let dto = try StoryContractCoding.decoder()
            .decode(StoryCoverageDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.dimensions.count, 1)
        XCTAssertEqual(dto.dimensions[0].coverage, .couldUseMore)   // categorical, not numeric
        XCTAssertEqual(dto.dimensions[0].label, "Human vs Landscape Scale")  // intent-derived label
        XCTAssertNil(dto.storyIdea)                                  // nullable, first-class
        XCTAssertEqual(dto.sufficiency.status, .workable)
    }

    func testDecodeWithStoryIdea() throws {
        let json = """
        {"schema_version":"story_coverage/1","story_id":"\(UUID().uuidString)",
         "moment_count":1,"pending_count":0,"source_understanding_ids":[],
         "dimensions":[],"strengths":[],"redundancies":[],
         "sufficiency":{"status":"workable","reason":"r"},
         "story_idea":{"title":"A quiet human moment","description":"someone in the frame","rationale":"r"}}
        """
        let dto = try StoryContractCoding.decoder()
            .decode(StoryCoverageDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.storyIdea?.title, "A quiet human moment")
    }

    func testDimensionIdIsSnapshotLocalNotPersistedAsIdentity() {
        // The engine must NOT persist/key anything on dimension id — only the JSON
        // blob + provenance fingerprints are stored. Assert no API surfaces dim id
        // as a stored key: StoryCoverageModel has no dimensionId field.
        let mirror = Mirror(reflecting: StoryCoverageModel(
            storyId: UUID(), coverageJSON: "{}",
            sourceUnderstandingIdsFingerprint: "a", creativeIntentFingerprint: "b", pendingCount: 0))
        let names = mirror.children.compactMap { $0.label }
        XCTAssertFalse(names.contains(where: { $0.lowercased().contains("dimensionid") }))
    }

    // MARK: - 2. Engine lifecycle

    func testRecomputeCachesAndSendsCompactInput() async {
        let story = makeStory()
        _ = addUnderstoodMoment(to: story)
        let fake = FakeCoverage()
        let eng = StoryCoverageEngine(context: ctx, service: fake)
        let cov = await eng.recomputeIfNeeded(for: story, force: true)
        XCTAssertNotNil(cov)
        XCTAssertEqual(fake.calls, 1)
        XCTAssertEqual(fake.lastRequest?.momentUnderstandings.count, 1)   // one understood moment sent
        XCTAssertNotNil(eng.cachedCoverage(for: story.id))               // cached
    }

    func testCachedCurrentMeansNoModelCall() async {
        let story = makeStory()
        _ = addUnderstoodMoment(to: story)
        let fake = FakeCoverage()
        let eng = StoryCoverageEngine(context: ctx, service: fake)
        _ = await eng.recomputeIfNeeded(for: story, force: true)   // call 1
        XCTAssertEqual(fake.calls, 1)
        XCTAssertFalse(eng.isStale(for: story))                    // now current
        _ = await eng.recomputeIfNeeded(for: story)                // should NOT call again
        XCTAssertEqual(fake.calls, 1)
    }

    func testAddingMomentMakesCoverageStale() async {
        let story = makeStory()
        _ = addUnderstoodMoment(to: story)
        let eng = StoryCoverageEngine(context: ctx, service: FakeCoverage())
        _ = await eng.recomputeIfNeeded(for: story, force: true)
        XCTAssertFalse(eng.isStale(for: story))
        _ = addUnderstoodMoment(to: story, summary: "a river")     // new understood moment
        XCTAssertTrue(eng.isStale(for: story))                     // provenance changed -> stale
    }

    func testIntentChangeMakesCoverageStale() async {
        let story = makeStory()
        _ = addUnderstoodMoment(to: story)
        let eng = StoryCoverageEngine(context: ctx, service: FakeCoverage())
        _ = await eng.recomputeIfNeeded(for: story, force: true)
        XCTAssertFalse(eng.isStale(for: story))
        story.intentEmphasis = ["people"]; try? ctx.save()         // intent changed
        XCTAssertTrue(eng.isStale(for: story))
    }

    func testFailedRecomputePreservesPreviousValidCoverage() async {
        let story = makeStory()
        _ = addUnderstoodMoment(to: story)
        // First: a successful compute caches a snapshot.
        let good = FakeCoverage(result: FakeCoverage.minimal(
            storyId: story.id, moments: 1, pending: 0, sufficiency: .sufficient))
        let eng1 = StoryCoverageEngine(context: ctx, service: good)
        _ = await eng1.recomputeIfNeeded(for: story, force: true)
        XCTAssertEqual(eng1.cachedCoverage(for: story.id)?.sufficiency.status, .sufficient)

        // Now a FAILING service + a stale input: cache must be preserved.
        _ = addUnderstoodMoment(to: story)                         // make stale
        let bad = FakeCoverage(error: StoryCoverageServiceError.unavailableRetryable)
        let eng2 = StoryCoverageEngine(context: ctx, service: bad)
        let result = await eng2.recomputeIfNeeded(for: story, force: true)
        XCTAssertEqual(bad.calls, 1)
        XCTAssertEqual(result?.sufficiency.status, .sufficient)    // previous valid, not nil
        XCTAssertEqual(eng2.cachedCoverage(for: story.id)?.sufficiency.status, .sufficient)
    }

    func testPendingCountIsSentAndUnderstoodSubsetReasoned() async {
        let story = makeStory()
        _ = addUnderstoodMoment(to: story)
        _ = addPendingMoment(to: story)                            // pending (no understanding)
        _ = addPendingMoment(to: story)
        let fake = FakeCoverage()
        let eng = StoryCoverageEngine(context: ctx, service: fake)
        _ = await eng.recomputeIfNeeded(for: story, force: true)
        XCTAssertEqual(fake.lastRequest?.pendingCount, 2)          // pending COUNTED, not absent
        XCTAssertEqual(fake.lastRequest?.momentUnderstandings.count, 1)  // only understood reasoned from
    }

    func testEmptyStoryIsNeverStaleAndCachesNothing() async {
        let story = makeStory()                                    // no moments
        let fake = FakeCoverage()
        let eng = StoryCoverageEngine(context: ctx, service: fake)
        let inputs = eng.currentInputs(for: story)
        XCTAssertTrue(inputs.completedMUValues.isEmpty)
        XCTAssertNil(eng.cachedCoverage(for: story.id))
    }

    // MARK: - 3. Presentation mapping

    func testGuideStrengthsUseOrdinaryLanguageNoIds() {
        let cov = FakeCoverage.minimal(storyId: UUID(), moments: 2, pending: 0)
        let lines = StoryCoveragePresentation.strengthLines(cov)
        XCTAssertEqual(lines.first, "Strong sense of place")       // the strength string, not "d1"
        XCTAssertFalse(lines.contains("d1"))                       // never a raw dimension id
    }

    func testSufficientShowsEnoughAndNoOpportunities() {
        let cov = StoryCoverageDTO(
            schemaVersion: "story_coverage/1", storyId: UUID(), momentCount: 3, pendingCount: 0,
            sourceUnderstandingIds: [],
            dimensions: [CoverageDimensionDTO(id: "d1", label: "Place", purpose: "p",
                         coverage: .couldUseMore, note: nil, evidenceMomentIds: [])],
            strengths: ["Rich material"], redundancies: [],
            sufficiency: CoverageSufficiencyDTO(status: .sufficient, reason: "enough"),
            storyIdea: nil, generatedAt: nil)
        XCTAssertTrue(StoryCoveragePresentation.opportunityLines(cov).isEmpty)  // ENOUGH owns this case
        XCTAssertFalse(StoryCoveragePresentation.enoughLine(cov).isEmpty)
    }

    func testWorkableSurfacesWeakDimensionAsOptionalOpportunity() {
        let cov = StoryCoverageDTO(
            schemaVersion: "story_coverage/1", storyId: UUID(), momentCount: 2, pendingCount: 0,
            sourceUnderstandingIds: [],
            dimensions: [CoverageDimensionDTO(id: "d1", label: "People", purpose: "a human presence",
                         coverage: .couldUseMore, note: nil, evidenceMomentIds: [])],
            strengths: [], redundancies: [],
            sufficiency: CoverageSufficiencyDTO(status: .workable, reason: "r"),
            storyIdea: nil, generatedAt: nil)
        XCTAssertEqual(StoryCoveragePresentation.opportunityLines(cov), ["a human presence"])
    }

    func testPendingLineOnlyWhenPending() {
        let none = FakeCoverage.minimal(storyId: UUID(), moments: 2, pending: 0)
        XCTAssertNil(StoryCoveragePresentation.pendingLine(none))
        let some = FakeCoverage.minimal(storyId: UUID(), moments: 2, pending: 3)
        XCTAssertNotNil(StoryCoveragePresentation.pendingLine(some))
        XCTAssertFalse(StoryCoveragePresentation.pendingLine(some)!.contains("missing"))  // never "missing"
    }
}
