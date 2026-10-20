import Foundation
import CryptoKit

// R4-A — iOS client for the account-owned cloud media API (/v1/media/*). Small-file path only:
//   initiate (declare sha256 + size) -> presigned PUT of the whole file -> complete (server verifies).
// Large-file true multipart is R4-B. The ORIGINAL is never uploaded through our backend — the presigned PUT
// goes device -> S3 directly.
//
// AUTH: every request carries the ENROLLING account's bearer token, passed EXPLICITLY into each call (rule 9:
// never use the currently-active account's token for another account's job). The caller (MediaUploadQueue)
// obtains a valid token for the job's owner and hands it in; this service never reads a global token seam.
enum MediaUploadError: Error, LocalizedError {
    case transport(Error)
    case unauthorized          // 401 — token invalid/expired for this owner
    case conflict              // 409 — ownership/content conflict
    case badStatus(Int)
    case decoding
    case s3PutFailed(Int)      // presigned PUT to S3 failed
    case verificationFailed(String)  // server /complete rejected (422)

    var errorDescription: String? {
        switch self {
        case .transport: return "Network error during upload."
        case .unauthorized: return "Upload session expired."
        case .conflict: return "Upload ownership conflict."
        case .badStatus(let c): return "Unexpected upload response (\(c))."
        case .decoding: return "Unexpected upload response shape."
        case .s3PutFailed(let c): return "Direct upload to storage failed (\(c))."
        case .verificationFailed(let m): return "Upload verification failed: \(m)"
        }
    }
}

struct MediaInitiateResult {
    let cloudMediaId: String
    let uploadURL: URL
    let created: Bool
}

/// Seam so MediaUploadQueue can be driven by a fake in tests (no network/S3).
protocol MediaUploading {
    func initiate(accessToken: String, sha256: String, size: Int,
                  deviceAssetId: String, sourceMomentId: String) async throws -> MediaInitiateResult
    func putToS3(uploadURL: URL, fileURL: URL, sha256Hex: String) async throws
    func complete(accessToken: String, cloudMediaId: String) async throws
}

struct MediaUploadService: MediaUploading {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = StoryBackend.backgroundSession   // isolated from interactive calls

    /// Full-file sha256 (hex) computed by streaming the file (never loads the whole video into memory).
    static func sha256Hex(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)   // 1 MiB
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    // POST /v1/media/initiate
    func initiate(accessToken: String, sha256: String, size: Int,
                  deviceAssetId: String, sourceMomentId: String) async throws -> MediaInitiateResult {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/media/initiate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "content_sha256": sha256, "size_bytes": size,
            "content_type": "video/quicktime",
            "device_asset_id": deviceAssetId, "source_moment_id": sourceMomentId])
        let (data, resp) = try await call(req)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 401 { throw MediaUploadError.unauthorized }
        if http.statusCode == 409 { throw MediaUploadError.conflict }
        guard http.statusCode == 200 else { throw MediaUploadError.badStatus(http.statusCode) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cmid = obj["cloud_media_id"] as? String,
              let upload = obj["upload"] as? [String: Any],
              let urlStr = upload["url"] as? String, let url = URL(string: urlStr) else {
            throw MediaUploadError.decoding
        }
        return MediaInitiateResult(cloudMediaId: cmid, uploadURL: url,
                                   created: (obj["created"] as? Bool) ?? true)
    }

    // Presigned PUT of the whole file directly to S3. Sends the ChecksumSHA256 header S3 enforces.
    func putToS3(uploadURL: URL, fileURL: URL, sha256Hex: String) async throws {
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "PUT"
        req.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
        // S3 ChecksumSHA256 = base64 of the RAW digest (not the hex).
        if let raw = Data(hexString: sha256Hex) {
            req.setValue(raw.base64EncodedString(), forHTTPHeaderField: "x-amz-checksum-sha256")
        }
        let (_, resp): (Data, URLResponse)
        do { (_, resp) = try await session.upload(for: req, fromFile: fileURL) }
        catch { throw MediaUploadError.transport(error) }
        let http = resp as! HTTPURLResponse
        guard (200...299).contains(http.statusCode) else { throw MediaUploadError.s3PutFailed(http.statusCode) }
    }

    // POST /v1/media/{id}/complete  — server verifies exists+size+full-file sha256.
    func complete(accessToken: String, cloudMediaId: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/media/\(cloudMediaId)/complete"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await call(req)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 401 { throw MediaUploadError.unauthorized }
        if http.statusCode == 404 { throw MediaUploadError.badStatus(404) }
        if http.statusCode == 422 {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"] as? String
            throw MediaUploadError.verificationFailed(detail ?? "verification failed")
        }
        guard http.statusCode == 200 else { throw MediaUploadError.badStatus(http.statusCode) }
    }

    private func call(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) }
        catch { throw MediaUploadError.transport(error) }
    }
}

private extension Data {
    /// Parse a hex string into bytes (nil if malformed / odd length).
    init?(hexString: String) {
        let s = hexString
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
}
