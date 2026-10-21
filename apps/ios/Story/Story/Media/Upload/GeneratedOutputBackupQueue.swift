import Foundation
import SwiftData

// R7-D — GeneratedOutputBackupQueue: the persistent, account-scoped driver that backs up a RENDERED
// GeneratedOutput MP4 to the account-owned cloud, so the exact video can be RESTORED on another device for
// playback/sharing (R6-style), NEVER re-planned or re-rendered.
//
// It is a deliberate sibling of MediaUploadQueue (originals), sharing its persistence/recovery/backoff
// discipline and REUSING the exact same R4 multipart upload pipeline (the MediaUploading seam) with
// media_kind="generated" + source_output_id — there is NO second uploader. The difference from the originals
// queue is semantic, not mechanical: a rendered output has no shared local-only "reservation" to arbitrate
// between two accounts (it is owned by its Story's owner from creation), so the Moment-reservation logic is
// intentionally absent here.
//
// INVARIANTS (owner):
//  - AUTH: each job carries the OUTPUT OWNER's token, obtained via tokenForOwner(owner); nil when that owner
//    is not the active account -> the job defers (rule 9: never B's token for A's job).
//  - The rendered MP4 is NEVER deleted by this queue (safeguard #8: never remove the only local copy before
//    cloud verification). On a missing file the job is simply dropped (the output is unbackable), never a retry.
//  - On server cloud_verified, stamp GeneratedOutputModel.cloudMediaId + cloudVerifiedAt, guarded by
//    owner-match + the current claimGeneration (rule 10: a stale async completion cannot overwrite newer state).
//  - Identity/version lineage/soundtrack/editPlanJSON are UNTOUCHED — backup only records a cloud reference.
@MainActor
final class GeneratedOutputBackupQueue {
    /// Set once by StoryApp to a closure bound to the live AuthStore + container context. The render-completion
    /// site (StoryCreationCoordinator) calls this fire-and-forget after persisting a new GeneratedOutput; it
    /// enrolls + drains ONLY when the active account has Auto Backup ON. Default no-op (safe before setup).
    nonisolated(unsafe) static var sharedAutoEnroll: (GeneratedOutputModel) -> Void = { _ in }

    private let context: ModelContext
    private let service: MediaUploading
    private let tokenForOwner: (String) async -> String?
    private let activeOwner: () -> String?
    private let networkAllows: (String) -> Bool

    private let baseBackoff: TimeInterval = 5
    private let maxBackoff: TimeInterval = 600
    private var draining = false

    init(context: ModelContext,
         service: MediaUploading = MediaUploadService(),
         activeOwner: @escaping () -> String?,
         tokenForOwner: @escaping (String) async -> String?,
         networkAllows: ((String) -> Bool)? = nil) {
        self.context = context
        self.service = service
        self.activeOwner = activeOwner
        self.tokenForOwner = tokenForOwner
        self.networkAllows = networkAllows ?? { owner in
            let allowCellular = AutoBackupStore(context: context).allowCellular(for: owner)
            return NetworkReachability.shared.uploadAllowed(allowCellular: allowCellular)
        }
    }

    // MARK: - Enroll

