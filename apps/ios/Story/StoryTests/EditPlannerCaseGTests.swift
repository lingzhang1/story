import XCTest
import SwiftData
@testable import Story

// R-b Case G — real Edit Planner request construction + EditPlan/2 decode (iOS side).
//
// VERIFIED HERE: pure request-shape + decode logic (no network, no render).
// REQUIRES XCODE/DEVICE: the actual /v1/edit-plan round-trip and MediaEngineV1 render.
//
// Covers:
//   1. Builder emits the exact backend shape: moments[].{id, duration_seconds, useful_segments:[[a,b]]}.
//   2. NO-MUSIC mode: no music_plan / music_asset_id / music_analysis fields on the wire.
//   3. creative_intent carries target_duration_seconds (required by the backend).
//   4. A Moment WITHOUT completed AU (or without a local file) is EXCLUDED, never sent with invented content.
//   5. No usable Moments -> a clear error, never an empty/fabricated request.
//   6. EditPlanV2 decodes a real backend response (field alignment).
@MainActor
final class EditPlannerCaseGTests: XCTestCase {
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

    private func newStory(target: Double? = 9.0) -> StoryModel {
        let s = StoryModel(title: "Learning Guitar", intentRawText: "my guitar journey",
                           intentTheme: "growth", intentTone: "warm", intentSummary: "learning to play")
        s.intentTargetDurationSeconds = target
        ctx.insert(s)
        return s
    }

    // A Moment whose asset file actually exists on disk (temp .mov placeholder) so MomentResolver keeps it.
    private func momentWithFile(_ story: StoryModel, rel: String, dur: Double) -> MomentModel {
        let abs = MediaStore.shared.absoluteURL(for: rel)
        try? FileManager.default.createDirectory(at: abs.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
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

    func test_builder_shape_and_identity_mapping() throws {
        let s = newStory()
        let m1 = momentWithFile(s, rel: "media/caseg-1.mov", dur: 8.0)
        completeAU(m1, useful: [(0.5, 5.0)])
        let m2 = momentWithFile(s, rel: "media/caseg-2.mov", dur: 10.0)
        completeAU(m2, useful: [(1.0, 6.0)])

        let build = try EditPlanRequestBuilder.build(story: s, context: ctx)
        XCTAssertEqual(build.includedMedia.count, 2)
        XCTAssertEqual(build.excludedMomentIds.count, 0)

        // Encode to the wire and assert the backend-visible shape.
        let data = try StoryContractCoding.encoder().encode(build.request)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(obj["story_id"]); XCTAssertNotNil(obj["creative_intent_id"])
        XCTAssertEqual(obj["output_format"] as? String, "vertical")

        let ci = obj["creative_intent"] as! [String: Any]
        XCTAssertEqual(ci["target_duration_seconds"] as? Double, 9.0)   // required

        let moments = obj["moments"] as! [[String: Any]]
        XCTAssertEqual(moments.count, 2)
        // Identity: request moment id == the persisted Moment id (== asset_id echoed back by the planner).
        XCTAssertEqual(moments[0]["id"] as? String, m1.id.uuidString)
        XCTAssertEqual(moments[0]["duration_seconds"] as? Double, 8.0)
        let useful = moments[0]["useful_segments"] as! [[Double]]
        XCTAssertEqual(useful.first ?? [], [0.5, 5.0])                  // [[a,b]] pairs, not AU objects
        _ = m2
    }

    func test_no_music_mode_omits_music_fields() throws {
        let s = newStory()
        let m = momentWithFile(s, rel: "media/caseg-nm.mov", dur: 6.0)
        completeAU(m, useful: [(0.0, 4.0)])
        let data = try StoryContractCoding.encoder().encode(EditPlanRequestBuilder.build(story: s, context: ctx).request)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(obj["music_plan"])
        XCTAssertNil(obj["music_asset_id"])
        XCTAssertNil(obj["music_analysis"])
        XCTAssertNil(obj["music_plan_id"])
    }

    func test_moment_without_completed_AU_is_excluded() throws {
        let s = newStory()
        let good = momentWithFile(s, rel: "media/caseg-good.mov", dur: 7.0)
        completeAU(good, useful: [(0.5, 4.0)])
        let noAU = momentWithFile(s, rel: "media/caseg-noau.mov", dur: 9.0)   // file exists, NO understanding

        let build = try EditPlanRequestBuilder.build(story: s, context: ctx)
        XCTAssertEqual(build.includedMedia.map(\.momentId), [good.id])
        XCTAssertEqual(build.excludedMomentIds, [noAU.id])               // dropped, never invented
    }

    func test_no_usable_moments_throws() {
        let s = newStory()
        // A Moment with completed AU but NO local file -> not resolvable -> excluded -> nothing to plan.
        let asset = AssetModel(relativePath: "media/missing-\(UUID()).mov", durationSeconds: 5, source: .directed)
        let m = MomentModel(source: .directed, asset: asset); m.story = s; ctx.insert(m)
        completeAU(m, useful: [(0, 3)])
        XCTAssertThrowsError(try EditPlanRequestBuilder.build(story: s, context: ctx))
    }

    func test_editplan_v2_decodes_real_response() throws {
        let json = """
        {"schema_version":"edit_plan/2","target_duration_seconds":9.0,"output_format":"vertical",
         "music_asset_id":null,"feasible":true,"segments":[
          {"order":0,"asset_id":"aaaaaaaa-0000-0000-0000-000000000001","source_start_seconds":0.5,
           "source_end_seconds":3.0,"output_duration_seconds":2.5,"speed":1.0,"native_audio":"keep",
           "music_alignment":null}]}
        """
        let plan = try DebugEditPlanFixture.decode(Data(json.utf8))
        XCTAssertEqual(plan.schemaVersion, "edit_plan/2")
        XCTAssertTrue(plan.feasible)
        XCTAssertEqual(plan.segments.first?.assetId, "aaaaaaaa-0000-0000-0000-000000000001")
        XCTAssertEqual(plan.segments.first?.nativeAudio, "keep")
        XCTAssertNil(plan.segments.first?.musicAlignment)
    }
}
