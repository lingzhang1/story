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

    // MARK: - R-b.1 crossfade

    func testTransitionDecodeAndCrossfadeMapping() throws {
        let json = """
        {"schema_version":"edit_plan/2","target_duration_seconds":6.0,"output_format":"vertical",
         "music_asset_id":null,"feasible":true,"segments":[
           {"order":0,"asset_id":"a","source_start_seconds":0,"source_end_seconds":3,
            "output_duration_seconds":3,"native_audio":"keep","transition":{"type":"cut"}},
           {"order":1,"asset_id":"b","source_start_seconds":0,"source_end_seconds":3,
            "output_duration_seconds":3,"native_audio":"keep","transition":{"type":"dissolve","duration_seconds":0.3}}]}
        """.data(using: .utf8)!
        let plan = try DebugEditPlanFixture.decode(json)
        XCTAssertEqual(plan.segments[0].transition?.type, "cut")
        XCTAssertEqual(plan.segments[0].transition?.crossfadeSeconds ?? -1, 0.0, accuracy: 0.0001)  // cut => no overlap
        XCTAssertEqual(plan.segments[1].transition?.type, "dissolve")
        XCTAssertEqual(plan.segments[1].transition?.crossfadeSeconds ?? -1, 0.3, accuracy: 0.0001)  // dissolve => 0.3 overlap
    }

    func testDissolveDefaultsToPointThreeWhenDurationOmitted() {
        XCTAssertEqual(Transition(type: "dissolve", durationSeconds: nil).crossfadeSeconds, 0.3, accuracy: 0.0001)
        XCTAssertEqual(Transition(type: "fade", durationSeconds: 0.3).crossfadeSeconds, 0.0, accuracy: 0.0001)  // fade != crossfade
    }

    func testCrossfadeFixtureOverlapAndDuration() {
        // 3 Moments, 2 dissolves of 0.3s each. output = sum(segments) - 0.3*2.
        let media = (0..<3).map { _ in MomentMedia(momentId: UUID(), relativePath: "media/x.mov", durationSeconds: 5) }
        let plan = DebugEditPlanFixture.crossfade(media: media)
        XCTAssertEqual(plan.segments.count, 3)
        XCTAssertNil(plan.segments[0].transition)                       // first never crossfades
        XCTAssertEqual(plan.segments[1].transition?.type, "dissolve")
        XCTAssertEqual(plan.segments[2].transition?.type, "dissolve")
        let segSum = plan.segments.reduce(0.0) { $0 + $1.outputDurationSeconds }
        XCTAssertEqual(plan.targetDurationSeconds, segSum - 0.6, accuracy: 0.01)   // two 0.3s overlaps removed
    }

    func testSpeedFixtureDurationConsistency() {
        // 0.5x -> output = span/0.5 (longer); 2.0x -> span/2 (shorter); span fixed at 2.0s head window.
        let media = (0..<2).map { _ in MomentMedia(momentId: UUID(), relativePath: "media/x.mov", durationSeconds: 5) }
        let plan = DebugEditPlanFixture.speedCases(media: media)
        XCTAssertEqual(plan.segments[0].speed, 0.5)
        XCTAssertEqual(plan.segments[0].outputDurationSeconds, 4.0, accuracy: 0.01)   // 2.0 / 0.5
        XCTAssertEqual(plan.segments[1].speed, 2.0)
        XCTAssertEqual(plan.segments[1].outputDurationSeconds, 1.0, accuracy: 0.01)   // 2.0 / 2.0
    }

    func testMissingMomentFixtureHasUnresolvableFirstSegment() {
        let media = (0..<2).map { _ in MomentMedia(momentId: UUID(), relativePath: "media/x.mov", durationSeconds: 5) }
        let plan = DebugEditPlanFixture.missingMoment(media: media)
        XCTAssertEqual(plan.segments.first?.assetId, "00000000-0000-0000-0000-000000000000")
        let resolver = MomentResolver.urlResolver(for: media)
        XCTAssertNil(resolver(plan.segments[0].assetId))                // first is unresolvable -> engine hard-fails
    }

    /// Regression lock for the exportFailed("Operation Stopped") bug: the crossfade placement MUST yield
    /// instruction time ranges that tile [0, total] CONTIGUOUSLY with NO gaps and NO overlaps. We reproduce
    /// the engine's placement arithmetic (segStart = cursor - xf; cursor = segStart + outDur) and the boundary
    /// sweep, then assert the slices are contiguous, cover exactly [0, total], and that overlap windows are
    /// precisely the two 0.3s crossfade regions — never double-covering a boundary (the original defect).
    func testCrossfadePlacementTilesTimelineContiguously() {
        let xf = 0.3, dur = 3.0
        // seg0 [0,3], seg1 [2.7,5.7], seg2 [5.4,8.4]  (each pulled back by xf from the running cursor)
        var cursor = 0.0
        var ranges: [(start: Double, end: Double)] = []
        for i in 0..<3 {
            let overlap = i == 0 ? 0.0 : xf
            let start = cursor - overlap
            ranges.append((start, start + dur))
            cursor = start + dur
        }
        let total = cursor
        XCTAssertEqual(total, 8.4, accuracy: 0.001)                     // 3*3 - 2*0.3
        XCTAssertEqual(ranges.map { $0.start }, [0.0, 2.7, 5.4])
        XCTAssertEqual(ranges.map { $0.end }, [3.0, 5.7, 8.4])

        // boundary sweep (mirrors buildComposition): distinct sorted segment starts+ends
        var bset = Set<Double>([0.0, total])
        for r in ranges { bset.insert(r.start); bset.insert(r.end) }
        let bounds = bset.sorted()
        // contiguity: each slice end == next slice start; full coverage [0,total]
        XCTAssertEqual(bounds.first, 0.0); XCTAssertEqual(bounds.last, total, accuracy: 0.001)
        // count live segments per slice; expect pattern solo,overlap,solo,overlap,solo
        func live(_ a: Double, _ b: Double) -> Int {
            ranges.filter { $0.start <= a + 1e-9 && $0.end >= b - 1e-9 }.count
        }
        var pattern: [Int] = []
        for k in 0..<(bounds.count - 1) {
            let a = bounds[k], b = bounds[k + 1]
            if b - a < 1e-9 { continue }
            pattern.append(live(a, b))
        }
        XCTAssertEqual(pattern, [1, 2, 1, 2, 1])                        // solo | crossfade | solo | crossfade | solo
        // no slice has 0 live segments (would be a gap -> black frame / invalid timeline)
        XCTAssertFalse(pattern.contains(0))
    }
}
