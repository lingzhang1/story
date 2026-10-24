import SwiftData
import XCTest
@testable import Story

// StoryGuideV2 + scene-image iOS tests (pre-beta shooting-script milestone).
//
// Covers (req 11 / Phase 6, iOS slice): v2 DTO decode (tolerant of absent fields + the double-optional
// flatten), version-aware coordinator (persist v2 into the SAME row, read back, NEVER mis-read a v1 row as
// v2), simplified-creation heuristics (default title, sufficient-context gate), and the SceneImage envelope
// decode + the text-only fallback contract (nil image). No network, no device build required.
@MainActor
final class StoryGuideV2Tests: XCTestCase {

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

    // MARK: - DTO decode

    func test_v2_scene_decode_tolerates_absent_optional_fields() throws {
        let sid = UUID().uuidString
        let json = """
        {"schema_version":"story_guide/2","story_id":"\(sid)","framing_summary":"Three days in New York",
         "scenes":[{"id":"scene_01","title":"First glimpse of the skyline","what_to_capture":"w",
                    "how_to_shoot":"h","why_it_matters":"y"}]}
        """.data(using: .utf8)!
        let g = try StoryContractCoding.decoder().decode(StoryGuideV2DTO.self, from: json)
        XCTAssertEqual(g.schemaVersion, "story_guide/2")
        XCTAssertEqual(g.scenes.count, 1)
        XCTAssertNil(g.scenes[0].visualReferenceQuery)   // absent -> nil (not a decode throw)
        XCTAssertTrue(g.scenes[0].capturePossibilities.isEmpty)
    }

    func test_scene_image_envelope_decodes_null_image() throws {
        let env = try StoryContractCoding.decoder().decode(
            SceneImageResponseDTO.self, from: #"{"image":null,"status":"no_match"}"#.data(using: .utf8)!)
        XCTAssertNil(env.image)                 // text-only fallback contract
        XCTAssertEqual(env.status, "no_match")
    }

    // MARK: - Version-aware coordinator

    private func makeStory() throws -> StoryModel {
        let s = StoryModel(title: "NY Trip", intentRawText: "Three days in New York",
                           intentTheme: "travel", intentTone: "warm", intentSummary: "NY trip")
        ctx.insert(s); try ctx.save(); return s
    }

    func test_ensureGuideV2_persists_and_reads_back_same_row() async throws {
        let s = try makeStory()
        let coord = StoryGuideCoordinator(context: ctx, v2Service: FakeV2Service())
        let g = await coord.ensureGuideV2(for: s)
        XCTAssertNotNil(g)
        XCTAssertTrue(coord.hasGuideV2(for: s.id))
        XCTAssertEqual(coord.guideV2(for: s.id)?.scenes.first?.title, "Skyline")
        // a SECOND ensure must NOT re-generate (returns the persisted one)
        let again = await coord.ensureGuideV2(for: s)
        XCTAssertEqual(again?.scenes.count, g?.scenes.count)
    }

    func test_v1_row_is_not_misread_as_v2() async throws {
        let s = try makeStory()
        // Persist a v1 guide row directly.
        let v1JSON = #"{"schema_version":"story_guide/1","story_id":"\#(s.id.uuidString)","framing_summary":"x","dimensions":[]}"#
        ctx.insert(StoryGuideModel(storyId: s.id, guideJSON: v1JSON, schemaVersion: "story_guide/1"))
        try ctx.save()
        let coord = StoryGuideCoordinator(context: ctx, v2Service: FakeV2Service())
        XCTAssertFalse(coord.hasGuideV2(for: s.id))       // v1 row is not v2
        XCTAssertNil(coord.guideV2(for: s.id))            // never decodes v1 as scenes
    }

    // MARK: - Simplified creation heuristics

    func test_default_title_is_non_empty() {
        XCTAssertFalse(StoryUseCases.defaultStoryTitle().isEmpty)
    }

    func test_sufficient_context_gate() {
        // a real description -> sufficient
        XCTAssertTrue(StoryUseCases.hasSufficientGuideContext(
            title: "Trip", description: "Three days in New York seeing a show"))
        // empty description + default-ish title -> NOT sufficient (don't fabricate a generic Guide)
        XCTAssertFalse(StoryUseCases.hasSufficientGuideContext(
            title: StoryUseCases.defaultStoryTitle(), description: ""))
        // a specific multi-word title can carry enough on its own
        XCTAssertTrue(StoryUseCases.hasSufficientGuideContext(
            title: "Maya's 5th Birthday", description: ""))
    }
}

// A fake v2 service: no network. Returns a deterministic scene-based guide for the requested story,
// built by decoding JSON (StoryGuideSceneDTO only has init(from:), so we exercise the real decoder).
private struct FakeV2Service: StoryGuideV2Generating {
    func generate(_ request: StoryGuideRequestDTO) async throws -> StoryGuideV2DTO {
        let json = """
        {"schema_version":"story_guide/2","story_id":"\(request.storyId.uuidString)",
         "framing_summary":"A fitting shooting script.",
         "scenes":[{"id":"scene_01","title":"Skyline","what_to_capture":"the city skyline",
                    "how_to_shoot":"hold a wide shot","why_it_matters":"sets the scene",
                    "visual_reference_query":"wide shot city skyline at dusk"}]}
        """.data(using: .utf8)!
        return try StoryContractCoding.decoder().decode(StoryGuideV2DTO.self, from: json)
    }
}
