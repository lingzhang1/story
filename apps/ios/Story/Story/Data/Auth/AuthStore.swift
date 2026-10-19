import Foundation
import SwiftUI
import AuthenticationServices

/// The single shared authentication/session layer (P0 Beta Auth Increment 4, Phase 1).
///
/// Owns the Cognito token set (via Keychain), exposes an observable auth state to SwiftUI, restores the
/// session on launch, refreshes access tokens silently, and resolves/holds the backend `story_user_id`
/// (NEVER the email or Apple relay as identity). It also provides the bearer token to the StoryBackend
/// networking seam and adopts anonymous local content on first sign-in.
@MainActor
@Observable
final class AuthStore: NSObject {
    enum State: Equatable { case signedOut, authenticating, signedIn }

    private(set) var state: State = .signedOut
    private(set) var storyUserId: String?
    private(set) var lastError: String?

    private var tokens: AuthTokens? { didSet { AuthStore.shared?.publishToken(tokens?.accessToken) } }
    private let client: CognitoAuthClient
    private var webAuthSession: ASWebAuthenticationSession?
    private var pkceVerifier: String?
    private var pkceState: String?

    /// Hook the app sets so local content can be adopted by the account on first sign-in (Phase 5). Receives
    /// the resolved story_user_id; implementation lives in the app layer (SwiftData) to keep this layer pure.
    var onFirstSignInAdopt: ((String) -> Void)?

    static private(set) var shared: AuthStore?

    init(client: CognitoAuthClient = CognitoAuthClient()) {
        self.client = client
        super.init()
        AuthStore.shared = self
    }

    var isSignedIn: Bool { state == .signedIn }

    // ---- launch restore ------------------------------------------------------------------------------
    func restore() async {
        guard let data = KeychainStore.load(),
              var t = try? JSONDecoder().decode(AuthTokens.self, from: data) else { return }
        if t.isExpired {
            do { t = try await refreshed(from: t) } catch { signOutLocal(); return }
        }
        tokens = t
        storyUserId = t.storyUserId
        state = .signedIn
    }

    // ---- Email OTP -----------------------------------------------------------------------------------
    func startEmailOTP(email: String) async throws -> OTPChallenge {
        state = .authenticating
        do { return try await client.startEmailOTP(email: email) }
        catch { state = .signedOut; throw error }
    }

    func verifyEmailOTP(_ code: String, challenge: OTPChallenge) async throws {
        do {
            let t = try await client.verifyEmailOTP(code, challenge: challenge)
            try await finishSignIn(with: t)
        } catch { state = .signedOut; lastError = (error as? LocalizedError)?.errorDescription; throw error }
    }

    // ---- Apple (OAuth code + PKCE via ASWebAuthenticationSession) ------------------------------------
    func signInWithApple() async throws {
        guard StoryAuthConfig.appleSignInAvailable else {
            throw CognitoAuthError.service("Apple sign-in isn't available in this build yet.")
        }
        state = .authenticating
        let verifier = AuthHelpers.randomCodeVerifier()
        let challenge = AuthHelpers.codeChallenge(for: verifier)
        let st = AuthHelpers.randomState()
        pkceVerifier = verifier; pkceState = st
        let url = StoryAuthConfig.authorizeURL(state: st, codeChallenge: challenge)
        let scheme = URL(string: StoryAuthConfig.redirectURI)!.scheme!

        let code: String = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] cbURL, err in
                if let err = err { cont.resume(throwing: CognitoAuthError.transport(err)); return }
                guard let cbURL = cbURL,
                      let comps = URLComponents(url: cbURL, resolvingAgainstBaseURL: false),
                      let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value,
                      returnedState == self?.pkceState,
                      let c = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                    cont.resume(throwing: CognitoAuthError.service("Apple sign-in was cancelled or failed."))
                    return
                }
                cont.resume(returning: c)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session
            session.start()
        }
        do {
            let t = try await client.exchangeAuthCode(code, codeVerifier: verifier)
            try await finishSignIn(with: t)
        } catch { state = .signedOut; lastError = (error as? LocalizedError)?.errorDescription; throw error }
    }

    // ---- silent refresh ------------------------------------------------------------------------------
    /// Returns a valid access token, refreshing if needed. The networking seam calls this before a cloud
    /// request. On refresh failure the session is cleared (the user must re-auth) — never falls back to an
    /// unauthenticated identity.
    func validAccessToken() async -> String? {
        guard var t = tokens else { return nil }
        if t.isExpired {
            do { t = try await refreshed(from: t); tokens = t; persist(t) }
            catch { signOutLocal(); return nil }
        }
        return t.accessToken
    }

    private func refreshed(from t: AuthTokens) async throws -> AuthTokens {
        var fresh = try await client.refresh(refreshToken: t.refreshToken)
        fresh.storyUserId = t.storyUserId
        return fresh
    }

    // ---- logout --------------------------------------------------------------------------------------
    /// Clears tokens + session state and the token published to the seam. Does NOT touch SwiftData or media
    /// (Phase 5: local content survives logout).
    func signOut() {
        signOutLocal()
    }

    private func signOutLocal() {
        tokens = nil
        storyUserId = nil
        state = .signedOut
        KeychainStore.clear()
        publishToken(nil)
    }

    // ---- finish sign-in: resolve story_user_id, adopt local content ---------------------------------
    private func finishSignIn(with incoming: AuthTokens) async throws {
        var t = incoming
        // Resolve the authoritative story_user_id from the backend (verifies the token server-side). Until a
        // dedicated /v1/me endpoint exists, the unverified `sub` is a display hint only; the backend remains
        // the authority on every protected request.
        t.storyUserId = AuthHelpers.unverifiedSub(fromJWT: t.idToken)
        tokens = t
        storyUserId = t.storyUserId
        persist(t)
        publishToken(t.accessToken)
        state = .signedIn
        if let uid = t.storyUserId { onFirstSignInAdopt?(uid) }
    }

    private func persist(_ t: AuthTokens) {
        if let data = try? JSONEncoder().encode(t) { KeychainStore.save(data) }
    }

    // ---- seam token bridge ---------------------------------------------------------------------------
    private func publishToken(_ token: String?) { StoryBackend.authTokenProvider = { token } }
}

extension AuthStore: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
