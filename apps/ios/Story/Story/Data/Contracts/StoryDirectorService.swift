import Foundation

// StoryDirectorService — the Milestone-C3B network boundary for the Director.
//
// Calls POST /v1/director/initialize with a JSON body:
//   { creative_intent, scene_understanding, capture_constraints }
// and decodes the canonical DirectorOutputDTO (concept + plan + director_state
// + decision). The server runs DirectorEngine -> ModelGateway -> configured
// Director model (currently amazon.nova-pro-v1:0).
//
// Scope: initialize only (the C3B slice). Failure is surfaced to the UI as a
// recoverable retry — we NEVER fabricate a plan or a recommendation.
enum StoryDirectorServiceError: Error, LocalizedError {
    case transport(Error)
    case unavailable            // 503 — model/provider/structured-output failure; retry
    case badStatus(Int)
    case encoding(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach Story. Check your connection and try again."
        case .unavailable: return "Story is thinking hard. Please try again."
        case .badStatus(let c): return "Unexpected response (\(c)). Please try again."
        case .encoding: return "Couldn't prepare the request. Please try again."
        case .decoding: return "Story returned something unexpected. Please try again."
        }
    }
}

struct StoryDirectorService {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = .shared

    /// Resolve the first Director recommendation. `sceneUnderstanding` is nil when the
    /// user used Skip Scan — the body then omits scene_understanding (server treats it as
    /// null and recommends environment-agnostically).
    func initialize(creativeIntent: CreativeIntentContractDTO,
                    sceneUnderstanding: SceneUnderstandingContractDTO?,
                    targetDurationSeconds: Double?,
                    selectedOpportunity: SelectedOpportunityDTO? = nil) async throws -> DirectorOutputDTO {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/director/initialize"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = StoryContractCoding.encoder()
        // The backend accepts the canonical contract objects as opaque dicts;
        // we send the exact wire JSON the C1/C2 responses used.
        do {
            let ci = try encoder.encode(creativeIntent)
            var constraints: [String: Any] = [:]
            if let d = targetDurationSeconds { constraints["target_duration_seconds"] = d }
            var body: [String: Any] = [
                "creative_intent": try JSONSerialization.jsonObject(with: ci),
                "capture_constraints": constraints
            ]
            if let su = sceneUnderstanding {       // Skip Scan omits this entirely
                let suData = try encoder.encode(su)
                body["scene_understanding"] = try JSONSerialization.jsonObject(with: suData)
            }
            if let opp = selectedOpportunity {     // E2-c: carry the user's chosen opportunity (optional)
                let oppData = try encoder.encode(opp)
                body["selected_opportunity"] = try JSONSerialization.jsonObject(with: oppData)
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw StoryDirectorServiceError.encoding(error)
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw StoryDirectorServiceError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw StoryDirectorServiceError.badStatus(-1)
        }
        if http.statusCode == 503 { throw StoryDirectorServiceError.unavailable }
        guard http.statusCode == 200 else {
            throw StoryDirectorServiceError.badStatus(http.statusCode)
        }
        do {
            return try StoryContractCoding.decoder().decode(DirectorOutputDTO.self, from: data)
        } catch {
            throw StoryDirectorServiceError.decoding(error)
        }
    }
}

// MARK: - Mapping a StoryModel's resolved intent back to the wire contract

extension CreativeIntentContractDTO {
    /// Rebuild the resolved CreativeIntent contract from the persisted Story so
    /// the Director receives the SAME intent the C1 model produced.
    init(from story: StoryModel) {
        self.init(
            id: story.id,
            sourceInputs: [],
            summary: story.intentSummary.isEmpty ? story.intentRawText : story.intentSummary,
            subject: story.intentSubject,
            desiredFeeling: story.intentDesiredFeeling,
            styleTags: story.intentStyleTags,
            pace: story.intentPace.flatMap { PaceDTO(rawValue: $0) },
            emphasis: story.intentEmphasis,
            creativeConstraints: story.intentConstraints,
            targetDurationSeconds: story.intentTargetDurationSeconds,
            targetFormat: nil,
            rawUserDescription: story.intentRawText,
            createdAt: Date()
        )
    }
}
