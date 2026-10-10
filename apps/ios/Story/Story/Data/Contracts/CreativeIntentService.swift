import Foundation

// CreativeIntentService — the ONLY Milestone-C1 network boundary.
//
// Calls the backend POST /v1/creative-intent, decoding the canonical
// CreativeIntentContractDTO (snake_case wire, ISO-8601). This is the real
// vertical slice: free-form direction -> backend -> Model Gateway -> model ->
// structured CreativeIntent -> here.
//
// Scope: Creative Intent only. No Scene Understanding, Director, or Edit calls.
// Failure is surfaced to the UI (recoverable retry) — we NEVER silently
// fabricate an intent (approved design §9).

enum StoryBackend {
    /// Override at launch with STORY_API_BASE_URL; defaults to the live dev
    /// App Runner service. Configuration-driven; no provider assumptions on
    /// the client.
    static var baseURL: URL {
        if let s = ProcessInfo.processInfo.environment["STORY_API_BASE_URL"],
           let u = URL(string: s) { return u }
        return URL(string: "https://ydmju5wdps.us-east-1.awsapprunner.com")!
    }

    /// A URLSession with a GENEROUS timeout for slow model-backed calls. The Edit Planner is one ~28s Opus
    /// call, and the music flow stacks MusicPlan (~8s) + candidates + a soundtrack download + the planner on
    /// top of App Runner cold-start latency — well past URLSession.shared's default 60s request timeout, which
    /// surfaced on device as NSURLErrorNetworkConnectionLost (-1005). 180s request / 300s resource covers it.
    static let longSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()
}

enum CreativeIntentServiceError: Error, LocalizedError {
    case transport(Error)
    case unavailable            // 503 — model/provider failure; retry
    case badStatus(Int)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach Story. Check your connection and try again."
        case .unavailable: return "Story's director is busy. Please try again."
        case .badStatus(let c): return "Unexpected response (\(c)). Please try again."
        case .decoding: return "Story returned something unexpected. Please try again."
        }
    }
}

struct CreativeIntentService {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = .shared

    func resolve(rawText: String) async throws -> CreativeIntentContractDTO {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/creative-intent"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["raw_text": rawText])

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw CreativeIntentServiceError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw CreativeIntentServiceError.badStatus(-1)
        }
        if http.statusCode == 503 { throw CreativeIntentServiceError.unavailable }
        guard http.statusCode == 200 else {
            throw CreativeIntentServiceError.badStatus(http.statusCode)
        }
        do {
            return try StoryContractCoding.decoder().decode(CreativeIntentContractDTO.self, from: data)
        } catch {
            throw CreativeIntentServiceError.decoding(error)
        }
    }
}
