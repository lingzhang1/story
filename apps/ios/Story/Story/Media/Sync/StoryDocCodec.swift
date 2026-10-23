import Foundation
import SwiftData
import CryptoKit

// R7-C — `story_doc/1` cloud mapping. Encodes a StoryModel + its relations into the account-owned cloud
// document shape the backend stores, and decodes a pulled document back into local SwiftData. PURE mapping
// logic lives in `StoryDocCodec` (dictionary <-> fields) so it is unit-testable without SwiftData; the
// SwiftData bridge (`encode(story:)` / `apply(_:into:)`) sits at the edges.
//
// INVARIANTS (owner):
//  - schema_version is "story_doc/1"; an UNSUPPORTED version is REJECTED explicitly (never best-effort decoded).
//  - NEVER carry a device-local absolute/relative file path as an authoritative cloud reference. A Moment ref
//    carries its STABLE moment_id + cloud_media_id (bytes resolve via R6); relativePath is intentionally absent.
//  - Frozen EditPlan contract is reused UNCHANGED (R7-C stores output METADATA + lineage; full edit-plan JSON
//    externalization and MP4 backup are R7-D — here outputs carry provenance + a nil cloud_media_id).

enum StoryDocError: Error, LocalizedError {
    case unsupportedSchema(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): return "Unsupported story document schema: \(v)"
        }
    }
}

enum StoryDocCodec {
    static let schemaVersion = "story_doc/1"

    // MARK: - encode (SwiftData -> cloud dict)

    @MainActor
    static func encode(story s: StoryModel) -> [String: Any] {
        var story: [String: Any] = [
            "id": s.id.uuidString,
            "title": s.title,
            "status": s.statusRaw,
            "intent": [
                "raw_text": s.intentRawText, "theme": s.intentTheme, "tone": s.intentTone,
                "summary": s.intentSummary,
                "subject": s.intentSubject as Any,
                "desired_feeling": s.intentDesiredFeeling, "style_tags": s.intentStyleTags,
                "emphasis": s.intentEmphasis, "constraints": s.intentConstraints,
                "pace": s.intentPace as Any, "target_duration_seconds": s.intentTargetDurationSeconds as Any,
            ],
            "created_at": s.createdAt.timeIntervalSince1970,
            "updated_at": s.updatedAt.timeIntervalSince1970,
        ]
        // Optional preferences / direction (only when present — keeps the doc compact + stable).
        story["sound_preference_explicit"] = s.soundPreferenceExplicit as Any
        story["editorial_mode"] = s.editorialMode as Any
        story["editing_approach_explicit"] = s.editingApproachExplicit as Any
        story["creative_directives_json"] = s.creativeDirectivesJSON as Any
        story["creative_direction_text"] = s.creativeDirectionText as Any
        story["event_context"] = s.eventContext as Any   // Guide v2.1: persistent editable event context
        story["plan_operation_id"] = s.planOperationId as Any
        story["plan_job_id"] = s.planJobId as Any

        // Moment refs in link order (NO local path — stable id + cloud ref only).
        let links = s.momentLinks.sorted {
            ($0.orderIndex ?? Int.max, $0.addedAt) < ($1.orderIndex ?? Int.max, $1.addedAt)
        }
        let momentRefs: [[String: Any]] = links.compactMap { link in
            guard let m = link.moment else { return nil }
            return [
                "moment_id": m.id.uuidString,
                "order_index": link.orderIndex as Any,
                "added_at": link.addedAt.timeIntervalSince1970,
                "caption": m.caption as Any,
                "source": m.sourceRaw,
                "cloud_media_id": m.cloudMediaId as Any,
                "cloud_verified": (m.cloudStateRaw == "cloud_verified"),
                "duration_seconds": m.asset?.durationSeconds as Any,
                "captured_at": m.asset?.capturedAt?.timeIntervalSince1970 as Any,
            ]
        }

        // GeneratedOutput ROWS — full version lineage so Device B materializes the EXACT version list (R7).
        // Each row is a version: version_id + parent_version_id + operation_type define the lineage DAG; the
        // exact validated EditPlanV2 rides in derived.output_edit_plans (verbatim, never re-planned). The
        // rendered-MP4 cloud ref is cloud_media_id + cloud_verified (R7-D). NO device-local path is carried as
        // an authoritative cloud reference — relative_file_path is a RESTORE HINT only (R6 re-mints its own).
        let outputs: [[String: Any]] = s.generatedOutputs.sorted { $0.createdAt < $1.createdAt }.map { o in
            [
                "output_id": o.id.uuidString,
                "title": o.title,
                "duration_seconds": o.durationSeconds,
                "created_at": o.createdAt.timeIntervalSince1970,
                "source_moment_ids": (o.sourceMomentIds.isEmpty ? o.momentIds : o.sourceMomentIds).map { $0.uuidString },
                "moment_ids": o.momentIds.map { $0.uuidString },
                "source_fingerprint": o.sourceFingerprint,
                "edit_plan_provenance": o.editPlanProvenance,
                // Version lineage (M-e versioning foundation).
                "version_id": o.versionId.uuidString,
                "parent_version_id": (o.parentVersionId?.uuidString as Any),
                "operation_type": o.operationType,
                // Render shape (echoed from the EditPlan/RenderResult; reproduces the Result UI without re-render).
                "output_format": o.outputFormat,
                "render_width": o.renderWidth,
                "render_height": o.renderHeight,
                "is_stale": o.isStale,
                "soundtrack_title": (o.soundtrackTitle as Any),
                // Music mix knobs + soundtrack identity (re-applied verbatim on a soundtrack-only re-render).
                "soundtrack_role": (o.soundtrackRole as Any),
                "native_audio_priority": (o.nativeAudioPriority as Any),
                "sound_preference_raw": (o.soundPreferenceRaw as Any),
                "music_asset_ref": (o.musicAssetRef as Any),
                // R7-D: the uploaded MP4's media record (nil until backed up). NEVER a local path.
                "cloud_media_id": (o.cloudMediaId as Any),
                "cloud_verified": (o.cloudVerifiedAt != nil),
            ]
        }

        var doc: [String: Any] = [
            "schema_version": schemaVersion,
            "story": story,
            "moment_refs": momentRefs,
            "outputs": outputs,
        ]
        doc["music_direction"] = NSNull()   // populated by the SwiftData bridge when a direction row exists
        return doc
    }

