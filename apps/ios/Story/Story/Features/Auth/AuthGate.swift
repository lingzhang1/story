import SwiftUI

/// Gates cloud-AI actions behind authentication (Phase 4). The caller wraps a cloud action in `run`; if the
/// user is signed in it executes immediately, otherwise it STORES the action, presents sign-in, and resumes
/// the SAME stored action exactly once after success — so navigation, selected Moments, Story customization,
/// and the user's intent are preserved and the model call fires only ONCE.
@MainActor
@Observable
final class AuthGate {
    private let auth: AuthStore
    var presentingSignIn = false
    private var pendingAction: (() -> Void)?
    private var resumed = false

    init(auth: AuthStore) { self.auth = auth }

    /// Run a cloud action, requiring auth first. In dev optional-auth the backend still accepts no token, but
    /// the app gates at the UI so the cutover to required-auth is a one-line flip (and so the user sees a
    /// sign-in prompt rather than a silent anonymous call). Pass `requireAuth:false` to bypass for a path that
    /// is intentionally anonymous.
    func run(requireAuth: Bool = true, _ action: @escaping () -> Void) {
        if !requireAuth || auth.isSignedIn {
            action()
            return
        }
        pendingAction = action
        resumed = false
        presentingSignIn = true
    }

    /// Called by the sign-in UI on success. Resumes the pending action AT MOST ONCE (guards against a resume
    /// racing a token refresh or a re-presented sheet → never a duplicate model call).
    func didSignIn() {
        presentingSignIn = false
        guard !resumed, let action = pendingAction else { return }
        resumed = true
        pendingAction = nil
        action()
    }

    func cancel() {
        presentingSignIn = false
        pendingAction = nil
        resumed = false
    }
}
