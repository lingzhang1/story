import Foundation
import CryptoKit

// AUEvidenceService — P1-F Option 8-i: DEVICE-SIDE retrieval of reusable AU frame evidence.
//
// On a valid cache hit the device SKIPS full-video restore + MomentFrameExtractor re-extraction at Create:
// it fetches the account-authorized evidence package manifest, downloads the ONE compact packed-frames blob
// over a short-lived presigned GET, validates identity/integrity, selects the editorially-relevant frames
// (Highlights vs Full Story) via EvidenceFrameMapper, and hands them to MomentContactSheetBuilder.buildFromFrames
// — the same sheet shape the extraction path produces. A miss/validation failure returns nil so the caller
// uses the EXISTING restore/extract fallback unchanged (never fabricated, never a different source version).
//
// SECURITY: retrieval is require_user server-side; the server turns the AU-time SHA CLAIM into AUTHORITY by
// matching the account's verified cloud-media record (owner + source identity + sha + extractor version). The
// device additionally re-validates the downloaded blob's sha256 against the manifest before use — so a wrong/
// corrupt blob is a MISS, never silently used.

// MARK: - Wire DTOs (match evidence_package/1 + the retrieval envelope)

struct EvidenceFrameRefDTO: Decodable {
    let index: Int
    let tMs: Int
    let offset: Int
    let length: Int
    enum CodingKeys: String, CodingKey { case index, tMs = "t_ms", offset, length }
}

struct EvidenceFramesRefDTO: Decodable {
    let cloudMediaId: String
    let bytes: Int
    let sha256: String
    let layout: String
    enum CodingKeys: String, CodingKey {
        case cloudMediaId = "cloud_media_id", bytes, sha256, layout
    }
}

struct EvidenceManifestDTO: Decodable {
    let schemaVersion: String
    let momentId: String
    let contentSha256: String
    let frameExtractionVersion: String
    let frameCount: Int
    let sampledFrameMs: [Int]
    let frames: [EvidenceFrameRefDTO]
    let framesRef: EvidenceFramesRefDTO
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", momentId = "moment_id", contentSha256 = "content_sha256"
        case frameExtractionVersion = "frame_extraction_version", frameCount = "frame_count"
        case sampledFrameMs = "sampled_frame_ms", frames, framesRef = "frames_ref"
    }
}

struct EvidenceDownloadDTO: Decodable {
    let url: String
    let expiresIn: Int
    enum CodingKeys: String, CodingKey { case url, expiresIn = "expires_in" }
}

struct EvidenceGetResponseDTO: Decodable {
    let available: Bool
    let reason: String?
    let manifest: EvidenceManifestDTO?
    let download: EvidenceDownloadDTO?
}

enum AUEvidenceError: Error {
    case miss(String)        // a benign cache miss (reason) -> caller falls back
    case integrity           // manifest/blob integrity failed -> treat as miss
    case transport(Error)
    case badStatus(Int)
}

// MARK: - Service

struct AUEvidenceService {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = StoryBackend.backgroundSession

    /// Resolve the account-authorized evidence manifest for a Moment, or a miss. `frameExtractionVersion` is
    /// sent so the SERVER rejects a package whose pixels came from a different extractor policy.
    func fetchManifest(momentId: UUID,
                       frameExtractionVersion: String = MomentFrameExtractor.extractionPolicy)
        async throws -> (manifest: EvidenceManifestDTO, download: EvidenceDownloadDTO) {
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/evidence/\(momentId.uuidString.lowercased())"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "frame_extraction_version", value: frameExtractionVersion)]
        var req = URLRequest(url: comps.url!)
        StoryBackend.authorize(&req)
        let data: Data; let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw AUEvidenceError.transport(error) }
        guard let http = resp as? HTTPURLResponse else { throw AUEvidenceError.badStatus(-1) }
        guard http.statusCode == 200 else { throw AUEvidenceError.badStatus(http.statusCode) }
        let decoded = try JSONDecoder().decode(EvidenceGetResponseDTO.self, from: data)
        guard decoded.available, let m = decoded.manifest, let d = decoded.download else {
            throw AUEvidenceError.miss(decoded.reason ?? "unavailable")
        }
        return (m, d)
    }

    /// Download the compact packed-frames blob and VALIDATE it against the manifest (size + full-file sha256).
    /// A mismatch -> integrity error (caller treats as a miss). Returns the raw packed bytes.
    func downloadPacked(_ download: EvidenceDownloadDTO, manifest: EvidenceManifestDTO) async throws -> Data {
        guard let url = URL(string: download.url) else { throw AUEvidenceError.integrity }
        let data: Data; let resp: URLResponse
        do { (data, resp) = try await session.data(from: url) }
        catch { throw AUEvidenceError.transport(error) }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AUEvidenceError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard data.count == manifest.framesRef.bytes else { throw AUEvidenceError.integrity }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sha == manifest.framesRef.sha256 else { throw AUEvidenceError.integrity }
        return data
    }

    /// Slice the packed blob into ordered AUExtractedFrames using the manifest index. Validates each slice is
    /// in-bounds; any inconsistency -> integrity error.
    func unpackFrames(_ packed: Data, manifest: EvidenceManifestDTO) throws -> [AUExtractedFrame] {
        var out: [AUExtractedFrame] = []
        for ref in manifest.frames.sorted(by: { $0.index < $1.index }) {
            let start = ref.offset, end = ref.offset + ref.length
            guard start >= 0, end <= packed.count, ref.length > 0 else { throw AUEvidenceError.integrity }
            let jpeg = packed.subdata(in: start..<end)
            out.append(AUExtractedFrame(jpeg: jpeg, tMs: ref.tMs))
        }
        guard !out.isEmpty else { throw AUEvidenceError.integrity }
        return out
    }
}
