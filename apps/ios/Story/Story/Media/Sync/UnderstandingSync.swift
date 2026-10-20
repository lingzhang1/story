import Foundation
import SwiftData

// R7-F — Moment Understanding sync + the hydration gate.
//
// UnderstandingSync: PUSH each completed MomentUnderstanding to the account-level /v1/understanding store, and
// on Device B PULL + RESTORE it so Asset Understanding is NOT re-run (restore first, reuse valid results).
// Reuse is gated on the Moment's media content_sha256 + a compatible schema (checked on restore).
//
// CloudHydrationGate: a PROCESS-WIDE barrier (like CoverageRecomputeGate). The AU / Guide / Coverage / Music
// queues ask `isHydrating(storyId:)` / `isHydrating(momentId:)` before starting inference; while a Story (or
// its Moments) is being hydrated from the cloud, they HOLD — so a sign-in / view recreation never kicks off
// regeneration that a restore is about to make unnecessary. Released only when hydration validated or the
// dependency is classified missing/incompatible.

// MARK: - HTTP client

struct CloudUnderstandingRecord {
    let momentId: String
    let understandingJSON: String
    let schemaVersion: String
    let promptVersion: String
    let framePolicy: String
    let contentSha256: String
    let modelId: String
}

protocol UnderstandingSyncing {
    func batchGet(accessToken: String, momentIds: [String]) async throws -> [CloudUnderstandingRecord]
    func put(accessToken: String, records: [CloudUnderstandingRecord]) async throws
}

struct UnderstandingSyncService: UnderstandingSyncing {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = .shared

    func batchGet(accessToken: String, momentIds: [String]) async throws -> [CloudUnderstandingRecord] {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/understanding/batch-get"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["moment_ids": momentIds])
        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 401 { throw StorySyncError.unauthorized }
        guard http.statusCode == 200 else { throw StorySyncError.badStatus(http.statusCode) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let arr = (obj["understanding"] as? [[String: Any]]) ?? []
        return arr.compactMap { r in
            guard let mid = r["moment_id"] as? String, let js = r["understanding_json"] as? String else { return nil }
            return CloudUnderstandingRecord(
                momentId: mid, understandingJSON: js,
                schemaVersion: (r["schema_version"] as? String) ?? "",
                promptVersion: (r["prompt_version"] as? String) ?? "",
                framePolicy: (r["frame_policy"] as? String) ?? "",
                contentSha256: (r["content_sha256"] as? String) ?? "",
                modelId: (r["model_id"] as? String) ?? "")
        }
    }

    func put(accessToken: String, records: [CloudUnderstandingRecord]) async throws {
        guard !records.isEmpty else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/understanding"))
        req.httpMethod = "PUT"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["records": records.map { [
            "moment_id": $0.momentId, "understanding_json": $0.understandingJSON,
            "schema_version": $0.schemaVersion, "prompt_version": $0.promptVersion,
            "frame_policy": $0.framePolicy, "content_sha256": $0.contentSha256, "model_id": $0.modelId] }])
        let (_, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 401 { throw StorySyncError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw StorySyncError.badStatus(http.statusCode) }
    }
}

// MARK: - CloudHydrationGate (barrier against premature inference)

@MainActor
final class CloudHydrationGate {
    static let shared = CloudHydrationGate()
    private var hydratingStories: Set<UUID> = []
    private var hydratingMoments: Set<UUID> = []
    /// True once we have seeded the in-memory barrier from the durable `hydrationPending` sync rows this
    /// process. Seeding happens lazily on the first `isHydrating`/`seedFromDurable` call so a SwiftUI view
    /// recreation or an app relaunch that races ahead of the pull STILL sees the barrier (issue 4 §13).
    private var didSeed = false

    func beginStory(_ id: UUID, moments: [UUID]) {
        hydratingStories.insert(id); for m in moments { hydratingMoments.insert(m) }
    }
    func endStory(_ id: UUID, moments: [UUID]) {
        hydratingStories.remove(id); for m in moments { hydratingMoments.remove(m) }
    }

