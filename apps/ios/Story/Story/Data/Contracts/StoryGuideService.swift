import Foundation

// StoryGuideService — POST /v1/story-guide (Milestone E2-c).
//
// CreativeIntent + scope -> StoryGuideDTO (story_guide/1). Generated ONCE at Story
// creation; no MomentUnderstanding needed. 503 => guide unavailable (preserve
// CreativeIntent, retry) — NEVER a fabricated Guide. The server mints the canonical
// stable dimension/possibility ids returned here.

protocol StoryGuideGenerating {
    func generate(_ request: StoryGuideRequestDTO) async throws -> StoryGuideDTO
}

struct StoryGuideRequestDTO: Encodable {
    let storyId: UUID
    let creativeIntent: JSONValue
    let scope: JSONValue
    let sourceCreativeIntentVersion: String?
    enum CodingKeys: String, CodingKey {
        case storyId = "story_id"
        case creativeIntent = "creative_intent"
        case scope
        case sourceCreativeIntentVersion = "source_creative_intent_version"
    }
}

enum StoryGuideServiceError: Error { case encoding(Error), transport(Error), badStatus(Int), unavailable, decoding(Error) }

final class StoryGuideService: StoryGuideGenerating {
    private let baseURL: URL
    private let session: URLSession
    init(baseURL: URL = StoryBackend.baseURL, session: URLSession = StoryBackend.longSession) {
        self.baseURL = baseURL
        self.session = session
    }

    func generate(_ request: StoryGuideRequestDTO) async throws -> StoryGuideDTO {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/story-guide"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try StoryContractCoding.encoder().encode(request)
        } catch { throw StoryGuideServiceError.encoding(error) }

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw StoryGuideServiceError.transport(error) }

        guard let http = resp as? HTTPURLResponse else { throw StoryGuideServiceError.badStatus(-1) }
        if http.statusCode == 503 { throw StoryGuideServiceError.unavailable }
        guard http.statusCode == 200 else { throw StoryGuideServiceError.badStatus(http.statusCode) }
        do { return try StoryContractCoding.decoder().decode(StoryGuideDTO.self, from: data) }
        catch { throw StoryGuideServiceError.decoding(error) }
    }
}
