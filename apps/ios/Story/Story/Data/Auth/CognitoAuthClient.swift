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
    case badCode                // wrong OTP
    case expiredCode            // OTP expired — a new one is needed
    case tooManyAttempts        // challenge exhausted; restart the flow
    case decoding
    case noChallengeSession

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach sign-in. Check your connection and try again."
        case .badCode: return "That code is incorrect. Check it and try again."
        case .expiredCode: return "That code has expired. Request a new one."
        case .tooManyAttempts: return "Too many tries. Request a new code to continue."
        case .service(let m): return m
        case .decoding, .noChallengeSession: return "Sign-in failed. Please try again."
        }
    }
}

/// A Cognito service error that preserves the raw `__type` so callers can branch (expired vs mismatch).
private struct CognitoServiceError: Error { let type: String; let message: String }

/// Result of requesting an email code. `maskedDestination` is Cognito's own masked address (e.g. "p***@s***")
/// — the UI shows the OTP entry screen ONLY when this is non-nil, i.e. a code was actually dispatched.
struct OTPChallenge { let session: String; let email: String; let maskedDestination: String }

actor CognitoAuthClient {
    private let urlSession: URLSession
    init(urlSession: URLSession = .shared) { self.urlSession = urlSession }

    // ---- Email OTP ----------------------------------------------------------------------------------
    /// Step 1: request a code via the NATIVE passwordless flow — no SignUp, no temporary password.
    ///
    /// The dev pool has `PreventUserExistenceErrors=ENABLED`, `EMAIL_OTP` as an allowed first-auth factor, and
    /// self-signup enabled. Verified against the live pool: a plain
    /// `InitiateAuth(USER_AUTH, PREFERRED_CHALLENGE=EMAIL_OTP)` returns `ChallengeName=EMAIL_OTP` with
    /// `CODE_DELIVERY_*` for BOTH a brand-new email and a returning one — Cognito creates/confirms the account
    /// atomically on the first successful code verification, so there is no phantom unconfirmed user and no
    /// client-generated credential. New-user-signup vs existing-user-sign-in is therefore a single UX step at
    /// this layer (anti-enumeration by design); the new-vs-returning distinction is resolved AFTER verification
    /// by the backend identity claim (a first verify mints a new StoryUser, a returning verify resolves it).
    ///
    /// Returns a challenge ONLY when Cognito reports a dispatched code (`CODE_DELIVERY_DELIVERY_MEDIUM`). A
    /// `SELECT_CHALLENGE` (EMAIL_OTP not offered) or any response without a delivery medium is surfaced as an
    /// error rather than advancing the UI to a code screen that would never receive a code.
    func startEmailOTP(email: String) async throws -> OTPChallenge {
        let normalized = AuthHelpers.normalizeEmail(email)
        let body: [String: Any] = [
            "AuthFlow": "USER_AUTH",
            "ClientId": StoryAuthConfig.appClientId,
            "AuthParameters": ["USERNAME": normalized, "PREFERRED_CHALLENGE": "EMAIL_OTP"],
        ]
        let json: [String: Any]
        do { json = try await idpCall(target: "InitiateAuth", body: body) }
        catch let e as CognitoServiceError {
            throw CognitoAuthError.service(e.message.isEmpty
                ? "Couldn't send a code to that email. Check the address and try again." : e.message)
        }
        let challengeName = json["ChallengeName"] as? String
        let params = json["ChallengeParameters"] as? [String: Any]
        let medium = params?["CODE_DELIVERY_DELIVERY_MEDIUM"] as? String
        guard challengeName == "EMAIL_OTP", let session = json["Session"] as? String, medium == "EMAIL" else {
            // SELECT_CHALLENGE or no delivery -> no code was sent. Do not show the OTP screen.
            throw CognitoAuthError.service("Couldn't send a code to that email. Check the address and try again.")
        }
        let masked = (params?["CODE_DELIVERY_DESTINATION"] as? String) ?? normalized
        return OTPChallenge(session: session, email: normalized, maskedDestination: masked)
    }

    /// Resend: identical to `startEmailOTP` (a fresh InitiateAuth dispatches a new code and a new Session).
    func resendEmailOTP(email: String) async throws -> OTPChallenge {
        try await startEmailOTP(email: email)
    }

    /// Step 2: verify the code. Returns tokens on success.
    ///
    /// Cognito signals a bad code two ways: (a) a thrown `CodeMismatchException`/`ExpiredCodeException`/
    /// `NotAuthorizedException` (attempts exhausted), or (b) a 200 that RE-ISSUES an `EMAIL_OTP` challenge
    /// instead of an `AuthenticationResult` (wrong code, retries remaining). Both are mapped to a typed error
    /// so the UI can tell "wrong code, try again" from "expired/exhausted, request a new one".
    func verifyEmailOTP(_ code: String, challenge: OTPChallenge) async throws -> AuthTokens {
        let body: [String: Any] = [
            "ChallengeName": "EMAIL_OTP",
            "ClientId": StoryAuthConfig.appClientId,
            "Session": challenge.session,
            "ChallengeResponses": ["USERNAME": challenge.email, "EMAIL_OTP_CODE": code],
        ]
        do {
            let json = try await idpCall(target: "RespondToAuthChallenge", body: body)
            if json["AuthenticationResult"] != nil {
                return try Self.tokens(fromAuthResult: json)
            }
            // Re-issued challenge -> the code was wrong but the flow is still open.
            throw CognitoAuthError.badCode
        } catch let e as CognitoServiceError {
            switch e.type {
            case let t where t.contains("ExpiredCode"):   throw CognitoAuthError.expiredCode
            case let t where t.contains("CodeMismatch"):  throw CognitoAuthError.badCode
            case let t where t.contains("NotAuthorized"): throw CognitoAuthError.tooManyAttempts
            default: throw CognitoAuthError.service(e.message.isEmpty ? e.type : e.message)
            }
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
            let msg = (obj["message"] as? String) ?? (obj["Message"] as? String) ?? ""
            throw CognitoServiceError(type: type, message: msg)
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
