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
    /// R1.1 — resolves the canonical backend story_user_id (GET /v1/me). Injectable for tests.
    private let identity: IdentityService
    private var webAuthSession: ASWebAuthenticationSession?
    private var pkceVerifier: String?
    private var pkceState: String?

    /// Hook the app sets so local content can be adopted by the account on first sign-in (Phase 5). Receives
    /// Hook the app sets so local content can be adopted/migrated on first sign-in. Receives BOTH the resolved
    /// CANONICAL story_user_id AND the legacy Cognito `sub` (R1 stamped ownership with the sub), so the app
    /// layer can re-key existing R1 Stories sub -> canonical. Implementation lives in the app layer (SwiftData)
    /// to keep this layer pure.
    var onFirstSignInAdopt: ((_ canonicalId: String, _ legacySub: String?) -> Void)?

    static private(set) var shared: AuthStore?

    init(client: CognitoAuthClient = CognitoAuthClient(), identity: IdentityService = IdentityService()) {
        self.client = client
        self.identity = identity
        super.init()
        AuthStore.shared = self
    }

    var isSignedIn: Bool { state == .signedIn }

    /// R1 — the active account scope for repositories. `.account(storyUserId)` only when signed in AND the id is
    /// resolved; otherwise `.anonymous`. Story creation requires `.account`; Moment reads tolerate `.anonymous`.
    var activeOwner: ActiveOwner {
        if state == .signedIn, let uid = storyUserId { return .account(uid) }
        return .anonymous
    }

    // ---- launch restore ------------------------------------------------------------------------------
    func restore() async {
        guard let data = KeychainStore.load(),
              var t = try? JSONDecoder().decode(AuthTokens.self, from: data) else { return }
        if t.isExpired {
            do { t = try await refreshed(from: t) } catch { signOutLocal(); return }
        }
        // R1.1 — a token blob persisted by a PRE-R1.1 build carries the Cognito `sub` (not the canonical
        // story_user_id) and `canonicalResolved == false`. We MUST NOT restore a session keyed on the sub, so
        // re-resolve the canonical id via /v1/me and only then restore. If that fails, sign out (no fallback to
        // the sub). An R1.1 blob (already canonical) restores WITHOUT a network round-trip, so a cold launch
        // offline keeps a valid session.
        if !t.canonicalResolved || (t.storyUserId ?? "").isEmpty {
            do {
                let canonicalId = try await identity.resolveCanonicalId(accessToken: t.accessToken)
                t.storyUserId = canonicalId
                t.canonicalResolved = true
                persist(t)
            } catch {
                signOutLocal()
                lastError = (error as? LocalizedError)?.errorDescription
                return
            }
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
        fresh.canonicalResolved = t.canonicalResolved   // R1.1: a refresh preserves the resolved canonical id
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

    // ---- finish sign-in: resolve CANONICAL story_user_id, adopt local content ----------------------
    private func finishSignIn(with incoming: AuthTokens) async throws {
        var t = incoming
        // R1.1 — resolve the CANONICAL, backend-minted story_user_id via GET /v1/me. This is the ONE identity
        // all ownership + account-scoped queries use. We NO LONGER key ownership on the Cognito `sub`.
        // If resolution fails, the sign-in FAILS (clear state, surface the error) — we never fall back to the
        // sub or the legacy `dev` identity (owner Decision 7), because that would re-introduce two identifiers.
        let canonicalId: String
        do {
            canonicalId = try await identity.resolveCanonicalId(accessToken: t.accessToken)
        } catch {
            signOutLocal()
            lastError = (error as? LocalizedError)?.errorDescription ?? "Couldn't finish signing in. Please try again."
            throw error
        }
        t.storyUserId = canonicalId
        t.canonicalResolved = true
        tokens = t
        storyUserId = canonicalId
        persist(t)
        publishToken(t.accessToken)
        state = .signedIn
        // R1.1: pass the canonical id AND the legacy Cognito sub so the app can re-key R1 Stories stamped with
        // the sub. The sub is read from the id token (display/migration hint only — authz uses the canonical id).
        let legacySub = AuthHelpers.unverifiedSub(fromJWT: t.idToken)
        onFirstSignInAdopt?(canonicalId, legacySub)
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
