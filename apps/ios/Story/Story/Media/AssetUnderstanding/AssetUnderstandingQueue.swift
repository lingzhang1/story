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
    /// Injectable media-presence check (defaults to the real MediaStore). A seam so tests don't depend on the
    /// device filesystem: the `run()` guard that DROPS a job when its media file is gone otherwise reads the
    /// real disk, making a fake "media/x.mov" job order/filesystem-dependent (the pre-existing
    /// AuthGatingTests flake). Same injection pattern as `extractFrames`/`isAuthed`.
    private let fileExists: (String) -> Bool
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
        isAuthed: @escaping () -> Bool = { AssetUnderstandingQueue.sharedIsAuthed() },
        fileExists: @escaping (String) -> Bool = { MediaStore.shared.fileExists(relativePath: $0) }
    ) {
        self.context = context
        self.service = service
        self.extractFrames = extractFrames
        self.isAuthed = isAuthed
        self.fileExists = fileExists
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
        // If the media file is gone (Moment deleted), drop the job — no retry. Uses the injectable seam so a
        // test is not coupled to the device filesystem.
        if !fileExists(job.relativeMediaPath),
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
            // P1-F (R1): compute the SOURCE file sha256 (full-file) off the main thread for the SAME file the
            // frames were just extracted from (so sha + frames refer to one file version). Best-effort — a
            // hash failure (missing/replaced file, read error) simply yields nil and AU proceeds WITHOUT an
            // evidence claim (caching unavailable this run; never blocks AU). Reuses the streaming upload hasher.
            let contentSha: String? = await Self.hashSource(url: url)
            let dto = try await service.analyze(
                frames: frames,
                momentId: job.momentId,
                sourceCaptureId: job.sourceCaptureId,
                captureContext: ctx,
                contentSha256: contentSha
            )
            try upsertUnderstanding(dto)
            job.state = .complete
            job.lastError = nil
            job.updatedAt = .now
            try? context.save()
            // Transient derived frames are released here (never persisted).
        } catch {
            // Classify the failure to decide RETRY vs STOP (pre-beta AU-429 hardening). All state uses the
            // EXISTING persisted fields (attempts / nextEligibleAt / lastError / state) so the SwiftData
            // @Model shape is UNCHANGED (no migration; honors the FROZEN model + device-build gate).
            job.lastError = String(describing: error).prefix(300).description
            let auErr = error as? AssetUnderstandingServiceError

            if case let .quotaExhausted(scope)? = auErr {
                // An ALLOWANCE is spent (daily gens / monthly USD / global breaker). Retrying now cannot
                // succeed — the cap clears when the PERIOD rolls over. Park the job PENDING but ineligible
                // until the next UTC-day boundary (the daily cap's reset; monthly/global clear later, re-checked
                // cheaply once a day). Do NOT burn an attempt — this is not a failure of the work, and we must
                // not let an exhausted cap push the job toward a hard-error ceiling.
                job.state = .pending
                job.nextEligibleAt = Self.nextUtcDayBoundary(after: Date())
                job.lastError = "quota_exhausted:\(scope) (deferred to next day)"
                job.updatedAt = .now
                try? context.save()
                return
            }

            if case let .rateLimited(retryAfter)? = auErr {
                // TEMPORARY per-user rate cap (ai_sync 20/min window). Retryable: wait at least the server's
                // Retry-After, but never less than our own exponential backoff, plus jitter to avoid a
                // thundering-herd re-fire of a bulk import all coming eligible at the same instant. We reuse
                // the EXISTING `attempts` counter for the backoff curve (no new @Model field -> no migration);
                // a rate limit advancing `attempts` only lengthens its own backoff, which is the desired
                // self-throttling under sustained 429s and still clears to COMPLETE on the first 200.
                job.attempts += 1
                let serverWait = TimeInterval(max(0, retryAfter ?? 0))
                let base = max(serverWait, backoff(for: job.attempts))
                job.state = .pending
                job.nextEligibleAt = Date().addingTimeInterval(Self.withJitter(base))
                job.updatedAt = .now
                try? context.save()
                return
            }

            // Transient (503 / transport) OR a hard error (badStatus / decoding). Transient errors are
            // retryable with bounded exponential backoff + jitter. A hard error is NOT expected to clear by
            // retrying; bound it by attempts so the queue stops hammering it (parks far out once the ceiling
            // is reached) while still surviving a restart (state persists).
            job.attempts += 1
            let retryable = auErr?.isRetryable ?? true   // unknown (non-AU) error -> treat as transient
            if !retryable && job.attempts >= Self.maxHardAttempts {
                // Permanent-looking failure that exhausted its bounded attempts: park far out (no terminal
                // state exists in the FROZEN model, so a distant nextEligibleAt is the no-migration stop).
                job.state = .pending
                job.nextEligibleAt = Date().addingTimeInterval(Self.hardErrorParkInterval)
            } else {
                job.state = .pending
                job.nextEligibleAt = Date().addingTimeInterval(Self.withJitter(backoff(for: job.attempts)))
            }
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

    // MARK: - AU-429 retry policy helpers (pre-beta hardening; no @Model change)

    /// Hard (non-retryable) errors — a bad status or an undecodable body — are not expected to clear by
    /// retrying. Bound them so the queue stops hammering after a few attempts, then parks the job far out.
    static let maxHardAttempts = 4
    /// Where a hard error parks once its bounded attempts are spent (effectively "stop, but survive a restart
    /// and allow a much-later re-check" — there is no terminal-fail state in the FROZEN model to migrate to).
    static let hardErrorParkInterval: TimeInterval = 24 * 60 * 60

    /// Full-jitter on a backoff interval: a uniform random in [base/2, base]. Prevents a bulk import whose
    /// jobs all fail a rate-limit window at once from coming eligible on the same instant and re-bursting.
    static func withJitter(_ base: TimeInterval) -> TimeInterval {
        guard base > 0 else { return 0 }
        return base / 2 + Double.random(in: 0...(base / 2))
    }

    /// The next 00:00:00 UTC boundary strictly after `date`. A quota-exhausted job defers to here because the
    /// per-user DAILY generation allowance resets on the UTC day; monthly/global caps clear later but a daily
    /// re-check is a cheap, bounded way to resume without spinning.
    static func nextUtcDayBoundary(after date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    /// P1-F (R1): full-file sha256 of the source clip, computed OFF the main actor on a background task so the
    /// AU drain (which is @MainActor) never blocks the UI hashing a large video. Best-effort: any failure
    /// (missing/replaced file, read error) returns nil and AU proceeds without an evidence claim. Reuses the
    /// streaming upload hasher (never loads the whole file into memory) so there is no second hashing subsystem.
    nonisolated private static func hashSource(url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            try? MediaUploadService.sha256Hex(fileURL: url)
        }.value
    }
}
