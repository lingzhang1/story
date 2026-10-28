import Foundation

// AssetUnderstandingService — the network boundary for Asset Understanding
// (06-asset-understanding.md §8; Rich Editorial AU v2 — Editorial Pipeline v2 P1-B).
//
// Calls POST /v1/asset-understanding on the EXISTING App Runner service with a
// multipart body: a `meta` JSON part (moment_id, source_capture_id?, capture_context?),
// a `frames_meta` JSON part (ordered [{t_ms}]), and 24 `frames` JPEG parts.
// Decodes the canonical moment_understanding/2 wire shape — a strict SUPERSET of v1:
// the observed/story_context blocks are byte-identical to v1, plus an OPTIONAL
// `editorial` block (visual + narrative candidates). An existing v1 record (no
// `editorial`) decodes unchanged because the field is optional.
//
// Failure is surfaced (503 => retryable) — the queue leaves the job PENDING and
// NEVER fabricates an understanding and NEVER falls back to another model.

// MARK: - Wire DTO (moment_understanding/2, snake_case)

struct MomentEventDTO: Codable {
    let startTime: Double
    let endTime: Double?
    let description: String
    enum CodingKeys: String, CodingKey {
        case startTime = "start_time", endTime = "end_time", description
    }
}

struct MomentUsefulSegmentDTO: Codable {
    let startTime: Double
    let endTime: Double
    let whyUseful: String
    enum CodingKeys: String, CodingKey {
        case startTime = "start_time", endTime = "end_time", whyUseful = "why_useful"
    }
}

struct MomentObservedDTO: Codable {
    let summary: String
    let subjects: [String]
    let events: [MomentEventDTO]
    let temporalOrderNote: String
    let usefulSegments: [MomentUsefulSegmentDTO]
    enum CodingKeys: String, CodingKey {
        case summary, subjects, events
        case temporalOrderNote = "temporal_order_note"
        case usefulSegments = "useful_segments"
    }
}

struct MomentStoryContextDTO: Codable {
    let storyUtility: String
    let requestedShotContribution: String?
    let requestedBeatContribution: String?
    enum CodingKeys: String, CodingKey {
        case storyUtility = "story_utility"
        case requestedShotContribution = "requested_shot_contribution"
        case requestedBeatContribution = "requested_beat_contribution"
    }
}

// MARK: - Editorial block (moment_understanding/2, additive — nil for v1 records)

/// A visually compelling source sub-range (Highlights). Interpretable value +
/// uncertainty, NEVER a single beauty score. ~2-5s is common, not a limit.
struct VisualCandidateDTO: Codable {
    let startTime: Double
    let endTime: Double
    let peakTime: Double?          // nil when not identifiable — never invented
    let visualValue: String
    let role: String?
    let confidence: Double?
    let evidence: String?
    enum CodingKeys: String, CodingKey {
        case startTime = "start_time", endTime = "end_time", peakTime = "peak_time"
        case visualValue = "visual_value", role, confidence, evidence
    }
}

/// A meaningful source interval (Full Story). May be substantially longer. Spoken
/// meaning is never inferred from frames (stays "unknown").
struct NarrativeCandidateDTO: Codable {
    let startTime: Double
    let endTime: Double
    let whatHappens: String
    let whyMatters: String
    let role: String?
    let confidence: Double?
    let spokenMeaning: String?     // "unknown" at this milestone
    enum CodingKeys: String, CodingKey {
        case startTime = "start_time", endTime = "end_time"
        case whatHappens = "what_happens", whyMatters = "why_matters"
        case role, confidence, spokenMeaning = "spoken_meaning"
    }
}

/// Reusable editorial interpretation derived from ONE understanding.
struct MomentEditorialDTO: Codable {
    let visualCandidates: [VisualCandidateDTO]
    let narrativeCandidates: [NarrativeCandidateDTO]
    let analysisVersion: String?
    enum CodingKeys: String, CodingKey {
        case visualCandidates = "visual_candidates"
        case narrativeCandidates = "narrative_candidates"
        case analysisVersion = "analysis_version"
    }
}

