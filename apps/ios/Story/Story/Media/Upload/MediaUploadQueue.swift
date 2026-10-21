import Foundation
import SwiftData

// R4-A — MediaUploadQueue: the persistent, account-scoped cloud-upload driver. A sibling of
// AssetUnderstandingQueue (same persistence/recovery/backoff discipline), with the cross-account
// immutable-owner rule baked in.
//
// Enroll (explicit, per owner policy) -> PENDING job bound IMMUTABLY to the enrolling canonical account +
// local Moment/Asset + a stable operationId; the Moment is RESERVED to that account (local reservation, not
// cloud ownership). drain() runs only jobs whose owner == the active account (rule 2). run() does
// initiate -> presigned PUT -> complete; on server cloud_verified it performs the Phase-4 ownership
// transition (rule 4/5/10): write cloud-state onto the Moment/Asset ONLY if the job's owner still matches the
// Moment's reservation AND the job's claimGeneration is current. A stale/cross-account callback is ignored.
//
// Capture is NEVER blocked: enrollment only writes a PENDING row + computes nothing on the capture path;
// hashing + upload happen in drain().
@MainActor
final class MediaUploadQueue {
    /// R4-A.1 — set once by StoryApp to a closure bound to the live AuthStore + container context. Capture/
    /// import sites (which don't hold AuthStore) call this fire-and-forget AFTER persisting a new Moment; it
    /// auto-enrolls + drains ONLY when the active account has Auto Backup ON. Default no-op (safe before setup).
    nonisolated(unsafe) static var sharedAutoEnroll: (MomentModel) -> Void = { _ in }

    private let context: ModelContext
    private let service: MediaUploading
    /// Returns a VALID access token for a SPECIFIC owner, or nil if that owner is not the active signed-in
    /// account (rule 9: never use B's token for A's job). Injected from the app layer (AuthStore).
    private let tokenForOwner: (String) async -> String?
    /// The currently-active canonical account id (nil = signed out). Used to scope scheduling.
    private let activeOwner: () -> String?
    /// Whether the CURRENT network path permits an upload for `owner` (consults that account's cellular pref +
    /// reachability). Default wires AutoBackupStore + NetworkReachability; injectable for tests. A nil return
    /// from the default means "hold" (e.g. Wi-Fi-only and currently on cellular) — the job stays PENDING.
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

    // MARK: - Enroll (explicit; reserves the Moment to the active account)

