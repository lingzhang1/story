import Foundation
import SwiftData

// R6 — MediaResolver: the single ASYNC gate that guarantees a Moment's ORIGINAL bytes are present+verified on
// disk before playback / editing / rendering read them (req #8). It sits in front of the existing synchronous
// MediaStore seam: callers `await ensureLocal(...)` first, then the unchanged sync path (MomentResolver.resolve
// / MediaStore.absoluteURL) resolves a file that is now guaranteed local.
//
// It never changes the frozen editing contract: it only fills bytes back into the SAME asset.relativePath,
// touching no source ranges / speed / native-audio / version lineage (req #9/#11). Originals are NEVER deleted
// here (eviction is R5 — req #12).
//
// DE-DUPE (req #3): concurrent callers for the same (owner, cloudMediaId) are coalesced onto ONE in-flight
// Task by this actor, and the persistent MediaDownloadJobModel row (unique composite key) is the durable
// de-dupe identity across relaunch.
//
// OWNERSHIP (req #6 / safeguard #6): a download is attempted ONLY when the Moment's immutable ownerAccountId
// == the active account, and the presign call carries that account's token. A Moment owned by another account
// is `.unavailable` — never fetched under the wrong token.

enum MediaResolveError: Error, LocalizedError {
    case signedOut
    case notOwnedByActiveAccount     // Moment belongs to a different account — no cross-account restore
    case noCloudCopy                 // local file missing AND no cloudMediaId — truly unavailable
    case download(MediaDownloadError)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to restore this video from your account."
        case .notOwnedByActiveAccount: return "This video belongs to a different account."
        case .noCloudCopy: return "This video isn't backed up and isn't on this device."
        case .download(let e): return e.errorDescription
        }
    }
}

@MainActor
final class MediaResolver {
    static let shared = MediaResolver()

    private let service: MediaDownloading
    private let store = MediaStore.shared
    /// In-flight coalescing: one Task per (owner#cloudMediaId). A second caller awaits the same Task.
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(service: MediaDownloading = MediaDownloadService()) { self.service = service }

