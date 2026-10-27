import Foundation

// StoryReusableEvidence — P1-F feature flag for device-side reuse of durable AU visual evidence (Option 8-i).
//
// OFF by default: until the owner's physical-device acceptance passes, Create uses the existing restore +
// MomentFrameExtractor path for every Moment (today's behavior, unchanged). When enabled, Create FIRST tries
// to satisfy each eligible Moment from the account-authorized cached AU frame package (skipping full-video
// restore + re-extraction on a valid cache hit), and falls back to restore/extract on any miss — so enabling
// it can only REMOVE duplicate work, never reduce visual coverage.
//
// Incident kill-switch parity with StoryMultimodalPlanning: env `STORY_REUSABLE_EVIDENCE=1` or UserDefaults
// bool `STORY_REUSABLE_EVIDENCE=true` turns it ON without a rebuild; absent any override it is OFF.
enum StoryReusableEvidence {
    static let flagKey = "STORY_REUSABLE_EVIDENCE"

    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["STORY_REUSABLE_EVIDENCE"] == "1" { return true }
        if UserDefaults.standard.object(forKey: flagKey) != nil {
            return UserDefaults.standard.bool(forKey: flagKey)   // explicit override (true or false) wins
        }
        return _enabledDefault
    }

    static func setPersistentOverride(_ on: Bool) { UserDefaults.standard.set(on, forKey: flagKey) }
    private static let _enabledDefault = false   // P1-F: OFF until device-accepted
}
