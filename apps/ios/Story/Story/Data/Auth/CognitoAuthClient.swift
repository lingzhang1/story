import Foundation

/// Thin HTTP client for the Cognito User Pool auth flows the Story iOS app uses. No AWS SDK — the User-Pool
/// IDP API is plain JSON-over-HTTPS with an `X-Amz-Target` header, and the OAuth token endpoint is form POST.
///
/// Email OTP uses the NATIVE USER_AUTH choice-based flow (no custom Lambdas, no passwords):
///   InitiateAuth(AuthFlow=USER_AUTH, PREFERRED_CHALLENGE=EMAIL_OTP) -> EMAIL_OTP challenge + Session
///   RespondToAuthChallenge(EMAIL_OTP_CODE) -> AuthenticationResult (access/id/refresh)
///
/// Apple uses the OAuth authorization-code + PKCE flow (handled by ASWebAuthenticationSession in AuthStore);
/// this client only exchanges the returned code at /oauth2/token and refreshes.
enum CognitoAuthError: Error, LocalizedError {
    case transport(Error)
    case service(String)        // Cognito __type / error message
    case badCode                // wrong/expired OTP
    case decoding
    case noChallengeSession

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach sign-in. Check your connection and try again."
        case .badCode: return "That code is incorrect or expired. Request a new one."
        case .service(let m): return m
        case .decoding, .noChallengeSession: return "Sign-in failed. Please try again."
        }
    }
}

struct OTPChallenge { let session: String; let email: String }

actor CognitoAuthClient {
    private let urlSession: URLSession
    init(urlSession: URLSession = .shared) { self.urlSession = urlSession }

    // ---- Email OTP ----------------------------------------------------------------------------------
    /// Step 1: request a code. Returns a challenge session to carry into `verifyEmailOTP`.
    func startEmailOTP(email: String) async throws -> OTPChallenge {
        let normalized = AuthHelpers.normalizeEmail(email)
        let body: [String: Any] = [
            "AuthFlow": "USER_AUTH",
            "ClientId": StoryAuthConfig.appClientId,
            "AuthParameters": ["USERNAME": normalized, "PREFERRED_CHALLENGE": "EMAIL_OTP"],
        ]
        let json = try await idpCall(target: "InitiateAuth", body: body)
        guard let session = json["Session"] as? String else {
            // If Cognito returned an immediate challenge list instead, EMAIL_OTP may not be selectable.
            throw CognitoAuthError.noChallengeSession
        }
        return OTPChallenge(session: session, email: normalized)
    }

    /// Step 2: verify the code. Returns tokens on success.
    func verifyEmailOTP(_ code: String, challenge: OTPChallenge) async throws -> AuthTokens {
        let body: [String: Any] = [
            "ChallengeName": "EMAIL_OTP",
            "ClientId": StoryAuthConfig.appClientId,
            "Session": challenge.session,
            "ChallengeResponses": ["USERNAME": challenge.email, "EMAIL_OTP_CODE": code],
        ]
        do {
            let json = try await idpCall(target: "RespondToAuthChallenge", body: body)
            return try Self.tokens(fromAuthResult: json)
        } catch let CognitoAuthError.service(msg) {
            if msg.lowercased().contains("code") || msg.lowercased().contains("notauthorized") {
                throw CognitoAuthError.badCode
            }
            throw CognitoAuthError.service(msg)
        }
    }

    // ---- OAuth (Apple) code exchange + refresh ------------------------------------------------------
    func exchangeAuthCode(_ code: String, codeVerifier: String) async throws -> AuthTokens {
        try await oauthTokenForm([
            "grant_type": "authorization_code",
            "client_id": StoryAuthConfig.appClientId,
            "code": code,
            "redirect_uri": StoryAuthConfig.redirectURI,
            "code_verifier": codeVerifier,
        ])
    }

    func refresh(refreshToken: String) async throws -> AuthTokens {
        var t = try await oauthTokenForm([
            "grant_type": "refresh_token",
            "client_id": StoryAuthConfig.appClientId,
            "refresh_token": refreshToken,
        ])
        // The refresh grant does not return a new refresh token unless rotation is enabled; carry the old one
        // forward when Cognito omits it.
        if t.refreshToken.isEmpty { t.refreshToken = refreshToken }
        return t
    }

    // ---- transport ----------------------------------------------------------------------------------
    private func idpCall(target: String, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: StoryAuthConfig.idpBase)
        req.httpMethod = "POST"
        req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        req.setValue("AWSCognitoIdentityProviderService.\(target)", forHTTPHeaderField: "X-Amz-Target")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await urlSession.data(for: req) }
        catch { throw CognitoAuthError.transport(error) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let type = (obj["__type"] as? String) ?? ""
            let msg = (obj["message"] as? String) ?? (obj["Message"] as? String) ?? type
            throw CognitoAuthError.service(msg.isEmpty ? "sign-in error" : msg)
        }
        return obj
    }

    private func oauthTokenForm(_ fields: [String: String]) async throws -> AuthTokens {
        var req = URLRequest(url: StoryAuthConfig.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await urlSession.data(for: req) }
        catch { throw CognitoAuthError.transport(error) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw CognitoAuthError.service((obj["error_description"] as? String) ?? (obj["error"] as? String) ?? "oauth error")
        }
        return try Self.tokens(fromOAuth: obj)
    }

    // ---- token shaping ------------------------------------------------------------------------------
    private static func tokens(fromAuthResult json: [String: Any]) throws -> AuthTokens {
        guard let r = json["AuthenticationResult"] as? [String: Any],
              let access = r["AccessToken"] as? String, let id = r["IdToken"] as? String else {
            throw CognitoAuthError.decoding
        }
        let refresh = (r["RefreshToken"] as? String) ?? ""
        let exp = (r["ExpiresIn"] as? Double) ?? 3600
        return AuthTokens(accessToken: access, idToken: id, refreshToken: refresh,
                          expiresAt: Date().addingTimeInterval(exp), storyUserId: nil)
    }

    private static func tokens(fromOAuth json: [String: Any]) throws -> AuthTokens {
        guard let access = json["access_token"] as? String, let id = json["id_token"] as? String else {
            throw CognitoAuthError.decoding
        }
        let refresh = (json["refresh_token"] as? String) ?? ""
        let exp = (json["expires_in"] as? Double) ?? 3600
        return AuthTokens(accessToken: access, idToken: id, refreshToken: refresh,
                          expiresAt: Date().addingTimeInterval(exp), storyUserId: nil)
    }
}
