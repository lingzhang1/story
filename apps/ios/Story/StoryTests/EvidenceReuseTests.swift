import XCTest
import CryptoKit
@testable import Story

// P1-F — iOS offline tests for the device-side evidence reuse (Option 8-i): the Swift EvidenceFrameMapper
// (deterministic port, kept in lockstep with packages/evidence_mapper) and AUEvidenceService packing/
// validation. Pure logic — no network, no SwiftData, no device media — so these run under ⌘U fast.
final class EvidenceReuseTests: XCTestCase {

    private func sampled(_ n: Int = 24, dur: Double = 35.3) -> [Int] {
        let step = (dur * 1000) / Double(n - 1)
        return (0..<n).map { Int(($0 == 0 ? 0 : Double($0) * step).rounded()) }
    }

    // MARK: - mapper determinism + budget

    func test_mapper_deterministic_and_within_budget() {
        let s = sampled()
        let args: () -> [Int] = {
            EvidenceFrameMapper.selectFrames(
                videoType: .highlights, sampledFrameMs: s,
                visualCandidates: [EvidenceCandidate(start: 6, end: 10.5, peak: 9.5, confidence: 0.8)],
                narrativeCandidates: [], eventTimesS: [], budget: 8)
        }
        let a = args(), b = args()
        XCTAssertEqual(a, b)                      // deterministic
        XCTAssertEqual(a, a.sorted())             // ascending
        XCTAssertEqual(a.count, Set(a).count)     // de-duplicated
        XCTAssertLessThanOrEqual(a.count, 8)
    }

    func test_mapper_no_candidate_uniform_full_budget() {
        let s = sampled()
        let out = EvidenceFrameMapper.selectFrames(
            videoType: .highlights, sampledFrameMs: s,
            visualCandidates: [], narrativeCandidates: [], eventTimesS: [], budget: 6)
        XCTAssertEqual(out.count, 6)
        XCTAssertEqual(out.first, 0)
        XCTAssertEqual(out.last, s.count - 1)
    }

    func test_mapper_overview_floor_survives_mid_candidate() {
        let s = sampled()
        let out = EvidenceFrameMapper.selectFrames(
            videoType: .highlights, sampledFrameMs: s,
            visualCandidates: [EvidenceCandidate(start: 15, end: 17, peak: 16, confidence: 0.9)],
            narrativeCandidates: [], eventTimesS: [], budget: 8)
        XCTAssertTrue(out.contains(0))            // opening context
        XCTAssertTrue(out.contains(s.count - 1))  // closing context
    }

    func test_mapper_highlights_vs_full_story_differ() {
        let s = sampled()
        let vis = [EvidenceCandidate(start: 3, end: 6, peak: 4.5, confidence: 0.9)]
        let nar = [EvidenceCandidate(start: 28, end: 33, peak: nil, confidence: 0.6)]
        let h = EvidenceFrameMapper.selectFrames(videoType: .highlights, sampledFrameMs: s,
                                                 visualCandidates: vis, narrativeCandidates: nar,
                                                 eventTimesS: [], budget: 6)
        let f = EvidenceFrameMapper.selectFrames(videoType: .fullStory, sampledFrameMs: s,
                                                 visualCandidates: vis, narrativeCandidates: nar,
                                                 eventTimesS: [], budget: 6)
        XCTAssertNotEqual(h, f)
    }

    // MARK: - IMG_9091 regression (misplaced peak must not collapse selection)

    func test_mapper_img9091_misplaced_peak_brackets_true_reveal() {
        let s = sampled(24, dur: 35.3)
        // AU interval 12..18 but peak mis-estimated early at 12.5s; true reveal ~16.62s.
        let out = EvidenceFrameMapper.selectFrames(
            videoType: .highlights, sampledFrameMs: s,
            visualCandidates: [EvidenceCandidate(start: 12, end: 18, peak: 12.5, confidence: 0.86)],
            narrativeCandidates: [], eventTimesS: [], budget: 8)
        let selectedMs = out.map { s[$0] }
        let trueReveal = 16620
        XCTAssertTrue(selectedMs.contains { abs($0 - trueReveal) <= 1600 }, "\(selectedMs)")
        XCTAssertTrue(selectedMs.contains { $0 < trueReveal }, "need a frame before the reveal")
        XCTAssertTrue(selectedMs.contains { $0 > trueReveal }, "need a frame after the reveal")
    }

    // MARK: - packed-blob unpack + integrity

    private func packed(_ frames: [(Int, Data)]) -> (Data, EvidenceManifestDTO) {
        var buf = Data(); var index: [EvidenceFrameRefDTO] = []
        for (i, (t, jpeg)) in frames.enumerated() {
            index.append(EvidenceFrameRefDTO(index: i, tMs: t, offset: buf.count, length: jpeg.count))
            buf.append(jpeg)
        }
        let sha = SHA256.hash(data: buf).map { String(format: "%02x", $0) }.joined()
        let man = EvidenceManifestDTO(
            schemaVersion: "evidence_package/1", momentId: UUID().uuidString.lowercased(),
            contentSha256: String(repeating: "a", count: 64), frameExtractionVersion: "au_extract/2",
            frameCount: frames.count, sampledFrameMs: frames.map { $0.0 }, frames: index,
            framesRef: EvidenceFramesRefDTO(cloudMediaId: "c", bytes: buf.count, sha256: sha, layout: "concat-jpeg"))
        return (buf, man)
    }

    func test_unpack_roundtrips_exact_bytes() throws {
        let frames = (0..<5).map { ($0 * 1000, Data("jpeg-\($0)-xxxxx".utf8)) }
        let (blob, man) = packed(frames)
        let svc = AUEvidenceService()
        let out = try svc.unpackFrames(blob, manifest: man)
        XCTAssertEqual(out.count, 5)
        for (i, (t, jpeg)) in frames.enumerated() {
            XCTAssertEqual(out[i].tMs, t)
            XCTAssertEqual(out[i].jpeg, jpeg)      // exact bytes preserved
        }
    }

    func test_download_rejects_size_mismatch() async {
        let frames = (0..<3).map { ($0 * 1000, Data("abc".utf8)) }
        let (blob, man) = packed(frames)
        // An out-of-range index in the manifest must be rejected by unpack's bounds check (integrity family:
        // a tampered/corrupt manifest never yields frames from the wrong byte range).
        let svc = AUEvidenceService()
        let oob = EvidenceManifestDTO(
            schemaVersion: man.schemaVersion, momentId: man.momentId, contentSha256: man.contentSha256,
            frameExtractionVersion: man.frameExtractionVersion, frameCount: 1, sampledFrameMs: [0],
            frames: [EvidenceFrameRefDTO(index: 0, tMs: 0, offset: 0, length: blob.count + 99)],
            framesRef: man.framesRef)
        XCTAssertThrowsError(try svc.unpackFrames(blob, manifest: oob))
    }

    // MARK: - buildFromFrames produces a sheet without extraction

    func test_build_from_frames_no_extraction() throws {
        // tiny 1x1 JPEGs so tiling has something to draw.
        func jpeg() -> Data {
            let r = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
            return r.jpegData(withCompressionQuality: 0.6) { ctx in
                UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        }
        let frames = (0..<5).map { AUExtractedFrame(jpeg: jpeg(), tMs: $0 * 1000) }
        let sheet = try MomentContactSheetBuilder.buildFromFrames(
            momentId: UUID(), frames: frames, durationSeconds: 5,
            budget: ContactSheetBudget(framesPerMoment: 5))
        XCTAssertGreaterThan(sheet.jpeg.count, 0)
        XCTAssertEqual(sheet.frameCount, 5)
    }
}
