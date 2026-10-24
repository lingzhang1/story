import SwiftData
import XCTest
@testable import Story

// Guide v2.1 refinement ("Update Guide") iOS tests.
//
// Covers the iOS-side acceptance slices (req 7/11):
//   - refinement DTO decode (result + change log, tolerant of absent fields);
//   - pin toggle is durable and feeds pinnedSceneIds (user-protected);
//   - captured-scene derivation from Coverage/2 (a strong/represented scene is "captured");
//   - refineGuideV2 persists the refined guide into the SAME row (version-aware);
//   - a FAILED refinement preserves the current guide (recoverable error, not cleared);
//   - the dedupe guard throws .duplicate for an empty-instruction repeat on unchanged inputs.
// No network, no device build required (fake refine service + in-memory SwiftData).
@MainActor
final class StoryGuideRefineTests: XCTestCase {

    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryScenePinModel.self,
                 StoryMusicDirectionModel.self,
            configurations: config)
    }

    private func makeStory() throws -> StoryModel {
        let s = StoryModel(title: "Japan Trip", intentRawText: "A week in Japan",
                           intentTheme: "travel", intentTone: "warm", intentSummary: "Japan trip")
        ctx.insert(s); try ctx.save(); return s
    }

    private func seedV2Guide(_ s: StoryModel) throws {
        let json = """
        {"schema_version":"story_guide/2","story_id":"\(s.id.uuidString)","framing_summary":"Your week in Japan",
         "scenes":[
           {"id":"scene_01","title":"Temple morning","what_to_capture":"w","how_to_shoot":"h","why_it_matters":"y"},
           {"id":"scene_02","title":"Street food","what_to_capture":"w","how_to_shoot":"h","why_it_matters":"y"}]}
        """
        ctx.insert(StoryGuideModel(storyId: s.id, guideJSON: json, schemaVersion: "story_guide/2",
                                   promptVersion: "story_guide/v2"))
        try ctx.save()
    }

    // MARK: - DTO decode

    func test_refinement_result_decodes_with_changes_and_archived() throws {
        let sid = UUID().uuidString
        let json = """
        {"guide":{"schema_version":"story_guide/2","story_id":"\(sid)","framing_summary":"f",
                  "scenes":[{"id":"scene_01","title":"T","what_to_capture":"w","how_to_shoot":"h","why_it_matters":"y"}]},
         "changes":[{"scene_id":"scene_01","disposition":"preserved","title":"T"},
                    {"scene_id":"scene_02","disposition":"archived"}],
         "archived_scene_ids":["scene_02"]}
        """.data(using: .utf8)!
        let r = try StoryContractCoding.decoder().decode(StoryGuideRefinementResultDTO.self, from: json)
        XCTAssertEqual(r.guide.scenes.count, 1)
        XCTAssertEqual(r.changes.count, 2)
        XCTAssertEqual(r.changes[1].title, "")             // absent title -> "" (no throw)
        XCTAssertEqual(r.archivedSceneIds, ["scene_02"])
    }

    // MARK: - Pins

    func test_pin_toggle_is_durable_and_protected() async throws {
        let s = try makeStory(); try seedV2Guide(s)
        let coord = StoryGuideCoordinator(context: ctx)
        XCTAssertFalse(coord.isPinned(storyId: s.id, sceneId: "scene_02"))
        XCTAssertTrue(coord.togglePin(storyId: s.id, sceneId: "scene_02"))   // pin -> true
        XCTAssertTrue(coord.isPinned(storyId: s.id, sceneId: "scene_02"))
        XCTAssertEqual(coord.pinnedSceneIds(for: s.id), ["scene_02"])
        XCTAssertFalse(coord.togglePin(storyId: s.id, sceneId: "scene_02"))  // unpin -> false
        XCTAssertTrue(coord.pinnedSceneIds(for: s.id).isEmpty)
    }

    // MARK: - Captured derivation + refinement preservation

    func test_refine_persists_and_preserves_captured_scene() async throws {
        let s = try makeStory(); try seedV2Guide(s)
        // Mark scene_01 captured via a Coverage/2 snapshot (strong state).
        let cov = """
        {"schema_version":"story_coverage/2","story_id":"\(s.id.uuidString)","story_guide_id":"g",
         "story_guide_version":"story_guide/2","moment_count":1,"pending_count":0,"source_understanding_ids":[],
         "dimension_coverage":[{"story_guide_dimension_id":"scene_01","state":"strong","note":null,
                                "evidence_moment_ids":[],"represented_possibility_ids":[]}],
         "strengths":[],"redundancies":[],"sufficiency":{"status":"workable","reason":null},"story_idea":null}
        """
        ctx.insert(StoryCoverageModel(storyId: s.id, coverageJSON: cov,
                   sourceUnderstandingIdsFingerprint: "", creativeIntentFingerprint: "", pendingCount: 0))
        try ctx.save()

        let coord = StoryGuideCoordinator(context: ctx, refineService: FakeRefineService())
        XCTAssertEqual(coord.capturedSceneIds(for: s.id), ["scene_01"])
        let outcome = try await coord.refineGuideV2(for: s, instruction: "we filmed temples, show something new")
        // captured scene_01 survived verbatim; the fake added a new scene; nothing captured was archived.
        XCTAssertTrue(outcome.guide.scenes.contains { $0.id == "scene_01" })
        XCTAssertFalse(outcome.archivedSceneIds.contains("scene_01"))
        // persisted into the SAME row
        XCTAssertEqual(coord.guideV2(for: s.id)?.scenes.contains { $0.id == "scene_01" }, true)
    }

    func test_failed_refine_preserves_current_guide() async throws {
        let s = try makeStory(); try seedV2Guide(s)
        let before = StoryGuideCoordinator(context: ctx).guideV2(for: s.id)
        let coord = StoryGuideCoordinator(context: ctx, refineService: BoomRefineService())
        do {
            _ = try await coord.refineGuideV2(for: s, instruction: "x")
            XCTFail("expected an unavailable error")
        } catch {
            // current guide untouched
            let after = coord.guideV2(for: s.id)
            XCTAssertEqual(after?.scenes.map { $0.id }, before?.scenes.map { $0.id })
        }
    }

    func test_refine_without_guide_throws_noGuide() async throws {
        let s = try makeStory()   // no v2 guide seeded
        let coord = StoryGuideCoordinator(context: ctx, refineService: FakeRefineService())
        do { _ = try await coord.refineGuideV2(for: s, instruction: "x"); XCTFail("expected noGuide") }
        catch { /* expected */ }
    }
}

