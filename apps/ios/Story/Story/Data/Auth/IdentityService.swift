import Foundation

// R1.1 — the ONE canonical account identity resolver.
//
// Before R1.1 the iOS client used the Cognito `sub` (from the id token) as `ownerAccountId`, while the backend
// authorizes on a SEPARATELY minted, immutable `story_user_id`. Building cloud ownership on two different
// identifiers is the bug this fixes. GET /v1/me (require_user) returns the backend's canonical id; the client
// adopts THAT as its one ownership identity.
//
// HARD RULE: resolution either succeeds or the sign-in FAILS. There is NO fallback to `sub` or `dev` — a failed
// resolve must not let the app key ownership on a different identifier (owner Decision 7).
enum IdentityServiceError: Error, LocalizedError {
    case transport(Error)
    case unauthorized           // 401 — token invalid/expired at /v1/me (should not happen right after sign-in)
    case badStatus(Int)
    case decoding
    case missingId              // 200 but no story_user_id in the body

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach Story to finish signing in. Check your connection and try again."
        case .unauthorized: return "Your session could not be verified. Please sign in again."
        case .badStatus(let c): return "Sign-in verification failed (\(c)). Please try again."
        case .decoding, .missingId: return "Sign-in verification returned an unexpected result. Please try again."
        }
    }
}

struct IdentityService {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = StoryBackend.longSession

    private struct MeResponse: Decodable { let story_user_id: String }

    /// Resolve the canonical `story_user_id` for the given access token. The token is passed explicitly (not via
    /// the shared `authTokenProvider` seam) because this runs DURING sign-in, before the seam is wired to the
    /// new session. Throws on any failure — the caller must treat that as sign-in failure, never fall back.
    func resolveCanonicalId(accessToken: String) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/me"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw IdentityServiceError.transport(error) }
        guard let http = resp as? HTTPURLResponse else { throw IdentityServiceError.decoding }
        if http.statusCode == 401 { throw IdentityServiceError.unauthorized }
        guard http.statusCode == 200 else { throw IdentityServiceError.badStatus(http.statusCode) }
        guard let me = try? JSONDecoder().decode(MeResponse.self, from: data) else {
            throw IdentityServiceError.decoding
        }
        let id = me.story_user_id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw IdentityServiceError.missingId }
        return id
    }
}
