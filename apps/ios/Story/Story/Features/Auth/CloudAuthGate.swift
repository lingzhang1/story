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
    fileprivate var gate: AuthGate?
    fileprivate var auth: AuthStore?

    func run(_ action: @escaping () -> Void) {
        guard let auth else { action(); return }
        let g = gate ?? AuthGate(auth: auth)
        gate = g
        g.run(action)
        showSignIn = g.presentingSignIn
    }

    func didSignIn() { showSignIn = false; gate?.didSignIn() }
    func cancel() { showSignIn = false; gate?.cancel() }
}

private struct CloudAuthGateModifier: ViewModifier {
    @Environment(AuthStore.self) private var auth
    @Bindable var model: CloudAuthGateModel

    func body(content: Content) -> some View {
        content
            .onAppear { model.auth = auth }
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
