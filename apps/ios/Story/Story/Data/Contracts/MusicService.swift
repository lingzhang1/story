import Foundation

// Music services (R-d Batch C) — the iOS clients for the music backend.
//
//   MusicPlanService        -> POST /v1/music-plan      (frozen music_plan/1; Opus 4.6 server-side)
//   MusicCandidatesService  -> POST /v1/music/candidates (Epidemic search+rank+preview+top analysis)
//                              POST /v1/music/analysis    (MusicAnalysis/1 for a chosen non-top track)
//                              POST /v1/music/soundtrack  (authorized download link) + fetch to a local file
//
// All provider endpoints are PROTOTYPING-gated server-side (404 when STORY_EPIDEMIC_MODE != prototyping) —
// the client treats 404 as "music unavailable" and the caller falls back to no-music creation. No track
// metadata is persisted beyond the current creation attempt; the downloaded file is a transient temp file.

// MARK: - Wire models

/// Epidemic returns signed media links as an object {url, expires}, NOT a bare string. Decode defensively:
/// accept either the object OR a plain string, and expose the url string. (A String-typed field here was the
/// bug that made the whole /v1/music/candidates response fail to decode -> recommend() returned nil -> no music.)
struct SignedURL: Decodable, Equatable {
    let url: String
    let expires: String?   // normalized to a string; the wire value may be a string OR a number (epoch secs)
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            url = s; expires = nil; return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        // `expires` may be a String (REST) or a NUMBER (MCP returns the epoch float, e.g. 1791704146.0).
        // Decode either and normalize to a string, so a numeric expiry never fails the whole decode ->
        // resolveSelection(nil) -> no music (the observed bug).
        // `expires` may be a String (REST) or a NUMBER (MCP returns the epoch float, e.g. 1791704146.0).
        // Decode either and normalize to a string, so a numeric expiry never fails the whole decode ->
        // resolveSelection(nil) -> no music (the observed bug). Flatten the double-optionals explicitly.
        let sExp: String? = (try? c.decodeIfPresent(String.self, forKey: .expires)).flatMap { $0 }
        if let sExp {
            expires = sExp
        } else {
            let dExp: Double? = (try? c.decodeIfPresent(Double.self, forKey: .expires)).flatMap { $0 }
            expires = dExp.map { String($0) }
        }
    }
    enum CodingKeys: String, CodingKey { case url, expires }
}

/// A ranked candidate track (consumer-facing subset — NO BPM/energy curves exposed to the user).
struct MusicCandidateDTO: Decodable, Equatable, Identifiable {
    let trackId: String
    let title: String
    let score: Double
    let durationSeconds: Double
    let vocalType: String?
    let previewURL: SignedURL?
    var id: String { trackId }
    var previewURLString: String? { previewURL?.url }
    enum CodingKeys: String, CodingKey {
        case trackId = "track_id", title, score
        case durationSeconds = "duration_seconds"
        case vocalType = "vocal_type"
        case previewURL = "preview_url"
    }
}

struct MusicCandidatesResponseDTO: Decodable {
    let candidates: [MusicCandidateDTO]
    let topTrackId: String?
    let topMusicAnalysis: MusicAnalysisV1?   // reuses the MediaEngine Decodable (extra fields ignored)
    enum CodingKeys: String, CodingKey {
        case candidates
        case topTrackId = "top_track_id"
        case topMusicAnalysis = "top_music_analysis"
    }
}

/// A page of free-text search results. `nextCursor` is nil when there are no further pages (stop load-more).
struct MusicSearchResponseDTO: Decodable {
    let candidates: [MusicCandidateDTO]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case candidates
        case nextCursor = "next_cursor"
    }
}

struct MusicSoundtrackLinkDTO: Decodable {
    let trackId: String
    let downloadURL: SignedURL
    let usage: String
    let commercialExportEnabled: Bool
    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case downloadURL = "download_url"
        case usage
        case commercialExportEnabled = "commercial_export_enabled"
    }
}

// MARK: - MusicPlanService

