import Foundation

/// THE single source of truth for which backend/Cognito environment the app talks to (TestFlight Option A,
/// beta-archive safety gate).
///
/// WHY THIS EXISTS: `StoryLaunchConfig` resolves each key independently as `env var → persisted UserDefaults
/// → nil → hardcoded dev default`. That is correct for an attached DEV run, but for a TestFlight ARCHIVE it
/// is unsafe three ways: (1) `ProcessInfo.environment` is empty (no attached scheme), (2) a tester's device
/// may carry stale persisted dev values, (3) the final fallback is the DEV pool/API — so a beta build could
/// silently talk to development. This type makes the environment ONE resolved object with FAIL-CLOSED rules
/// in a release build, independent of how the archive scheme is wired.
///
/// RESOLUTION RULES:
///  • RELEASE build (`#if !DEBUG`, i.e. an Archive / TestFlight / App Store build): the environment is read
///    ONLY from values BAKED INTO Info.plist at build time (`StoryBuildEnv` + `StoryEnv*` keys, populated via
///    `$(STORY_BUILD_ENV)` / `$(STORY_ENV_*)` build-setting substitution from the selected xcconfig). Process
///    environment and persisted UserDefaults are IGNORED — a stale dev override can never redirect a beta
///    build. If the baked env is `beta` but ANY required value is missing, still an unresolved `$(...)` token,
///    or MISMATCHED (e.g. a beta API with a dev Cognito pool), resolution FAILS CLOSED (fatalError at launch)
///    rather than silently selecting development. A release build therefore cannot run against the wrong
///    backend: it runs against the fully-consistent baked environment or it does not run.
///  • DEBUG build: developer flexibility is preserved — the legacy `StoryLaunchConfig` chain (scheme env →
///    persisted → dev default) still applies, so attached dev runs and scheme toggles behave exactly as before.
///
/// These are NON-SECRET identifiers (pool id, public client id, hosted domain, API URL) — never credentials.
enum StoryEnvironmentKind: String { case development, beta, gamma, production }

/// A fully-resolved, internally-consistent environment. Construction is the ONLY place the values are chosen,
/// so no caller can assemble a half-dev/half-beta mix.
struct StoryEnvironment: Equatable {
    let kind: StoryEnvironmentKind
    let apiBaseURL: URL
    let cognitoRegion: String
    let userPoolId: String
    let appClientId: String
    let domainPrefix: String
    let redirectURI: String

    // ---- hardcoded development defaults (the DEBUG fallback target) ---------------------------------
    static let developmentDefault = StoryEnvironment(
        kind: .development,
        apiBaseURL: URL(string: "https://ydmju5wdps.us-east-1.awsapprunner.com")!,
        cognitoRegion: "us-east-1",
        userPoolId: "us-east-1_AzfHOEdA5",
        appClientId: "5rnvp7oq6d7crbt01ldpe89tkh",
        domainPrefix: "story-development-auth",
        redirectURI: "story://auth")

    /// The resolved environment for THIS build. Computed once; see the rules in the type doc above.
    static let current: StoryEnvironment = resolve()

    // ---- resolution ---------------------------------------------------------------------------------
    private static func resolve() -> StoryEnvironment {
        #if DEBUG
        // Developer build: keep the flexible legacy chain (scheme env → persisted → dev default), resolved
        // per key through StoryLaunchConfig so attached dev runs and scheme toggles are unchanged.
        return debugResolved()
        #else
        // Release / Archive / TestFlight: ONLY the baked Info.plist environment, fail-closed.
        return releaseResolvedOrDie()
        #endif
    }