    /// All cloud_media_ids the doc depends on (for the PUT's referenced_cloud_media_ids — server verifies C3).
    static func referencedCloudMediaIds(_ doc: [String: Any]) -> [String] {
        var ids: [String] = []
        for r in (doc["moment_refs"] as? [[String: Any]]) ?? [] {
            if let c = r["cloud_media_id"] as? String, !c.isEmpty { ids.append(c) }
        }
        for o in (doc["outputs"] as? [[String: Any]]) ?? [] {
            if let c = o["cloud_media_id"] as? String, !c.isEmpty { ids.append(c) }
        }
        // R7 Phase 4: an externalized EditPlan is a dependency too — the server must find it verified.
        if let derived = doc["derived"] as? [String: Any],
           let plans = derived["output_edit_plans"] as? [[String: Any]] {
            for p in plans {
                if let r = p["edit_plan_ref"] as? [String: Any],
                   let c = r["cloud_media_id"] as? String, !c.isEmpty { ids.append(c) }
            }
        }
        return Array(Set(ids))
    }

    /// True if any referenced Moment is not yet cloud_verified — the caller reports incomplete backup honestly.
    static func hasIncompleteDependencies(_ doc: [String: Any]) -> Bool {
        for r in (doc["moment_refs"] as? [[String: Any]]) ?? [] {
            let verified = (r["cloud_verified"] as? Bool) ?? false
            if !verified { return true }
        }
        return false
    }

    /// Reject an unsupported schema BEFORE any decode (owner: explicit rejection, never best-effort).
    static func validateSchema(_ doc: [String: Any]) throws {
        let v = (doc["schema_version"] as? String) ?? ""
        guard v == schemaVersion || v == "story_doc/2" else { throw StoryDocError.unsupportedSchema(v) }
    }