struct MusicPlanRequestDTO: Encodable {
    let storyId: UUID
    let creativeIntent: JSONValue
    let musicDirection: JSONValue      // AUTHORITATIVE (user-authored overrides inferred, resolved by caller)
    let targetDurationSeconds: Double
    let storyGuide: JSONValue
    let storyCoverage: JSONValue
    enum CodingKeys: String, CodingKey {
        case storyId = "story_id"
        case creativeIntent = "creative_intent"
        case musicDirection = "music_direction"
        case targetDurationSeconds = "target_duration_seconds"
        case storyGuide = "story_guide"
        case storyCoverage = "story_coverage"
    }
}

enum MusicServiceError: Error, LocalizedError {
    case unavailable          // 404 (flag off) or 503 — treat as "music unavailable", fall back to no-music
    case transport(Error)
    case badStatus(Int)
    case decoding(Error)
    case encoding(Error)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Music isn't available right now."
        case .transport(let e): return "Couldn't reach the music service: \(e)"
        case .badStatus(let c): return "Unexpected music response (\(c))."
        case .decoding(let e): return "Music response couldn't be read: \(e)"
        case .encoding(let e): return "Couldn't build the music request: \(e)"
        }
    }
}

protocol MusicPlanning {
    /// Returns the MusicPlan as a raw JSONValue (threaded unchanged into the Edit Planner request). Throws
    /// MusicServiceError.unavailable on 404/503 so the caller falls back to no-music.
    func plan(_ request: MusicPlanRequestDTO) async throws -> JSONValue
}

final class MusicPlanService: MusicPlanning {
    private let baseURL: URL
    private let session: URLSession
    init(baseURL: URL = StoryBackend.baseURL, session: URLSession = StoryBackend.longSession) {
        self.baseURL = baseURL
        self.session = session
    }

    func plan(_ request: MusicPlanRequestDTO) async throws -> JSONValue {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/music-plan"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { req.httpBody = try StoryContractCoding.encoder().encode(request) }
        catch { throw MusicServiceError.encoding(error) }

        let data: Data; let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw MusicServiceError.transport(error) }
        guard let http = resp as? HTTPURLResponse else { throw MusicServiceError.badStatus(-1) }
        if http.statusCode == 404 || http.statusCode == 503 { throw MusicServiceError.unavailable }
        guard http.statusCode == 200 else { throw MusicServiceError.badStatus(http.statusCode) }
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw MusicServiceError.decoding(error) }
    }
}

// MARK: - MusicCandidatesService

struct MusicCandidatesRequestDTO: Encodable {
    let musicPlan: JSONValue
    let targetDurationSeconds: Double
    let limit: Int
    enum CodingKeys: String, CodingKey {
        case musicPlan = "music_plan"
        case targetDurationSeconds = "target_duration_seconds"
        case limit
    }
}

private struct MusicTrackRequestDTO: Encodable {
    let trackId: String
    enum CodingKeys: String, CodingKey { case trackId = "track_id" }
}

private struct MusicSearchRequestDTO: Encodable {
    let query: String
    let pageSize: Int
    let cursor: String?
    enum CodingKeys: String, CodingKey {
        case query
        case pageSize = "page_size"
        case cursor
    }
}

