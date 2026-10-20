import Foundation
import SwiftData

// R5 — account-scoped read/upsert of the Optimize-iPhone-Storage preference. Mirrors AutoBackupStore. Default
// OFF (a missing row = disabled). DISTINCT from Auto Backup (owner: never conflate upload with eviction).
@MainActor
struct OptimizationStore {
    let context: ModelContext

    func autoOptimizeEnabled(for owner: String) -> Bool {
        row(for: owner)?.autoOptimizeEnabled ?? false
    }

    func setAutoOptimize(_ on: Bool, for owner: String) {
        if let r = row(for: owner) {
            r.autoOptimizeEnabled = on; r.updatedAt = .now
        } else {
            context.insert(OptimizationSettingModel(accountId: owner, autoOptimizeEnabled: on))
        }
        try? context.save()
    }

    private func row(for owner: String) -> OptimizationSettingModel? {
        (try? context.fetch(FetchDescriptor<OptimizationSettingModel>(
            predicate: #Predicate { $0.accountId == owner })))?.first
    }
}
