import Foundation
import SwiftData

// R7-D — GeneratedOutputResolver: the single ASYNC gate that guarantees a GeneratedOutput's exact rendered
// MP4 is present on disk before playback / Save / Share read it. The sibling of MediaResolver (which restores
// a Moment's ORIGINAL), but it operates on a GeneratedOutput and installs into RenderOutputStore instead of
// MediaStore. It REUSES the exact R6 download service (MediaDownloading) — which already presigns, streams,
// and VERIFIES size + full-file sha256 before the file is installed — so the restored MP4 is byte-identical
// to what was rendered. It NEVER re-plans or re-renders (safeguard: restore only; no editing contract touched).
//
// Fast path (file already local) does NO network. Cloud-only requires a verified cloudMediaId AND that the
// output's owner == the active account (immutable-owner binding; no cross-account restore). The resolver
// stamps the restored file's relativeFilePath onto the output so subsequent reads hit the fast path.
//
// DE-DUPE: concurrent callers for the same (owner, cloudMediaId) are coalesced onto ONE in-flight Task; the
// persistent MediaDownloadJobModel row (R6) is the durable de-dupe identity across relaunch.

enum GeneratedOutputResolveError: Error, LocalizedError {
    case signedOut
    case notOwnedByActiveAccount
    case noCloudCopy                 // local file missing AND no verified cloudMediaId — truly unavailable
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
final class GeneratedOutputResolver {
    static let shared = GeneratedOutputResolver()

    private let service: MediaDownloading
    private let store = RenderOutputStore.shared
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(service: MediaDownloading = MediaDownloadService()) { self.service = service }