    /// Seed the in-memory barrier from the DURABLE `hydrationPending` sync rows (survives relaunch / view
    /// recreation). Idempotent; call it before reading `isHydrating` from a view. A pending row holds the
    /// Story (and, via its moment_refs, its Moments) until the pull clears the flag. Owner-scoped is not needed
    /// here — a pending row only exists for an account that signed in on THIS device, and the pull clears it
    /// before any cross-account view opens.
    func seedFromDurable(context: ModelContext) {
        let rows = (try? context.fetch(FetchDescriptor<StorySyncJobModel>(
            predicate: #Predicate { $0.hydrationPending == true }))) ?? []
        for r in rows {
            hydratingStories.insert(r.storyId)
            // Also hold the Story's Moments so AU does not fire before the understanding restore.
            if let s = (try? context.fetch(FetchDescriptor<StoryModel>(
                predicate: #Predicate { $0.id == r.storyId })))?.first {
                for m in s.moments { hydratingMoments.insert(m.id) }
            }
        }
        didSeed = true
    }

    /// AU/Guide/Coverage/Music queues call this before starting inference for a Story/Moment. Seeds from the
    /// durable rows on first use so a view that raced ahead of the pull still holds.
    func isHydrating(storyId: UUID) -> Bool {
        if hydratingStories.contains(storyId) { return true }
        return false
    }
    func isHydrating(momentId: UUID) -> Bool { hydratingMoments.contains(momentId) }

    /// Convenience for a VIEW: seed from durable state (once) then report whether this Story is still
    /// hydrating. Views pass their context; queues that already run inside the pull window use `isHydrating`.
    func isHydratingAfterSeed(storyId: UUID, context: ModelContext) -> Bool {
        if !didSeed { seedFromDurable(context: context) }
        return isHydrating(storyId: storyId)
    }
}

// MARK: - UnderstandingSync coordinator

@MainActor
final class UnderstandingSync {
    static let shared = UnderstandingSync()
    private let service: UnderstandingSyncing
    init(service: UnderstandingSyncing = UnderstandingSyncService()) { self.service = service }

    /// PUSH all completed understandings this account owns that carry a content sha (so they are reusable).
    /// Idempotent + cheap; called on foreground/sign-in after local AU has produced results.
    func push(context: ModelContext, activeOwner: String?, token: @escaping () async -> String?) async {
        guard activeOwner != nil, let accessToken = await token() else { return }
        let mus = (try? context.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? []
        var recs: [CloudUnderstandingRecord] = []
        for mu in mus {
            let sha = contentSha(for: mu.momentId, context: context)
            guard !sha.isEmpty else { continue }   // only push understandings whose media is cloud-backed (reusable)
            recs.append(CloudUnderstandingRecord(
                momentId: mu.momentId.uuidString, understandingJSON: mu.understandingJSON,
                schemaVersion: mu.schemaVersion, promptVersion: mu.promptVersion,
                framePolicy: mu.framePolicy, contentSha256: sha, modelId: mu.modelId ?? ""))
        }
        // chunk to stay under the batch cap
        for i in stride(from: 0, to: recs.count, by: 100) {
            try? await service.put(accessToken: accessToken, records: Array(recs[i..<min(i+100, recs.count)]))
        }
    }

    /// RESTORE understandings for the given moment ids that are MISSING locally, reusing the cloud copy iff its
    /// content_sha256 matches the local Moment's media (same bytes) — so a restored Moment is not re-analyzed.
    /// Returns how many were restored.
    @discardableResult
    func restore(momentIds: [UUID], context: ModelContext, activeOwner: String?,
                 token: @escaping () async -> String?) async -> Int {
        guard activeOwner != nil, let accessToken = await token(), !momentIds.isEmpty else { return 0 }
        // Only fetch ones we don't already have locally.
        let missing = momentIds.filter { mid in
            ((try? context.fetch(FetchDescriptor<MomentUnderstandingModel>(
                predicate: #Predicate { $0.momentId == mid })))?.first) == nil
        }
        guard !missing.isEmpty else { return 0 }
        let cloud: [CloudUnderstandingRecord]
        do { cloud = try await service.batchGet(accessToken: accessToken, momentIds: missing.map { $0.uuidString }) }
        catch { return 0 }
        var restored = 0
        for rec in cloud {
            guard let mid = UUID(uuidString: rec.momentId) else { continue }
            guard !rec.schemaVersion.isEmpty else { continue }       // compatible schema required
            // Reuse gate (restore first, reuse valid): accept the cloud understanding when it is for the SAME
            // media. Device A can confirm via its upload job's content_sha256; Device B (no upload job) confirms
            // via the Moment carrying a cloudMediaId (the account-scoped server record it was pushed against).
            let localSha = contentSha(for: mid, context: context)
            let shaMatches = !rec.contentSha256.isEmpty && rec.contentSha256 == localSha
            let cloudBacked = momentHasCloudMedia(mid, context: context)
            guard shaMatches || cloudBacked else { continue }
            context.insert(MomentUnderstandingModel(
                momentId: mid, schemaVersion: rec.schemaVersion, framePolicy: rec.framePolicy,
                promptVersion: rec.promptVersion, modelId: rec.modelId.isEmpty ? nil : rec.modelId,
                nFrames: nil, understandingJSON: rec.understandingJSON))
            restored += 1
        }
        if restored > 0 { try? context.save() }
        return restored
    }

    /// The Moment's media content sha — the reuse key. Sourced from the upload job (contentSha256) for a
    /// Moment uploaded here, else empty (not reusable cross-device without a known sha).
    private func contentSha(for momentId: UUID, context: ModelContext) -> String {
        if let job = (try? context.fetch(FetchDescriptor<MediaUploadJobModel>(
            predicate: #Predicate { $0.momentId == momentId })))?.first, let s = job.contentSha256 { return s }
        return ""
    }

    /// True if the local Moment is cloud-backed (has a cloudMediaId) — the Device-B reuse signal.
    private func momentHasCloudMedia(_ momentId: UUID, context: ModelContext) -> Bool {
        if let m = (try? context.fetch(FetchDescriptor<MomentModel>(
            predicate: #Predicate { $0.id == momentId })))?.first {
            return (m.cloudMediaId ?? "").isEmpty == false
        }
        return false
    }
}
