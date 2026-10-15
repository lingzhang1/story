import Foundation
import CryptoKit

// StoryCoverageService — the Milestone-E network boundary for Story Coverage
// (story_coverage/1, FROZEN).
//
// Calls POST /v1/story-coverage on the EXISTING App Runner service with a JSON
// body (TEXT-ONLY — no media, no frames, no Director history, no SceneUnderstanding,
// no CaptureSessions): the resolved CreativeIntent (compact), scope, the COMPLETE
// MomentUnderstanding records (observed + story_context), and pending_count.
// Decodes the canonical story_coverage/1 wire shape.
//
// Failure is surfaced (503 => retryable / keep-cache). The engine NEVER fabricates
// coverage and NEVER falls back to another model — on failure it preserves the
// previous valid cached StoryCoverage.

// MARK: - Request body (matches apps/api StoryCoverageRequest, snake_case)

struct StoryCoverageRequestDTO: Encodable {
    let storyId: UUID
    /// The resolved CreativeIntent, compact (free-form JSON object).
    let creativeIntent: JSONValue
    /// {target_duration_seconds?, format?}
    let scope: JSONValue
    /// Completed MomentUnderstanding records (each: {moment_id, observed{...}, story_context{...}}).
    let momentUnderstandings: [JSONValue]
    let pendingCount: Int

    enum CodingKeys: String, CodingKey {
        case storyId = "story_id"
        case creativeIntent = "creative_intent"
        case scope
        case momentUnderstandings = "moment_understandings"
        case pendingCount = "pending_count"
    }
}

enum StoryCoverageServiceError: Error, LocalizedError {
    case transport(Error)
    case unavailableRetryable      // 503 — compute failed; keep previous cached coverage
    case badStatus(Int)
    case decoding(Error)
    case jobFailed(String)         // worker classified a terminal failure (category)
    case jobCancelled              // user cancelled
    case pollTimedOut(String)      // gave up polling this attempt; job id kept for recovery

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach Story to update your Story Guide."
        case .unavailableRetryable: return "Story Guide is updating; will retry."
        case .badStatus(let c): return "Unexpected coverage response (\(c))."
        case .decoding: return "Coverage returned an unexpected shape."
        case .jobFailed(let cat):
            return cat == "provider_exhausted"
                ? "Story Guide analysis is temporarily rate-limited. Try again later."
                : "Story Guide analysis didn't complete (\(cat))."
        case .jobCancelled: return "Story Guide update was cancelled."
        case .pollTimedOut: return "Story Guide is still analyzing; it will finish in the background."
        }
    }
}

// Protocol seam so the engine can be driven by a fake in tests (no network).
protocol StoryCoverageComputing {
    func compute(_ request: StoryCoverageRequestDTO) async throws -> StoryCoverageDTO
}

// MARK: - Coverage/2 (E2-c) — Guide-relative. POST /v1/story-coverage/v2.

struct StoryCoverageV2RequestDTO: Encodable {
    let storyId: UUID
    /// The frozen persisted StoryGuide (dimensions w/ stable ids), passed through verbatim.
    let storyGuide: JSONValue
    let storyGuideVersion: String
    let creativeIntent: JSONValue
    let scope: JSONValue
    let momentUnderstandings: [JSONValue]
    let pendingCount: Int
    enum CodingKeys: String, CodingKey {
        case storyId = "story_id"
        case storyGuide = "story_guide"
        case storyGuideVersion = "story_guide_version"
        case creativeIntent = "creative_intent"
        case scope
        case momentUnderstandings = "moment_understandings"
        case pendingCount = "pending_count"
    }
}

protocol StoryCoverageV2Computing {
    func compute(_ request: StoryCoverageV2RequestDTO) async throws -> StoryCoverageV2DTO
}

struct StoryCoverageV2Service: StoryCoverageV2Computing {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = StoryBackend.coverageSession
    /// Max wall-clock to poll a submitted job before giving up this attempt (worker runs <900s; the device
    /// keeps the job id so a later open RECOVERS the same job rather than re-submitting — see the engine).
    var maxPollSeconds: TimeInterval = 300
    var pollIntervalSeconds: UInt64 = 3

    /// Submit -> poll -> retrieve. The sync /v1/story-coverage/v2 ran two sequential Opus calls (~191s cold)
    /// past App Runner's hard 120s wall, so the device never received the result and looped. This runs the
    /// SAME computation as an async job (worker Lambda, no 120s wall) and polls durable status. The
    /// operation_id is a stable hash of the canonical request body: identical Story evidence -> same id ->
    /// the existing queued/running/completed job is recovered WITHOUT launching new inference; changed
    /// evidence -> new id -> new job. Polling never triggers inference (it only reads status).
    func compute(_ request: StoryCoverageV2RequestDTO) async throws -> StoryCoverageV2DTO {
        let bodyData: Data
        do { bodyData = try StoryContractCoding.encoder().encode(request) }
        catch { throw StoryCoverageServiceError.decoding(error) }
        let bodyString = String(data: bodyData, encoding: .utf8) ?? "{}"
        // The op-id MUST be stable across opens for the SAME Story evidence, else every open creates a NEW job
        // (duplicate inference + the UI never recovers a result). The body JSON key order is NOT guaranteed
        // stable (JSONValue wraps Swift dictionaries), so hash a CANONICAL re-serialization with sorted keys
        // instead of the raw body bytes.
        let operationId = Self.operationId(for: bodyData)

        let jobId = try await submit(operationId: operationId, body: bodyString)
        return try await pollToResult(jobId: jobId)
    }