    /// A stable content hash of the SYNCED fields, used to decide dirtiness (current vs last-synced) without
    /// instrumenting every mutation site. Order-independent via sorted JSON.
    static func contentHash(_ doc: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data()
        return sha256Hex(data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - story_doc/2 DERIVED AI-state block (R7-F)
// Carries the reusable AI caches so Device B RESTORES them instead of regenerating (target: 0 Bedrock calls).
// Inline JSON for now; a future large-blob case externalizes to S3 ai_artifact (the doc then holds a ref).
// Backward compatible: a story_doc/1 doc simply has no "derived" key and decodes as today.
extension StoryDocCodec {
    static let schemaVersion2 = "story_doc/2"

    /// The FULL story_doc/2 the client pushes: base metadata + the derived AI-state block, schema bumped to v2.
    @MainActor
    static func encodeFull(story s: StoryModel, context: ModelContext) -> [String: Any] {
        var doc = encode(story: s)
        doc["schema_version"] = schemaVersion2
        doc["derived"] = encodeDerived(story: s, context: context)
        return doc
    }

    /// Build the derived block from the Story's local AI caches. Each entry carries its provenance
    /// (fingerprints + schema/prompt version) so the receiver can reuse it only when compatible.
    @MainActor
    static func encodeDerived(story s: StoryModel, context: ModelContext) -> [String: Any] {
        var derived: [String: Any] = [:]
        let sid = s.id
        func first<T: PersistentModel>(_ type: T.Type, _ pred: Predicate<T>) -> T? {
            var d = FetchDescriptor<T>(predicate: pred); d.fetchLimit = 1
            return (try? context.fetch(d))?.first
        }
        if let g = first(StoryGuideModel.self, #Predicate { $0.storyId == sid }) {
            derived["guide"] = ["json": g.guideJSON, "schema_version": g.schemaVersion,
                                "prompt_version": g.promptVersion, "model_id": g.modelId as Any]
        }
        // Guide v2.1: user-pinned scene ids (durable user decisions; refinement-protected). Carried as a
        // simple id list keyed by the Story so pins survive cross-device sync + guide refinement.
        let pinDesc = FetchDescriptor<StoryScenePinModel>(predicate: #Predicate { $0.storyId == sid })
        let pins = ((try? context.fetch(pinDesc)) ?? []).map { $0.sceneId }
        if !pins.isEmpty { derived["scene_pins"] = pins }
        if let c = first(StoryCoverageModel.self, #Predicate { $0.storyId == sid }) {
            derived["coverage"] = ["json": c.coverageJSON, "schema_version": c.schemaVersion,
                                   "prompt_version": c.promptVersion,
                                   "source_understanding_fingerprint": c.sourceUnderstandingIdsFingerprint,
                                   "creative_intent_fingerprint": c.creativeIntentFingerprint,
                                   "guide_fingerprint": c.storyGuideFingerprint,
                                   "pending_count": c.pendingCount]
        }
        if let m = first(StoryMusicDirectionModel.self, #Predicate { $0.storyId == sid }) {
            derived["music_direction"] = ["json": m.directionJSON, "user_authored": m.userAuthored,
                                          "fingerprint": m.fingerprint]
        }
        if let p = first(MusicPlanCacheModel.self, #Predicate { $0.storyId == sid }) {
            derived["music_plan"] = ["json": p.planJSON, "input_fingerprint": p.inputFingerprint,
                                     "prompt_version": p.promptVersion]
        }
        if let d = first(DurationRecCacheModel.self, #Predicate { $0.storyId == sid }) {
            derived["duration_rec"] = ["json": d.recommendationJSON, "input_fingerprint": d.inputFingerprint,
                                       "prompt_version": d.promptVersion]
        }
        // Per-output EXACT edit plans (preserve the validated plan verbatim — never re-plan for playback).
        let outputPlans: [[String: Any]] = s.generatedOutputs.compactMap { o in
            guard let pj = o.editPlanJSON, !pj.isEmpty else { return nil }
            return ["output_id": o.id.uuidString, "edit_plan_json": pj,
                    "source_fingerprint": o.sourceFingerprint]
        }
        if !outputPlans.isEmpty { derived["output_edit_plans"] = outputPlans }
        return derived
    }

    /// Apply a pulled derived block into local SwiftData caches. REUSE-GATED by default: only write a cache
    /// when the device does not already have one. When `preferCloud` is true (called during HYDRATION on a
    /// clean record), a PROVISIONAL local cache generated during the pull-vs-view race IS overwritten with the
    /// verified cloud copy (issue 4) — EXCEPT a user-authored music direction, which is never clobbered. A
    /// genuinely dirty record never reaches here (the caller's dirty guard raises a conflict instead), so
    /// preferCloud only ever replaces provisional, non-user-authored, non-dirty AI caches. Preserves cloud
    /// provenance (fingerprints + schema/prompt version). Returns the count of caches hydrated.
    @MainActor
    @discardableResult
    static func applyDerived(_ doc: [String: Any], storyId: UUID, context: ModelContext,
                             preferCloud: Bool = false) -> Int {
        guard let derived = doc["derived"] as? [String: Any] else { return 0 }
        var n = 0
        // upsert: insert when absent; when present, overwrite via `overwrite` ONLY when preferCloud (hydration)
        // AND `allowOverwrite` is true for this cache kind. Otherwise keep the local copy (reuse-first).
        func upsert<T: PersistentModel>(_ type: T.Type, _ pred: Predicate<T>, allowOverwrite: Bool = true,
                                        make: () -> T, overwrite: (T) -> Void) {
            var d = FetchDescriptor<T>(predicate: pred); d.fetchLimit = 1
            if let existing = (try? context.fetch(d))?.first {
                if preferCloud && allowOverwrite { overwrite(existing); n += 1 }
                // else keep local if present (compatible); do not clobber
            } else { context.insert(make()); n += 1 }
        }
        let sid = storyId
        if let g = derived["guide"] as? [String: Any], let json = g["json"] as? String {
            let schema = (g["schema_version"] as? String) ?? "story_guide/1"
            upsert(StoryGuideModel.self, #Predicate { $0.storyId == sid },
                   make: { StoryGuideModel(storyId: sid, guideJSON: json, schemaVersion: schema) },
                   overwrite: { row in row.guideJSON = json; row.schemaVersion = schema; row.updatedAt = .now })
        }
        // Guide v2.1: adopt pinned scene ids (additive; a pin is a durable user decision). Insert any pin the
        // device is missing; never delete a local pin on pull (pins are user-owned and merge-additive).
        if let pins = derived["scene_pins"] as? [String] {
            for pid in pins {
                let key = "\(sid.uuidString)#\(pid)"
                var pd = FetchDescriptor<StoryScenePinModel>(predicate: #Predicate { $0.key == key }); pd.fetchLimit = 1
                if ((try? context.fetch(pd))?.first) == nil {
                    context.insert(StoryScenePinModel(storyId: sid, sceneId: pid)); n += 1
                }
            }
        }
        if let c = derived["coverage"] as? [String: Any], let json = c["json"] as? String {
            upsert(StoryCoverageModel.self, #Predicate { $0.storyId == sid },
                   make: { StoryCoverageModel(
                       storyId: sid, coverageJSON: json,
                       sourceUnderstandingIdsFingerprint: (c["source_understanding_fingerprint"] as? String) ?? "",
                       creativeIntentFingerprint: (c["creative_intent_fingerprint"] as? String) ?? "",
                       pendingCount: (c["pending_count"] as? Int) ?? 0,
                       storyGuideFingerprint: (c["guide_fingerprint"] as? String) ?? "",
                       schemaVersion: (c["schema_version"] as? String) ?? "story_coverage/2",
                       modelId: nil, promptVersion: (c["prompt_version"] as? String) ?? "story_coverage/v2") },
                   overwrite: { row in
                       row.coverageJSON = json
                       row.sourceUnderstandingIdsFingerprint = (c["source_understanding_fingerprint"] as? String) ?? row.sourceUnderstandingIdsFingerprint
                       row.creativeIntentFingerprint = (c["creative_intent_fingerprint"] as? String) ?? row.creativeIntentFingerprint
                       row.storyGuideFingerprint = (c["guide_fingerprint"] as? String) ?? row.storyGuideFingerprint
                       row.pendingCount = (c["pending_count"] as? Int) ?? row.pendingCount
                   })
        }
        if let m = derived["music_direction"] as? [String: Any], let json = m["json"] as? String {
            // Never clobber a LOCAL user-authored direction (even under preferCloud). Overwrite only a
            // non-user-authored (inferred/provisional) local direction with the cloud copy.
            let cloudAuthored = (m["user_authored"] as? Bool) ?? false
            upsert(StoryMusicDirectionModel.self, #Predicate { $0.storyId == sid },
                   make: { StoryMusicDirectionModel(storyId: sid, directionJSON: json,
                           userAuthored: cloudAuthored,
                           fingerprint: (m["fingerprint"] as? String) ?? "") },
                   overwrite: { row in
                       guard !row.userAuthored else { return }   // protect the user's own choice
                       row.directionJSON = json
                       row.userAuthored = cloudAuthored
                       row.fingerprint = (m["fingerprint"] as? String) ?? row.fingerprint
                   })
        }
        if let p = derived["music_plan"] as? [String: Any], let json = p["json"] as? String {
            upsert(MusicPlanCacheModel.self, #Predicate { $0.storyId == sid },
                   make: { MusicPlanCacheModel(storyId: sid, planJSON: json,
                           inputFingerprint: (p["input_fingerprint"] as? String) ?? "") },
                   overwrite: { row in row.planJSON = json
                       row.inputFingerprint = (p["input_fingerprint"] as? String) ?? row.inputFingerprint })
        }
        if let dr = derived["duration_rec"] as? [String: Any], let json = dr["json"] as? String {
            upsert(DurationRecCacheModel.self, #Predicate { $0.storyId == sid },
                   make: { DurationRecCacheModel(storyId: sid, recommendationJSON: json,
                           inputFingerprint: (dr["input_fingerprint"] as? String) ?? "") },
                   overwrite: { row in row.recommendationJSON = json
                       row.inputFingerprint = (dr["input_fingerprint"] as? String) ?? row.inputFingerprint })
        }
        // Restore exact edit plans onto existing outputs (never re-plan for playback).
        if let plans = derived["output_edit_plans"] as? [[String: Any]] {
            for p in plans {
                guard let oid = (p["output_id"] as? String).flatMap(UUID.init),
                      let pj = p["edit_plan_json"] as? String else { continue }
                var d = FetchDescriptor<GeneratedOutputModel>(predicate: #Predicate { $0.id == oid }); d.fetchLimit = 1
                if let o = (try? context.fetch(d))?.first, (o.editPlanJSON ?? "").isEmpty {
                    o.editPlanJSON = pj; n += 1
                }
            }
        }
        try? context.save()
        return n
    }

    /// Materialize the Story's GeneratedOutput VERSION ROWS from a pulled doc (R7). This is the decode half the
    /// earlier R7-C landed WITHOUT: `apply()` restored the Story + Moments, but NOTHING created the output rows,
    /// so Device B saw zero versions and "Create my Story" started a fresh Story. Here each `outputs[]` entry
    /// becomes (or updates) a GeneratedOutputModel keyed by its STABLE output_id — idempotent, so repeated pulls
    /// never duplicate a version (rule 12). Full lineage is preserved (version_id / parent_version_id /
    /// operation_type), the rendered-MP4 cloud ref is restored (cloud_media_id + cloud_verified -> R6 restores
    /// bytes on play; NEVER re-rendered), and the exact EditPlanV2 is filled from derived.output_edit_plans.
    /// NEVER triggers AI planning/rendering. `relative_file_path` from the cloud is a RESTORE HINT only and is
    /// NOT adopted as authoritative — the local bytes are proven by R6 (size + sha256) before playback.
    ///
    /// Returns the number of output rows CREATED (new versions materialized on this device).
    @MainActor
    @discardableResult
    static func applyOutputs(_ doc: [String: Any], storyId: UUID, context: ModelContext) -> Int {
        guard let outputs = doc["outputs"] as? [[String: Any]] else { return 0 }
        // The owning Story must exist (apply() inserts it before calling this).
        var sd = FetchDescriptor<StoryModel>(predicate: #Predicate { $0.id == storyId }); sd.fetchLimit = 1
        guard let story = (try? context.fetch(sd))?.first else { return 0 }
        let owner = story.ownerAccountId
        // Exact edit plans keyed by output_id (restored verbatim onto the row — never re-planned).
        var planByOutput: [UUID: String] = [:]
        if let derived = doc["derived"] as? [String: Any],
           let plans = derived["output_edit_plans"] as? [[String: Any]] {
            for p in plans {
                if let oid = (p["output_id"] as? String).flatMap(UUID.init),
                   let pj = p["edit_plan_json"] as? String, !pj.isEmpty { planByOutput[oid] = pj }
            }
        }
        var created = 0
        for ref in outputs {
            guard let oid = (ref["output_id"] as? String).flatMap(UUID.init) else { continue }
            func uuids(_ key: String) -> [UUID] {
                ((ref[key] as? [String]) ?? []).compactMap(UUID.init)
            }
            let momentIds = uuids("moment_ids")
            let sourceMomentIds = uuids("source_moment_ids")
            let versionId = (ref["version_id"] as? String).flatMap(UUID.init) ?? oid
            let parentVersionId = (ref["parent_version_id"] as? String).flatMap(UUID.init)
            let operationType = (ref["operation_type"] as? String) ?? "original"
            let editPlanJSON = planByOutput[oid]

            var od = FetchDescriptor<GeneratedOutputModel>(predicate: #Predicate { $0.id == oid }); od.fetchLimit = 1
            if let existing = (try? context.fetch(od))?.first {
                // UPDATE in place (idempotent re-pull): never duplicate, never regress a locally-present plan or
                // a locally-verified cloud ref. Lineage + cloud metadata are server-authoritative on a clean row.
                existing.story = existing.story ?? story
                if existing.ownerAccountId == nil { existing.ownerAccountId = owner }
                existing.title = (ref["title"] as? String) ?? existing.title
                existing.durationSeconds = (ref["duration_seconds"] as? NSNumber)?.doubleValue ?? existing.durationSeconds
                if existing.sourceMomentIds.isEmpty { existing.sourceMomentIds = sourceMomentIds }
                if existing.momentIds.isEmpty { existing.momentIds = momentIds }
                existing.sourceFingerprint = (ref["source_fingerprint"] as? String) ?? existing.sourceFingerprint
                existing.editPlanProvenance = (ref["edit_plan_provenance"] as? String) ?? existing.editPlanProvenance
                existing.versionId = versionId
                existing.parentVersionId = parentVersionId ?? existing.parentVersionId
                existing.operationType = operationType
                existing.outputFormat = (ref["output_format"] as? String) ?? existing.outputFormat
                existing.renderWidth = (ref["render_width"] as? NSNumber)?.doubleValue ?? existing.renderWidth
                existing.renderHeight = (ref["render_height"] as? NSNumber)?.doubleValue ?? existing.renderHeight
                existing.isStale = (ref["is_stale"] as? Bool) ?? existing.isStale
                existing.soundtrackTitle = (ref["soundtrack_title"] as? String) ?? existing.soundtrackTitle
                existing.soundtrackRole = (ref["soundtrack_role"] as? String) ?? existing.soundtrackRole
                existing.nativeAudioPriority = (ref["native_audio_priority"] as? String) ?? existing.nativeAudioPriority
                existing.soundPreferenceRaw = (ref["sound_preference_raw"] as? String) ?? existing.soundPreferenceRaw
                existing.musicAssetRef = (ref["music_asset_ref"] as? String) ?? existing.musicAssetRef
                // Cloud MP4 ref: adopt from the server only when the local row has none (don't drop a locally
                // verified ref). cloud_verified timestamp is advisory — R6 re-proves bytes before playback.
                if existing.cloudMediaId == nil, let cmid = ref["cloud_media_id"] as? String, !cmid.isEmpty {
                    existing.cloudMediaId = cmid
                    if (ref["cloud_verified"] as? Bool) ?? false, existing.cloudVerifiedAt == nil {
                        existing.cloudVerifiedAt = .now
                    }
                }
                if (existing.editPlanJSON ?? "").isEmpty, let pj = editPlanJSON { existing.editPlanJSON = pj }
            } else {
                // CREATE the version row (the missing decode path). relative_file_path is intentionally NOT set
                // from the cloud — the bytes are cloud-only until R6 restores+verifies and mints the local path.
                let o = GeneratedOutputModel(
                    id: oid,
                    title: (ref["title"] as? String) ?? "",
                    durationSeconds: (ref["duration_seconds"] as? NSNumber)?.doubleValue ?? 0,
                    momentIds: momentIds,
                    relativeFilePath: nil,
                    sourceMomentIds: sourceMomentIds,
                    sourceFingerprint: (ref["source_fingerprint"] as? String) ?? "",
                    editPlanProvenance: (ref["edit_plan_provenance"] as? String) ?? "",
                    outputFormat: (ref["output_format"] as? String) ?? "vertical",
                    renderWidth: (ref["render_width"] as? NSNumber)?.doubleValue ?? 0,
                    renderHeight: (ref["render_height"] as? NSNumber)?.doubleValue ?? 0,
                    isStale: (ref["is_stale"] as? Bool) ?? false,
                    soundtrackTitle: ref["soundtrack_title"] as? String,
                    versionId: versionId,
                    parentVersionId: parentVersionId,
                    operationType: operationType,
                    editPlanJSON: editPlanJSON,
                    soundtrackRole: ref["soundtrack_role"] as? String,
                    nativeAudioPriority: ref["native_audio_priority"] as? String,
                    soundPreferenceRaw: ref["sound_preference_raw"] as? String,
                    musicAssetRef: ref["music_asset_ref"] as? String,
                    createdAt: (ref["created_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .now)
                o.story = story
                o.ownerAccountId = owner
                if let cmid = ref["cloud_media_id"] as? String, !cmid.isEmpty {
                    o.cloudMediaId = cmid
                    if (ref["cloud_verified"] as? Bool) ?? false { o.cloudVerifiedAt = .now }
                }
                context.insert(o)
                created += 1
            }
        }
        try? context.save()
        return created
    }
}


// MARK: - story_doc/2 Phase 4 — ai_artifact externalization (pure doc transforms)
// Keeps the codec free of network I/O: these helpers DECIDE what to externalize and rewrite the doc; the
// StorySyncCoordinator performs the actual upload/download via AIArtifactStore and feeds the results back.
extension StoryDocCodec {
    /// The server's hard ceiling; we externalize before reaching it (leave headroom for metadata growth).
    static let docSizeHardLimit = 350_000
    static let docSizeBudget = 300_000          // externalize when the serialized doc exceeds this
    static let planExternalizeMinBytes = 8_000  // only a plan at least this large is worth externalizing

    /// Serialized size of a doc in bytes (sorted keys = stable, matches contentHash serialization).
    static func serializedSize(_ doc: [String: Any]) -> Int {
        ((try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data()).count
    }

    /// One plan that must be externalized: its output_id + the exact JSON to upload. Returned to the
    /// coordinator, which uploads each and calls `applyExternalizedRefs` with the resulting references.
    struct PlanToExternalize: Equatable {
        let outputId: String
        let json: String
        let schemaVersion: String
    }

    /// If `doc` exceeds the size budget, pick the LARGEST inline edit plans to externalize until the doc fits
    /// (or no further candidates remain). Returns the plans whose bytes must be uploaded. Does NOT mutate the
    /// doc — the coordinator uploads these, then calls `applyExternalizedRefs` to rewrite the doc. Returns [] when
    /// the doc already fits or there is nothing worth externalizing (never truncates / caps versions).
    static func plansToExternalize(_ doc: [String: Any]) -> [PlanToExternalize] {
        guard serializedSize(doc) > docSizeBudget else { return [] }
        guard let derived = doc["derived"] as? [String: Any],
              let plans = derived["output_edit_plans"] as? [[String: Any]] else { return [] }
        // Candidates: still-inline plans, largest first.
        let candidates: [(oid: String, json: String, size: Int, schema: String)] = plans.compactMap { p in
            guard let oid = p["output_id"] as? String,
                  let json = p["edit_plan_json"] as? String, !json.isEmpty else { return nil }
            let size = json.utf8.count
            guard size >= planExternalizeMinBytes else { return nil }
            let schema = (p["edit_plan_schema_version"] as? String) ?? "edit_plan/2"
            return (oid, json, size, schema)
        }.sorted { $0.size > $1.size }

        var out: [PlanToExternalize] = []
        var projected = serializedSize(doc)
        for c in candidates {
            if projected <= docSizeBudget { break }
            out.append(PlanToExternalize(outputId: c.oid, json: c.json, schemaVersion: c.schema))
            // Replacing inline JSON (size) with a compact ref (~160 bytes) shrinks the doc by roughly `size`.
            projected -= max(0, c.size - 200)
        }
        return out
    }

    /// Rewrite `doc`, replacing each externalized plan's inline `edit_plan_json` with a durable `edit_plan_ref`
    /// (keyed by output_id). Version history is preserved — the entry stays, only its payload moves to S3.
    static func applyExternalizedRefs(_ doc: [String: Any], refs: [String: AIArtifactRef]) -> [String: Any] {
        guard !refs.isEmpty, var derived = doc["derived"] as? [String: Any],
              var plans = derived["output_edit_plans"] as? [[String: Any]] else { return doc }
        for i in plans.indices {
            guard let oid = plans[i]["output_id"] as? String, let ref = refs[oid] else { continue }
            plans[i].removeValue(forKey: "edit_plan_json")   // bytes now live in S3
            plans[i]["edit_plan_ref"] = ref.asDict
        }
        derived["output_edit_plans"] = plans
        var d = doc; d["derived"] = derived
        return d
    }

    /// Every externalized reference in a pulled doc that must be resolved before decode. Empty for an inline
    /// (fully self-contained) doc — the common case — so the pull path pays nothing extra.
    static func externalizedRefs(_ doc: [String: Any]) -> [(outputId: String, ref: AIArtifactRef)] {
        guard let derived = doc["derived"] as? [String: Any],
              let plans = derived["output_edit_plans"] as? [[String: Any]] else { return [] }
        return plans.compactMap { p in
            guard let oid = p["output_id"] as? String,
                  let rd = p["edit_plan_ref"] as? [String: Any], let ref = AIArtifactRef(rd) else { return nil }
            return (oid, ref)
        }
    }

    /// Inline resolved plan JSON back into the doc (replacing `edit_plan_ref` with `edit_plan_json`) so the
    /// existing decode path (applyOutputs / applyDerived) consumes it unchanged. The coordinator resolves every
    /// ref FIRST and only calls this when ALL are present — a missing ref is an explicit decode failure
    /// upstream, never a silently dropped version.
    static func inlineResolvedPlans(_ doc: [String: Any], resolved: [String: String]) -> [String: Any] {
        guard var derived = doc["derived"] as? [String: Any],
              var plans = derived["output_edit_plans"] as? [[String: Any]] else { return doc }
        for i in plans.indices {
            guard let oid = plans[i]["output_id"] as? String, let json = resolved[oid] else { continue }
            plans[i].removeValue(forKey: "edit_plan_ref")
            plans[i]["edit_plan_json"] = json
        }
        derived["output_edit_plans"] = plans
        var d = doc; d["derived"] = derived
        return d
    }
}
