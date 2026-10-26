import XCTest
@testable import Story

// Rich Editorial AU v2 (moment_understanding/2) iOS-side tests — Editorial Pipeline v2 P1-B §13.
// Decode compatibility (v1 read-only + v2 with editorial), candidate shape, and the local
// auActionTimestamps evidence helper (bounds + ordering). No network, no device playback.
final class AssetUnderstandingV2Tests: XCTestCase {

    private func decode(_ json: String) throws -> MomentUnderstandingDTO {
        try StoryContractCoding.decoder().decode(MomentUnderstandingDTO.self, from: Data(json.utf8))
    }

    private let mid = "11111111-1111-1111-1111-111111111111"

    // MARK: - Decode compatibility

    func testV1RecordDecodesReadOnly() throws {
        let v1 = """
        {"moment_id":"\(mid)","schema_version":"moment_understanding/1","frame_policy":"au_frames/1",
         "prompt_version":"au_prompt/1","observed":{"summary":"a","subjects":[],"events":[],
         "temporal_order_note":"","useful_segments":[]},"story_context":{"story_utility":"none"}}
        """
        let dto = try decode(v1)
        XCTAssertEqual(dto.schemaVersion, "moment_understanding/1")
        XCTAssertNil(dto.editorial)            // v1 has no editorial block
        XCTAssertFalse(dto.isV2)
    }

    func testV2RecordDecodesWithCandidates() throws {
        let v2 = """
        {"moment_id":"\(mid)","schema_version":"moment_understanding/2","frame_policy":"au_frames/1",
         "prompt_version":"au_prompt/2","observed":{"summary":"twirl","subjects":["girl"],"events":[],
         "temporal_order_note":"","useful_segments":[]},
         "editorial":{"visual_candidates":[{"start_time":1.0,"end_time":3.5,"peak_time":2.2,
            "visual_value":"dress expands mid-twirl","role":"payoff","confidence":0.7,"evidence":"frames@1200-2400ms"}],
          "narrative_candidates":[{"start_time":0.0,"end_time":10.0,"what_happens":"child plays",
            "why_matters":"establishing context","spoken_meaning":"unknown"}],
          "analysis_version":"au_editorial/1"},
         "story_context":{"story_utility":"strong_elsewhere"}}
        """
        let dto = try decode(v2)
        XCTAssertTrue(dto.isV2)
        XCTAssertEqual(dto.editorial?.visualCandidates.count, 1)
        XCTAssertEqual(dto.editorial?.narrativeCandidates.count, 1)
        XCTAssertEqual(dto.editorial?.visualCandidates.first?.peakTime, 2.2)
        XCTAssertEqual(dto.editorial?.visualCandidates.first?.role, "payoff")
        XCTAssertEqual(dto.editorial?.narrativeCandidates.first?.spokenMeaning, "unknown")
        XCTAssertEqual(dto.editorial?.analysisVersion, "au_editorial/1")
    }

    func testV2MissingPeakDecodesAsNil() throws {
        let v2 = """
        {"moment_id":"\(mid)","schema_version":"moment_understanding/2","frame_policy":"au_frames/1",
         "prompt_version":"au_prompt/2","observed":{"summary":"s","subjects":[],"events":[],
         "temporal_order_note":"","useful_segments":[]},
         "editorial":{"visual_candidates":[{"start_time":1.0,"end_time":3.0,"visual_value":"uncertain"}],
          "narrative_candidates":[]},
         "story_context":{"story_utility":"none"}}
        """
        let dto = try decode(v2)
        XCTAssertNil(dto.editorial?.visualCandidates.first?.peakTime)   // uncertainty retained
    }

    // MARK: - auActionTimestamps helper (local refinement evidence)

    func testActionTimestampsOrderedInBounds() {
        let u = JSONValue.object(fromJSONString: """
        {"observed":{"events":[{"start_time":5.0,"end_time":8.0,"description":"x"},
          {"start_time":1.0,"end_time":2.0,"description":"y"}],"useful_segments":[]},
         "editorial":{"visual_candidates":[{"start_time":3.0,"end_time":4.0,"peak_time":3.5,"visual_value":"v"}],
          "narrative_candidates":[]}}
        """)
        let ts = EditPlanRequestBuilder.auActionTimestamps(from: u, duration: 10.0)
        XCTAssertEqual(ts, [1.0, 2.0, 3.5, 5.0, 8.0])   // sorted, de-duplicated, all in (0,10]
    }

    func testActionTimestampsClampsOutOfBounds() {
        let u = JSONValue.object(fromJSONString: """
        {"observed":{"events":[{"start_time":0.0,"end_time":99.0,"description":"x"}],"useful_segments":[]}}
        """)
        // 0.0 dropped (not > 0); 99.0 dropped (> duration). Nothing survives.
        XCTAssertEqual(EditPlanRequestBuilder.auActionTimestamps(from: u, duration: 10.0), [])
    }

    func testActionTimestampsV1RecordNoEditorial() {
        let u = JSONValue.object(fromJSONString: """
        {"observed":{"events":[{"start_time":2.0,"end_time":4.0,"description":"x"}],"useful_segments":[]}}
        """)
        // A v1 record (no editorial) still yields its event times — safe, additive.
        XCTAssertEqual(EditPlanRequestBuilder.auActionTimestamps(from: u, duration: 10.0), [2.0, 4.0])
    }

    func testActionTimestampsEmptyWhenNoEvidence() {
        let u = JSONValue.object(fromJSONString: #"{"observed":{"events":[],"useful_segments":[]}}"#)
        XCTAssertEqual(EditPlanRequestBuilder.auActionTimestamps(from: u, duration: 10.0), [])
    }

    // sampled_frame_ms provenance (§2) — server-minted frame-input timestamps, optional.
    func testV2SampledFrameMsDecodes() throws {
        let v2 = """
        {"moment_id":"\(mid)","schema_version":"moment_understanding/2","frame_policy":"au_frames/1",
         "prompt_version":"au_prompt/3","n_frames":3,"sampled_frame_ms":[0,1385,2770],
         "observed":{"summary":"s","subjects":[],"events":[],"temporal_order_note":"","useful_segments":[]},
         "story_context":{"story_utility":"none"}}
        """
        let dto = try decode(v2)
        XCTAssertEqual(dto.sampledFrameMs, [0, 1385, 2770])
    }

    func testRecordWithoutSampledFrameMsDecodesNil() throws {
        let v2 = """
        {"moment_id":"\(mid)","schema_version":"moment_understanding/2","frame_policy":"au_frames/1",
         "prompt_version":"au_prompt/2","observed":{"summary":"s","subjects":[],"events":[],
         "temporal_order_note":"","useful_segments":[]},"story_context":{"story_utility":"none"}}
        """
        XCTAssertNil(try decode(v2).sampledFrameMs)   // pre-field record
    }
}