    /// Deterministic operation id = sha256 of a CANONICAL (sorted-keys) re-serialization of the request body.
    /// Captures every output-affecting input (guide, intent, scope, the completed MU set, pending count) and
    /// is INVARIANT to JSON key ordering, so the same Story evidence always yields the same id across opens.
    static func operationId(for bodyData: Data) -> String {
        var canonical = bodyData
        if let obj = try? JSONSerialization.jsonObject(with: bodyData),
           let sorted = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            canonical = sorted
        }
        let digest = SHA256.hash(data: canonical)
        return "coverage_v2:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func submit(operationId: String, body: String) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/story-coverage/v2/jobs"))
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        func field(_ name: String, _ value: String) -> String {
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        var form = field("operation_id", operationId)
        form += field("owner", "dev")
        form += field("body", body)
        form += "--\(boundary)--\r\n"
        req.httpBody = Data(form.utf8)

        let data: Data; let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw StoryCoverageServiceError.transport(error) }
        guard let http = resp as? HTTPURLResponse else { throw StoryCoverageServiceError.badStatus(-1) }
        guard http.statusCode == 202 else { throw StoryCoverageServiceError.badStatus(http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobId = obj["job_id"] as? String else {
            throw StoryCoverageServiceError.decoding(
                NSError(domain: "coverage", code: 0, userInfo: [NSLocalizedDescriptionKey: "no job_id"]))
        }
        return jobId
    }

    private func pollToResult(jobId: String) async throws -> StoryCoverageV2DTO {
        let deadline = Date().addingTimeInterval(maxPollSeconds)
        let url = baseURL.appendingPathComponent("v1/story-coverage/v2/jobs/\(jobId)")
        while Date() < deadline {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            let data: Data; let resp: URLResponse
            do { (data, resp) = try await session.data(for: req) }
            catch { throw StoryCoverageServiceError.transport(error) }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StoryCoverageServiceError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let status = (obj["status"] as? String) ?? "unknown"
            switch status {
            case "completed":
                guard let result = obj["result"] else {
                    throw StoryCoverageServiceError.decoding(
                        NSError(domain: "coverage", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "completed without result"]))
                }
                let resultData = try JSONSerialization.data(withJSONObject: result)
                do { return try StoryContractCoding.decoder().decode(StoryCoverageV2DTO.self, from: resultData) }
                catch { throw StoryCoverageServiceError.decoding(error) }
            case "failed":
                let cat = (obj["failure_category"] as? String) ?? "unknown"
                throw StoryCoverageServiceError.jobFailed(cat)
            case "cancelled":
                throw StoryCoverageServiceError.jobCancelled
            case "expired":
                throw StoryCoverageServiceError.unavailableRetryable
            default:   // queued | running | cancel_requested — keep polling (no inference triggered)
                try? await Task.sleep(nanoseconds: pollIntervalSeconds * 1_000_000_000)
            }
        }
        // Timed out waiting — the job keeps running server-side; the device recovers it on the next open.
        throw StoryCoverageServiceError.pollTimedOut(jobId)
    }
}

struct StoryCoverageService: StoryCoverageComputing {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = StoryBackend.longSession

    func compute(_ request: StoryCoverageRequestDTO) async throws -> StoryCoverageDTO {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/story-coverage"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try StoryContractCoding.encoder().encode(request)
        } catch {
            throw StoryCoverageServiceError.decoding(error)
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw StoryCoverageServiceError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw StoryCoverageServiceError.badStatus(-1)
        }
        if http.statusCode == 503 { throw StoryCoverageServiceError.unavailableRetryable }
        guard http.statusCode == 200 else {
            throw StoryCoverageServiceError.badStatus(http.statusCode)
        }
        do {
            return try StoryContractCoding.decoder().decode(StoryCoverageDTO.self, from: data)
        } catch {
            throw StoryCoverageServiceError.decoding(error)
        }
    }
}

// MARK: - JSONValue — a minimal Codable "any JSON" value
//
// CreativeIntent, scope, and each MomentUnderstanding are passed through from the
// stored wire JSON unchanged (we do not re-model them here — they are already the
// frozen contracts). JSONValue lets us decode the stored snake_case JSON and
// re-encode it verbatim into the request body, preserving every field the engine
// expects without a hand-maintained Swift mirror of each contract.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    /// Convenience readers for extracting scalar diagnostics (e.g. job diagnostics planning_mode/sheet_count).
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    /// Decode an arbitrary JSON string ("{...}") into a JSONValue object.
    static func object(fromJSONString s: String) -> JSONValue {
        guard let d = s.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: d) else {
            return .object([:])
        }
        return v
    }
}
