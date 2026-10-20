import Foundation

// R7-C — HTTP client for the account-owned Story sync API (/v1/stories). Explicit-token auth (owner-bound,
// never the ambient active account inside a callback). Push carries base_revision + mutation_id; a genuine
// 409 surfaces the server's current {revision, doc} for Keep Both / Use Cloud Version.

enum StorySyncError: Error, LocalizedError {
    case transport(Error)
    case unauthorized
    case notFound
    case tooLarge                                   // 413 — doc over the server limit (externalize plans: R7-D)
    case mutationPayloadMismatch                    // 409 mutation_id reused with a different payload
    case conflict(serverRevision: Int, serverDoc: [String: Any])   // genuine optimistic-concurrency conflict
    case badStatus(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .transport: return "Network error during sync."
        case .unauthorized: return "Sync session expired."
        case .notFound: return "Story not found for this account."
        case .tooLarge: return "Story is too large to sync."
        case .mutationPayloadMismatch: return "Sync retry payload mismatch."
        case .conflict: return "This Story changed on another device."
        case .badStatus(let c): return "Unexpected sync response (\(c))."
        case .decoding: return "Unexpected sync response shape."
        }
    }
}

struct StoryIndexEntry {
    let storyId: String
    let revision: Int
    let updatedAt: Int
    let deleted: Bool
    let incompleteDeps: Bool
}

struct StoryPutResult {
    let revision: Int
    let deleted: Bool
    let incompleteDeps: Bool
}

protocol StorySyncing {
    func index(accessToken: String) async throws -> [StoryIndexEntry]
    func get(accessToken: String, storyId: String) async throws -> (revision: Int, doc: [String: Any], deleted: Bool)
    func put(accessToken: String, storyId: String, baseRevision: Int, mutationId: String,
             doc: [String: Any], deleted: Bool, referencedCloudMediaIds: [String]) async throws -> StoryPutResult
}

struct StorySyncService: StorySyncing {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = .shared

    private func authed(_ path: String, _ method: String, token: String) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    func index(accessToken: String) async throws -> [StoryIndexEntry] {
        let req = authed("v1/stories", "GET", token: accessToken)
        let (data, resp) = try await send(req)
        try check(resp, data)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["stories"] as? [[String: Any]] else { throw StorySyncError.decoding }
        return arr.map {
            StoryIndexEntry(
                storyId: ($0["story_id"] as? String) ?? "",
                revision: intOf($0["revision"]),
                updatedAt: intOf($0["updated_at"]),
                deleted: ($0["deleted"] as? Bool) ?? false,
                incompleteDeps: ($0["incomplete_deps"] as? Bool) ?? false)
        }
    }

    func get(accessToken: String, storyId: String) async throws -> (revision: Int, doc: [String: Any], deleted: Bool) {
        let req = authed("v1/stories/\(storyId)", "GET", token: accessToken)
        let (data, resp) = try await send(req)
        try check(resp, data)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw StorySyncError.decoding
        }
        return (intOf(obj["revision"]), (obj["doc"] as? [String: Any]) ?? [:], (obj["deleted"] as? Bool) ?? false)
    }

    func put(accessToken: String, storyId: String, baseRevision: Int, mutationId: String,
             doc: [String: Any], deleted: Bool, referencedCloudMediaIds: [String]) async throws -> StoryPutResult {
        var req = authed("v1/stories/\(storyId)", "PUT", token: accessToken)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "base_revision": baseRevision, "mutation_id": mutationId, "doc": doc,
            "deleted": deleted, "referenced_cloud_media_ids": referencedCloudMediaIds])
        let (data, resp) = try await send(req)
        let http = resp as! HTTPURLResponse
        switch http.statusCode {
        case 200:
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return StoryPutResult(revision: intOf(obj["revision"]), deleted: (obj["deleted"] as? Bool) ?? false,
                                  incompleteDeps: (obj["incomplete_deps"] as? Bool) ?? false)
        case 401: throw StorySyncError.unauthorized
        case 413: throw StorySyncError.tooLarge
        case 409:
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"] as? [String: Any] ?? [:]
            if (detail["error"] as? String) == "mutation_id_payload_mismatch" {
                throw StorySyncError.mutationPayloadMismatch
            }
            let cur = detail["current"] as? [String: Any] ?? [:]
            throw StorySyncError.conflict(serverRevision: intOf(cur["revision"]),
                                          serverDoc: (cur["doc"] as? [String: Any]) ?? [:])
        default: throw StorySyncError.badStatus(http.statusCode)
        }
    }

    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) }
        catch { throw StorySyncError.transport(error) }
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        let http = resp as! HTTPURLResponse
        switch http.statusCode {
        case 200: return
        case 401: throw StorySyncError.unauthorized
        case 404: throw StorySyncError.notFound
        default: throw StorySyncError.badStatus(http.statusCode)
        }
    }

    private func intOf(_ v: Any?) -> Int { (v as? Int) ?? (v as? NSNumber)?.intValue ?? 0 }
}
