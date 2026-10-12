import Foundation

// SceneUnderstandingService — the Milestone-C2 network boundary for Scene Scan.
//
// Calls the backend POST /v1/scene-understanding with a multipart/form-data
// body: one `context` JSON part + one `frames` part per JPEG. Decodes the
// canonical SceneUnderstandingContractDTO (snake_case wire, ISO-8601).
//
// Scope: Scene Understanding only. Failure is surfaced to the UI (recoverable
// retry) — we NEVER silently fabricate observations.
enum SceneUnderstandingServiceError: Error, LocalizedError {
    case transport(Error)
    case unavailable            // 503 — model/provider failure; retry
    case badStatus(Int)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach Story. Check your connection and try again."
        case .unavailable: return "Story's eyes are busy. Please try again."
        case .badStatus(let c): return "Unexpected response (\(c)). Please try again."
        case .decoding: return "Story returned something unexpected. Please try again."
        }
    }
}

struct SceneUnderstandingService {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = StoryBackend.backgroundSession

    func analyze(frames: [Data],
                 captureSessionId: UUID,
                 mode: String,
                 storyId: UUID?) async throws -> SceneUnderstandingContractDTO {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/scene-understanding"))
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = try makeBody(frames: frames,
                                    captureSessionId: captureSessionId,
                                    mode: mode,
                                    storyId: storyId,
                                    boundary: boundary)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw SceneUnderstandingServiceError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw SceneUnderstandingServiceError.badStatus(-1)
        }
        if http.statusCode == 503 { throw SceneUnderstandingServiceError.unavailable }
        guard http.statusCode == 200 else {
            throw SceneUnderstandingServiceError.badStatus(http.statusCode)
        }
        do {
            return try StoryContractCoding.decoder()
                .decode(SceneUnderstandingContractDTO.self, from: data)
        } catch {
            throw SceneUnderstandingServiceError.decoding(error)
        }
    }

    // MARK: - Multipart body

    private func makeBody(frames: [Data],
                          captureSessionId: UUID,
                          mode: String,
                          storyId: UUID?,
                          boundary: String) throws -> Data {
        var body = Data()
        let crlf = "\r\n"

        func append(_ string: String) {
            if let d = string.data(using: .utf8) { body.append(d) }
        }

        // context part (application/json).
        var context: [String: Any] = [
            "capture_session_id": captureSessionId.uuidString,
            "mode": mode
        ]
        if let storyId { context["story_id"] = storyId.uuidString }
        let contextData = try JSONSerialization.data(withJSONObject: context)

        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"context\"\(crlf)")
        append("Content-Type: application/json\(crlf)\(crlf)")
        body.append(contextData)
        append(crlf)

        // one part per JPEG frame, all named "frames".
        for (index, frame) in frames.enumerated() {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"frames\"; filename=\"frame-\(index).jpg\"\(crlf)")
            append("Content-Type: image/jpeg\(crlf)\(crlf)")
            body.append(frame)
            append(crlf)
        }

        append("--\(boundary)--\(crlf)")
        return body
    }
}
