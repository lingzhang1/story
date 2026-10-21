import Foundation
import CryptoKit

/// Pure, side-effect-free auth helpers — the unit-tested core (no network, no UI, no Keychain).

enum AuthHelpers {
    /// Email normalization for OTP: trim + lowercase. (We do NOT strip Gmail dots/plus — that would merge
    /// distinct deliverable addresses; normalization here is only about casing/whitespace so the same inbox
    /// maps to one claim. The authoritative identity is still the Cognito sub, never the email.)
    static func normalizeEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isPlausibleEmail(_ email: String) -> Bool {
        let e = normalizeEmail(email)
        guard let at = e.firstIndex(of: "@"), at != e.startIndex else { return false }
        let domain = e[e.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !e.contains(" ")
    }

    // ---- PKCE (RFC 7636) --------------------------------------------------------------------------------
    static func randomCodeVerifier(_ bytes: Int = 64) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        return base64url(Data(raw))
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64url(Data(digest))
    }

    static func randomState() -> String { randomCodeVerifier(24) }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode the `sub` claim from a JWT WITHOUT verifying the signature. Client-side this is used ONLY as a
    /// display/convenience hint; the backend re-verifies the token and resolves the authoritative
    /// story_user_id. Never treat this as trusted identity.
    static func unverifiedSub(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["sub"] as? String
    }
}

/// The token set persisted in the Keychain. story_user_id is the backend-resolved immutable identity (NOT
/// the email or Apple relay).
struct AuthTokens: Codable, Equatable {
    var accessToken: String
    var idToken: String
    var refreshToken: String
    var expiresAt: Date         // access-token expiry (for proactive silent refresh)
    var storyUserId: String?    // R1.1: the CANONICAL backend story_user_id (from /v1/me), NOT the Cognito sub
    /// R1.1 — true once `storyUserId` holds the canonical backend id (resolved via /v1/me). A token blob
    /// persisted by a PRE-R1.1 build decodes this as false (Codable default), so restore() knows it must
    /// re-resolve the canonical id rather than trust a possibly-`sub` value. Defaulted for migration safety.
    var canonicalResolved: Bool = false

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }  // 60s skew for proactive refresh
}

/// OTP resend cooldown policy (pure). Enforces a 60s window between code requests.
struct OTPCooldown {
    let window: TimeInterval
    private var lastRequest: Date?
    init(window: TimeInterval = 60) { self.window = window }

    mutating func canRequest(now: Date = Date()) -> Bool {
        if let last = lastRequest, now.timeIntervalSince(last) < window { return false }
        lastRequest = now
        return true
    }

    func secondsRemaining(now: Date = Date()) -> Int {
        guard let last = lastRequest else { return 0 }
        return max(0, Int(window - now.timeIntervalSince(last)))
    }
}
