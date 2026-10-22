import Foundation

/// Durable launch configuration for backend/auth selection (P0 Beta Security Phase 4 follow-up).
///
/// THE PROBLEM this solves: `ProcessInfo.processInfo.environment` only carries an Xcode SCHEME's environment
/// variables when the app is launched ATTACHED to the debugger. A home-screen tap, a TestFlight run, or a
/// "run after build then detach" launch gets an EMPTY environment — so `StoryAuthConfig`/`StoryBackend` fell
/// back to their DEV defaults (dev Cognito pool + dev App Runner) and the app silently talked to the dev
/// ("personal") account even though the scheme pointed at beta. This is the same trap already fixed once for
/// `STORY_MULTIMODAL_PLANNING` (a scheme env var is injected ONLY for an attached launch).
///
/// THE FIX: resolve each config key as  env var  →  persisted UserDefaults  →  nil (caller's default).
/// On EVERY launch, any key that IS present in the environment is PERSISTED to UserDefaults. So:
///   • launch ATTACHED once with the beta scheme  → the beta values are captured and become sticky;
///   • every later DETACHED / home-screen / TestFlight launch reads them back from UserDefaults → stays beta;
///   • an env override ALWAYS wins when present (so switching schemes re-points immediately).
/// These are NON-SECRET identifiers (pool id, public client id, hosted domain, API URL) — never credentials.
enum StoryLaunchConfig {
    /// The config keys that select which backend/account the app talks to. Capturing exactly these (not the
    /// whole environment) keeps the persisted set intentional and auditable.
    static let keys = [
        "STORY_API_BASE_URL",
        "STORY_COGNITO_REGION",
        "STORY_COGNITO_USER_POOL_ID",
        "STORY_COGNITO_APP_CLIENT_ID",
        "STORY_COGNITO_DOMAIN_PREFIX",
        "STORY_COGNITO_REDIRECT_URI",
    ]

    private static let storePrefix = "StoryLaunchConfig."

    /// Call ONCE at the very start of app launch, BEFORE any backend/auth config is read. Persists any
    /// config key present in the current launch environment so a later detached launch resolves the same
    /// backend. A key ABSENT from this launch's environment is left as previously persisted (a detached
    /// launch therefore does not wipe the sticky value).
    static func captureLaunchOverrides(_ defaults: UserDefaults = .standard) {
        let envv = ProcessInfo.processInfo.environment
        for k in keys {
            if let v = envv[k], !v.isEmpty {
                defaults.set(v, forKey: storePrefix + k)
            }
        }
        logResolved(defaults)
    }

    /// DIAGNOSTIC: print, per key, the env value, the persisted value, and which SOURCE won
    /// (env / persisted / default). This is the fast way to tell apart "the scheme env vars never reached
    /// the app" (all keys show env=nil → the Run was not actually injecting them) from "they reached it and
    /// were persisted" (env=<beta> → source=env). Printed once at launch; grep the Xcode console for
    /// `STORY_LAUNCH_CONFIG`.
    static func logResolved(_ defaults: UserDefaults = .standard) {
        let envv = ProcessInfo.processInfo.environment
        for k in keys {
            let e = envv[k].map { $0.isEmpty ? "<empty>" : $0 } ?? "nil"
            let p = defaults.string(forKey: storePrefix + k) ?? "nil"
            let source = (envv[k]?.isEmpty == false) ? "env"
                : (defaults.string(forKey: storePrefix + k)?.isEmpty == false) ? "persisted"
                : "default"
            print("STORY_LAUNCH_CONFIG \(k) source=\(source) env=\(e) persisted=\(p)")
        }
    }

    /// Resolve a config value: env var (attached launch / explicit override) → persisted value → nil.
    /// Returns nil when neither is set, so the CALLER keeps its own final default (dev) — a fresh install
    /// that has never been launched attached to a beta scheme still behaves exactly as before.
    static func value(_ key: String, _ defaults: UserDefaults = .standard) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        if let v = defaults.string(forKey: storePrefix + key), !v.isEmpty { return v }
        return nil
    }
}