    /// Ensure `output`'s rendered MP4 is on disk and return its local URL, downloading+verifying+installing
    /// from the cloud when it is cloud-only. Throws GeneratedOutputResolveError. `context` persists the
    /// download-job row + the restored relativeFilePath. `activeOwner`/`token` scope auth to the owner.
    func ensureLocal(output: GeneratedOutputModel,
                     context: ModelContext,
                     activeOwner: String?,
                     token: @escaping () async -> String?) async throws -> URL {
        // Fast path: a rendered file already exists locally. No network, no job row.
        if let rel = output.relativeFilePath, !rel.isEmpty, store.exists(relative: rel) {
            return store.absoluteURL(for: rel)
        }
        // Cloud-only. Must have a verified cloud copy AND be the active account's (immutable owner binding).
        guard let owner = activeOwner else { throw GeneratedOutputResolveError.signedOut }
        guard let cmid = output.cloudMediaId, output.cloudVerifiedAt != nil else {
            throw GeneratedOutputResolveError.noCloudCopy
        }
        let outputOwner = output.ownerAccountId ?? output.story?.ownerAccountId
        if let o = outputOwner, o != owner { throw GeneratedOutputResolveError.notOwnedByActiveAccount }

        let key = MediaDownloadJobModel.makeKey(ownerAccountId: owner, cloudMediaId: cmid)
        if let running = inFlight[key] { return try await running.value }   // coalesce concurrent callers

        // Target relative path: reuse the output's existing one (Device A, file evicted) or mint a fresh one
        // (Device B, never had a local render). Persisted onto the output after a verified install.
        let targetRel = (output.relativeFilePath?.isEmpty == false)
            ? output.relativeFilePath!
            : store.newRelativePath()
        let outputId = output.id
        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw GeneratedOutputResolveError.noCloudCopy }
            defer { self.inFlight[key] = nil }
            return try await self.performDownload(owner: owner, cloudMediaId: cmid, outputId: outputId,
                                                  targetRelativePath: targetRel, context: context, token: token)
        }
        inFlight[key] = task
        return try await task.value
    }

    private func performDownload(owner: String, cloudMediaId: String, outputId: UUID,
                                 targetRelativePath rel: String,
                                 context: ModelContext,
                                 token: @escaping () async -> String?) async throws -> URL {
        // Reuse the R6 persistent download-job row (keyed by owner#cloudMediaId). momentId is unused for a
        // generated restore; we store the OUTPUT id there for traceability (the row is keyed by cloudMediaId).
        let job = upsertJob(owner: owner, cloudMediaId: cloudMediaId, outputId: outputId,
                            targetRelativePath: rel, context: context)
        job.state = .running; job.attempts += 1; job.lastError = nil; job.updatedAt = .now
        try? context.save()

        guard let accessToken = await token() else {
            fail(job, "signed out", context); throw GeneratedOutputResolveError.signedOut
        }

        let tempURL = store.newDownloadTempURL()
        do {
            var target = try await service.presignDownload(accessToken: accessToken, cloudMediaId: cloudMediaId)
            job.expectedSize = target.expectedSize; job.expectedSha256 = target.expectedSha256Hex
            try? context.save()
            do {
                try await service.download(target: target, to: tempURL, progress: { [weak job] p in
                    job?.progress = p
                })
            } catch MediaDownloadError.s3GetFailed(let code) where code == 403 {
                // Presigned GET expired/denied -> refresh once and retry the body.
                target = try await service.presignDownload(accessToken: accessToken, cloudMediaId: cloudMediaId)
                try await service.download(target: target, to: tempURL, progress: { [weak job] p in
                    job?.progress = p
                })
            }
        } catch let e as MediaDownloadError {
            try? FileManager.default.removeItem(at: tempURL)
            fail(job, e.errorDescription ?? "download failed", context)
            throw GeneratedOutputResolveError.download(e)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            fail(job, error.localizedDescription, context)
            throw GeneratedOutputResolveError.download(.transport(error))
        }

        // The temp is already size + full-file sha256 verified by the service. Install atomically.
        do {
            _ = try store.installDownloadedOutput(from: tempURL, to: rel)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            fail(job, "install failed: \(error.localizedDescription)", context)
            throw GeneratedOutputResolveError.download(.transport(error))
        }

        // Stamp the restored path + cloud ref onto the output (bytes-only restore; identity/lineage/plan
        // untouched). Guarded by owner-match so we never mutate another account's output.
        if let o = fetchOutput(outputId, context: context) {
            let outputOwner = o.ownerAccountId ?? o.story?.ownerAccountId
            if outputOwner == nil || outputOwner == owner {
                o.relativeFilePath = rel
                o.cloudMediaId = cloudMediaId
                if o.cloudVerifiedAt == nil { o.cloudVerifiedAt = .now }
                if o.ownerAccountId == nil { o.ownerAccountId = owner }
            }
        }
        job.state = .verified; job.progress = 1; job.updatedAt = .now
        try? context.save()
        return store.absoluteURL(for: rel)
    }

    // MARK: - persistence helpers (reuse the R6 MediaDownloadJobModel)

    private func upsertJob(owner: String, cloudMediaId: String, outputId: UUID,
                           targetRelativePath: String, context: ModelContext) -> MediaDownloadJobModel {
        let key = MediaDownloadJobModel.makeKey(ownerAccountId: owner, cloudMediaId: cloudMediaId)
        if let existing = (try? context.fetch(FetchDescriptor<MediaDownloadJobModel>(
            predicate: #Predicate { $0.key == key })))?.first {
            return existing
        }
        // momentId carries the output id for a generated restore (the row's identity is owner#cloudMediaId).
        let job = MediaDownloadJobModel(ownerAccountId: owner, cloudMediaId: cloudMediaId,
                                        momentId: outputId, targetRelativePath: targetRelativePath)
        context.insert(job)
        return job
    }

    private func fetchOutput(_ id: UUID, context: ModelContext) -> GeneratedOutputModel? {
        (try? context.fetch(FetchDescriptor<GeneratedOutputModel>(predicate: #Predicate { $0.id == id })))?.first
    }

    private func fail(_ job: MediaDownloadJobModel, _ message: String, _ context: ModelContext) {
        job.state = .failed; job.lastError = message; job.updatedAt = .now
        try? context.save()
    }
}
