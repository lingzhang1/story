import AVFoundation
import XCTest
@testable import Story

// Media Engine V1 unit tests (Milestone R-b §6). These exercise the PURE, deterministic logic — output sizing,
// aspect-fill transforms, native-audio + soundtrack gain policy, cut-snap eligibility, EditPlan/2 decode, and
// error typing. They run under XCTest (Xcode/simulator). ACTUAL render/export is a device-gate case, NOT here.
final class MediaEngineV1Tests: XCTestCase {

    func testOutputSizeSelection() throws {
        XCTAssertEqual(try OutputSize.render(for: "vertical"), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(try OutputSize.render(for: "square"), CGSize(width: 1080, height: 1080))
        XCTAssertEqual(try OutputSize.render(for: "landscape"), CGSize(width: 1920, height: 1080))
        XCTAssertThrowsError(try OutputSize.render(for: "hexagon"))
    }

    func testAspectFillCentersAndCovers() {
        // a 1920x1080 landscape source into a 1080x1920 vertical frame -> scale to cover, centered
        let t = MediaEngineV1.aspectFillTransform(natural: CGSize(width: 1920, height: 1080),
                                                  preferred: .identity,
                                                  render: CGSize(width: 1080, height: 1920))
        // covering a 1080-wide frame from a 1920-wide source after height-fill: scale = max(1080/1920, 1920/1080)
        XCTAssertGreaterThan(t.a, 1.0)   // scaled up to cover the taller frame
        XCTAssertEqual(t.a, t.d, accuracy: 0.0001)  // uniform scale (no stretch)
    }

    func testNativeAudioCaptureGain() {
        XCTAssertEqual(NativeAudioPolicy.captureGain(nativeAudio: "keep"), 1.0)
        XCTAssertEqual(NativeAudioPolicy.captureGain(nativeAudio: "duck"), 0.25, accuracy: 0.001)
        XCTAssertEqual(NativeAudioPolicy.captureGain(nativeAudio: "mute"), 0.0)
    }

    func testSoundtrackStepsBackUnderKeptImportantNative() {
        // keep + important + sparse => music silenced so the real sound leads
        XCTAssertEqual(NativeAudioPolicy.soundtrackGainUnder(nativeAudio: "keep", role: "sparse", priority: "important"), 0.0)
        // keep + important (non-sparse) => music well back
        XCTAssertLessThan(NativeAudioPolicy.soundtrackGainUnder(nativeAudio: "keep", role: "continuous", priority: "important"), 0.2)
        // duck + continuous => music carries full
        XCTAssertEqual(NativeAudioPolicy.soundtrackGainUnder(nativeAudio: "duck", role: "continuous", priority: "low"), 1.0)
    }

    func testCutSnapEligibilityTempoGated() {
        let tempo = MusicAnalysisV1(durationSeconds: 20, bpm: 120, tempoReliable: true,
                                    beats: [0, 0.5, 1.0, 1.48], downbeats: [0, 2.0], highlightWindow: nil)
        // planned 1.46s with downbeat anchor + reliable tempo -> snaps to nearest beat within 0.15
        XCTAssertEqual(MediaEngineV1.snappedCut(at: 1.46, anchor: "beat", analysis: tempo), 1.48, accuracy: 0.001)
        // ambient (tempo NOT reliable) -> never snapped, even with a beat grid present
        let ambient = MusicAnalysisV1(durationSeconds: 20, bpm: nil, tempoReliable: false,
                                      beats: [0, 0.5, 1.0], downbeats: [0], highlightWindow: nil)
        XCTAssertEqual(MediaEngineV1.snappedCut(at: 0.52, anchor: "downbeat", analysis: ambient), 0.52, accuracy: 0.001)
        // anchor none -> never snapped
        XCTAssertEqual(MediaEngineV1.snappedCut(at: 0.52, anchor: "none", analysis: tempo), 0.52, accuracy: 0.001)
        // beyond tolerance -> keep planned
        XCTAssertEqual(MediaEngineV1.snappedCut(at: 5.0, anchor: "beat", analysis: tempo), 5.0, accuracy: 0.001)
    }

    func testEditPlanV2Decodes() throws {
        let json = """
        {"schema_version":"edit_plan/2","target_duration_seconds":12.0,"output_format":"vertical",
         "music_asset_id":null,"feasible":true,"segments":[
           {"order":0,"asset_id":"11111111-1111-1111-1111-111111111111","source_start_seconds":0.0,
            "source_end_seconds":4.0,"output_duration_seconds":4.0,"native_audio":"keep",
            "music_alignment":{"anchor":"highlight"}}]}
        """.data(using: .utf8)!
        let plan = try DebugEditPlanFixture.decode(json)
        XCTAssertEqual(plan.schemaVersion, "edit_plan/2")
        XCTAssertEqual(plan.segments.first?.nativeAudio, "keep")
        XCTAssertEqual(plan.segments.first?.musicAlignment?.anchor, "highlight")
    }

    func testMissingMomentHardFails() async {
        let plan = EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: 4.0, outputFormat: "vertical",
                              musicAssetId: nil, feasible: true,
                              segments: [EditSegmentV2(order: 0, assetId: "nope", sourceStartSeconds: 0,
                                                       sourceEndSeconds: 4, outputDurationSeconds: 4,
                                                       speed: 1.0, nativeAudio: "keep", musicAlignment: nil)])
        let inputs = MediaEngineInputs(plan: plan, resolveMomentURL: { _ in nil }, soundtrackURL: nil,
                                       musicAnalysis: nil, soundtrackRole: "supportive", nativeAudioPriority: "low")
        do {
            _ = try MediaEngineV1().buildComposition(inputs)
            XCTFail("expected missingMoment")
        } catch MediaEngineError.missingMoment(let id) {
            XCTAssertEqual(id, "nope")   // hard fail, never silent skip
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testInfeasiblePlanRejected() {
        let plan = EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: 4.0, outputFormat: "vertical",
                              musicAssetId: nil, feasible: false, segments: [])
        let inputs = MediaEngineInputs(plan: plan, resolveMomentURL: { _ in nil }, soundtrackURL: nil,
                                       musicAnalysis: nil, soundtrackRole: "supportive", nativeAudioPriority: "low")
        XCTAssertThrowsError(try MediaEngineV1().buildComposition(inputs))
    }
}
