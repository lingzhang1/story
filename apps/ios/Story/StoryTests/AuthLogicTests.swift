import XCTest
import CryptoKit
@testable import Story

// P0 Beta Auth Increment 4 — pure, device-independent auth logic. The device paths (Keychain,
// ASWebAuthenticationSession, live Cognito OTP/Apple, SwiftUI) are physical-device acceptance (Phase 6).
final class AuthLogicTests: XCTestCase {

    // MARK: Email normalization + validity
    func test_email_normalization_trims_and_lowercases() {
        XCTAssertEqual(AuthHelpers.normalizeEmail("  User@Example.COM \n"), "user@example.com")
    }

    func test_email_validity() {
        XCTAssertTrue(AuthHelpers.isPlausibleEmail("a@b.co"))
        XCTAssertTrue(AuthHelpers.isPlausibleEmail(" Person@Mail.Example.com "))
        XCTAssertFalse(AuthHelpers.isPlausibleEmail("nope"))
        XCTAssertFalse(AuthHelpers.isPlausibleEmail("@b.co"))
        XCTAssertFalse(AuthHelpers.isPlausibleEmail("a@b"))
        XCTAssertFalse(AuthHelpers.isPlausibleEmail("a b@c.co"))
    }

    // MARK: PKCE (RFC 7636)
    func test_pkce_challenge_is_base64url_sha256_of_verifier() {
        let verifier = "test-verifier-123"
        let expected = AuthHelpers.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        XCTAssertEqual(AuthHelpers.codeChallenge(for: verifier), expected)
        XCTAssertFalse(expected.contains("="))
        XCTAssertFalse(expected.contains("+"))
        XCTAssertFalse(expected.contains("/"))
    }

    func test_pkce_verifiers_are_random_and_urlsafe() {
        let a = AuthHelpers.randomCodeVerifier()
        let b = AuthHelpers.randomCodeVerifier()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains("=") || a.contains("+") || a.contains("/"))
    }

    // MARK: OTP resend cooldown
    func test_otp_cooldown_blocks_within_window_and_counts_down() {
        var cd = OTPCooldown(window: 60)
        let t0 = Date()
        XCTAssertTrue(cd.canRequest(now: t0))          // first allowed
        XCTAssertFalse(cd.canRequest(now: t0.addingTimeInterval(10)))  // within window blocked
        XCTAssertEqual(cd.secondsRemaining(now: t0.addingTimeInterval(10)), 50)
        XCTAssertTrue(cd.canRequest(now: t0.addingTimeInterval(61)))   // after window allowed
    }

    // MARK: Unverified JWT sub (display hint only)
    func test_unverified_sub_decodes_payload() {
        // header.payload.signature with payload {"sub":"abc-123"}
        func b64url(_ s: String) -> String {
            AuthHelpers.base64url(Data(s.utf8))
        }
        let token = "\(b64url("{}")).\(b64url("{\"sub\":\"abc-123\"}")).sig"
        XCTAssertEqual(AuthHelpers.unverifiedSub(fromJWT: token), "abc-123")
        XCTAssertNil(AuthHelpers.unverifiedSub(fromJWT: "not-a-jwt"))
    }

    // MARK: Token expiry uses a proactive skew
    func test_tokens_expired_uses_60s_skew() {
        let almost = AuthTokens(accessToken: "a", idToken: "i", refreshToken: "r",
                                expiresAt: Date().addingTimeInterval(30), storyUserId: nil)
        XCTAssertTrue(almost.isExpired, "within 60s of expiry should be treated as expired for proactive refresh")
        let fresh = AuthTokens(accessToken: "a", idToken: "i", refreshToken: "r",
                               expiresAt: Date().addingTimeInterval(600), storyUserId: nil)
        XCTAssertFalse(fresh.isExpired)
    }

    // MARK: Identity is never the email/relay
    func test_story_user_id_is_separate_from_email() {
        // AuthTokens carries storyUserId distinct from any email; the type has no email-as-identity field.
        let t = AuthTokens(accessToken: "a", idToken: "i", refreshToken: "r",
                           expiresAt: Date().addingTimeInterval(600), storyUserId: "story-uuid")
        XCTAssertEqual(t.storyUserId, "story-uuid")
    }
}
