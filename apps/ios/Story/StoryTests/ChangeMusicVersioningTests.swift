import XCTest
@testable import Story

// Change Music + shared versioning contract tests (Milestone M-e).
// PURE/deterministic parts only — real re-render/export is a device-gate case (Phase 5), not here.
//
// The load-bearing guarantee: a persisted executable EditPlan (GeneratedOutputModel.editPlanJSON)
// round-trips to the IDENTICAL visual edit, so Change Music reuses the exact timeline rather than
// a similar one. This is what makes "same visual edit, different soundtrack" true.
final class ChangeMusicVersioningTests: XCTestCase {

    private let wire = """
    {"schema_version":"edit_plan/2","target_duration_seconds":12.5,"output_format":"vertical",
     "music_asset_id":"abc","feasible":true,
     "segments":[
      {"order":0,"asset_id":"A1B2","source_start_seconds":1.0,"source_end_seconds":4.5,
       "output_duration_seconds":3.5,"speed":1.0,"native_audio":"keep",
       "music_alignment":{"anchor":"beat","note":"x"},"transition":{"type":"dissolve","duration_seconds":0.3}},
      {"order":1,"asset_id":"C3D4","source_start_seconds":0.0,"source_end_seconds":2.0,
       "output_duration_seconds":4.0,"speed":1.5,"native_audio":"duck","transition":{"type":"cut"}}
     ]}
    """.data(using: .utf8)!

    /// Encoding a decoded plan and decoding it again preserves EVERY field that defines the visual edit.
    func testExecutablePlanRoundTripPreservesVisualEdit() throws {
        let plan = try StoryContractCoding.decoder().decode(EditPlanV2.self, from: wire)
        let reencoded = try StoryContractCoding.encoder().encode(plan)
        let plan2 = try StoryContractCoding.decoder().decode(EditPlanV2.self, from: reencoded)

        XCTAssertEqual(plan2.segments.count, 2)
        XCTAssertEqual(plan2.targetDurationSeconds, 12.5)
        XCTAssertEqual(plan2.outputFormat, "vertical")

        XCTAssertEqual(plan2.segments[0].assetId, "A1B2")
        XCTAssertEqual(plan2.segments[0].sourceStartSeconds, 1.0)
        XCTAssertEqual(plan2.segments[0].sourceEndSeconds, 4.5)
        XCTAssertEqual(plan2.segments[0].outputDurationSeconds, 3.5)
        XCTAssertEqual(plan2.segments[0].nativeAudio, "keep")
        XCTAssertEqual(plan2.segments[0].transition?.type, "dissolve")
        XCTAssertEqual(plan2.segments[0].transition?.durationSeconds, 0.3)
        XCTAssertEqual(plan2.segments[0].musicAlignment?.anchor, "beat")

        XCTAssertEqual(plan2.segments[1].speed, 1.5)
        XCTAssertEqual(plan2.segments[1].outputDurationSeconds, 4.0)
        XCTAssertEqual(plan2.segments[1].nativeAudio, "duck")
        XCTAssertEqual(plan2.segments[1].transition?.type, "cut")
    }

    /// A Change-Music version carries the SAME plan JSON as its parent and links lineage correctly.
    func testChangeMusicVersionCarriesSamePlanAndLinksParent() throws {
        let parent = GeneratedOutputModel(
            title: "TMB", durationSeconds: 12.5, momentIds: [],
            editPlanJSON: String(data: wire, encoding: .utf8),
            soundtrackRole: "supportive", nativeAudioPriority: "selective",
            soundPreferenceRaw: "balanced", musicAssetRef: "provider:T1")

        // Simulate the persistence a Change-Music re-render performs (same plan, new version, parent link).
        let child = GeneratedOutputModel(
            title: parent.title, durationSeconds: parent.durationSeconds, momentIds: [],
            versionId: UUID(), parentVersionId: parent.versionId, operationType: "change_music",
            editPlanJSON: parent.editPlanJSON, soundtrackRole: parent.soundtrackRole,
            nativeAudioPriority: parent.nativeAudioPriority, soundPreferenceRaw: parent.soundPreferenceRaw,
            musicAssetRef: "mymusic:ABC")

        XCTAssertEqual(child.operationType, "change_music")
        XCTAssertEqual(child.parentVersionId, parent.versionId)
        XCTAssertNotEqual(child.versionId, parent.versionId)       // a distinct version, not an overwrite
        XCTAssertEqual(child.editPlanJSON, parent.editPlanJSON)    // SAME visual edit
        XCTAssertEqual(child.musicAssetRef, "mymusic:ABC")         // only the soundtrack changed
        XCTAssertNotEqual(child.musicAssetRef, parent.musicAssetRef)
    }

    /// A legacy output (no persisted plan) is correctly NOT Change-Music eligible — honest, not a crash.
    func testLegacyOutputHasNoPlanSoChangeMusicIsRefused() {
        let legacy = GeneratedOutputModel(title: "old", durationSeconds: 5, momentIds: [])
        XCTAssertNil(legacy.editPlanJSON)
        XCTAssertEqual(legacy.operationType, "original")   // defaults are migration-safe
        XCTAssertEqual(legacy.versionId, legacy.id)        // versionId defaults to the row id
    }
}