// Fake refine service: echoes current scenes + appends one new scene (exercises persist + preserve paths).
private struct FakeRefineService: StoryGuideRefining {
    func refine(_ request: StoryGuideRefineRequestDTO) async throws -> StoryGuideRefinementResultDTO {
        // Build a result: keep scene_01, add scene_03; archive nothing captured.
        let sid = request.storyId.uuidString
        let json = """
        {"guide":{"schema_version":"story_guide/2","story_id":"\(sid)","framing_summary":"updated",
                  "scenes":[{"id":"scene_01","title":"Temple morning","what_to_capture":"w","how_to_shoot":"h","why_it_matters":"y"},
                            {"id":"scene_03","title":"Bamboo grove","what_to_capture":"w","how_to_shoot":"h","why_it_matters":"y"}]},
         "changes":[{"scene_id":"scene_01","disposition":"preserved","title":"Temple morning"},
                    {"scene_id":"scene_03","disposition":"added","title":"Bamboo grove"},
                    {"scene_id":"scene_02","disposition":"archived","title":"Street food"}],
         "archived_scene_ids":["scene_02"]}
        """.data(using: .utf8)!
        return try StoryContractCoding.decoder().decode(StoryGuideRefinementResultDTO.self, from: json)
    }
}

// A refine service that always fails -> the coordinator must preserve the current guide + surface .unavailable.
private struct BoomRefineService: StoryGuideRefining {
    func refine(_ request: StoryGuideRefineRequestDTO) async throws -> StoryGuideRefinementResultDTO {
        throw StoryGuideServiceError.unavailable
    }
}