    /// Enroll a rendered GeneratedOutput for cloud backup under its Story's owner. Idempotent: a non-terminal
    /// job for this (owner, output) is reused; an already-verified output (cloudVerifiedAt set) is skipped.
    /// Refuses when signed out, when the output has no rendered file, or when the output's owner is not the
    /// active account (no cross-account backup). Returns the job, or nil.
    @discardableResult
    func enroll(output: GeneratedOutputModel) -> GeneratedOutputBackupJobModel? {
        guard let owner = activeOwner() else { return nil }
        // Owner binding: prefer the output's own owner; fall back to the Story's owner. Must match the active
        // account (never back up another account's output under this token).
        let outputOwner = output.ownerAccountId ?? output.story?.ownerAccountId
        if let o = outputOwner, o != owner { return nil }
        guard let rel = output.relativeFilePath, !rel.isEmpty,
              RenderOutputStore.shared.exists(relative: rel) else { return nil }
        // Already backed up + verified -> nothing to do.
        if output.cloudMediaId != nil && output.cloudVerifiedAt != nil { return nil }

        let oid = output.id
        if let live = (try? context.fetch(FetchDescriptor<GeneratedOutputBackupJobModel>(
            predicate: #Predicate { $0.outputId == oid && $0.ownerAccountId == owner })))?
            .first(where: { !$0.isAutoTerminal }) {
            return live
        }

        // Stamp the output's owner if still unset (inherit from the active account), never overwrite.
        if output.ownerAccountId == nil { output.ownerAccountId = owner }

        let job = GeneratedOutputBackupJobModel(
            ownerAccountId: owner, outputId: output.id,
            storyId: output.story?.id ?? output.id,
            operationId: UUID().uuidString, relativeFilePath: rel, claimGeneration: 0)
        context.insert(job)
        try? context.save()
        return job
    }

    /// Auto-enroll a NEWLY rendered output IFF the active account has Auto Backup ON. A no-op when signed out
    /// or the preference is OFF. Reuses `enroll`. Call AFTER the output is persisted, fire-and-forget.
    @discardableResult
    func autoEnrollIfEnabled(output: GeneratedOutputModel) -> GeneratedOutputBackupJobModel? {
        guard let owner = activeOwner() else { return nil }
        guard AutoBackupStore(context: context).isEnabled(for: owner) else { return nil }
        return enroll(output: output)
    }

    // MARK: - Launch recovery

    /// Reset orphaned RUNNING jobs (app killed mid-upload) back to PENDING. The rendered MP4 is untouched.
    func recoverOrphans() {
        let running = (try? context.fetch(FetchDescriptor<GeneratedOutputBackupJobModel>(
            predicate: #Predicate { $0.stateRaw == "running" }))) ?? []
        for job in running { job.state = .pending; job.updatedAt = .now }
        if !running.isEmpty { try? context.save() }
    }

    // MARK: - Drain (account-scoped, opportunistic)

    func drain(maxJobs: Int = 25) async {
        if draining { return }
        guard let owner = activeOwner() else { return }
        draining = true
        defer { draining = false }
        var processed = 0
        while processed < maxJobs, let job = nextEligibleJob(owner: owner) {
            processed += 1
            await run(job)
        }
    }

    private func nextEligibleJob(owner: String) -> GeneratedOutputBackupJobModel? {
        let now = Date()
        var desc = FetchDescriptor<GeneratedOutputBackupJobModel>(
            predicate: #Predicate { $0.stateRaw == "pending" && $0.ownerAccountId == owner && $0.nextEligibleAt <= now },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first
    }

    // MARK: - One job

    private func run(_ job: GeneratedOutputBackupJobModel) async {
        let owner = job.ownerAccountId
        guard let token = await tokenForOwner(owner) else { return }       // rule 9: active account's token only
        guard networkAllows(owner) else { return }                          // Wi-Fi gate: hold, burn no retry

        let url = RenderOutputStore.shared.absoluteURL(for: job.relativeFilePath)
        guard RenderOutputStore.shared.exists(relative: job.relativeFilePath) else {
            // Rendered MP4 gone (output deleted / evicted) — drop the job; never a retry. Never deletes bytes.
            context.delete(job); try? context.save(); return
        }

        job.state = .running; job.updatedAt = .now; try? context.save()
        let generationAtStart = job.claimGeneration

        do {
            let size = job.sizeBytes ?? MediaUploadService.fileSize(url)
            job.sizeBytes = size
            let multipartThreshold = 16 * 1024 * 1024
            if size > multipartThreshold {
                try await uploadMultipart(job: job, token: token, url: url)
            } else {
                try await uploadSingle(job: job, token: token, url: url)
            }
            job.state = .verified; job.lastError = nil; job.updatedAt = .now
            applyVerifiedTransition(job: job, generationAtStart: generationAtStart)
            try? context.save()
        } catch {
            job.attempts += 1
            job.lastError = String(describing: error).prefix(300).description
            if job.attempts >= 6 {
                job.state = .failed
            } else {
                job.state = .pending
                job.nextEligibleAt = Date().addingTimeInterval(backoff(for: job.attempts))
            }
            job.updatedAt = .now
            try? context.save()
        }
    }

    /// Small-file path: one presigned PUT of the whole MP4, then server verify. media_kind="generated".
    private func uploadSingle(job: GeneratedOutputBackupJobModel, token: String, url: URL) async throws {
        let sha: String
        if let existing = job.contentSha256 { sha = existing }
        else { sha = try MediaUploadService.sha256Hex(fileURL: url) }
        job.contentSha256 = sha
        let init0 = try await service.initiate(
            accessToken: token, sha256: sha, size: job.sizeBytes ?? 0,
            deviceAssetId: "", sourceMomentId: "",
            mediaKind: CloudMediaKind.generated, sourceOutputId: job.outputId.uuidString,
            contentType: "video/mp4")
        job.cloudMediaId = init0.cloudMediaId; try? context.save()
        try await service.putToS3(uploadURL: init0.uploadURL, fileURL: url, sha256Hex: sha,
                                  contentType: "video/mp4")
        job.progress = 1.0
        try await service.complete(accessToken: token, cloudMediaId: init0.cloudMediaId)
    }

    /// Large-file path: true S3 multipart with part-level resume (identical to the originals queue), with
    /// media_kind="generated". Never loads the whole MP4 into memory; never deletes the rendered file.
    private func uploadMultipart(job: GeneratedOutputBackupJobModel, token: String, url: URL) async throws {
        let partSize = 8 * 1024 * 1024
        let plan = try MediaUploadService.makeMultipartPlan(fileURL: url, partSize: partSize)
        job.contentSha256 = plan.fileSha256Hex; job.sizeBytes = plan.size; try? context.save()

        let init0 = try await service.initiateMultipart(
            accessToken: token, plan: plan,
            deviceAssetId: "", sourceMomentId: "",
            mediaKind: CloudMediaKind.generated, sourceOutputId: job.outputId.uuidString,
            contentType: "video/mp4")
        job.cloudMediaId = init0.cloudMediaId; try? context.save()

        let already = try await service.uploadedPartNumbers(accessToken: token, cloudMediaId: init0.cloudMediaId)
        let allParts = Array(1...plan.partCount)
        let missing = allParts.filter { !already.contains($0) }

        if !missing.isEmpty {
            let urls = try await service.presignParts(
                accessToken: token, cloudMediaId: init0.cloudMediaId, partNumbers: missing)
            for pn in missing {
                guard let partURL = urls[pn] else { throw MediaUploadError.decoding }
                let offset = (pn - 1) * partSize
                let length = min(partSize, plan.size - offset)
                try await service.putPart(uploadURL: partURL, fileURL: url, offset: offset,
                                          length: length, partShaB64: plan.partShasB64[pn - 1],
                                          contentType: "video/mp4")
                let done = plan.partCount - missing.count + (missing.firstIndex(of: pn)! + 1)
                job.progress = Double(done) / Double(plan.partCount)
                try? context.save()
            }
        } else {
            job.progress = 1.0
        }

        try await service.completeMultipart(accessToken: token, cloudMediaId: init0.cloudMediaId)
    }

    /// Stamp the output's cloud ref, guarded by owner-match + current generation. If a newer claim superseded
    /// this run, or the output's owner no longer matches, the verified record still stands server-side but we
    /// do NOT mutate newer local state (rule 10/5).
    private func applyVerifiedTransition(job: GeneratedOutputBackupJobModel, generationAtStart: Int) {
        guard job.claimGeneration == generationAtStart else { return }
        guard let cmid = job.cloudMediaId else { return }
        let oid = job.outputId
        guard let output = (try? context.fetch(FetchDescriptor<GeneratedOutputModel>(
            predicate: #Predicate { $0.id == oid })))?.first else { return }
        let outputOwner = output.ownerAccountId ?? output.story?.ownerAccountId
        guard outputOwner == nil || outputOwner == job.ownerAccountId else { return }
        output.cloudMediaId = cmid
        output.cloudVerifiedAt = .now
        if output.ownerAccountId == nil { output.ownerAccountId = job.ownerAccountId }
    }

    /// Explicit user retry of a FAILED job (bounded recovery). Re-arms it for the active account only.
    func retry(job: GeneratedOutputBackupJobModel) {
        guard job.state == .failed, job.ownerAccountId == activeOwner() else { return }
        job.attempts = 0; job.state = .pending; job.nextEligibleAt = .now
        job.claimGeneration += 1; job.updatedAt = .now
        try? context.save()
    }

    private func backoff(for attempts: Int) -> TimeInterval {
        min(baseBackoff * pow(4.0, Double(max(0, attempts - 1))), maxBackoff)
    }
}
