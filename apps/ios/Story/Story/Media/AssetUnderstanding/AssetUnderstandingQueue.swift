import Foundation
import SwiftData

// AssetUnderstandingQueue — the FROZEN persistent on-device AU job queue
// (06-asset-understanding.md §6-7, §9-10).
//
// State machine (persisted, survives app termination):
//     enqueue ──▶ PENDING ──(eligible)──▶ RUNNING ──success──▶ COMPLETE
//                    ▲                        │
//                    └──── failure / interruption (incl. the server's own
//                          single retry already spent) ───┘  (+ backoff)
//
// Invariants:
//  - Moment creation NEVER blocks on AU: enqueue only writes a PENDING job row.
//  - Opportunistic + resumable: drain() runs on app-active / network-available /
//    next launch. No assumption of unlimited background execution.
//  - Orphan recovery: any RUNNING job found at launch (app was killed mid-run)
//    is reset to PENDING.
//  - Idempotent: one job and one MomentUnderstanding per momentId (upsert); a
//    resumed/duplicate run never creates a second understanding row (§9).
//  - No model fallback / routing: a server 503 (its own one retry already spent)
//    sends the job back to PENDING with bounded exponential backoff.
@MainActor
final class AssetUnderstandingQueue {
    private let context: ModelContext
    private let service: AUAnalyzing
    private let extractFrames: (URL) async throws -> [AUExtractedFrame]
    /// Whether an authenticated session exists. Asset Understanding is a PAID cloud call, so draining is
    /// DEFERRED until this returns true (Increment 4, Phase 4): the Moment and its PENDING job are preserved;
    /// no model call is made while signed out. On sign-in the app calls `drain()` and the existing idempotent
    /// upsert + orphan recovery resume each pending job exactly once under the authenticated account. Injected
    /// (not an AuthStore import) to keep the queue pure/testable; defaults to the shared predicate below so all
    /// existing construction sites defer correctly without plumbing an AuthStore through each.
    private let isAuthed: () -> Bool

    /// Shared auth predicate, set once by AuthStore (same seam pattern as `StoryBackend.authTokenProvider`).
    /// Defaults to `false` — fail SAFE: until AuthStore wires it, paid AU does not run unauthenticated. The app
    /// sets it on launch before the first drain, and in dev optional-auth AuthStore reports signed-in state
    /// honestly (a restored session = true).
    nonisolated(unsafe) static var sharedIsAuthed: () -> Bool = { false }

    /// P1-E (AU durability): fired ONCE after a drain batch that completed at least one understanding, so a
    /// result produced MID-SESSION is pushed to the account store without waiting for the next foreground /
    /// sign-in (the previous push cadence). Wired by StoryApp to a coalesced, idempotent
    /// `UnderstandingSync.shared.push(...)`; default no-op so the queue stays pure/testable and construction
    /// sites that never set it (incl. unit tests) do nothing. Same static-seam pattern as `sharedIsAuthed` /
    /// `MediaUploadQueue.sharedAutoEnroll`. The push itself is cheap + idempotent (PUT), and already skips any
    /// understanding whose media is not yet cloud-backed — so a Moment whose sha is not ready is simply retried
    /// by the upload-complete hook later, never lost.
    nonisolated(unsafe) static var sharedPushUnderstanding: () -> Void = { }
    private let framePolicy = MomentFrameExtractor.framePolicy
    private let promptVersion = "au_prompt/2"
    private let schemaVersion = "moment_understanding/2"

    // Bounded exponential backoff: 5s, 20s, 80s, ... capped at 10 min.
    private let baseBackoff: TimeInterval = 5
    private let maxBackoff: TimeInterval = 600

    private var draining = false

    init(
        context: ModelContext,
        service: AUAnalyzing = AssetUnderstandingService(),
        extractFrames: @escaping (URL) async throws -> [AUExtractedFrame] = { try await MomentFrameExtractor.extract(from: $0) },
        isAuthed: @escaping () -> Bool = { AssetUnderstandingQueue.sharedIsAuthed() }
    ) {
        self.context = context
        self.service = service
        self.extractFrames = extractFrames
        self.isAuthed = isAuthed
    }

