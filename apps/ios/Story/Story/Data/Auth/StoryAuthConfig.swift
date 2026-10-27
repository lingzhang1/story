import Foundation

/// Client-side Cognito configuration for the Story auth flows (P0 Beta Auth Increment 4).
///
/// These are NON-SECRET identifiers (pool id, public app-client id, hosted domain) — never credentials.
/// Dev defaults match the provisioned `story-development-auth` stack; override at launch via environment for
/// staging/prod. There is NO client secret (the iOS app client is public, PKCE-protected).
enum StoryAuthConfig {
    static let region = StoryEnvironment.current.cognitoRegion
    static let userPoolId = StoryEnvironment.current.userPoolId
    static let appClientId = StoryEnvironment.current.appClientId
    /// Cognito hosted domain PREFIX (the full host is `<prefix>.auth.<region>.amazoncognito.com`).
    static let domainPrefix = StoryEnvironment.current.domainPrefix
    /// Native custom-scheme redirect registered on the app client + in Info.plist URL types.
    static let redirectURI = StoryEnvironment.current.redirectURI
    static let appleProviderName = "SignInWithApple"

    /// Apple sign-in is only offered when the Apple IdP has been configured on the pool. Until the Apple
    /// Developer credentials are provisioned, the UI keeps the Apple button disabled / "unavailable in this
    /// build" rather than showing a nonfunctional button (owner directive, Phase 3).
    static var appleSignInAvailable: Bool {
        (env("STORY_APPLE_SIGNIN_AVAILABLE") ?? "0") == "1"
    }

    static var domainHost: String { "\(domainPrefix).auth.\(region).amazoncognito.com" }
    static var tokenEndpoint: URL { URL(string: "https://\(domainHost)/oauth2/token")! }
    static var idpBase: URL { URL(string: "https://cognito-idp.\(region).amazonaws.com/")! }
    static func authorizeURL(state: String, codeChallenge: String) -> URL {
        var c = URLComponents(string: "https://\(domainHost)/oauth2/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: appClientId),
            .init(name: "identity_provider", value: appleProviderName),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        return c.url!
    }
}