struct MomentUnderstandingDTO: Codable {
    let momentId: UUID
    let sourceCaptureId: UUID?
    let schemaVersion: String
    let framePolicy: String
    let promptVersion: String
    let modelId: String?
    let nFrames: Int?
    let sampledFrameMs: [Int]?   // server-minted frame-input provenance; nil for pre-field records
    let observed: MomentObservedDTO
    let editorial: MomentEditorialDTO?   // nil for v1 records (optional => v1 JSON decodes unchanged)
    let storyContext: MomentStoryContextDTO
    let createdAt: Date?
    enum CodingKeys: String, CodingKey {
        case momentId = "moment_id", sourceCaptureId = "source_capture_id"
        case schemaVersion = "schema_version", framePolicy = "frame_policy"
        case promptVersion = "prompt_version", modelId = "model_id", nFrames = "n_frames"
        case sampledFrameMs = "sampled_frame_ms"
        case observed, editorial, storyContext = "story_context", createdAt = "created_at"
    }

    // Explicit memberwise init with editorial defaulted to nil, so existing v1 construction
    // sites (tests/fakes) compile unchanged while decode fills editorial when present.
    init(momentId: UUID, sourceCaptureId: UUID?, schemaVersion: String, framePolicy: String,
         promptVersion: String, modelId: String?, nFrames: Int?, observed: MomentObservedDTO,
         editorial: MomentEditorialDTO? = nil, storyContext: MomentStoryContextDTO, createdAt: Date? = nil,
         sampledFrameMs: [Int]? = nil) {
        self.momentId = momentId
        self.sourceCaptureId = sourceCaptureId
        self.schemaVersion = schemaVersion
        self.framePolicy = framePolicy
        self.promptVersion = promptVersion
        self.modelId = modelId
        self.nFrames = nFrames
        self.sampledFrameMs = sampledFrameMs
        self.observed = observed
        self.editorial = editorial
        self.storyContext = storyContext
        self.createdAt = createdAt
    }

    /// True when this record carries the v2 editorial interpretation.
    var isV2: Bool { editorial != nil && schemaVersion == "moment_understanding/2" }
}

enum AssetUnderstandingServiceError: Error, LocalizedError {
    case transport(Error)
    case unavailableRetryable      // 503 — analysis failed after retry; job stays pending
    case rateLimited(retryAfter: Int?)   // 429 error:"rate_limited" — temporary per-user rate cap; RETRYABLE
                                         // after Retry-After (the server's ai_sync 20/min window).
    case quotaExhausted(scope: String)   // 429 error:"quota_exceeded" — an ALLOWANCE is spent (daily gens /
                                         // monthly USD / global). PERMANENT for the period: do NOT auto-retry.
    case badStatus(Int)
    case decoding(Error)

    /// Whether the AU queue should send the job back to PENDING and try again later. A temporary rate limit
    /// and a transient 503/transport error are retryable; an exhausted allowance and an unexpected status are
    /// NOT (retrying an exhausted daily cap just burns attempts and never succeeds until the period resets).
    var isRetryable: Bool {
        switch self {
        case .transport, .unavailableRetryable, .rateLimited: return true
        case .quotaExhausted, .badStatus, .decoding: return false
        }
    }

    /// Server-provided Retry-After (seconds) when present, so the queue can wait at least that long before the
    /// next attempt instead of only its own backoff.
    var retryAfterSeconds: Int? {
        if case let .rateLimited(ra) = self { return ra }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach Story for Moment analysis."
        case .unavailableRetryable: return "Moment analysis is busy; will retry."
        case .rateLimited: return "Moment analysis is rate-limited; will retry shortly."
        case .quotaExhausted(let s): return "Moment analysis paused — usage limit reached (\(s))."
        case .badStatus(let c): return "Unexpected analysis response (\(c))."
        case .decoding: return "Analysis returned an unexpected shape."
        }
    }
}

// Protocol seam so the queue can be driven by a fake analyzer in tests (no network).
protocol AUAnalyzing {
    func analyze(
        frames: [AUExtractedFrame],
        momentId: UUID,
        sourceCaptureId: UUID?,
        captureContext: [String: Any]?,
        contentSha256: String?
    ) async throws -> MomentUnderstandingDTO
}

