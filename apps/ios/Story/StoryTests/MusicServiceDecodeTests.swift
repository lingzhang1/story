import XCTest
@testable import Story

// Music wire-DTO decode tests (R-d). The long "no music on device" bug was a DECODE throw: Epidemic returns
// signed links as an OBJECT {url, expires}, but the DTO fields were typed String, so the WHOLE candidates
// response failed to decode and the app fell back to no-music. These lock the exact wire shapes.
final class MusicServiceDecodeTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func test_signedURL_decodes_object_shape() throws {
        let s = try decode(SignedURL.self, #"{"url":"https://pdn.example/x.m3u8?Expires=1","expires":"2026-10-11T00:00:00Z"}"#)
        XCTAssertEqual(s.url, "https://pdn.example/x.m3u8?Expires=1")
        XCTAssertEqual(s.expires, "2026-10-11T00:00:00Z")
    }

    func test_signedURL_decodes_bare_string_fallback() throws {
        let s = try decode(SignedURL.self, #""https://pdn.example/y.mp3""#)
        XCTAssertEqual(s.url, "https://pdn.example/y.mp3")
        XCTAssertNil(s.expires)
    }

    func test_candidate_decodes_with_object_preview_url() throws {
        // THE regression: object-shaped preview_url must NOT throw.
        let json = """
        {"track_id":"t1","title":"Alpine Journey","score":0.5,"duration_seconds":62.0,
         "vocal_type":"NONE","preview_url":{"url":"https://pdn.example/t1.m3u8","expires":"2026-10-11T00:00:00Z"}}
        """
        let c = try decode(MusicCandidateDTO.self, json)
        XCTAssertEqual(c.trackId, "t1")
        XCTAssertEqual(c.title, "Alpine Journey")
        XCTAssertEqual(c.durationSeconds, 62.0, accuracy: 0.001)
        XCTAssertEqual(c.previewURLString, "https://pdn.example/t1.m3u8")
    }

    func test_candidate_decodes_with_null_preview_url() throws {
        let json = """
        {"track_id":"t2","title":"The Heart","score":0.4,"duration_seconds":58.0,"vocal_type":"NONE","preview_url":null}
        """
        let c = try decode(MusicCandidateDTO.self, json)
        XCTAssertNil(c.previewURLString)
    }

    func test_candidates_response_decodes_full_shape() throws {
        let json = """
        {"candidates":[
            {"track_id":"t1","title":"A","score":0.5,"duration_seconds":62.0,"vocal_type":"NONE",
             "preview_url":{"url":"https://pdn.example/t1.m3u8","expires":"z"}},
            {"track_id":"t2","title":"B","score":0.4,"duration_seconds":58.0,"vocal_type":"NONE","preview_url":null}
         ],
         "top_track_id":"t1",
         "top_music_analysis":{"schema_version":"music_analysis/1","duration_seconds":62.0,"bpm":91.0,
            "tempo_reliable":true,"beats":[0.0,0.5],"downbeats":[0.0],"energy_curve":[],"vocal_type":"NONE"}}
        """
        let r = try decode(MusicCandidatesResponseDTO.self, json)
        XCTAssertEqual(r.candidates.count, 2)
        XCTAssertEqual(r.topTrackId, "t1")
        XCTAssertNotNil(r.topMusicAnalysis)
        XCTAssertEqual(r.topMusicAnalysis?.durationSeconds, 62.0)
        XCTAssertEqual(r.topMusicAnalysis?.tempoReliable, true)
    }

    func test_soundtrack_link_decodes_object_download_url() throws {
        let json = """
        {"track_id":"t1","download_url":{"url":"https://dl.example/t1.mp3?sig=abc","expires":"z"},
         "usage":"prototyping_test","commercial_export_enabled":false}
        """
        let l = try decode(MusicSoundtrackLinkDTO.self, json)
        XCTAssertEqual(l.downloadURL.url, "https://dl.example/t1.mp3?sig=abc")
        XCTAssertEqual(l.usage, "prototyping_test")
        XCTAssertFalse(l.commercialExportEnabled)
    }
}
