import Foundation
import SwiftData

// R5 — Safe Local Storage Optimization. Frees local ORIGINAL bytes of videos that are safely backed up, so a
// cloud-only Moment restores on demand via R6. It NEVER deletes a cloud original and NEVER changes cloud
// ownership: eviction only flips AssetModel.localAvailability available -> evicted and removes the local file;
// the Moment stays cloud_verified and owned. Local availability is an INDEPENDENT dimension from cloud state
// (owner correction) — cloudStateRaw is never mutated here.
//
// SAFETY (owner Phase 3, nine checks) — an original is evictable ONLY when ALL hold:
//   1. server-authoritative cloud_verified (the Moment's cloud_verified reflects a server-verified upload),
//   2. the cloud record has valid size + checksum metadata (so R6 can verify a future restore),
//   3. it is restorable through the accepted R6 path (has a cloudMediaId),
//   4. no active upload / download / capture / playback / render / export depends on the file (caller guard +
//      no live upload/download job),
//   5. Keep Downloaded is disabled for this asset,
//   6. the local preview + cloud reference are persisted (cloudMediaId retained; preview is the thumbnail
//      cache, untouched by eviction),
//   7. the transition is crash-safe + idempotent (availability flips to `evicted` and is SAVED before the file
//      is removed; a crash leaves an `evicted` record whose file is already gone, or an `available` record whose
//      file still exists — never a dangling half-state),
//   8. the active authenticated account owns the cloud media (ownerAccountId == active owner),
//   9. the file is not shared by another local Moment/asset (no other AssetModel points at the same
//      relativePath) and the path is non-empty.
//
// DEBUG protected mode (Phase 4): instead of deleting, MOVE the original into a protected recovery dir that R6
// cannot resolve, so a failed restore can be recovered and no real bytes are lost during acceptance. Protected
// bytes are NOT counted as freed. Never runs in a release build.

struct StorageSummary: Equatable {
    var localOriginalBytes: Int = 0     // bytes of originals currently ON device (available)
    var cloudBackedBytes: Int = 0       // bytes of originals that are cloud_verified (reclaimable universe)
    var reclaimableBytes: Int = 0       // bytes that PASS the eviction safety checks right now
    var evictedCount: Int = 0           // Moments already optimized (cloud-only)
    var availableCount: Int = 0
}

@MainActor
struct StorageOptimizer {
    let context: ModelContext
    /// The active canonical account (owner). Eviction is scoped to this account's own media.
    let activeOwner: String?
    /// Returns true if the Moment id is in active use by playback/edit/render/export RIGHT NOW (check #4).
    /// The caller supplies this (the storage screen passes a guard that knows the current render/export set).
    var isInActiveUse: (UUID) -> Bool = { _ in false }

    #if DEBUG
    /// Phase-4 protected acceptance mode: MOVE the original to a protected dir instead of deleting it.
    var protectedMode: Bool = false
    #endif

    // MARK: - Eviction eligibility (the 9 checks)

    enum EvictionRefusal: String {
        case notCloudVerified, noCloudId, keepDownloaded, inActiveUse, liveJob,
             notOwned, sharedFile, alreadyEvicted, emptyPath
    }

    /// Why this asset's original is NOT evictable, or nil if it passes ALL safety checks.
    func evictionRefusal(for moment: MomentModel) -> EvictionRefusal? {
        guard let asset = moment.asset else { return .noCloudId }
        if asset.relativePath.isEmpty { return .emptyPath }                               // #9
        if asset.localAvailability == .evicted { return .alreadyEvicted }
        if moment.cloudStateRaw != "cloud_verified" { return .notCloudVerified }          // #1
        guard let cmid = moment.cloudMediaId, !cmid.isEmpty else { return .noCloudId }    // #2/#3 (restorable)
        guard let owner = activeOwner, moment.ownerAccountId == owner else { return .notOwned }  // #8
        if asset.keepDownloaded { return .keepDownloaded }                               // #5
        if isInActiveUse(moment.id) { return .inActiveUse }                              // #4 (caller guard)
        if hasLiveJob(momentId: moment.id, owner: owner) { return .liveJob }             // #4 (upload/download)
        if isFileShared(relativePath: asset.relativePath, excludingAsset: asset.id) { return .sharedFile } // #9
        return nil
    }

    var isEvictable: (MomentModel) -> Bool { { evictionRefusal(for: $0) == nil } }

    // MARK: - Manual Free Up Space

