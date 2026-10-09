import Foundation

// EditPlannerService — POST /v1/edit-plan (Milestone M-d / R-b Case G, frozen edit_plan/2).
//
// Builds the request from a Story's ALREADY-PERSISTED data (resolved CreativeIntent, completed
// MomentUnderstanding[]) and returns the backend's EditPlanV2 (one Opus 4.6 call under the server's
// DETERMINISTIC validator — an invalid plan is a 503, never a fabricated plan; infeasible material is a 422
// with a reason). MUSIC IS OPTIONAL: Case G runs in NO-MUSIC mode (no production MusicPlan engine exists),
// so music_plan/music_asset_id/music_analysis are omitted and the planner emits no music anchors.
//
// This service PLANS. It makes NO creative decisions and NO rendering decisions — the Media Engine renders
// the returned plan locally. No Epidemic, no provider credentials ever reach the device.

protocol EditPlanning {
    func plan(_ request: EditPlanRequestDTO) async throws -> EditPlanV2
}

// MARK: - Request DTO (mirrors the backend EditPlanRequest; snake_case wire)

struct EditPlanRequestDTO: Encodable {
    let storyId: UUID
    let creativeIntentId: UUID
    let creativeIntent: JSONValue          // resolved CreativeIntent incl. target_duration_seconds
    let storyGuide: JSONValue
    let storyCoverage: JSONValue
    let moments: [JSONValue]               // each: {id, duration_seconds, useful_segments:[[a,b],...]}
    let outputFormat: String               // vertical | square | landscape
    // No-music mode: music_plan / music_asset_id / music_analysis intentionally omitted.

    enum CodingKeys: String, CodingKey {
        case storyId = "story_id"
        case creativeIntentId = "creative_intent_id"
        case creativeIntent = "creative_intent"
        case storyGuide = "story_guide"
        case storyCoverage = "story_coverage"
        case moments
        case outputFormat = "output_format"
    }
}

enum EditPlannerServiceError: Error, LocalizedError {
    case transport(Error)
    case unavailable            // 503 — model/validation failure; the server refused to fabricate a plan
    case infeasible(String)     // 422 — material can't reach target; carries the server's reason
    case badStatus(Int)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach the Edit Planner. Check your connection and try again."
        case .unavailable: return "The Edit Planner is temporarily unavailable. Please retry."
        case .infeasible(let r): return "This Story's material can't fill the target: \(r)"
        case .badStatus(let c): return "Unexpected response (\(c))."
        case .decoding: return "The plan response couldn't be read."
        }
    }
}

final class EditPlannerService: EditPlanning {
    private let baseURL: URL
    private let session: URLSession
    init(baseURL: URL = StoryBackend.baseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func plan(_ request: EditPlanRequestDTO) async throws -> EditPlanV2 {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/edit-plan"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { req.httpBody = try StoryContractCoding.encoder().encode(request) }
        catch { throw EditPlannerServiceError.transport(error) }

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw EditPlannerServiceError.transport(error) }

        guard let http = resp as? HTTPURLResponse else { throw EditPlannerServiceError.badStatus(-1) }
        switch http.statusCode {
        case 200:
            do { return try StoryContractCoding.decoder().decode(EditPlanV2.self, from: data) }
            catch { throw EditPlannerServiceError.decoding(error) }
        case 422:
            throw EditPlannerServiceError.infeasible(Self.detail(data))
        case 503:
            throw EditPlannerServiceError.unavailable
        default:
            throw EditPlannerServiceError.badStatus(http.statusCode)
        }
    }

    private static func detail(_ data: Data) -> String {
        (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
            ?? String(data: data, encoding: .utf8) ?? "infeasible"
    }
}
