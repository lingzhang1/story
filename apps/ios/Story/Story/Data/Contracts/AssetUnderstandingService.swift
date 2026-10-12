import Foundation

// AssetUnderstandingService — the Milestone-D network boundary for Asset
// Understanding (06-asset-understanding.md §8, FROZEN).
//
// Calls POST /v1/asset-understanding on the EXISTING App Runner service with a
// multipart body: a `meta` JSON part (moment_id, source_capture_id?, capture_context?),
// a `frames_meta` JSON part (ordered [{t_ms}]), and 24 `frames` JPEG parts.
// Decodes the canonical moment_understanding/1 wire shape.
//
// Failure is surfaced (503 => retryable) — the queue leaves the job PENDING and
// NEVER fabricates an understanding and NEVER falls back to another model.

// MARK: - Wire DTO (moment_understanding/1, snake_case)

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

struct MomentUnderstandingDTO: Codable {
    let momentId: UUID
    let sourceCaptureId: UUID?
    let schemaVersion: String
    let framePolicy: String
    let promptVersion: String
    let modelId: String?
    let nFrames: Int?
    let observed: MomentObservedDTO
    let storyContext: MomentStoryContextDTO
    let createdAt: Date?
    enum CodingKeys: String, CodingKey {
        case momentId = "moment_id", sourceCaptureId = "source_capture_id"
        case schemaVersion = "schema_version", framePolicy = "frame_policy"
        case promptVersion = "prompt_version", modelId = "model_id", nFrames = "n_frames"
        case observed, storyContext = "story_context", createdAt = "created_at"
    }
}

enum AssetUnderstandingServiceError: Error, LocalizedError {
    case transport(Error)
    case unavailableRetryable      // 503 — analysis failed after retry; job stays pending
    case badStatus(Int)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach Story for Moment analysis."
        case .unavailableRetryable: return "Moment analysis is busy; will retry."
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
        captureContext: [String: Any]?
    ) async throws -> MomentUnderstandingDTO
}

struct AssetUnderstandingService: AUAnalyzing {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = StoryBackend.backgroundSession

    func analyze(
        frames: [AUExtractedFrame],
        momentId: UUID,
        sourceCaptureId: UUID?,
        captureContext: [String: Any]?
    ) async throws -> MomentUnderstandingDTO {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/asset-understanding"))
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = try makeBody(
            frames: frames, momentId: momentId, sourceCaptureId: sourceCaptureId,
            captureContext: captureContext, boundary: boundary
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
        boundary: String
    ) throws -> Data {
        var body = Data()
        let crlf = "\r\n"
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }

        var meta: [String: Any] = ["moment_id": momentId.uuidString]
        if let sourceCaptureId { meta["source_capture_id"] = sourceCaptureId.uuidString }
        if let captureContext { meta["capture_context"] = captureContext }
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
