import Foundation

// MusicDirectionService — POST /v1/music-direction (Milestone M-c).
//
// CreativeIntent (+ optional StoryGuide.framing_summary) -> MusicDirectionContractDTO
// (the intended soundtrack FEEL). DETERMINISTIC server inference — no model call. This
// supplies only the INFERRED default; a user-authored direction overrides it client-side
// and is never regenerated. 422 => the intent was invalid (do not fabricate a feel).

protocol MusicDirectionInferring {
    func infer(_ request: MusicDirectionRequestDTO) async throws -> MusicDirectionContractDTO
}

struct MusicDirectionRequestDTO: Encodable {
    let creativeIntent: JSONValue
    let guideFramingSummary: String?
    enum CodingKeys: String, CodingKey {
        case creativeIntent = "creative_intent"
        case guideFramingSummary = "guide_framing_summary"
    }
}

enum MusicDirectionServiceError: Error { case encoding(Error), transport(Error), badStatus(Int), decoding(Error) }

final class MusicDirectionService: MusicDirectionInferring {
    private let baseURL: URL
    private let session: URLSession
    init(baseURL: URL = StoryBackend.baseURL, session: URLSession = StoryBackend.longSession) {
        self.baseURL = baseURL
        self.session = session
    }

    func infer(_ request: MusicDirectionRequestDTO) async throws -> MusicDirectionContractDTO {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/music-direction"))
        StoryBackend.authorize(&req)  // P0 auth seam: bearer token when signed in
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try StoryContractCoding.encoder().encode(request)
        } catch { throw MusicDirectionServiceError.encoding(error) }

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw MusicDirectionServiceError.transport(error) }

        guard let http = resp as? HTTPURLResponse else { throw MusicDirectionServiceError.badStatus(-1) }
        guard http.statusCode == 200 else { throw MusicDirectionServiceError.badStatus(http.statusCode) }
        do { return try StoryContractCoding.decoder().decode(MusicDirectionContractDTO.self, from: data) }
        catch { throw MusicDirectionServiceError.decoding(error) }
    }
}