    /// Enroll a local Moment for cloud backup under the ACTIVE account. Idempotent: a non-terminal job for this
    /// (owner, moment) is reused. Refuses if signed out, or if the Moment is already RESERVED/owned by a
    /// DIFFERENT account (prevents A and B both claiming the same local-only Moment). Returns the job, or nil.
    @discardableResult
    func enroll(moment: MomentModel) -> MediaUploadJobModel? {
        guard let owner = activeOwner() else { return nil }                 // must be signed in
        guard let asset = moment.asset else { return nil }
        // Reservation guard: the Moment must be local-only (nil owner) OR already this account's.
        if let existingOwner = moment.ownerAccountId, existingOwner != owner { return nil }

        // Idempotent: reuse a live job for this (owner, moment).
        let mid = moment.id
        if let live = (try? context.fetch(FetchDescriptor<MediaUploadJobModel>(
            predicate: #Predicate { $0.momentId == mid && $0.ownerAccountId == owner })))?
            .first(where: { !$0.isAutoTerminal }) {
            return live
        }

        // Atomic local reservation: stamp the Moment's owner (NOT cloud ownership — cloudStateRaw stays
        // local_only until the server verifies). This blocks the other account from claiming it.
        moment.ownerAccountId = owner
        asset.ownerAccountId = owner

        let job = MediaUploadJobModel(
            ownerAccountId: owner, momentId: moment.id, assetId: asset.id,
            operationId: UUID().uuidString, relativeMediaPath: asset.relativePath,
            claimGeneration: 0)
        context.insert(job)
        try? context.save()
        return job
    }

    /// R4-A.1 — auto-enroll a NEWLY captured/imported Moment IFF the active account has Auto Backup ON (req 6).
    /// A no-op when signed out or the preference is OFF (default). Reuses `enroll` (same reservation guards), so
    /// it never claims a Moment already owned by another account and never blocks capture. Call AFTER the Moment
    /// is persisted, fire-and-forget. Returns the job if enrolled.
    @discardableResult
    func autoEnrollIfEnabled(moment: MomentModel) -> MediaUploadJobModel? {
        guard let owner = activeOwner() else { return nil }
        guard AutoBackupStore(context: context).isEnabled(for: owner) else { return nil }
        return enroll(moment: moment)
    }

    // MARK: - Launch recovery

    /// Reset orphaned RUNNING jobs (app killed mid-upload) back to PENDING. The original media is untouched.
    func recoverOrphans() {
        let running = (try? context.fetch(FetchDescriptor<MediaUploadJobModel>(
            predicate: #Predicate { $0.stateRaw == "running" }))) ?? []
        for job in running { job.state = .pending; job.updatedAt = .now }
        if !running.isEmpty { try? context.save() }
    }

    // MARK: - Drain (account-scoped, opportunistic)

    /// Process eligible PENDING jobs for the ACTIVE account only (rule 2: a switch to B stops scheduling A's
    /// jobs). Safe to call repeatedly. Signed out -> no-op.
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

    private func nextEligibleJob(owner: String) -> MediaUploadJobModel? {
        let now = Date()
        var desc = FetchDescriptor<MediaUploadJobModel>(
            predicate: #Predicate { $0.stateRaw == "pending" && $0.ownerAccountId == owner && $0.nextEligibleAt <= now },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first
    }

    // MARK: - One job

    private func run(_ job: MediaUploadJobModel) async {
        let owner = job.ownerAccountId
        // Rule 9: get a token for THIS job's owner; nil if that owner is not the active account -> defer.
        guard let token = await tokenForOwner(owner) else { return }
        // R4-A.1 Wi-Fi gate: if the current path is not permitted for this account (e.g. Wi-Fi-only and on
        // cellular), HOLD — leave the job PENDING, burn no retry. A later drain (Wi-Fi/foreground) picks it up.
        guard networkAllows(owner) else { return }

        let url = MediaStore.shared.absoluteURL(for: job.relativeMediaPath)
        guard MediaStore.shared.fileExists(relativePath: job.relativeMediaPath) else {
            // Original missing (Moment deleted) — drop the job; never a retry. Reservation released below.
            releaseReservationIfOwned(job: job)
            context.delete(job); try? context.save(); return
        }

        job.state = .running; job.updatedAt = .now; try? context.save()
        let generationAtStart = job.claimGeneration

        do {
            let size = job.sizeBytes ?? MediaUploadService.fileSize(url)
            job.sizeBytes = size
            // R4-B: large files use true S3 multipart (part-level resume); small files keep the single PUT.
            let multipartThreshold = 16 * 1024 * 1024
            if size > multipartThreshold {
                try await uploadMultipart(job: job, token: token, url: url)
            } else {
                try await uploadSingle(job: job, token: token, url: url)
            }

            // Phase-4 ownership transition — ONLY after server cloud_verified, and ONLY if this is still the
            // current claim for an unchanged owner (rule 10: a stale callback cannot overwrite a newer state).
            job.state = .verified; job.lastError = nil; job.updatedAt = .now
            applyVerifiedTransition(job: job, generationAtStart: generationAtStart)
            try? context.save()
        } catch {
            job.attempts += 1
            job.lastError = String(describing: error).prefix(300).description
            // Bounded retries; after a cap, FAILED (recoverable by explicit retry) — reservation stays so the
            // Moment is not re-claimed by another account; retry/release is an explicit user action.
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

    /// Small-file path (R4-A): one presigned PUT of the whole file, then server verify. sha256 computed here.
    private func uploadSingle(job: MediaUploadJobModel, token: String, url: URL) async throws {
        let sha: String
        if let existing = job.contentSha256 { sha = existing }
        else { sha = try MediaUploadService.sha256Hex(fileURL: url) }
        job.contentSha256 = sha
        let init0 = try await service.initiate(
            accessToken: token, sha256: sha, size: job.sizeBytes ?? 0,
            deviceAssetId: job.assetId.uuidString, sourceMomentId: job.momentId.uuidString)
        job.cloudMediaId = init0.cloudMediaId; try? context.save()
        try await service.putToS3(uploadURL: init0.uploadURL, fileURL: url, sha256Hex: sha)
        job.progress = 1.0
        try await service.complete(accessToken: token, cloudMediaId: init0.cloudMediaId)
        job.state = .verified; job.lastError = nil; job.updatedAt = .now
    }

    /// Large-file path (R4-B): true S3 multipart with part-level resume. Builds the part plan (streamed), (re)
    /// initiates the MPU (idempotent — recovers the same upload_id), RECONCILES already-uploaded parts with S3
    /// and re-uploads ONLY the missing ones (resume after interruption), refreshes presigned part URLs, then
    /// completes + verifies server-side. Never loads the whole file into memory; never deletes the original.
    private func uploadMultipart(job: MediaUploadJobModel, token: String, url: URL) async throws {
        let partSize = 8 * 1024 * 1024
        let plan = try MediaUploadService.makeMultipartPlan(fileURL: url, partSize: partSize)
        job.contentSha256 = plan.fileSha256Hex; job.sizeBytes = plan.size; try? context.save()

        let init0 = try await service.initiateMultipart(
            accessToken: token, plan: plan,
            deviceAssetId: job.assetId.uuidString, sourceMomentId: job.momentId.uuidString)
        job.cloudMediaId = init0.cloudMediaId; try? context.save()

        // Reconcile: which parts does S3 already have? Re-upload only the missing ones (resume).
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
                                          length: length, partShaB64: plan.partShasB64[pn - 1])
                // Advisory progress across all parts (reused + newly uploaded).
                let done = plan.partCount - missing.count + (missing.firstIndex(of: pn)! + 1)
                job.progress = Double(done) / Double(plan.partCount)
                try? context.save()
            }
        } else {
            job.progress = 1.0
        }

        try await service.completeMultipart(accessToken: token, cloudMediaId: init0.cloudMediaId)
        job.state = .verified; job.lastError = nil; job.updatedAt = .now
    }

    /// Write cloud-state onto the Moment + Asset, guarded by owner-match + current generation. If the Moment's
    /// reservation no longer belongs to the job's owner (e.g. it was released/reassigned), the verified cloud
    /// record still stands on the server, but we do NOT mutate another account's local content (rule 5).
    private func applyVerifiedTransition(job: MediaUploadJobModel, generationAtStart: Int) {
        guard job.claimGeneration == generationAtStart else { return }   // a newer claim superseded this run
        guard let cmid = job.cloudMediaId else { return }
        let mid = job.momentId
        guard let moment = (try? context.fetch(FetchDescriptor<MomentModel>(
            predicate: #Predicate { $0.id == mid })))?.first else { return }
        // Only mutate if the Moment is still reserved to THIS job's owner (never B's content).
        guard moment.ownerAccountId == job.ownerAccountId else { return }
        moment.cloudMediaId = cmid
        moment.cloudStateRaw = "cloud_verified"      // now account-owned (visibility becomes account-scoped)
        if let asset = moment.asset {
            asset.ownerAccountId = job.ownerAccountId
        }
    }

    /// On drop of a job whose Moment was reserved but never verified, release the reservation back to shared
    /// local-only so the original is not permanently locked (safe retry/release policy).
    private func releaseReservationIfOwned(job: MediaUploadJobModel) {
        let mid = job.momentId
        guard let moment = (try? context.fetch(FetchDescriptor<MomentModel>(
            predicate: #Predicate { $0.id == mid })))?.first else { return }
        if moment.ownerAccountId == job.ownerAccountId && moment.cloudStateRaw == "local_only" {
            moment.ownerAccountId = nil   // back to shared local-only (not verified, so safe to release)
            moment.asset?.ownerAccountId = nil
        }
    }

    /// Explicit user retry of a FAILED job (bounded recovery). Re-arms it for the active account only.
    func retry(job: MediaUploadJobModel) {
        guard job.state == .failed, job.ownerAccountId == activeOwner() else { return }
        job.attempts = 0; job.state = .pending; job.nextEligibleAt = .now
        job.claimGeneration += 1; job.updatedAt = .now
        try? context.save()
    }

    /// Explicit cancel: stop the job and release the reservation (if not yet verified). Original media kept.
    func cancel(job: MediaUploadJobModel) {
        guard job.ownerAccountId == activeOwner() else { return }
        if job.state != .verified {
            job.state = .cancelled; job.claimGeneration += 1; job.updatedAt = .now
            releaseReservationIfOwned(job: job)
            try? context.save()
        }
    }

    private func backoff(for attempts: Int) -> TimeInterval {
        min(baseBackoff * pow(4.0, Double(max(0, attempts - 1))), maxBackoff)
    }
}