    // MARK: - Enqueue (called AFTER the Moment is persisted; never blocks it)

    /// Enqueue an AU job for a freshly-persisted Moment. Idempotent: if a job
    /// already exists for this momentId, it is left as-is (no duplicate).
    func enqueue(
        momentId: UUID,
        relativeMediaPath: String,
        sourceCaptureId: UUID?,
        captureContext: [String: Any]?
    ) {
        if existingJob(for: momentId) != nil { return }
        // R7-C fix: a Moment that ALREADY has a completed understanding must NOT be re-analyzed — this is the
        // case after an R6 restore (the downloaded original is byte-identical, SHA256-verified, to what was
        // understood before). Re-enqueuing here is what flooded the queue with duplicate AU + coverage work.
        if hasCompletedUnderstanding(momentId: momentId) { return }
        var ctxJSON: String?
        if let captureContext,
           let d = try? JSONSerialization.data(withJSONObject: captureContext) {
            ctxJSON = String(data: d, encoding: .utf8)
        }
        let job = AssetUnderstandingJobModel(
            momentId: momentId,
            relativeMediaPath: relativeMediaPath,
            sourceCaptureId: sourceCaptureId,
            captureContextJSON: ctxJSON,
            framePolicy: framePolicy,
            promptVersion: promptVersion,
            schemaVersion: schemaVersion
        )
        context.insert(job)
        try? context.save()
    }

    // MARK: - Launch recovery

    /// Reset orphaned RUNNING jobs (app was killed mid-analysis) back to PENDING.
    /// Call once at launch before the first drain.
    func recoverOrphans() {
        let running = (try? context.fetch(
            FetchDescriptor<AssetUnderstandingJobModel>(
                predicate: #Predicate { $0.stateRaw == "running" }
            )
        )) ?? []
        for job in running {
            job.state = .pending
            job.updatedAt = .now
        }
        if !running.isEmpty { try? context.save() }
    }

    // MARK: - Drain (opportunistic)

    /// Process eligible PENDING jobs one at a time. Safe to call repeatedly
    /// (app-active tick, network-available, next launch). Re-entrancy guarded.
    ///
    /// DEFERRED while signed out: Asset Understanding is a paid cloud call, so a signed-out drain is a silent
    /// no-op — pending jobs are left untouched (not failed, no backoff burned) and resume on the next drain
    /// after sign-in. This is the "defer background AI until an authenticated session exists" boundary; there
    /// is NO sign-in prompt here (background work waits silently).
    func drain(maxJobs: Int = 50) async {
        if draining { return }
        guard isAuthed() else { return }   // defer silently until authenticated
        draining = true
        defer { draining = false }

        var processed = 0
        var completedAny = false
        while processed < maxJobs, let job = nextEligibleJob() {
            processed += 1
            // R7-F: do NOT analyze a Moment while its Story's cloud state is still hydrating — a restore may
            // be about to supply a reusable understanding (restore first, regenerate only if missing).
            if CloudHydrationGate.shared.isHydrating(momentId: job.momentId) { continue }
            let before = job.stateRaw
            await run(job)
            if before != "complete" && job.stateRaw == "complete" { completedAny = true }
        }
        // P1-E (AU durability): a result produced in THIS session is pushed now (coalesced: one push for the
        // whole batch, not one per Moment) instead of waiting for the next foreground/sign-in. No-op until
        // StoryApp wires the seam; idempotent PUT; media-not-yet-backed understandings are retried by the
        // upload-complete hook, never lost.
        if completedAny { Self.sharedPushUnderstanding() }
    }

    // MARK: - One job