final class MusicCandidatesService {
    private let baseURL: URL
    private let session: URLSession
    init(baseURL: URL = StoryBackend.baseURL, session: URLSession = StoryBackend.longSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// MusicPlan -> ranked candidates (+ preview urls + top-pick analysis). Returns the typed response AND
    /// the RAW top_music_analysis JSON subtree (so the planner gets the exact wire analysis with NO lossy
    /// re-encode, and the renderer gets the decoded MusicAnalysisV1 — both from one source).
    func candidates(musicPlan: JSONValue, targetDurationSeconds: Double, limit: Int = 5)
        async throws -> (response: MusicCandidatesResponseDTO, rawTopAnalysis: JSONValue?) {
        let body = MusicCandidatesRequestDTO(musicPlan: musicPlan, targetDurationSeconds: targetDurationSeconds, limit: limit)
        let data = try await postData("v1/music/candidates", body: body)
        let dto: MusicCandidatesResponseDTO
        do { dto = try StoryContractCoding.decoder().decode(MusicCandidatesResponseDTO.self, from: data) }
        catch {
            do { dto = try JSONDecoder().decode(MusicCandidatesResponseDTO.self, from: data) }
            catch { throw MusicServiceError.decoding(error) }
        }
        // Pull the raw top_music_analysis subtree verbatim (for the planner request).
        var rawTop: JSONValue? = nil
        if let whole = try? JSONDecoder().decode(JSONValue.self, from: data),
           case let .object(root) = whole, let a = root["top_music_analysis"] {
            if case .null = a { rawTop = nil } else { rawTop = a }
        }
        return (dto, rawTop)
    }

    /// Free-text catalog search with cursor pagination (for the picker's search bar + load-more). Returns a
    /// page of candidates and the next cursor (nil = no more pages). Throws .unavailable on 404/503.
    func searchPage(query: String, pageSize: Int = 10, cursor: String? = nil) async throws -> MusicSearchResponseDTO {
        let body = MusicSearchRequestDTO(query: query, pageSize: pageSize, cursor: cursor)
        let data = try await postData("v1/music/search", body: body)
        do { return try StoryContractCoding.decoder().decode(MusicSearchResponseDTO.self, from: data) }
        catch {
            do { return try JSONDecoder().decode(MusicSearchResponseDTO.self, from: data) }
            catch { throw MusicServiceError.decoding(error) }
        }
    }

    /// MusicAnalysis/1 for a SPECIFIC chosen track (when the user picks a non-top candidate). Returns BOTH the
    /// decoded analysis and its raw JSON (for the planner).
    func analysisBoth(trackId: String) async throws -> (analysis: MusicAnalysisV1, raw: JSONValue) {
        let data = try await postData("v1/music/analysis", body: MusicTrackRequestDTO(trackId: trackId))
        let decoded: MusicAnalysisV1
        do { decoded = try StoryContractCoding.decoder().decode(MusicAnalysisV1.self, from: data) }
        catch { throw MusicServiceError.decoding(error) }
        let raw = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
        return (decoded, raw)
    }

    /// MusicAnalysis/1 for a SPECIFIC chosen track (decoded only).
    func analysis(trackId: String) async throws -> MusicAnalysisV1 {
        return try await analysisBoth(trackId: trackId).analysis
    }

    /// Resolve an authorized download link for the selected track, then FETCH it to a transient local file.
    /// Returns the local file URL (caller threads it into MediaEngineInputs.soundtrackURL). Prototyping,
    /// non-commercial test use only — the server marks usage='prototyping_test', export OFF.
    func downloadSoundtrack(trackId: String) async throws -> URL {
        let link: MusicSoundtrackLinkDTO = try await postDecode("v1/music/soundtrack", body: MusicTrackRequestDTO(trackId: trackId))
        guard let url = URL(string: link.downloadURL.url) else { throw MusicServiceError.badStatus(-1) }
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(from: url) }
        catch { throw MusicServiceError.transport(error) }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw MusicServiceError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("soundtrack-\(trackId).mp3")
        try? FileManager.default.removeItem(at: tmp)
        do { try data.write(to: tmp) } catch { throw MusicServiceError.transport(error) }
        return tmp
    }

    private func postData<B: Encodable>(_ path: String, body: B) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { req.httpBody = try StoryContractCoding.encoder().encode(body) }
        catch { throw MusicServiceError.encoding(error) }
        let data: Data; let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw MusicServiceError.transport(error) }
        guard let http = resp as? HTTPURLResponse else { throw MusicServiceError.badStatus(-1) }
        if http.statusCode == 404 || http.statusCode == 503 { throw MusicServiceError.unavailable }
        guard http.statusCode == 200 else { throw MusicServiceError.badStatus(http.statusCode) }
        return data
    }

    private func postDecode<B: Encodable, R: Decodable>(_ path: String, body: B) async throws -> R {
        let data = try await postData(path, body: body)
        do { return try StoryContractCoding.decoder().decode(R.self, from: data) }
        catch {
            do { return try JSONDecoder().decode(R.self, from: data) }
            catch { throw MusicServiceError.decoding(error) }
        }
    }
}