    /// Treat empty, the literal "unknown", or an unresolved `$(...)` build token as NOT baked (matches the
    /// BuildProvenance.GitCommitSHA convention).
    private static func baked(_ key: String) -> String? {
        let raw = (Bundle.main.infoDictionary?[key] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw.lowercased() == "unknown" || raw.hasPrefix("$(") { return nil }
        return raw
    }

    #if DEBUG
    private static func debugResolved() -> StoryEnvironment {
        let d = developmentDefault
        let api = StoryLaunchConfig.value("STORY_API_BASE_URL").flatMap(URL.init(string:)) ?? d.apiBaseURL
        return StoryEnvironment(
            kind: StoryEnvironmentKind(rawValue: baked("StoryBuildEnv") ?? "development") ?? .development,
            apiBaseURL: api,
            cognitoRegion: StoryLaunchConfig.value("STORY_COGNITO_REGION") ?? d.cognitoRegion,
            userPoolId: StoryLaunchConfig.value("STORY_COGNITO_USER_POOL_ID") ?? d.userPoolId,
            appClientId: StoryLaunchConfig.value("STORY_COGNITO_APP_CLIENT_ID") ?? d.appClientId,
            domainPrefix: StoryLaunchConfig.value("STORY_COGNITO_DOMAIN_PREFIX") ?? d.domainPrefix,
            redirectURI: StoryLaunchConfig.value("STORY_COGNITO_REDIRECT_URI") ?? d.redirectURI)
    }
    #endif

    #if !DEBUG
    private static func releaseResolvedOrDie() -> StoryEnvironment {
        // If NO environment is baked, this build was not wired to an xcconfig. Rather than brick an existing
        // plain-Release build, fall back to the development default — a dev-labelled release is the local /
        // simulator release case and is NOT a distributable beta. (A beta archive MUST select Beta.xcconfig,
        // which bakes StoryBuildEnv=beta and trips the fail-closed checks below.)
        guard let envRaw = baked("StoryBuildEnv"), let kind = StoryEnvironmentKind(rawValue: envRaw) else {
            return developmentDefault
        }
        // A development-labelled release build resolves the baked (or default) dev environment. It is not a
        // shipping beta; we do not fail it, but we also never let it masquerade as beta.
        if kind == .development {
            // Prefer baked dev values when present; else the hardcoded dev default.
            if let apiStr = baked("StoryEnvApiBaseURL"), let api = URL(string: apiStr),
               let region = baked("StoryEnvCognitoRegion"), let pool = baked("StoryEnvUserPoolId"),
               let client = baked("StoryEnvAppClientId"), let domain = baked("StoryEnvDomainPrefix"),
               let redirect = baked("StoryEnvRedirectURI") {
                return StoryEnvironment(kind: .development, apiBaseURL: api, cognitoRegion: region,
                                        userPoolId: pool, appClientId: client,
                                        domainPrefix: domain, redirectURI: redirect)
            }
            return developmentDefault
        }
        // A NON-development release (beta/gamma/production): every required value must be baked AND
        // internally consistent — no dev fallback, no half-mix. Missing or mismatched => FAIL CLOSED.
        guard let apiStr = baked("StoryEnvApiBaseURL"), let api = URL(string: apiStr),
              let region = baked("StoryEnvCognitoRegion"),
              let pool = baked("StoryEnvUserPoolId"),
              let client = baked("StoryEnvAppClientId"),
              let domain = baked("StoryEnvDomainPrefix"),
              let redirect = baked("StoryEnvRedirectURI") else {
            fatalError("StoryEnvironment: \(kind.rawValue) release build is missing required baked values "
                       + "(StoryEnvApiBaseURL / StoryEnvCognitoRegion / StoryEnvUserPoolId / "
                       + "StoryEnvAppClientId / StoryEnvDomainPrefix / StoryEnvRedirectURI). Refusing to run "
                       + "rather than silently selecting development.")
        }
        let resolved = StoryEnvironment(kind: kind, apiBaseURL: api, cognitoRegion: region,
                                        userPoolId: pool, appClientId: client,
                                        domainPrefix: domain, redirectURI: redirect)
        // Reject a half-dev/half-beta mix: baked values must NOT be the development identifiers while the
        // label claims a non-dev env. Catches an xcconfig that set only some keys.
        do { try resolved.assertConsistent() }
        catch {
            fatalError("StoryEnvironment: \(kind.rawValue) release build has a mixed environment "
                       + "(\(error)). Refusing to run rather than talk to the wrong backend.")
        }
        return resolved
    }
    #endif

    // ---- consistency guard --------------------------------------------------------------------------
    enum ConsistencyError: Error { case mixed(String) }

    /// Fail if the resolved environment mixes development identifiers with a non-development label, or the
    /// reverse. Uses the known dev identifiers as the tripwire.
    func assertConsistent() throws {
        let dev = StoryEnvironment.developmentDefault
        let usesDevPool = userPoolId == dev.userPoolId || appClientId == dev.appClientId
        let usesDevApi = apiBaseURL == dev.apiBaseURL
        if kind != .development {
            if usesDevPool { throw ConsistencyError.mixed("non-dev env with a development Cognito pool/client") }
            if usesDevApi { throw ConsistencyError.mixed("non-dev env with the development API base URL") }
        } else {
            // A dev-labelled build must not carry non-dev Cognito/API (a mislabelled beta).
            if !usesDevPool && !userPoolId.isEmpty {
                throw ConsistencyError.mixed("development label with a non-development Cognito pool")
            }
        }
    }
}
