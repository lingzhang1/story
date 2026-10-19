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

    /// A SEPARATE session for BACKGROUND model inference (asset/scene understanding). Isolating it from the
    /// interactive `longSession` means a Story's 20-25 large multipart AU uploads cannot occupy the connection
    /// pool that interactive requests (creative-intent, guide, director) need — so starting/working on Story B
    /// stays responsive while Story A analyzes. Per-host connections are capped so the client itself bounds how
    /// much AU hits the backend at once (interactive priority = isolation, not preemption). Generous timeout
    /// (AU is a model call) but a tighter per-host cap than the default 6.
    static let backgroundSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 2   // bound background upload concurrency at the transport layer
        return URLSession(configuration: cfg)
    }()

    /// Coverage/2 recompute is a SINGLE long Opus Mapper+Judge pass whose COLD first call over a large moment
    /// set (26-50 rich understandings, 8192 output tokens) was measured at ~191s on the dev backend — longer
    /// than longSession's 180s request timeout. With the shorter cap the device timed out, discarded the
    /// successful result, kept the empty cache, and re-triggered on next open: a recompute LOOP that never
    /// updated the Guide. A dedicated session with headroom lets the first cold call complete and cache.
    static let coverageSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 420
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: cfg)
    }()

    /// P0 Beta Auth Increment 4: the single token seam. AuthStore sets this to a closure returning the current
    /// access token (or nil when signed out). Every service stamps its request through `authorize(_:)` so the
    /// Authorization header is added in ONE place rather than 14 request-builders.
    nonisolated(unsafe) static var authTokenProvider: (() -> String?)?

    /// Stamp the bearer token onto a request when a session exists. No-op when signed out (dev optional-auth
    /// keeps working; prod rejects the unauthenticated request server-side).
    static func authorize(_ request: inout URLRequest) {
        if let token = authTokenProvider?(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
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
    // Model-backed call: use the GENEROUS 180s session, NOT URLSession.shared (60s). Under load — e.g. starting
    // a SECOND Story while the first is still uploading 24 clips (each AU ~10-14s, coverage ~40s, saturating the
    // backend) — the shared 60s timeout fires and the client throws "Couldn't create your Story" even though the
    // request later succeeds server-side. The 180s session absorbs that contention + App Runner cold start.
    var session: URLSession = StoryBackend.longSession

    func resolve(rawText: String) async throws -> CreativeIntentContractDTO {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/creative-intent"))
        StoryBackend.authorize(&req)  // P0 auth seam: bearer token when signed in
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
