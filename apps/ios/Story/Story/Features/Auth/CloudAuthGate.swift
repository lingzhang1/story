import SwiftUI

/// Reusable sign-in gate for cloud-AI actions (P0 Beta Auth Increment 4, Phase 4).
///
/// Usage in a presenting view:
///   @Environment(AuthStore.self) private var auth
///   @State private var cloudGate = CloudAuthGateModel()
///   ...
///   Button("…") { cloudGate.run { <cloud action> } }
///   ...
///   .cloudAuthGate(cloudGate)      // installs the SignInView sheet, bound to THIS view's model
///
/// The host OWNS the model (as @State) and both drives it (`run`) and installs the sheet (`.cloudAuthGate`),
/// so there is no environment-propagation dependency across sheet/cover boundaries — the gate works inside a
/// sheet, a fullScreenCover, or a pushed view. If signed out it presents SignInView and resumes the action
/// exactly once after success (no duplicate model call).
@MainActor
@Observable
final class CloudAuthGateModel {
    var showSignIn = false
    @ObservationIgnored fileprivate var auth: AuthStore?
    @ObservationIgnored private var gate: AuthGate?
    @ObservationIgnored private var pendingAction: (() -> Void)?

    func run(_ action: @escaping () -> Void) {
        // If auth isn't bound yet the SAFE default is to GATE (store + present), never to run the paid action
        // ungated. The modifier binds `auth` in `body` (not only onAppear), so by the time a user can tap it is
        // set — but if it somehow is not, we still store and present rather than firing a paid call anonymously.
        guard let auth else {
            pendingAction = action
            showSignIn = true
            return
        }
        // Delegate the resume-once bookkeeping to the tested AuthGate core, then mirror its presentation flag
        // SYNCHRONOUSLY into the sheet binding (set immediately after run, so it cannot be read stale).
        let g = gate ?? AuthGate(auth: auth)
        gate = g
        pendingAction = nil
        g.run(action)
        showSignIn = g.presentingSignIn
    }

    func didSignIn() {
        showSignIn = false
        if let gate { gate.didSignIn() }
        else if let action = pendingAction { pendingAction = nil; action() }  // auth-was-nil path
    }

    func cancel() {
        showSignIn = false
        gate?.cancel()
        pendingAction = nil
    }
}

private struct CloudAuthGateModifier: ViewModifier {
    @Environment(AuthStore.self) private var auth
    @Bindable var model: CloudAuthGateModel

    func body(content: Content) -> some View {
        // Bind auth eagerly here (evaluated on every body pass), not only in onAppear, so `run()` can never
        // see a nil auth and fall through ungated.
        model.auth = auth
        return content
            .sheet(isPresented: $model.showSignIn) {
                SignInView(auth: auth,
                           onSignedIn: { model.didSignIn() },
                           onCancel: { model.cancel() })
            }
    }
}

extension View {
    /// Install the cloud-AI sign-in sheet, bound to a host-owned `CloudAuthGateModel`.
    func cloudAuthGate(_ model: CloudAuthGateModel) -> some View {
        modifier(CloudAuthGateModifier(model: model))
    }
}