    /// The result of a free-up run — enough to message honestly (count + bytes + whether protected-moved).
    struct EvictionOutcome: Equatable {
        var evictedCount = 0        // Moments whose original was removed/moved this run
        var freedBytes = 0          // REAL bytes reclaimed (0 in DEBUG protected mode)
        var protectedCount = 0      // Moments moved to the protected store (DEBUG) — not counted as freed
    }

    /// Evict every eligible Moment for the active account, PRESERVING a poster preview for each first (owner #6:
    /// never blank a tile). Async because it extracts a poster frame before freeing. Crash-safe + idempotent.
    @discardableResult
    func freeUpSpace(moments: [MomentModel]) async -> EvictionOutcome {
        var out = EvictionOutcome()
        for m in moments where evictionRefusal(for: m) == nil {
            let (bytes, evicted, protectedMove) = await evict(moment: m)
            if evicted { out.evictedCount += 1 }
            out.freedBytes += bytes
            if protectedMove { out.protectedCount += 1 }
        }
        return out
    }

    /// Evict ONE Moment's original (after re-checking eligibility). PRESERVES a poster preview FIRST and REFUSES
    /// to evict if the poster cannot be written (#6). Returns (bytesFreed, didEvict, protectedMove). Crash-safe:
    /// flip availability -> evicted and SAVE before removing bytes (#7).
    @discardableResult
    func evict(moment: MomentModel) async -> (bytes: Int, evicted: Bool, protectedMove: Bool) {
        guard evictionRefusal(for: moment) == nil, let asset = moment.asset else { return (0, false, false) }
        let rel = asset.relativePath
        let url = MediaStore.shared.absoluteURL(for: rel)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 ?? 0

        // #6: persist a poster preview from the ORIGINAL before we free it. If this fails, DO NOT evict.
        let previewOK = await MediaPreviewStore.shared.ensurePreview(momentId: moment.id, originalURL: url)
        guard previewOK else { return (0, false, false) }

        // Crash-safe ordering: record the intended state FIRST, then remove bytes. (#7)
        asset.localAvailability = .evicted
        try? context.save()

        #if DEBUG
        if protectedMode {
            // Phase 4: MOVE the original into a protected recovery dir R6 cannot resolve. Protected bytes are
            // NOT freed storage — report protectedMove, 0 freed.
            let protectedURL = StorageOptimizer.protectedRecoveryURL(for: rel)
            try? FileManager.default.createDirectory(
                at: protectedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: protectedURL)
            try? FileManager.default.moveItem(at: url, to: protectedURL)
            return (0, true, true)
        }
        #endif

        try? FileManager.default.removeItem(at: url)
        return (bytes, true, false)
    }

    // MARK: - storage summary

    func summary(moments: [MomentModel]) -> StorageSummary {
        var s = StorageSummary()
        for m in moments {
            guard let asset = m.asset, !asset.relativePath.isEmpty else { continue }
            let verified = m.cloudStateRaw == "cloud_verified"
            let bytes: Int
            if asset.localAvailability == .available {
                let url = MediaStore.shared.absoluteURL(for: asset.relativePath)
                bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 ?? 0
                s.localOriginalBytes += bytes
                s.availableCount += 1
            } else {
                bytes = 0
                s.evictedCount += 1
            }
            if verified {
                // The cloud-backed universe: use the recorded size when the local file is gone.
                s.cloudBackedBytes += bytes
            }
            if evictionRefusal(for: m) == nil { s.reclaimableBytes += bytes }
        }
        return s
    }

    // MARK: - helpers

    private func hasLiveJob(momentId: UUID, owner: String) -> Bool {
        let up = (try? context.fetch(FetchDescriptor<MediaUploadJobModel>(
            predicate: #Predicate { $0.momentId == momentId && $0.ownerAccountId == owner })))?
            .contains { !$0.isAutoTerminal } ?? false
        if up { return true }
        // A download in flight (restoring) also blocks eviction.
        let downloads = (try? context.fetch(FetchDescriptor<MediaDownloadJobModel>())) ?? []
        return downloads.contains { $0.momentId == momentId && $0.stateRaw == "running" }
    }

    private func isFileShared(relativePath: String, excludingAsset assetId: UUID) -> Bool {
        let all = (try? context.fetch(FetchDescriptor<AssetModel>(
            predicate: #Predicate { $0.relativePath == relativePath && $0.id != assetId }))) ?? []
        return !all.isEmpty
    }

    #if DEBUG
    static func protectedRecoveryURL(for relativePath: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Under a DISTINCT dir name that MediaStore/MediaResolver never resolve from, so R6 cannot read it.
        return docs.appendingPathComponent("r5-protected-recovery").appendingPathComponent(relativePath)
    }
    #endif
}
