import SwiftUI

/// Passwordless sign-in: Email OTP (primary) + Sign in with Apple (when configured). No passwords.
struct SignInView: View {
    let auth: AuthStore
    var onSignedIn: () -> Void
    var onCancel: () -> Void

    private enum Step { case email, code }
    @State private var step: Step = .email
    @State private var email = ""
    @State private var code = ""
    @State private var challenge: OTPChallenge?
    @State private var busy = false
    @State private var error: String?
    @State private var cooldown = OTPCooldown()
    @State private var cooldownLeft = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 20) {
            Text("Sign in to use Story's AI")
                .font(.headline)
            Text("Your captured Moments and saved Stories stay on this device either way.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)

            switch step {
            case .email: emailStep
            case .code: codeStep
            }

            if StoryAuthConfig.appleSignInAvailable {
                Button { Task { await appleSignIn() } } label: {
                    Label("Continue with Apple", systemImage: "applelogo").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).disabled(busy)
            } else {
                Label("Apple sign-in unavailable in this build", systemImage: "applelogo")
                    .font(.footnote).foregroundStyle(.tertiary)
            }

            if let error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
            Button("Not now", action: onCancel).font(.footnote)
        }
        .padding()
        .onDisappear { timer?.invalidate() }
    }

    private var emailStep: some View {
        VStack(spacing: 12) {
            TextField("you@example.com", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button { Task { await requestCode() } } label: {
                HStack { if busy { ProgressView() }; Text("Email me a code") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !AuthHelpers.isPlausibleEmail(email))
        }
    }

    private var codeStep: some View {
        VStack(spacing: 12) {
            Text("Enter the code sent to \(AuthHelpers.normalizeEmail(email))")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("123456", text: $code)
                .keyboardType(.numberPad).textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
            Button { Task { await verify() } } label: {
                HStack { if busy { ProgressView() }; Text("Verify") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).disabled(busy || code.count < 4)
            Button(cooldownLeft > 0 ? "Resend in \(cooldownLeft)s" : "Resend code") {
                Task { await requestCode() }
            }
            .font(.footnote).disabled(busy || cooldownLeft > 0)
        }
    }

    // ---- actions ----
    private func requestCode() async {
        guard cooldown.canRequest() else { startCooldownTimer(); return }
        error = nil; busy = true; defer { busy = false }
        do {
            challenge = try await auth.startEmailOTP(email: email)
            step = .code
            startCooldownTimer()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't send a code." }
    }

    private func verify() async {
        guard let challenge else { return }
        error = nil; busy = true; defer { busy = false }
        do {
            try await auth.verifyEmailOTP(code, challenge: challenge)
            onSignedIn()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "That code didn't work." }
    }

    private func appleSignIn() async {
        error = nil; busy = true; defer { busy = false }
        do { try await auth.signInWithApple(); onSignedIn() }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Apple sign-in failed." }
    }

    private func startCooldownTimer() {
        timer?.invalidate()
        cooldownLeft = cooldown.secondsRemaining()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            Task { @MainActor in
                cooldownLeft = max(0, cooldownLeft - 1)
                if cooldownLeft == 0 { t.invalidate() }
            }
        }
    }
}
