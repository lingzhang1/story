import Foundation
import CryptoKit

// R6 — iOS client for cloud media DOWNLOAD & restoration (/v1/media/{id}/download).
// Flow: ask the backend for a short-lived presigned GET + the SERVER-AUTHORITATIVE expectation
// (size_bytes + full-file content_sha256), then STREAM the object to a temp file while hashing, and
// verify size + full-file sha256 before the caller atomically installs it.
//
// AUTH: every request carries the OWNER account's bearer token, passed EXPLICITLY (same rule as upload —
// never use another account's token). The backend scopes the presign to principal.story_user_id, so an
// object that is not the caller's returns 404 and no cross-account bytes are ever fetched.
//
// NEVER loads a large video into memory (safeguard #2 / req #2): the body is consumed as an async byte
// stream, 1 MiB at a time, written straight to disk and fed to the hasher incrementally.

enum MediaDownloadError: Error, LocalizedError {
    case transport(Error)
    case unauthorized           // 401
    case notFound               // 404 — not the caller's object (or gone)
    case notVerified            // 409 — cloud object not yet cloud_verified
    case badStatus(Int)
    case decoding
    case s3GetFailed(Int)       // presigned GET to S3 failed
    case sizeMismatch(expected: Int, got: Int)
    case checksumMismatch       // downloaded bytes != server-authoritative full-file sha256
    case missingExpectation     // server did not return size/checksum to verify against

    var errorDescription: String? {
        switch self {
        case .transport: return "Network error during download."
        case .unauthorized: return "Download session expired."
        case .notFound: return "Cloud media not found for this account."
        case .notVerified: return "Cloud media not yet verified."
        case .badStatus(let c): return "Unexpected download response (\(c))."
        case .decoding: return "Unexpected download response shape."
        case .s3GetFailed(let c): return "Download from storage failed (\(c))."
        case .sizeMismatch(let e, let g): return "Downloaded size \(g) != expected \(e)."
        case .checksumMismatch: return "Downloaded file failed integrity check."
        case .missingExpectation: return "Server did not provide size/checksum to verify the download."
        }
    }
}

/// The server-authoritative download target: a short-lived presigned GET plus the expectation the download
/// is verified against (safeguard #7 — comes from the cloud record, NOT a local upload job).
struct MediaDownloadTarget {
    let url: URL
    let expiresIn: Int
    let expectedSize: Int
    let expectedSha256Hex: String   // full-file sha256 (hex)
    let contentType: String
}

/// Seam so MediaResolver can be driven by a fake in tests (no network/S3).
protocol MediaDownloading {
    /// GET /v1/media/{id}/download — returns the presigned URL + server-authoritative size/checksum.
    func presignDownload(accessToken: String, cloudMediaId: String) async throws -> MediaDownloadTarget
    /// Stream `target.url` to `destURL`, verifying size + full-file sha256. Writes a WHOLE file atomically
    /// into `destURL` only after verification passes; on any failure `destURL` is left absent.
    func download(target: MediaDownloadTarget, to destURL: URL,
                  progress: ((Double) -> Void)?) async throws
}

struct MediaDownloadService: MediaDownloading {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = StoryBackend.backgroundSession

    func presignDownload(accessToken: String, cloudMediaId: String) async throws -> MediaDownloadTarget {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/media/\(cloudMediaId)/download"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw MediaDownloadError.transport(error) }
        let http = resp as! HTTPURLResponse
        switch http.statusCode {
        case 200: break
        case 401: throw MediaDownloadError.unauthorized
        case 404: throw MediaDownloadError.notFound
        case 409: throw MediaDownloadError.notVerified
        default: throw MediaDownloadError.badStatus(http.statusCode)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let urlStr = obj["url"] as? String, let url = URL(string: urlStr) else {
            throw MediaDownloadError.decoding
        }
        // Server-authoritative expectation (safeguard #7). A record missing either is not verifiable.
        guard let size = (obj["size_bytes"] as? Int) ?? (obj["size_bytes"] as? NSNumber)?.intValue,
              let sha = obj["content_sha256"] as? String, !sha.isEmpty else {
            throw MediaDownloadError.missingExpectation
        }
        return MediaDownloadTarget(
            url: url,
            expiresIn: (obj["expires_in"] as? Int) ?? 0,
            expectedSize: size,
            expectedSha256Hex: sha,
            contentType: (obj["content_type"] as? String) ?? "application/octet-stream")
    }

    func download(target: MediaDownloadTarget, to destURL: URL,
                  progress: ((Double) -> Void)? = nil) async throws {
        // Stream to a sibling .part file, hashing as we go; promote to destURL only after verification.
        let partURL = destURL.appendingPathExtension("part")
        let fm = FileManager.default
        try? fm.removeItem(at: partURL)
        try? fm.removeItem(at: destURL)
        fm.createFile(atPath: partURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partURL)
        var hasher = SHA256()
        var written = 0
        let expected = max(target.expectedSize, 1)
        do {
            let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
            do { (bytes, resp) = try await session.bytes(from: target.url) }
            catch { throw MediaDownloadError.transport(error) }
            let http = resp as! HTTPURLResponse
            guard (200...299).contains(http.statusCode) else {
                throw MediaDownloadError.s3GetFailed(http.statusCode)
            }
            var buffer = Data(); buffer.reserveCapacity(1 << 20)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= (1 << 20) {         // flush every 1 MiB — never hold the whole video
                    try handle.write(contentsOf: buffer)
                    hasher.update(data: buffer)
                    written += buffer.count
                    buffer.removeAll(keepingCapacity: true)
                    progress?(min(1.0, Double(written) / Double(expected)))
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                hasher.update(data: buffer)
                written += buffer.count
            }
            try handle.close()
        } catch {
            try? handle.close(); try? fm.removeItem(at: partURL)
            throw (error as? MediaDownloadError) ?? .transport(error)
        }

        // VERIFY before exposing anything as a valid original (safeguard #1/#2).
        if written != target.expectedSize {
            try? fm.removeItem(at: partURL)
            throw MediaDownloadError.sizeMismatch(expected: target.expectedSize, got: written)
        }
        let gotSha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if gotSha.lowercased() != target.expectedSha256Hex.lowercased() {
            try? fm.removeItem(at: partURL)
            throw MediaDownloadError.checksumMismatch
        }
        // Verified → promote the .part to the real temp destination (the CALLER then atomically installs it
        // into the Moment's relativePath). Promotion is a rename on the same volume.
        try? fm.removeItem(at: destURL)
        try fm.moveItem(at: partURL, to: destURL)
        progress?(1.0)
    }
}