    /// Ensure `moment`'s original is on disk and return its local URL, downloading+verifying+installing from
    /// the cloud if it is cloud-only. Fast path (already local) does NO network. Throws MediaResolveError.
    ///
    /// `context` is the SwiftData context (for the persistent download-job row). `activeOwner` is the active
    /// canonical story_user_id; `token` yields a fresh access token for that owner.
    func ensureLocal(moment: MomentModel,
                     context: ModelContext,
                     activeOwner: String?,
                     token: @escaping () async -> String?) async throws -> URL {
        guard let asset = moment.asset else { throw MediaResolveError.noCloudCopy }
        let rel = asset.relativePath

        // Fast path: already on disk. No network, no job row.
        if store.fileExists(relativePath: rel) {
            return store.absoluteURL(for: rel)
        }
        // Cloud-only. Must have a cloud copy AND be the active account's (immutable owner binding).
        guard let owner = activeOwner else { throw MediaResolveError.signedOut }
        guard let cmid = moment.cloudMediaId else { throw MediaResolveError.noCloudCopy }
        if let momentOwner = moment.ownerAccountId, momentOwner != owner {
            throw MediaResolveError.notOwnedByActiveAccount
        }

        let key = MediaDownloadJobModel.makeKey(ownerAccountId: owner, cloudMediaId: cmid)
        if let running = inFlight[key] {
            return try await running.value          // coalesce concurrent callers (req #3)
        }

        let momentId = moment.id
        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw MediaResolveError.noCloudCopy }
            defer { self.inFlight[key] = nil }
            return try await self.performDownload(owner: owner, cloudMediaId: cmid, momentId: momentId,
                                                  targetRelativePath: rel, context: context, token: token)
        }
        inFlight[key] = task
        return try await task.value
    }

    // MARK: - download + verify + atomic install

    private func performDownload(owner: String, cloudMediaId: String, momentId: UUID,
                                 targetRelativePath rel: String,
                                 context: ModelContext,
                                 token: @escaping () async -> String?) async throws -> URL {
        let job = upsertJob(owner: owner, cloudMediaId: cloudMediaId, momentId: momentId,
                            targetRelativePath: rel, context: context)
        job.state = .running; job.attempts += 1; job.lastError = nil; job.updatedAt = .now
        // R5: mark the asset `restoring` so a crash mid-download is recoverable (not stuck as `evicted` with a
        // live job). Returns to `available` on verified install, or back to `evicted` on failure.
        if let m = fetchMoment(momentId, context: context), m.asset?.localAvailability == .evicted {
            m.asset?.localAvailability = .restoring
        }
        try? context.save()

        guard let accessToken = await token() else {
            fail(job, "signed out", context); throw MediaResolveError.signedOut
        }

        let tempURL = store.newDownloadTempURL()
        do {
            // Presign (server-authoritative size+sha — safeguard #7). Refresh once on an expired URL (req #4).
            var target = try await service.presignDownload(accessToken: accessToken, cloudMediaId: cloudMediaId)
            job.expectedSize = target.expectedSize; job.expectedSha256 = target.expectedSha256Hex
            try? context.save()
            do {
                try await service.download(target: target, to: tempURL, progress: { [weak job] p in
                    job?.progress = p
                })
            } catch MediaDownloadError.s3GetFailed(let code) where code == 403 {
                // Presigned GET expired/denied → refresh the URL once and retry the body (req #4).
                target = try await service.presignDownload(accessToken: accessToken, cloudMediaId: cloudMediaId)
                try await service.download(target: target, to: tempURL, progress: { [weak job] p in
                    job?.progress = p
                })
            }
        } catch let e as MediaDownloadError {
            try? FileManager.default.removeItem(at: tempURL)
            fail(job, e.errorDescription ?? "download failed", context)
            throw MediaResolveError.download(e)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            fail(job, error.localizedDescription, context)
            throw MediaResolveError.download(.transport(error))
        }

        // The downloaded temp is already size+sha verified by the service. Install atomically (req #4).
        do {
            _ = try store.installDownloadedOriginal(from: tempURL, to: rel)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            fail(job, "install failed: \(error.localizedDescription)", context)
            throw MediaResolveError.download(.transport(error))
        }

        // Re-stamp the Moment's cloud fields (bytes-only restore; lineage/ranges untouched — req #11).
        if let m = fetchMoment(momentId, context: context) {
            m.cloudMediaId = cloudMediaId          // keep the cloud reference
            m.ownerAccountId = owner
            // R5/R6: the original bytes are back — local availability returns to `available`. Cloud state is an
            // INDEPENDENT dimension and stays cloud_verified (a restored original is still verified + owned).
            m.asset?.localAvailability = .available
        }
        job.state = .verified; job.progress = 1; job.updatedAt = .now
        try? context.save()
        return store.absoluteURL(for: rel)
    }

    // MARK: - crash recovery (R5)

    /// At launch, reset any asset stuck in `restoring` (the app died mid-download) back to `evicted` so it is
    /// cleanly restorable again — never stuck. Whole-file retry means the discarded partial (purged separately)
    /// is simply re-downloaded on next access. Idempotent.
    func recoverInterruptedRestores(context: ModelContext) {
        let stuck = (try? context.fetch(FetchDescriptor<AssetModel>(
            predicate: #Predicate { $0.localAvailabilityRaw == "restoring" }))) ?? []
        guard !stuck.isEmpty else { return }
        for a in stuck { a.localAvailability = .evicted }
        try? context.save()
    }

    // MARK: - reconcile local cloud-state from the server (R6 self-heal)
    /// Re-stamp local Moments' cloud-state from the SERVER-AUTHORITATIVE /v1/media list. The server knows what
    /// is backed up; a local SwiftData store can lose that knowledge (a schema migration that reset defaults, a
    /// reinstall, or a brand-new device in R7). For each VERIFIED server record whose `source_moment_id` matches
    /// a local Moment owned by (or local-only and claimable by) the active account, set cloudMediaId +
    /// cloudStateRaw="cloud_verified" + ownerAccountId. It NEVER clears a stamp and never downloads bytes (that
    /// stays on-demand via ensureLocal) — it only restores the "is this backed up?" truth. Returns how many
    /// Moments it (re)stamped. Safe to call on every sign-in; idempotent.
    @discardableResult
    func reconcileCloudState(context: ModelContext, activeOwner: String?,
                             token: @escaping () async -> String?) async -> Int {
        guard let owner = activeOwner, let accessToken = await token() else { return 0 }
        let records: [CloudMediaRecord]
        do { records = try await service.listMedia(accessToken: accessToken) }
        catch { return 0 }   // best-effort; a failed reconcile never blocks the UI

        var stamped = 0
        for rec in records where rec.isVerified && !rec.sourceMomentId.isEmpty {
            guard let mid = UUID(uuidString: rec.sourceMomentId),
                  let m = fetchMoment(mid, context: context) else { continue }
            // Only claim a Moment that is this account's OR still shared local-only (never re-key another
            // account's Moment — immutable-owner rule).
            if let existingOwner = m.ownerAccountId, existingOwner != owner { continue }
            let needs = (m.cloudMediaId != rec.cloudMediaId) || (m.cloudStateRaw != "cloud_verified")
                || (m.ownerAccountId != owner)
            if needs {
                m.cloudMediaId = rec.cloudMediaId
                m.cloudStateRaw = "cloud_verified"
                m.ownerAccountId = owner
                m.asset?.ownerAccountId = owner
                stamped += 1
            }
        }
        if stamped > 0 { try? context.save() }
        return stamped
    }

    // MARK: - persistence helpers

    private func upsertJob(owner: String, cloudMediaId: String, momentId: UUID,
                           targetRelativePath: String, context: ModelContext) -> MediaDownloadJobModel {
        let key = MediaDownloadJobModel.makeKey(ownerAccountId: owner, cloudMediaId: cloudMediaId)
        if let existing = (try? context.fetch(FetchDescriptor<MediaDownloadJobModel>(
            predicate: #Predicate { $0.key == key })))?.first {
            return existing
        }
        let job = MediaDownloadJobModel(ownerAccountId: owner, cloudMediaId: cloudMediaId,
                                        momentId: momentId, targetRelativePath: targetRelativePath)
        context.insert(job)
        return job
    }

    private func fetchMoment(_ id: UUID, context: ModelContext) -> MomentModel? {
        (try? context.fetch(FetchDescriptor<MomentModel>(predicate: #Predicate { $0.id == id })))?.first
    }

    private func fail(_ job: MediaDownloadJobModel, _ message: String, _ context: ModelContext) {
        job.state = .failed; job.lastError = message; job.updatedAt = .now
        // R5: a failed restore returns the asset to `evicted` (cloud-only), never stuck in `restoring`.
        if let m = fetchMoment(job.momentId, context: context), m.asset?.localAvailability == .restoring {
            m.asset?.localAvailability = .evicted
        }
        try? context.save()
    }
}
