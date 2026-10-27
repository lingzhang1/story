import Foundation
import CryptoKit
import SwiftData

// MyMusicCloudBackup — P1-E (pre-beta): durable, account-owned cloud backup + restore for USER-IMPORTED
// My Music audio, so an imported track survives app uninstall/reinstall.
//
// It introduces NO new infrastructure: it reuses the SAME account-owned R4 upload / R6 verified-download
// pipeline that Moment originals, generated MP4s, and AI artifacts already ride (the AIArtifactStore pattern),
// with media_kind="music". Account-scoped (owner-derived server-side), content-addressed by uuid5(owner+sha),
// full-file SHA256 verified, reference-safe retention.
//
// Owner-approved policy (P1-E):
//   • ONLY user-imported files are uploaded. Provider/catalog favorites are NEVER uploaded (licensing) — they
//     carry a providerTrackId and this engine skips them.
//   • Size cap MAX_UPLOAD_BYTES; audio content only (the file was already AV-validated at import).
//   • Idempotent: a re-backup of the same bytes maps to the same cloud_media_id (no dup, no extra egress).
//   • Honest state: cloudBackupState tracks local_only -> backing_up -> cloud_verified; a restore that only
//     has metadata is restore_pending (NOT "backed up"); bytes that cannot be fetched are unavailable.
//   • Deletion: removing an imported track deletes the local bytes + row; the cloud record is retention-safe
//     (the media store never deletes — reference-safe), matching existing R7 semantics. (Explicit cloud
//     deletion is a separate increment; a removed local row simply stops being restored into the library.)
enum MyMusicCloudBackup {
    /// 30 MB cap for a single imported track (owner policy). Audio well under video; bounded egress/cost.
    static let maxUploadBytes = 30 * 1024 * 1024

    enum BackupError: Error, LocalizedError {
        case notImported          // a provider favorite — never uploaded (licensing)
        case tooLarge(Int)
        case missingBytes
        case uploadFailed(String)
        var errorDescription: String? {
            switch self {
            case .notImported: return "Saved catalog tracks aren't uploaded (they stay with the music provider)."
            case .tooLarge(let n): return "That track is too large to back up (\(n / (1024*1024)) MB; limit 30 MB)."
            case .missingBytes: return "That track's local file is missing, so it can't be backed up."
            case .uploadFailed(let m): return "Couldn't back up that track (\(m))."
            }
        }
    }

    // MARK: - Backup (upload imported bytes to the user's account)

    /// Back up ONE imported asset's bytes to the account-owned store. No-op (idempotent) if already verified.
    /// Marks the row backing_up -> cloud_verified; a provider favorite is refused. Requires an authenticated
    /// token for `owner`.
    @MainActor
    static func backUp(_ asset: MyMusicAssetModel, owner: String, accessToken: String,
                       uploader: MediaUploading = MediaUploadService()) async throws {
        guard !asset.isProviderFavorite else { throw BackupError.notImported }
        if asset.isCloudBacked { return }   // already verified — idempotent

        let url = MyMusicStore.shared.absoluteURL(for: asset.relativePath)
        guard MyMusicStore.shared.exists(asset) else { throw BackupError.missingBytes }
        guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw BackupError.missingBytes }
        guard bytes.count <= maxUploadBytes else { throw BackupError.tooLarge(bytes.count) }

        // content hash for imported rows IS the sha256 of the bytes; the server content-addresses by it.
        let sha = asset.contentHash.count == 64 ? asset.contentHash
            : SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let contentType = Self.audioContentType(forExtension: url.pathExtension)

        asset.ownerAccountId = owner
        asset.cloudBackupState = .backingUp
        // (save is the caller's responsibility via its context; state is observed live)

