import Foundation
import SwiftData

// R4-A.1 — account-scoped Auto Backup preference access + the auto-enroll decision. Pure persistence helpers
// over AutoBackupSettingModel (one row per canonical story_user_id). Default OFF: a missing row reads disabled.
@MainActor
struct AutoBackupStore {
    let context: ModelContext

    /// The preference row for an account, or nil if never set (= disabled, Wi-Fi-only, no existing-choice yet).
    func setting(for accountId: String) -> AutoBackupSettingModel? {
        let want: String? = accountId
        return (try? context.fetch(FetchDescriptor<AutoBackupSettingModel>(
            predicate: #Predicate { $0.accountId == want })))?.first
    }

    func isEnabled(for accountId: String) -> Bool { setting(for: accountId)?.enabled ?? false }
    func allowCellular(for accountId: String) -> Bool { setting(for: accountId)?.allowCellular ?? false }

    /// Upsert the enabled flag (one-time opt-in path sets enabled=true). Returns the row.
    @discardableResult
    func setEnabled(_ enabled: Bool, for accountId: String) -> AutoBackupSettingModel {
        let row = setting(for: accountId) ?? {
            let r = AutoBackupSettingModel(accountId: accountId); context.insert(r); return r
        }()
        row.enabled = enabled; row.updatedAt = .now
        try? context.save()
        return row
    }

    @discardableResult
    func setAllowCellular(_ allow: Bool, for accountId: String) -> AutoBackupSettingModel {
        let row = setting(for: accountId) ?? {
            let r = AutoBackupSettingModel(accountId: accountId); context.insert(r); return r
        }()
        row.allowCellular = allow; row.updatedAt = .now
        try? context.save()
        return row
    }

    func markExistingChoiceMade(for accountId: String) {
        let row = setting(for: accountId) ?? {
            let r = AutoBackupSettingModel(accountId: accountId); context.insert(r); return r
        }()
        row.existingChoiceMade = true; row.updatedAt = .now
        try? context.save()
    }
}
