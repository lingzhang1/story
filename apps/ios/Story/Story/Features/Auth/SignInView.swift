import SwiftUI

/// Passwordless email sign-up AND sign-in in ONE screen (TestFlight self-signup, Option A): enter email →
/// get a code → enter it → you're in. A brand-new email self-registers (Cognito SignUp + ConfirmSignUp); a
/// returning email signs in (EMAIL_OTP). The visual journey is identical; the client runs the correct Cognito
/// operation behind the scenes. No passwords, no invite codes, no separate registration screen.
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
                HStack { if busy { ProgressView() }; Text("Continue") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !AuthHelpers.isPlausibleEmail(email))
            Text("New here or returning — we'll email you a code. No password needed.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
    }

    private var codeStep: some View {
        VStack(spacing: 12) {
            Text("Enter the code sent to \(challenge?.maskedDestination ?? AuthHelpers.normalizeEmail(email))")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("123456", text: $code)
                .keyboardType(.numberPad).textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
                .textContentType(.oneTimeCode)
            Button { Task { await verify() } } label: {
                HStack { if busy { ProgressView() }; Text("Verify") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).disabled(busy || code.count < 4)
            Button(cooldownLeft > 0 ? "Resend in \(cooldownLeft)s" : "Resend code") {
                Task { await resend() }
            }
            .font(.footnote).disabled(busy || cooldownLeft > 0)
            Text("The code can take a minute or two to arrive. Check your spam folder if you don't see it.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
    }

    // ---- actions ----
    private func requestCode() async {
        guard cooldown.canRequest() else { startCooldownTimer(); return }
        error = nil; busy = true; defer { busy = false }
        do {
            challenge = try await auth.startEmailAuth(email: email)
            step = .code
            startCooldownTimer()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't send a code." }
    }

    private func resend() async {
        guard let current = challenge, cooldown.canRequest() else { startCooldownTimer(); return }
        error = nil; busy = true; defer { busy = false }
        do {
            challenge = try await auth.resendCode(for: current)
            startCooldownTimer()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't resend the code." }
    }

    private func verify() async {
        guard let challenge else { return }
        error = nil; busy = true; defer { busy = false }
        do {
            try await auth.verifyCode(code, challenge: challenge)
            onSignedIn()
        } catch CognitoAuthError.badCode {
            code = ""; error = CognitoAuthError.badCode.errorDescription
        } catch CognitoAuthError.expiredCode {
            // The code (and this challenge) are dead — send the user back to request a fresh one.
            code = ""; self.challenge = nil; step = .email
            error = CognitoAuthError.expiredCode.errorDescription
        } catch CognitoAuthError.tooManyAttempts {
            code = ""; self.challenge = nil; step = .email
            error = CognitoAuthError.tooManyAttempts.errorDescription
        } catch CognitoAuthError.noChallengeSession {
            // New account was CONFIRMED but Cognito couldn't auto-sign-in from the signup session; a fresh
            // sign-in code was just sent. Keep the user on the code screen as an EXISTING-user challenge.
            code = ""
            self.challenge = OTPChallenge(session: "", email: AuthHelpers.normalizeEmail(email),
                                          maskedDestination: challenge.maskedDestination, kind: .signIn)
            Task { await requestFreshSignInCode() }
            error = "Almost there — enter the new code we just emailed you."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "That code didn't work."
        }
    }

    /// Replace the placeholder post-confirm challenge with a real EMAIL_OTP sign-in challenge (carries the
    /// Cognito Session needed to verify). Used only on the rare ConfirmSignUp-session fallback.
    private func requestFreshSignInCode() async {
        do { challenge = try await auth.startEmailAuth(email: email) }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't send a new code." }
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