        do {
            // device_asset_id carries the My Music row id so a restore relinks bytes to THIS library row.
            let init0 = try await uploader.initiate(
                accessToken: accessToken, sha256: sha, size: bytes.count,
                deviceAssetId: asset.id.uuidString, sourceMomentId: "",
                mediaKind: CloudMediaKind.music, sourceOutputId: "", contentType: contentType)
            try await uploader.putToS3(uploadURL: init0.uploadURL, fileURL: url, sha256Hex: sha, contentType: contentType)
            try await uploader.complete(accessToken: accessToken, cloudMediaId: init0.cloudMediaId)
            asset.cloudMediaId = init0.cloudMediaId
            asset.cloudBackupState = .cloudVerified
        } catch {
            asset.cloudBackupState = .localOnly   // recoverable: a later backup retries; bytes are still local
            throw BackupError.uploadFailed("\(error)")
        }
    }

    // MARK: - Restore (after reinstall / on a new device)

    /// Restore account-owned imported tracks the signed-in account owns. For each `media_kind="music"` verified
    /// cloud record NOT present locally (by device_asset_id), insert a restore_pending row, then download +
    /// verify the bytes into managed storage and flip it to cloud_verified. A record whose bytes cannot be
    /// fetched is left `unavailable` (honest UI), never fabricated, never deleted. Empty remote is a NO-OP
    /// (never clears the local library). Returns (metadataRestored, bytesRestored).
    @MainActor
    @discardableResult
    static func restore(context: ModelContext, owner: String, accessToken: String,
                        uploader: MediaUploading = MediaUploadService(),
                        downloader: MediaDownloading = MediaDownloadService()) async -> (Int, Int) {
        let records: [CloudMediaRecord]
        do { records = try await downloader.listMedia(accessToken: accessToken) }
        catch { return (0, 0) }
        let musicRecords = records.filter { $0.mediaKind == CloudMediaKind.music && $0.isVerified && !$0.deviceAssetId.isEmpty }
        // Empty remote => nothing to restore; NEVER interpret as "clear the local library".
        guard !musicRecords.isEmpty else { return (0, 0) }

        MyMusicStore.shared.ensureDir()
        var metaRestored = 0, bytesRestored = 0

        for rec in musicRecords {
            guard let assetId = UUID(uuidString: rec.deviceAssetId) else { continue }
            let existing = (try? context.fetch(FetchDescriptor<MyMusicAssetModel>(
                predicate: #Predicate { $0.id == assetId })))?.first

            // Already have a verified local copy -> skip (dedup; no duplicate row, no re-download).
            if let e = existing, e.isCloudBacked, MyMusicStore.shared.exists(e) { continue }

            // Metadata row: reuse an existing row (keep its identity/history) or insert a restore_pending shell.
            let asset: MyMusicAssetModel
            if let e = existing { asset = e }
            else {
                asset = MyMusicAssetModel(
                    id: assetId, displayName: "Imported track", relativePath: "",
                    originalFilename: "", durationSeconds: 0, contentHash: "",
                    ownerAccountId: owner,
                    cloudBackupStateRaw: MyMusicAssetModel.CloudBackupState.restorePending.rawValue)
                context.insert(asset)
                metaRestored += 1
            }
            asset.ownerAccountId = owner
            asset.cloudMediaId = rec.cloudMediaId
            if asset.cloudBackupState != .cloudVerified { asset.cloudBackupState = .restorePending }
            try? context.save()

            // Download + verify the bytes into managed storage.
            let rel = "mymusic/\(assetId.uuidString).m4a"
            let dest = MyMusicStore.shared.absoluteURL(for: rel)
            do {
                let target = try await downloader.presignDownload(accessToken: accessToken, cloudMediaId: rec.cloudMediaId)
                try await downloader.download(target: target, to: dest, progress: nil)
                asset.relativePath = rel
                if asset.contentHash.isEmpty { asset.contentHash = target.expectedSha256Hex }
                asset.cloudBackupState = .cloudVerified
                bytesRestored += 1
                try? context.save()
            } catch {
                asset.cloudBackupState = .unavailable   // owned remotely but bytes unfetchable right now (honest)
                try? context.save()
            }
        }
        return (metaRestored, bytesRestored)
    }

    static func audioContentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        default: return "audio/mp4"
        }
    }
}
