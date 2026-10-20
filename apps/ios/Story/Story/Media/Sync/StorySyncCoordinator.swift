import Foundation
import SwiftData

// R7-C — StorySyncCoordinator. Local SwiftData is ALWAYS authoritative for editing; sync is async and never
// blocks the editor. Push is dirty-driven + debounced + idempotent (mutation_id + base_revision). Pull applies
// ONLY to clean local records; a dirty record facing a newer server revision is PRESERVED and raised as a
// recoverable conflict (Keep Both / Use Cloud Version). Owner is bound per job and never re-derived from the
// active account inside a callback; a claimGeneration guard drops stale callbacks after an account switch.
//
// R7-C scope: Story METADATA only. Generated-MP4 upload/restore is R7-D (outputs sync as metadata with a nil
// cloud_media_id). AI planning/rendering is NEVER triggered by sync.

@MainActor
final class StorySyncCoordinator {
    static let shared = StorySyncCoordinator()

    private let service: StorySyncing
    private var debounce: [UUID: Task<Void, Never>] = [:]   // per-story debounce tasks
    private let debounceNanos: UInt64 = 2_500_000_000       // ~2.5s

    init(service: StorySyncing = StorySyncService()) { self.service = service }

    // MARK: - dirty marking (called by mutation seams; hash-diff is the safety net)

    /// Mark a Story dirty and schedule a debounced push. Cheap + idempotent; safe to call on every edit.
    func touch(storyId: UUID, context: ModelContext, activeOwner: String?, token: @escaping () async -> String?) {
        guard let owner = activeOwner else { return }
        let job = upsert(owner: owner, storyId: storyId, context: context)
        job.dirty = true; job.updatedAt = .now
        try? context.save()
        schedulePush(storyId: storyId, context: context, owner: owner, token: token)
    }