extension AUAnalyzing {
    // Back-compat default so existing callers/tests that omit the P1-F sha claim keep compiling unchanged.
    func analyze(
        frames: [AUExtractedFrame],
        momentId: UUID,
        sourceCaptureId: UUID?,
        captureContext: [String: Any]?
    ) async throws -> MomentUnderstandingDTO {
        try await analyze(frames: frames, momentId: momentId, sourceCaptureId: sourceCaptureId,
                          captureContext: captureContext, contentSha256: nil)
    }
}

struct AssetUnderstandingService: AUAnalyzing {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = StoryBackend.backgroundSession

    func analyze(
        frames: [AUExtractedFrame],
        momentId: UUID,
        sourceCaptureId: UUID?,
        captureContext: [String: Any]?,
        contentSha256: String?
    ) async throws -> MomentUnderstandingDTO {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/asset-understanding"))
        StoryBackend.authorize(&req)  // P0 auth seam: bearer token when signed in
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = try makeBody(
            frames: frames, momentId: momentId, sourceCaptureId: sourceCaptureId,
            captureContext: captureContext, contentSha256: contentSha256, boundary: boundary
        )

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw AssetUnderstandingServiceError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw AssetUnderstandingServiceError.badStatus(-1)
        }
        if http.statusCode == 503 { throw AssetUnderstandingServiceError.unavailableRetryable }
        if http.statusCode == 429 {
            // Two distinct 429s share the status but mean opposite things for retry (see throttle.py /
            // quota_gate.py): error:"rate_limited" is a TEMPORARY per-user rate cap (retry after the window);
            // error:"quota_exceeded" is a SPENT allowance (daily gens / monthly USD / global breaker) that
            // does NOT clear by retrying. Parse the body to tell them apart; default the AMBIGUOUS case to the
            // SAFE non-retrying branch so we never hammer an exhausted allowance.
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            let err = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let kind = (err?["error"] as? String) ?? ""
            if kind == "rate_limited" {
                throw AssetUnderstandingServiceError.rateLimited(retryAfter: retryAfter)
            }
            // quota_exceeded (or an unrecognized 429): treat as a permanent allowance stop — no auto-retry.
            let scope = (err?["scope"] as? String) ?? (err?["class"] as? String) ?? "quota"
            throw AssetUnderstandingServiceError.quotaExhausted(scope: scope)
        }
        guard http.statusCode == 200 else {
            throw AssetUnderstandingServiceError.badStatus(http.statusCode)
        }
        do {
            return try StoryContractCoding.decoder().decode(MomentUnderstandingDTO.self, from: data)
        } catch {
            throw AssetUnderstandingServiceError.decoding(error)
        }
    }

    // MARK: - Multipart body

    private func makeBody(
        frames: [AUExtractedFrame],
        momentId: UUID,
        sourceCaptureId: UUID?,
        captureContext: [String: Any]?,
        contentSha256: String?,
        boundary: String
    ) throws -> Data {
        var body = Data()
        let crlf = "\r\n"
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }

        var meta: [String: Any] = ["moment_id": momentId.uuidString]
        if let sourceCaptureId { meta["source_capture_id"] = sourceCaptureId.uuidString }
        if let captureContext { meta["capture_context"] = captureContext }
        // P1-F (R1): the device-supplied source sha CLAIM + the extractor policy that produced these frames.
        // Both optional + additive; the backend format-validates the sha and NEVER treats it as verified
        // identity (authority is established at retrieval against the account's media record).
        if let contentSha256, contentSha256.count == 64 { meta["content_sha256"] = contentSha256 }
        meta["frame_extraction_version"] = MomentFrameExtractor.extractionPolicy
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"meta\"\(crlf)")
        append("Content-Type: application/json\(crlf)\(crlf)")
        body.append(metaData); append(crlf)

        let framesMeta = frames.map { ["t_ms": $0.tMs] }
        let framesMetaData = try JSONSerialization.data(withJSONObject: framesMeta)
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"frames_meta\"\(crlf)")
        append("Content-Type: application/json\(crlf)\(crlf)")
        body.append(framesMetaData); append(crlf)

        for (i, f) in frames.enumerated() {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"frames\"; filename=\"f\(i).jpg\"\(crlf)")
            append("Content-Type: image/jpeg\(crlf)\(crlf)")
            body.append(f.jpeg); append(crlf)
        }
        append("--\(boundary)--\(crlf)")
        return body
    }
}
