import Foundation

/// Thin HTTP client for the Cognito User Pool auth flows the Story iOS app uses. No AWS SDK — the User-Pool
/// IDP API is plain JSON-over-HTTPS with an `X-Amz-Target` header, and the OAuth token endpoint is form POST.
///
/// UNIFIED passwordless email flow (TestFlight self-signup, owner-approved Option A). ONE email-first UI
/// serves both new and returning testers; the client picks the correct Cognito operation behind the scenes:
///
///   NEW user (self-registration, no admin provisioning, no password):
///     SignUp(Username=email, UserAttributes=[email])            -> Cognito emails a verification code
///     ConfirmSignUp(Username=email, ConfirmationCode=code)      -> { Session }  (account now CONFIRMED)
///     InitiateAuth(AuthFlow=USER_AUTH, Session, USERNAME=email)  -> AuthenticationResult  (no 2nd code)
///       (fallback if the returned Session is absent/expired: the normal EMAIL_OTP sign-in below.)
///
///   EXISTING user (unchanged — identity/tokens/refresh/ownership preserved):
///     InitiateAuth(AuthFlow=USER_AUTH, PREFERRED_CHALLENGE=EMAIL_OTP) -> EMAIL_OTP challenge + Session
///     RespondToAuthChallenge(EMAIL_OTP_CODE)                          -> AuthenticationResult
///
/// New-vs-existing is resolved WITHOUT enumerating: the client attempts SignUp first; `UsernameExistsException`
/// means "already a user" -> fall through to the existing EMAIL_OTP sign-in. The UI shows the same "enter the
/// code" screen in both cases; only the VERIFY operation (ConfirmSignUp vs RespondToAuthChallenge) differs,
/// tracked by the challenge `kind`. Verified pool prerequisites (dev us-east-1_AzfHOEdA5): ESSENTIALS tier,
/// self-signup enabled, email IS the username, AutoVerified=email, ALLOW_USER_AUTH, PreventUserExistence
/// ENABLED, SDK SignUp is passwordless. No pool-plan / SES / infra change required.
///
/// Admin-provisioned accounts (legacy invite script) remain fully compatible: they are ordinary CONFIRMED
/// users, so they take the EXISTING-user branch exactly as before.
///
/// Apple uses the OAuth authorization-code + PKCE flow (handled by ASWebAuthenticationSession in AuthStore);
/// this client only exchanges the returned code at /oauth2/token and refreshes.
enum CognitoAuthError: Error, LocalizedError {
    case transport(Error)
    case service(String)        // Cognito __type / error message
    case badCode                // wrong OTP / confirmation code
    case expiredCode            // code expired — a new one is needed
    case tooManyAttempts        // challenge exhausted / throttled; restart the flow
    case noOTPPath              // Cognito offered no EMAIL_OTP path for a request that needed one
    case accountDisabled        // a disabled/suspended/revoked account cannot sign in
    case decoding
    case noChallengeSession

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach sign-in. Check your connection and try again."
        case .badCode: return "That code is incorrect. Check it and try again."
        case .expiredCode: return "That code has expired. Request a new one."
        case .tooManyAttempts: return "Too many tries. Request a new code to continue."
        case .noOTPPath: return "Couldn't send a code to that email. Check the address and try again."
        case .accountDisabled: return "This account can't sign in. Contact support if you think this is a mistake."
        case .service(let m): return m
        case .decoding, .noChallengeSession: return "Sign-in failed. Please try again."
        }
    }
}

/// A Cognito service error that preserves the raw `__type` so callers can branch (expired vs mismatch).
private struct CognitoServiceError: Error { let type: String; let message: String }

/// Which Cognito verify operation the pending code belongs to — so the shared code-entry UI calls the
/// CORRECT operation. `.signUp` verifies a brand-new registration (ConfirmSignUp); `.signIn` verifies an
/// existing-user EMAIL_OTP challenge (RespondToAuthChallenge). Never guess from the code itself.
enum OTPChallengeKind: Equatable { case signIn, signUp }

/// Result of requesting an email code. `maskedDestination` is Cognito's own masked address (e.g. "p***@s***").
/// `kind` records whether this challenge is a new-user registration confirmation or an existing-user sign-in,
/// so the verify step runs the right Cognito operation. `session` is the Cognito challenge Session for a
/// `.signIn` challenge; for a `.signUp` challenge it is unused (ConfirmSignUp carries the code, not a session).
struct OTPChallenge {
    let session: String
    let email: String
    let maskedDestination: String
    var kind: OTPChallengeKind = .signIn
}

