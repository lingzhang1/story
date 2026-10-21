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
    private let artifacts: AIArtifactStore
    private var debounce: [UUID: Task<Void, Never>] = [:]   // per-story debounce tasks
    private let debounceNanos: UInt64 = 2_500_000_000       // ~2.5s

    init(service: StorySyncing = StorySyncService(), artifacts: AIArtifactStore = AIArtifactStore()) {
        self.service = service
        self.artifacts = artifacts
    }

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
        let doc = StoryDocCodec.encodeFull(story: story, context: context)
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
        // R7 Phase 4: if the serialized doc would exceed the server's 350 KB ceiling, externalize the largest
        // inline EditPlans to S3 (ai_artifact) and carry durable refs instead — version history is preserved,
        // never capped/truncated. Proactive (before the PUT) so a known-large doc never wastes a round-trip; a
        // 413 below is the belt-and-braces safety net. An externalize failure leaves the doc dirty for retry
        // rather than pushing a doc that will 413 (never drops a version).
        var outDoc = doc
        let toExternalize = StoryDocCodec.plansToExternalize(doc)
        if !toExternalize.isEmpty {
            do {
                var refs: [String: AIArtifactRef] = [:]
                for plan in toExternalize {
                    refs[plan.outputId] = try await artifacts.externalize(
                        json: plan.json, accessToken: accessToken,
                        sourceOutputId: plan.outputId, schemaVersion: plan.schemaVersion)
                }
                outDoc = StoryDocCodec.applyExternalizedRefs(doc, refs: refs)
            } catch {
                if let j2 = fetchJob(owner: owner, storyId: storyId, context: context), j2.claimGeneration == gen {
                    j2.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"; try? context.save()
                }
                return   // stay dirty; retry on the next trigger
            }
        }
        let refs = StoryDocCodec.referencedCloudMediaIds(outDoc)
        do {
            let res = try await service.put(accessToken: accessToken, storyId: storyId.uuidString,
                                            baseRevision: job.baseRevision, mutationId: mutationId,
                                            doc: outDoc, deleted: false, referencedCloudMediaIds: refs)
            // Rule 9: a stale callback (owner rebound/retry since) must not regress newer state.
            guard let j2 = fetchJob(owner: owner, storyId: storyId, context: context), j2.claimGeneration == gen else { return }
            j2.baseRevision = res.revision
            j2.lastSyncedHash = hash
            j2.pendingMutationId = nil
            // Only clear dirty if NO newer local edit happened during the request (hash still current).
            let current = StoryDocCodec.contentHash(StoryDocCodec.encodeFull(story: story, context: context))
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
            let hash = StoryDocCodec.contentHash(StoryDocCodec.encodeFull(story: s, context: context))
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
                            let localDoc = StoryDocCodec.encodeFull(story: story, context: context)
                            recordConflict(owner: owner, storyId: sid, serverRevision: srv.revision,
                                           serverDoc: srv.doc, localDoc: localDoc, context: context)
                        }
                    } catch { /* leave dirty; retry later */ }
                }
                continue
            }
            // CLEAN local record -> adopt the server version.
            // Issue 4: mark hydration PENDING (durable) + begin the gate BEFORE the network GET, so a view that
            // opens while this pull is in flight (or a relaunch mid-pull) holds AU/Guide/Coverage/Music until
            // the restore lands. The flag is seeded into CloudHydrationGate.seedFromDurable on the view side.
            job.hydrationPending = true
            job.cloudRevisionSeen = e.revision
            try? context.save()
            // Seed the in-memory barrier for this Story + its already-known local Moments immediately.
            CloudHydrationGate.shared.beginStory(sid, moments: currentMomentIds(sid, context: context))
            do {
                let srv = try await service.get(accessToken: accessToken, storyId: e.storyId)
                guard j_ownerStable(owner: owner, storyId: sid, context: context) else {
                    CloudHydrationGate.shared.endStory(sid, moments: currentMomentIds(sid, context: context))
                    clearHydrationPending(owner: owner, storyId: sid, context: context)
                    continue
                }  // account switch guard (rule 11)
                // R7-F: hold AU/Guide/Coverage/Music inference for this Story + its moments until hydration
                // completes (restore first, regenerate only if genuinely missing).
                let momentIds: [UUID] = ((srv.doc["moment_refs"] as? [[String: Any]]) ?? [])
                    .compactMap { ($0["moment_id"] as? String).flatMap(UUID.init) }
                CloudHydrationGate.shared.beginStory(sid, moments: momentIds)
                // R7 Phase 4: resolve any externalized EditPlans (edit_plan_ref -> verified JSON) BEFORE decode,
                // then inline them so applyOutputs/applyDerived consume them unchanged. A ref that cannot be
                // restored THROWS (caught by the retry catch below) — the version is never silently dropped and
                // the doc is never decoded with a missing plan.
                let srvDoc = try await resolveExternalized(srv.doc, accessToken: accessToken)
                try apply(doc: srvDoc, deleted: srv.deleted, owner: owner, storyId: sid, context: context)
                // R7: materialize the GeneratedOutput VERSION ROWS from the doc BEFORE applyDerived, so the
                // exact per-output EditPlans in `derived.output_edit_plans` attach to rows that now exist. This
                // is the decode half R7-C omitted — without it Device B has zero versions. Idempotent by
                // output_id (no duplicates on re-pull). Never re-renders; R6 restores MP4 bytes on play.
                StoryDocCodec.applyOutputs(srvDoc, storyId: sid, context: context)
                // Restore derived AI caches (Guide/Coverage/Music/plans), PREFERRING the cloud copy over a
                // provisional local one generated during the race (issue 4 §8). A user-authored music direction
                // and genuinely dirty records are never clobbered (enforced inside applyDerived + the dirty
                // guard above).
                StoryDocCodec.applyDerived(srvDoc, storyId: sid, context: context, preferCloud: true)
                // Restore Moment Understanding from the account-level store (so AU is not re-run on B).
                _ = await UnderstandingSync.shared.restore(momentIds: momentIds, context: context,
                                                           activeOwner: owner, token: token)
                job.baseRevision = srv.revision
                job.lastSyncedHash = StoryDocCodec.contentHash(srv.doc)
                job.dirty = false; job.updatedAt = .now
                // Hydration of this revision COMPLETE — clear the durable barrier and release the gate.
                job.hydrationPending = false
                try? context.save()
                CloudHydrationGate.shared.endStory(sid, moments: momentIds)
            } catch StoryDocError.unsupportedSchema {
                // Explicit skip; never best-effort decode. Release the barrier (do NOT leave it pending forever,
                // which would permanently block regeneration — issue 4 §12).
                CloudHydrationGate.shared.endStory(sid, moments: currentMomentIds(sid, context: context))
                clearHydrationPending(owner: owner, storyId: sid, context: context)
                continue
            }
            catch {
                // Offline / transport failure: hydration did NOT complete. Release the in-memory gate so the
                // app is usable, but LEAVE hydrationPending durable so the NEXT pull retries the restore before
                // any regeneration — a hydration timeout must not auto-trigger expensive inference (§12). The
                // view-side seeder re-holds from the durable flag on the next appearance.
                CloudHydrationGate.shared.endStory(sid, moments: currentMomentIds(sid, context: context))
                continue
            }
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
           let sDoc0 = (try? JSONSerialization.jsonObject(with: Data(sDocJSON.utf8))) as? [String: Any] {
            // R7 Phase 4: resolve externalized EditPlans before adopting; if an artifact cannot be restored,
            // ABORT the adopt (leave the conflict unresolved for retry) rather than adopt a doc missing a plan.
            var sDoc = sDoc0
            if !StoryDocCodec.externalizedRefs(sDoc0).isEmpty {
                guard let accessToken = await token(),
                      let resolved = try? await resolveExternalized(sDoc0, accessToken: accessToken) else {
                    return   // keep the conflict; the user can retry Keep Both / Use Cloud when back online
                }
                sDoc = resolved
            }
            try? apply(doc: sDoc, deleted: false, owner: owner, storyId: storyId, context: context)
            // Adopt the server's version rows + derived AI caches too (same as a clean pull) so the adopted
            // Story shows its versions/guide/coverage and never re-renders. Idempotent by output_id.
            StoryDocCodec.applyOutputs(sDoc, storyId: storyId, context: context)
            StoryDocCodec.applyDerived(sDoc, storyId: storyId, context: context, preferCloud: true)
            job.baseRevision = job.conflictServerRevision
            job.lastSyncedHash = StoryDocCodec.contentHash(sDoc0)   // hash the WIRE doc (what the server holds)
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

    /// R7 Phase 4: resolve every externalized EditPlan ref in a pulled doc to verified JSON and inline it, so
    /// the decode path consumes a fully self-contained doc. A doc with no refs (the common case) returns
    /// unchanged with zero network cost. THROWS if any referenced artifact cannot be restored — the caller
    /// treats that as a retryable hydration failure (version history is never decoded with a missing plan).
    private func resolveExternalized(_ doc: [String: Any], accessToken: String) async throws -> [String: Any] {
        let refs = StoryDocCodec.externalizedRefs(doc)
        if refs.isEmpty { return doc }
        var resolved: [String: String] = [:]
        for (oid, ref) in refs {
            resolved[oid] = try await artifacts.resolve(ref, accessToken: accessToken)
        }
        return StoryDocCodec.inlineResolvedPlans(doc, resolved: resolved)
    }

    private func fetchStory(_ id: UUID, context: ModelContext) -> StoryModel? {
        (try? context.fetch(FetchDescriptor<StoryModel>(predicate: #Predicate { $0.id == id })))?.first
    }

    /// The Story's currently-known local Moment ids (used to hold/release the hydration gate when the server
    /// moment_refs are not yet available — e.g. before the GET, or on an error path).
    private func currentMomentIds(_ storyId: UUID, context: ModelContext) -> [UUID] {
        guard let s = fetchStory(storyId, context: context) else { return [] }
        return s.moments.map { $0.id }
    }

    /// Clear the durable hydration-pending flag for a Story (hydration finished or classified unresolvable).
    private func clearHydrationPending(owner: String, storyId: UUID, context: ModelContext) {
        guard let job = fetchJob(owner: owner, storyId: storyId, context: context) else { return }
        if job.hydrationPending { job.hydrationPending = false; try? context.save() }
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