    private func schedulePush(storyId: UUID, context: ModelContext, owner: String,
                              token: @escaping () async -> String?) {
        debounce[storyId]?.cancel()
        debounce[storyId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanos ?? 0)
            if Task.isCancelled { return }
            await self?.pushIfDirty(storyId: storyId, context: context, owner: owner, token: token)
        }
    }

    // MARK: - push

    /// Push a dirty Story at its base_revision with a stable mutation_id. Same-payload retry is idempotent
    /// (the server returns committed). A genuine 409 records a conflict (never discards local). Offline/errors
    /// leave it dirty for the next trigger (persistent retry).
    func pushIfDirty(storyId: UUID, context: ModelContext, owner: String,
                     token: @escaping () async -> String?) async {
        guard let story = fetchStory(storyId, context: context) else { return }
        // Owner guard: only sync a Story this account owns; never under another account's token (rule 6/7).
        guard story.ownerAccountId == owner else { return }
        let job = upsert(owner: owner, storyId: storyId, context: context)
        if job.inConflict { return }                     // wait for the user to resolve before pushing again
        let doc = StoryDocCodec.encode(story: story)
        let hash = StoryDocCodec.contentHash(doc)
        if !job.dirty && hash == job.lastSyncedHash { return }   // nothing changed
        // Stable mutation_id for THIS attempt: reuse the pending one so a lost-response retry is idempotent;
        // mint a new one only when the content changed since the pending attempt.
        let mutationId: String
        if let pending = job.pendingMutationId, hash == job.lastAttemptHash { mutationId = pending }
        else { mutationId = UUID().uuidString; job.pendingMutationId = mutationId; job.lastAttemptHash = hash }
        job.attempts += 1; try? context.save()

        guard let accessToken = await token() else { return }   // offline/signed-out: stays dirty, retry later
        let gen = job.claimGeneration
        let refs = StoryDocCodec.referencedCloudMediaIds(doc)
        do {
            let res = try await service.put(accessToken: accessToken, storyId: storyId.uuidString,
                                            baseRevision: job.baseRevision, mutationId: mutationId,
                                            doc: doc, deleted: false, referencedCloudMediaIds: refs)
            // Rule 9: a stale callback (owner rebound/retry since) must not regress newer state.
            guard let j2 = fetchJob(owner: owner, storyId: storyId, context: context), j2.claimGeneration == gen else { return }
            j2.baseRevision = res.revision
            j2.lastSyncedHash = hash
            j2.pendingMutationId = nil
            // Only clear dirty if NO newer local edit happened during the request (hash still current).
            let current = StoryDocCodec.contentHash(StoryDocCodec.encode(story: story))
            j2.dirty = (current != hash)      // a newer edit while in flight keeps it dirty (rule: preserve newer)
            j2.lastError = nil; j2.updatedAt = .now
            try? context.save()
            if j2.dirty { schedulePush(storyId: storyId, context: context, owner: owner, token: token) }
        } catch StorySyncError.conflict(let sRev, let sDoc) {
            recordConflict(owner: owner, storyId: storyId, serverRevision: sRev, serverDoc: sDoc,
                           localDoc: doc, context: context)
        } catch {
            // mutationPayloadMismatch / tooLarge / transport: stay dirty, surface the error, retry next trigger.
            if let j2 = fetchJob(owner: owner, storyId: storyId, context: context), j2.claimGeneration == gen {
                j2.lastError = (error as? StorySyncError)?.errorDescription ?? "\(error)"; try? context.save()
            }
        }
    }

    // MARK: - pull

    /// Push EVERY owned Story whose current doc-hash differs from its last-synced hash (the hash-diff catches
    /// edits even if no per-site touch fired — the Phase-0 dirty-trigger safety net). Called on foreground/
    /// sign-in alongside pull. Owner-scoped; idempotent.
    func syncAllDirty(context: ModelContext, activeOwner: String?, token: @escaping () async -> String?) async {
        guard let owner = activeOwner else { return }
        let stories = (try? context.fetch(FetchDescriptor<StoryModel>())) ?? []
        for s in stories where s.ownerAccountId == owner {
            let job = upsert(owner: owner, storyId: s.id, context: context)
            if job.inConflict { continue }
            let hash = StoryDocCodec.contentHash(StoryDocCodec.encode(story: s))
            if hash != job.lastSyncedHash { job.dirty = true }
            if job.dirty {
                await pushIfDirty(storyId: s.id, context: context, owner: owner, token: token)
            }
        }
        try? context.save()
    }

    /// Pull the account's Story index and apply CLEAN, newer documents. Dirty records are never clobbered
    /// (a newer server revision on a dirty record becomes a conflict). Never triggers AI planning/rendering.
    func pull(context: ModelContext, activeOwner: String?, token: @escaping () async -> String?) async {
        guard let owner = activeOwner, let accessToken = await token() else { return }
        let entries: [StoryIndexEntry]
        do { entries = try await service.index(accessToken: accessToken) }
        catch { return }   // best-effort
        for e in entries {
            guard let sid = UUID(uuidString: e.storyId) else { continue }
            let job = upsert(owner: owner, storyId: sid, context: context)
            if e.revision <= job.baseRevision && !e.deleted { continue }   // we already have it
            if job.dirty || job.inConflict {
                // Rule 8: never overwrite a dirty draft. If the server is genuinely newer, raise a conflict.
                if e.revision > job.baseRevision {
                    do {
                        let srv = try await service.get(accessToken: accessToken, storyId: e.storyId)
                        if let story = fetchStory(sid, context: context) {
                            let localDoc = StoryDocCodec.encode(story: story)
                            recordConflict(owner: owner, storyId: sid, serverRevision: srv.revision,
                                           serverDoc: srv.doc, localDoc: localDoc, context: context)
                        }
                    } catch { /* leave dirty; retry later */ }
                }
                continue
            }
            // CLEAN local record -> adopt the server version.
            do {
                let srv = try await service.get(accessToken: accessToken, storyId: e.storyId)
                guard j_ownerStable(owner: owner, storyId: sid, context: context) else { continue }  // account switch guard
                try apply(doc: srv.doc, deleted: srv.deleted, owner: owner, storyId: sid, context: context)
                job.baseRevision = srv.revision
                job.lastSyncedHash = StoryDocCodec.contentHash(srv.doc)
                job.dirty = false; job.updatedAt = .now
                try? context.save()
            } catch StoryDocError.unsupportedSchema { continue }   // explicit skip; never best-effort decode
            catch { continue }
        }
    }

    // MARK: - conflict recovery (C1 / Phase 4)

    /// Keep Both Stories: clone the local conflicting draft as a NEW Story (new id, "… (copy)"), then adopt the
    /// server version for the original. Both creative histories preserved. (Clone is a NEW Story — NEVER called
    /// "another version".)
    func resolveKeepBoth(storyId: UUID, context: ModelContext, owner: String,
                         token: @escaping () async -> String?) async {
        guard let job = fetchJob(owner: owner, storyId: storyId, context: context), job.inConflict,
              let story = fetchStory(storyId, context: context) else { return }
        _ = cloneStoryAsNew(story, context: context, owner: owner)    // preserve local draft as a separate Story
        // Adopt the server doc for the original.
        if let sDocJSON = job.conflictServerDocJSON,
           let sDoc = (try? JSONSerialization.jsonObject(with: Data(sDocJSON.utf8))) as? [String: Any] {
            try? apply(doc: sDoc, deleted: false, owner: owner, storyId: storyId, context: context)
            job.baseRevision = job.conflictServerRevision
            job.lastSyncedHash = StoryDocCodec.contentHash(sDoc)
        }
        clearConflict(job); job.dirty = false; try? context.save()
        // The clone is a brand-new Story -> it will be pushed on its own next trigger.
    }

    /// Use Cloud Version: adopt the server document, but preserve the local draft FIRST (as a Keep-Both clone)
    /// so no creative history is lost (owner: never silent discard).
    func resolveUseCloud(storyId: UUID, context: ModelContext, owner: String,
                         token: @escaping () async -> String?) async {
        await resolveKeepBoth(storyId: storyId, context: context, owner: owner, token: token)
        // (Same effect for beta: the local draft is preserved as a clone and the server version adopted for the
        // original id. The distinction from Keep Both is UX framing; both preserve the draft before adopting.)
    }

    // MARK: - helpers

    private func recordConflict(owner: String, storyId: UUID, serverRevision: Int, serverDoc: [String: Any],
                                localDoc: [String: Any], context: ModelContext) {
        guard let job = fetchJob(owner: owner, storyId: storyId, context: context) else { return }
        job.inConflict = true
        job.conflictServerRevision = serverRevision
        job.conflictServerDocJSON = jsonString(serverDoc)
        job.conflictLocalDraftJSON = jsonString(localDoc)   // never discarded
        job.pendingMutationId = nil
        job.updatedAt = .now
        try? context.save()
    }

    private func clearConflict(_ job: StorySyncJobModel) {
        job.inConflict = false; job.conflictServerDocJSON = nil; job.conflictLocalDraftJSON = nil
        job.conflictServerRevision = 0
    }

    private func upsert(owner: String, storyId: UUID, context: ModelContext) -> StorySyncJobModel {
        if let j = fetchJob(owner: owner, storyId: storyId, context: context) { return j }
        let j = StorySyncJobModel(ownerAccountId: owner, storyId: storyId)
        context.insert(j); return j
    }

    private func fetchJob(owner: String, storyId: UUID, context: ModelContext) -> StorySyncJobModel? {
        let key = StorySyncJobModel.makeKey(ownerAccountId: owner, storyId: storyId)
        return (try? context.fetch(FetchDescriptor<StorySyncJobModel>(predicate: #Predicate { $0.key == key })))?.first
    }

    private func fetchStory(_ id: UUID, context: ModelContext) -> StoryModel? {
        (try? context.fetch(FetchDescriptor<StoryModel>(predicate: #Predicate { $0.id == id })))?.first
    }

    /// The Story must still be owned by `owner` (account-switch guard for the clean-apply path).
    private func j_ownerStable(owner: String, storyId: UUID, context: ModelContext) -> Bool {
        guard let s = fetchStory(storyId, context: context) else { return true }  // creating a new shell is fine
        return s.ownerAccountId == nil || s.ownerAccountId == owner
    }

    private func jsonString(_ obj: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

// MARK: - SwiftData decode bridge (apply a pulled story_doc/1 into local SwiftData)

extension StorySyncCoordinator {
    /// Decode a story_doc/1 into SwiftData for `storyId` under `owner`. Creates the Story if absent, updates
    /// its fields + Moment links in order, and creates CLOUD-ONLY Moment SHELLS (valid R6 shape) for referenced
    /// Moments not present locally. NEVER triggers AI planning/rendering. Rejects an unsupported schema.
    func apply(doc: [String: Any], deleted: Bool, owner: String, storyId: UUID, context: ModelContext) throws {
        try StoryDocCodec.validateSchema(doc)
        let story = fetchStory(storyId, context: context) ?? {
            let s = StoryModel(id: storyId, title: "", status: .active,
                               intentRawText: "", intentTheme: "", intentTone: "", intentSummary: "")
            s.ownerAccountId = owner
            context.insert(s); return s
        }()
        guard story.ownerAccountId == nil || story.ownerAccountId == owner else { return }  // never cross-account
        story.ownerAccountId = owner
        if deleted { story.statusRaw = story.statusRaw }  // soft-delete handling is UI-level in beta; keep record

        let sd = (doc["story"] as? [String: Any]) ?? [:]
        story.title = (sd["title"] as? String) ?? story.title
        story.statusRaw = (sd["status"] as? String) ?? story.statusRaw
        if let intent = sd["intent"] as? [String: Any] {
            story.intentRawText = (intent["raw_text"] as? String) ?? story.intentRawText
            story.intentTheme = (intent["theme"] as? String) ?? story.intentTheme
            story.intentTone = (intent["tone"] as? String) ?? story.intentTone
            story.intentSummary = (intent["summary"] as? String) ?? story.intentSummary
            story.intentSubject = intent["subject"] as? String
            story.intentDesiredFeeling = (intent["desired_feeling"] as? [String]) ?? []
            story.intentStyleTags = (intent["style_tags"] as? [String]) ?? []
            story.intentEmphasis = (intent["emphasis"] as? [String]) ?? []
            story.intentConstraints = (intent["constraints"] as? [String]) ?? []
            story.intentPace = intent["pace"] as? String
            story.intentTargetDurationSeconds = (intent["target_duration_seconds"] as? NSNumber)?.doubleValue
        }
        story.soundPreferenceExplicit = sd["sound_preference_explicit"] as? String
        story.editorialMode = sd["editorial_mode"] as? String
        story.editingApproachExplicit = sd["editing_approach_explicit"] as? String
        story.creativeDirectivesJSON = sd["creative_directives_json"] as? String
        story.creativeDirectionText = sd["creative_direction_text"] as? String
        story.planOperationId = sd["plan_operation_id"] as? String
        story.planJobId = sd["plan_job_id"] as? String
        story.updatedAt = .now

        applyMomentLinks((doc["moment_refs"] as? [[String: Any]]) ?? [], to: story, owner: owner, context: context)
        try? context.save()
    }

    /// Rebuild the Story's Moment links from the doc order, creating cloud-only shells as needed.
    private func applyMomentLinks(_ refs: [[String: Any]], to story: StoryModel, owner: String,
                                  context: ModelContext) {
        // Index existing links by moment id.
        var existing: [UUID: StoryMomentLink] = [:]
        for l in story.momentLinks { if let mid = l.moment?.id { existing[mid] = l } }
        var keep: Set<UUID> = []
        for (i, ref) in refs.enumerated() {
            guard let mid = (ref["moment_id"] as? String).flatMap(UUID.init) else { continue }
            keep.insert(mid)
            let moment = fetchMoment(mid, context: context) ?? makeCloudOnlyShell(ref: ref, owner: owner, context: context)
            if let link = existing[mid] {
                link.orderIndex = i
            } else {
                let link = StoryMomentLink(story: story, moment: moment, orderIndex: i)
                context.insert(link)
            }
        }
        // Remove links the server no longer lists (ordering/membership is server-authoritative for a clean apply).
        for (mid, link) in existing where !keep.contains(mid) { context.delete(link) }
    }

    /// A cloud-only Moment SHELL with a VALID R6 shape: MomentModel + AssetModel (so moment.asset.relativePath
    /// is the install target), stable id, cloudMediaId, cloud_verified state, localAvailability=.evicted,
    /// owner stamped. R6's MediaResolver.ensureLocal restores the bytes on demand.
    private func makeCloudOnlyShell(ref: [String: Any], owner: String, context: ModelContext) -> MomentModel {
        let mid = (ref["moment_id"] as? String).flatMap(UUID.init) ?? UUID()
        let dur = (ref["duration_seconds"] as? NSNumber)?.doubleValue ?? 0
        let rel = MediaStore.shared.newRelativeVideoPath()     // reserved path; bytes arrive via R6 on restore
        let asset = AssetModel(relativePath: rel, durationSeconds: dur,
                               source: MomentSource(rawValue: (ref["source"] as? String) ?? "directed") ?? .directed)
        asset.ownerAccountId = owner
        asset.localAvailability = .evicted                     // cloud-only until restored
        if let ca = (ref["captured_at"] as? NSNumber)?.doubleValue { asset.capturedAt = Date(timeIntervalSince1970: ca) }
        let m = MomentModel(id: mid, source: asset.source, caption: ref["caption"] as? String, asset: asset)
        m.ownerAccountId = owner
        m.cloudMediaId = ref["cloud_media_id"] as? String
        m.cloudStateRaw = ((ref["cloud_verified"] as? Bool) ?? false) ? "cloud_verified" : "local_only"
        context.insert(asset); context.insert(m)
        return m
    }

    private func fetchMoment(_ id: UUID, context: ModelContext) -> MomentModel? {
        (try? context.fetch(FetchDescriptor<MomentModel>(predicate: #Predicate { $0.id == id })))?.first
    }

    /// Clone a Story as a brand-new Story (new id, "… (copy)") preserving creative state + Moment links. Used
    /// by conflict recovery to keep the local draft. NOT a generated "version".
    @discardableResult
    func cloneStoryAsNew(_ src: StoryModel, context: ModelContext, owner: String) -> StoryModel {
        let copy = StoryModel(id: UUID(), title: src.title + " (copy)", status: src.status,
                              intentRawText: src.intentRawText, intentTheme: src.intentTheme,
                              intentTone: src.intentTone, intentSummary: src.intentSummary)
        copy.ownerAccountId = owner
        copy.intentSubject = src.intentSubject
        copy.intentDesiredFeeling = src.intentDesiredFeeling; copy.intentStyleTags = src.intentStyleTags
        copy.intentEmphasis = src.intentEmphasis; copy.intentConstraints = src.intentConstraints
        copy.intentPace = src.intentPace; copy.intentTargetDurationSeconds = src.intentTargetDurationSeconds
        copy.soundPreferenceExplicit = src.soundPreferenceExplicit
        copy.editorialMode = src.editorialMode; copy.editingApproachExplicit = src.editingApproachExplicit
        copy.creativeDirectivesJSON = src.creativeDirectivesJSON
        copy.creativeDirectionText = src.creativeDirectionText
        context.insert(copy)
        // Re-link the SAME Moments (shared references; we never duplicate media).
        for l in src.momentLinks.sorted(by: { ($0.orderIndex ?? 0) < ($1.orderIndex ?? 0) }) {
            if let m = l.moment {
                context.insert(StoryMomentLink(story: copy, moment: m, orderIndex: l.orderIndex))
            }
        }
        try? context.save()
        return copy
    }
}