actor CognitoAuthClient {
    private let urlSession: URLSession
    init(urlSession: URLSession = .shared) { self.urlSession = urlSession }

    // ---- Unified email entry: self-signup OR existing-user sign-in ----------------------------------
    /// Step 1 of the ONE email-first journey. Resolves new-vs-existing WITHOUT enumerating the user, then
    /// returns the challenge whose `kind` tells the verify step which Cognito operation to run.
    ///
    /// Strategy (bounded, no enumeration): attempt `SignUp` FIRST.
    ///   • SignUp SUCCEEDS  -> brand-new user; Cognito emailed a ConfirmSignUp code. Return `.signUp`.
    ///   • UsernameExists   -> the email is already a user (confirmed OR not); fall through to the existing
    ///                         EMAIL_OTP sign-in (`.signIn`). We never reveal which case it was to the caller.
    ///   • Unconfirmed-existing edge: an account that signed up but never confirmed also returns
    ///     UsernameExists; the EMAIL_OTP `InitiateAuth` below then surfaces it for recovery (resend/confirm).
    ///
    /// We do NOT lead with `InitiateAuth`: `PreventUserExistenceErrors=ENABLED` makes it return a DECOY
    /// EMAIL_OTP challenge for an unknown email (no code sent, no user created), which cannot be told from a
    /// real one — so leading with it would strand a genuinely-new tester forever. SignUp-first is the only
    /// path that actually creates the account for a new email.
    func startEmailAuth(email: String) async throws -> OTPChallenge {
        let normalized = AuthHelpers.normalizeEmail(email)
        do {
            // Passwordless SignUp (SDK API requires no Password on this pool). email is the username.
            let signUp = try await idpCall(target: "SignUp", body: [
                "ClientId": StoryAuthConfig.appClientId,
                "Username": normalized,
                "UserAttributes": [["Name": "email", "Value": normalized]],
            ])
            let params = (signUp["CodeDeliveryDetails"] as? [String: Any])
            let masked = (params?["Destination"] as? String) ?? normalized
            return OTPChallenge(session: "", email: normalized, maskedDestination: masked, kind: .signUp)
        } catch let e as CognitoServiceError where e.type.contains("UsernameExists") {
            // Already a user — take the existing-user EMAIL_OTP sign-in path.
            return try await startSignInOTP(email: normalized)
        } catch let e as CognitoServiceError {
            // Disabled/suspended user re-signup, throttling, or other service errors — surface safely.
            if e.type.contains("NotAuthorized") { throw CognitoAuthError.accountDisabled }
            if e.type.contains("TooManyRequests") || e.type.contains("LimitExceeded") {
                throw CognitoAuthError.tooManyAttempts
            }
            throw CognitoAuthError.service(e.message.isEmpty
                ? "Couldn't start sign-in. Check the address and try again." : e.message)
        }
    }

    /// Existing-user EMAIL_OTP via the NATIVE USER_AUTH flow (no password, no Lambda). Also used as the
    /// fallback when a new-user first sign-in cannot reuse the ConfirmSignUp session.
    func startSignInOTP(email: String) async throws -> OTPChallenge {
        let normalized = AuthHelpers.normalizeEmail(email)
        let json: [String: Any]
        do {
            json = try await idpCall(target: "InitiateAuth", body: [
                "AuthFlow": "USER_AUTH",
                "ClientId": StoryAuthConfig.appClientId,
                "AuthParameters": ["USERNAME": normalized, "PREFERRED_CHALLENGE": "EMAIL_OTP"],
            ])
        } catch let e as CognitoServiceError {
            if e.type.contains("NotAuthorized") { throw CognitoAuthError.accountDisabled }
            throw CognitoAuthError.service(e.message.isEmpty
                ? "Couldn't start sign-in. Check your connection and try again." : e.message)
        }
        let challengeName = json["ChallengeName"] as? String
        let params = json["ChallengeParameters"] as? [String: Any]
        let medium = params?["CODE_DELIVERY_DELIVERY_MEDIUM"] as? String
        guard challengeName == "EMAIL_OTP", let session = json["Session"] as? String, medium == "EMAIL" else {
            throw CognitoAuthError.noOTPPath
        }
        let masked = (params?["CODE_DELIVERY_DESTINATION"] as? String) ?? normalized
        return OTPChallenge(session: session, email: normalized, maskedDestination: masked, kind: .signIn)
    }

    /// Resend. A `.signUp` challenge resends the ConfirmSignUp code (ResendConfirmationCode); a `.signIn`
    /// challenge re-runs InitiateAuth (fresh code + fresh Session). Returns a refreshed challenge of the same
    /// kind so the verify step still routes correctly.
    func resendCode(for challenge: OTPChallenge) async throws -> OTPChallenge {
        switch challenge.kind {
        case .signIn:
            return try await startSignInOTP(email: challenge.email)
        case .signUp:
            do {
                let json = try await idpCall(target: "ResendConfirmationCode", body: [
                    "ClientId": StoryAuthConfig.appClientId,
                    "Username": challenge.email,
                ])
                let params = json["CodeDeliveryDetails"] as? [String: Any]
                let masked = (params?["Destination"] as? String) ?? challenge.email
                return OTPChallenge(session: "", email: challenge.email, maskedDestination: masked, kind: .signUp)
            } catch let e as CognitoServiceError {
                if e.type.contains("TooManyRequests") || e.type.contains("LimitExceeded") {
                    throw CognitoAuthError.tooManyAttempts
                }
                throw CognitoAuthError.service(e.message.isEmpty ? e.type : e.message)
            }
        }
    }

    /// Step 2: verify the code. Routes on `challenge.kind`:
    ///   • `.signUp` -> ConfirmSignUp, then first sign-in using the returned Session via USER_AUTH (no 2nd
    ///     code); if Cognito returns no usable Session, fall back to a normal EMAIL_OTP sign-in.
    ///   • `.signIn` -> RespondToAuthChallenge(EMAIL_OTP_CODE) against the challenge Session.
    func verifyCode(_ code: String, challenge: OTPChallenge) async throws -> AuthTokens {
        switch challenge.kind {
        case .signIn:  return try await verifyExistingOTP(code, challenge: challenge)
        case .signUp:  return try await confirmSignUpThenSignIn(code, challenge: challenge)
        }
    }

    /// Existing-user EMAIL_OTP verify. Cognito signals a bad code two ways: (a) a thrown
    /// `CodeMismatch`/`ExpiredCode`/`NotAuthorized` (attempts exhausted), or (b) a 200 that RE-ISSUES an
    /// EMAIL_OTP challenge instead of an AuthenticationResult. Both map to typed errors.
    private func verifyExistingOTP(_ code: String, challenge: OTPChallenge) async throws -> AuthTokens {
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
            throw CognitoAuthError.badCode   // re-issued challenge -> wrong code, flow still open
        } catch let e as CognitoServiceError {
            throw Self.mapOTPServiceError(e)
        }
    }

    /// New-user verify: ConfirmSignUp activates the account and (per the API) returns a Session usable to sign
    /// the user in immediately via USER_AUTH — NO second code. If the Session is missing/expired/rejected we
    /// fall back to the normal EMAIL_OTP sign-in (one more code), so registration always completes.
    private func confirmSignUpThenSignIn(_ code: String, challenge: OTPChallenge) async throws -> AuthTokens {
        let confirmed: [String: Any]
        do {
            confirmed = try await idpCall(target: "ConfirmSignUp", body: [
                "ClientId": StoryAuthConfig.appClientId,
                "Username": challenge.email,
                "ConfirmationCode": code,
            ])
        } catch let e as CognitoServiceError {
            throw Self.mapOTPServiceError(e)
        }
        // Preferred path: immediate sign-in with the ConfirmSignUp Session (no extra code).
        if let session = confirmed["Session"] as? String, session.count >= 20 {
            do {
                let json = try await idpCall(target: "InitiateAuth", body: [
                    "AuthFlow": "USER_AUTH",
                    "ClientId": StoryAuthConfig.appClientId,
                    "Session": session,
                    "AuthParameters": ["USERNAME": challenge.email],
                ])
                if json["AuthenticationResult"] != nil {
                    return try Self.tokens(fromAuthResult: json)
                }
                // Cognito wants another factor despite the session — fall through to a fresh OTP sign-in.
            } catch is CognitoServiceError {
                // Session not accepted for direct sign-in — fall through to the normal OTP sign-in.
            }
        }
        // Fallback: standard EMAIL_OTP sign-in. The account is now CONFIRMED, so this is an ordinary
        // existing-user flow — but it needs the user to enter the NEW code, surfaced via noChallengeSession
        // so the UI can present a fresh code entry rather than silently failing.
        _ = try await startSignInOTP(email: challenge.email)
        throw CognitoAuthError.noChallengeSession
    }

    /// Map a Cognito service error from an OTP/confirm verify to a typed app error.
    private static func mapOTPServiceError(_ e: CognitoServiceError) -> CognitoAuthError {
        switch e.type {
        case let t where t.contains("ExpiredCode"):   return .expiredCode
        case let t where t.contains("CodeMismatch"):  return .badCode
        case let t where t.contains("NotAuthorized"): return .tooManyAttempts
        case let t where t.contains("TooManyFailedAttempts"): return .tooManyAttempts
        case let t where t.contains("LimitExceeded") || t.contains("TooManyRequests"): return .tooManyAttempts
        default: return .service(e.message.isEmpty ? e.type : e.message)
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