    private func run(_ job: AssetUnderstandingJobModel) async {
        job.state = .running
        job.updatedAt = .now
        try? context.save()

        let url = MediaStore.shared.absoluteURL(for: job.relativeMediaPath)
        // If the media file is gone (Moment deleted), drop the job — no retry.
        if !MediaStore.shared.fileExists(relativePath: job.relativeMediaPath),
           job.relativeMediaPath.hasPrefix("media/") {
            context.delete(job)
            try? context.save()
            return
        }

        do {
            let frames = try await extractFrames(url)
            var ctx: [String: Any]?
            if let j = job.captureContextJSON, let d = j.data(using: .utf8) {
                ctx = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
            let dto = try await service.analyze(
                frames: frames,
                momentId: job.momentId,
                sourceCaptureId: job.sourceCaptureId,
                captureContext: ctx
            )
            try upsertUnderstanding(dto)
            job.state = .complete
            job.lastError = nil
            job.updatedAt = .now
            try? context.save()
            // Transient derived frames are released here (never persisted).
        } catch {
            // Failure / interruption -> back to PENDING with bounded backoff.
            job.attempts += 1
            job.lastError = String(describing: error).prefix(300).description
            job.state = .pending
            job.nextEligibleAt = Date().addingTimeInterval(backoff(for: job.attempts))
            job.updatedAt = .now
            try? context.save()
        }
    }

    // MARK: - Idempotent upsert of the understanding (§9)

    private func upsertUnderstanding(_ dto: MomentUnderstandingDTO) throws {
        let json = String(data: try StoryContractCoding.encoder().encode(dto), encoding: .utf8) ?? "{}"
        let momentId = dto.momentId
        if let existing = (try? context.fetch(
            FetchDescriptor<MomentUnderstandingModel>(
                predicate: #Predicate { $0.momentId == momentId }
            )
        ))?.first {
            existing.sourceCaptureId = dto.sourceCaptureId
            existing.schemaVersion = dto.schemaVersion
            existing.framePolicy = dto.framePolicy
            existing.promptVersion = dto.promptVersion
            existing.modelId = dto.modelId
            existing.nFrames = dto.nFrames
            existing.understandingJSON = json
            existing.updatedAt = .now
        } else {
            context.insert(MomentUnderstandingModel(
                momentId: dto.momentId,
                sourceCaptureId: dto.sourceCaptureId,
                schemaVersion: dto.schemaVersion,
                framePolicy: dto.framePolicy,
                promptVersion: dto.promptVersion,
                modelId: dto.modelId,
                nFrames: dto.nFrames,
                understandingJSON: json
            ))
        }
    }

    // MARK: - Queries

    private func existingJob(for momentId: UUID) -> AssetUnderstandingJobModel? {
        (try? context.fetch(
            FetchDescriptor<AssetUnderstandingJobModel>(
                predicate: #Predicate { $0.momentId == momentId }
            )
        ))?.first
    }

    /// True if a completed MomentUnderstanding already exists for this Moment — used to avoid re-analyzing a
    /// Moment whose original was merely RESTORED (R6). A restored original is the SAME verified bytes, so its
    /// understanding is still valid; re-running AU (and the coverage it invalidates) is pure waste.
    private func hasCompletedUnderstanding(momentId: UUID) -> Bool {
        // v2-aware (06v2 §9): a Moment with a CURRENT-version understanding is not
        // re-analyzed (R7-restore no-reanalysis guarantee holds for v2 records). A stale
        // v1 record does NOT block — it stays usable but the Moment is eligible for lazy
        // v2 enrichment when next used. Bulk re-analysis is never triggered here.
        let current = schemaVersion
        return ((try? context.fetch(
            FetchDescriptor<MomentUnderstandingModel>(
                predicate: #Predicate { $0.momentId == momentId && $0.schemaVersion == current }
            )
        ))?.first) != nil
    }

    private func nextEligibleJob() -> AssetUnderstandingJobModel? {
        let now = Date()
        var desc = FetchDescriptor<AssetUnderstandingJobModel>(
            predicate: #Predicate { $0.stateRaw == "pending" && $0.nextEligibleAt <= now },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first
    }

    private func backoff(for attempts: Int) -> TimeInterval {
        let exp = baseBackoff * pow(4.0, Double(max(0, attempts - 1)))
        return min(exp, maxBackoff)
    }
}
