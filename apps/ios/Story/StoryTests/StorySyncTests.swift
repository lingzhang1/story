import XCTest
import SwiftData
@testable import Story

// R7-C — Story sync tests. A fake StorySyncing stands in for the backend (holds server revision + doc per
// story), exercising the REAL coordinator push/pull/conflict/dirty logic + the story_doc/1 codec.
@MainActor
final class StorySyncTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
                 MyMusicAssetModel.self, PendingOperationModel.self,
                 MusicPlanCacheModel.self, DurationRecCacheModel.self, MediaUploadJobModel.self,
                 AutoBackupSettingModel.self, MediaDownloadJobModel.self, OptimizationSettingModel.self,
                 StorySyncJobModel.self,
            configurations: config)
    }

    // A server stub: per-story {revision, doc, lastMutationId, lastDigest}.
    final class FakeSync: StorySyncing, @unchecked Sendable {
        struct Row { var revision: Int; var doc: [String: Any]; var mut: String; var digest: String; var deleted: Bool }
        var rows: [String: Row] = [:]
        var putCount = 0
        func index(accessToken: String) async throws -> [StoryIndexEntry] {
            rows.map { StoryIndexEntry(storyId: $0.key, revision: $0.value.revision, updatedAt: 0,
                                       deleted: $0.value.deleted, incompleteDeps: false) }
        }
        func get(accessToken: String, storyId: String) async throws -> (revision: Int, doc: [String: Any], deleted: Bool) {
            guard let r = rows[storyId] else { throw StorySyncError.notFound }
            return (r.revision, r.doc, r.deleted)
        }
        func put(accessToken: String, storyId: String, baseRevision: Int, mutationId: String,
                 doc: [String: Any], deleted: Bool, referencedCloudMediaIds: [String]) async throws -> StoryPutResult {
            putCount += 1
            let digest = StoryDocCodec.contentHash(doc) + "\(baseRevision)\(deleted)"
            if let r = rows[storyId] {
                if r.revision != baseRevision {
                    if r.mut == mutationId { return StoryPutResult(revision: r.revision, deleted: r.deleted, incompleteDeps: false) } // idempotent
                    throw StorySyncError.conflict(serverRevision: r.revision, serverDoc: r.doc)
                }
            } else if baseRevision != 0 {
                throw StorySyncError.conflict(serverRevision: 0, serverDoc: [:])
            }
            let newRev = baseRevision + 1
            rows[storyId] = Row(revision: newRev, doc: doc, mut: mutationId, digest: digest, deleted: deleted)
            return StoryPutResult(revision: newRev, deleted: deleted, incompleteDeps: false)
        }
        // seed a server doc as if written by another device
        func seed(storyId: String, title: String, revision: Int) {
            rows[storyId] = Row(revision: revision,
                                doc: ["schema_version": "story_doc/1",
                                      "story": ["id": storyId, "title": title, "status": "active",
                                                "intent": ["raw_text": "", "theme": "", "tone": "", "summary": ""]],
                                      "moment_refs": [], "outputs": []],
                                mut: "seed", digest: "seed", deleted: false)
        }
    }

    private func coord(_ f: FakeSync) -> StorySyncCoordinator { StorySyncCoordinator(service: f) }

    private func makeStory(owner: String, title: String) throws -> StoryModel {
        let s = StoryModel(title: title, intentRawText: "r", intentTheme: "t", intentTone: "to", intentSummary: "s")
        s.ownerAccountId = owner
        ctx.insert(s); try ctx.save(); return s
    }

    // 1. Codec: encode carries essentials + NO local path.
    func test_codec_encodes_essentials_no_path() throws {
        let s = try makeStory(owner: "A", title: "Trip")
        let doc = StoryDocCodec.encode(story: s)
        XCTAssertEqual((doc["schema_version"] as? String), "story_doc/1")
        XCTAssertEqual(((doc["story"] as? [String: Any])?["title"] as? String), "Trip")
        // No relativePath anywhere in the serialized doc.
        let json = String(data: try JSONSerialization.data(withJSONObject: doc), encoding: .utf8)!
        XCTAssertFalse(json.contains("relativePath"))
        XCTAssertFalse(json.contains("relative_path"))
    }

    // 2. Unsupported schema is rejected explicitly.
    func test_apply_rejects_unsupported_schema() {
        let c = coord(FakeSync())
        XCTAssertThrowsError(try c.apply(doc: ["schema_version": "story_doc/99"], deleted: false,
                                         owner: "A", storyId: UUID(), context: ctx)) { e in
            guard case StoryDocError.unsupportedSchema = e else { return XCTFail("wrong error") }
        }
    }

    // 3. Dirty push creates server rev 1; a same-content re-push is idempotent (no new revision).
    func test_push_then_idempotent() async throws {
        let f = FakeSync(); let c = coord(f)
        let s = try makeStory(owner: "A", title: "Push")
        await c.pushIfDirty(storyId: s.id, context: ctx, owner: "A", token: { "tok" })
        XCTAssertEqual(f.rows[s.id.uuidString]?.revision, 1)
        let after1 = f.putCount
        // Re-push with no change -> no-op (hash == lastSyncedHash).
        await c.pushIfDirty(storyId: s.id, context: ctx, owner: "A", token: { "tok" })
        XCTAssertEqual(f.putCount, after1)   // did not even call PUT again
    }

    // 4. Clean pull applies a server doc the device lacks + creates a cloud-only Moment shell.
    func test_pull_applies_clean_and_creates_cloud_shell() async throws {
        let f = FakeSync(); let c = coord(f)
        let sid = UUID().uuidString
        let momentId = UUID().uuidString
        f.rows[sid] = FakeSync.Row(
            revision: 3,
            doc: ["schema_version": "story_doc/1",
                  "story": ["id": sid, "title": "FromCloud", "status": "active",
                            "intent": ["raw_text": "", "theme": "", "tone": "", "summary": ""]],
                  "moment_refs": [["moment_id": momentId, "order_index": 0, "added_at": 0,
                                   "cloud_media_id": "cm-1", "cloud_verified": true,
                                   "duration_seconds": 5.0, "source": "directed"]],
                  "outputs": []],
            mut: "x", digest: "x", deleted: false)
        await c.pull(context: ctx, activeOwner: "A", token: { "tok" })
        let story = (try ctx.fetch(FetchDescriptor<StoryModel>())).first { $0.id.uuidString == sid }
        XCTAssertEqual(story?.title, "FromCloud")
        // cloud-only Moment shell exists with a valid R6 shape.
        let m = (try ctx.fetch(FetchDescriptor<MomentModel>())).first { $0.id.uuidString == momentId }
        XCTAssertNotNil(m?.asset)                                  // moment<->asset relationship
        XCTAssertEqual(m?.cloudMediaId, "cm-1")
        XCTAssertEqual(m?.cloudStateRaw, "cloud_verified")
        XCTAssertEqual(m?.asset?.localAvailability, .evicted)       // cloud-only until R6 restore
        XCTAssertEqual(m?.ownerAccountId, "A")
    }

    // 5. A DIRTY local record facing a newer server revision raises a conflict and PRESERVES the draft.
    func test_dirty_pull_raises_conflict_preserves_draft() async throws {
        let f = FakeSync(); let c = coord(f)
        let s = try makeStory(owner: "A", title: "LocalDraft")
        // Make it dirty with a known job (baseRevision 1 so a server rev 2 is 'newer').
        await c.pushIfDirty(storyId: s.id, context: ctx, owner: "A", token: { "tok" })  // server rev 1, clean
        s.title = "LocalDraft EDITED"; try ctx.save()
        // mark dirty via touch's effect: set job.dirty by syncing hash-diff detection
        let keyDesc = FetchDescriptor<StorySyncJobModel>()
        let job = (try ctx.fetch(keyDesc)).first { $0.storyId == s.id }!
        job.dirty = true; try ctx.save()
        // Another device advanced the server to rev 2.
        f.rows[s.id.uuidString]?.revision = 2
        f.rows[s.id.uuidString]?.doc["story"] = ["id": s.id.uuidString, "title": "ServerWins", "status": "active",
                                                 "intent": ["raw_text": "", "theme": "", "tone": "", "summary": ""]]
        await c.pull(context: ctx, activeOwner: "A", token: { "tok" })
        let j2 = (try ctx.fetch(keyDesc)).first { $0.storyId == s.id }!
        XCTAssertTrue(j2.inConflict)
        XCTAssertNotNil(j2.conflictLocalDraftJSON)                 // local draft preserved, never discarded
        XCTAssertEqual(s.title, "LocalDraft EDITED")               // local NOT clobbered by the pull
    }

    // 6. Keep Both: clone preserves the local draft as a NEW story; original adopts the server doc.
    func test_keep_both_clones_and_adopts_server() async throws {
        let f = FakeSync(); let c = coord(f)
        let s = try makeStory(owner: "A", title: "Original")
        await c.pushIfDirty(storyId: s.id, context: ctx, owner: "A", token: { "tok" })
        // Force a conflict state.
        f.rows[s.id.uuidString]?.revision = 5
        f.rows[s.id.uuidString]?.doc["story"] = ["id": s.id.uuidString, "title": "CloudTitle", "status": "active",
                                                 "intent": ["raw_text": "", "theme": "", "tone": "", "summary": ""]]
        s.title = "LocalTitle"; try ctx.save()
        let job = (try ctx.fetch(FetchDescriptor<StorySyncJobModel>())).first { $0.storyId == s.id }!
        job.dirty = true; try ctx.save()
        await c.pull(context: ctx, activeOwner: "A", token: { "tok" })   // -> conflict
        await c.resolveKeepBoth(storyId: s.id, context: ctx, owner: "A", token: { "tok" })
        let stories = try ctx.fetch(FetchDescriptor<StoryModel>())
        XCTAssertTrue(stories.contains { $0.title == "LocalTitle (copy)" })   // draft preserved as new story
        XCTAssertEqual(stories.first { $0.id == s.id }?.title, "CloudTitle")  // original adopts server
    }

    // 7. Account isolation: a stale callback for A never mutates under B; pull scoped to active owner.
    func test_pull_owner_scoped() async throws {
        let f = FakeSync(); let c = coord(f)
        f.seed(storyId: UUID().uuidString, title: "A's cloud story", revision: 1)
        // Pull as B: B has no local story for A's id; a shell would be created under B only if B pulls it.
        await c.pull(context: ctx, activeOwner: "B", token: { "tok" })
        let stories = try ctx.fetch(FetchDescriptor<StoryModel>())
        // The created shell (if any) is owned by B, never A — no cross-account ownership.
        for s in stories { XCTAssertEqual(s.ownerAccountId, "B") }
    }
}

// R7-C fix: a restored (already-understood) Moment must NOT be re-enqueued for Asset Understanding.
extension StorySyncTests {
    func test_au_not_reenqueued_when_understanding_exists() throws {
        // A Moment with a real file + an EXISTING completed understanding.
        MediaStore.shared.ensureMediaDirectory()
        let rel = MediaStore.shared.newRelativeVideoPath()
        try Data("vid".utf8).write(to: MediaStore.shared.absoluteURL(for: rel))
        let asset = AssetModel(relativePath: rel, durationSeconds: 5, source: .directed)
        let m = MomentModel(source: .directed, asset: asset)
        ctx.insert(asset); ctx.insert(m)
        let mu = MomentUnderstandingModel(momentId: m.id, schemaVersion: "moment_understanding/1",
                                          framePolicy: "f", promptVersion: "p", modelId: nil, nFrames: nil,
                                          understandingJSON: "{}")
        ctx.insert(mu); try ctx.save()
        let q = AssetUnderstandingQueue(context: ctx)
        q.enqueue(momentId: m.id, relativeMediaPath: rel, sourceCaptureId: nil, captureContext: nil)
        // No new AU job created (already understood).
        let jobs = try ctx.fetch(FetchDescriptor<AssetUnderstandingJobModel>()).filter { $0.momentId == m.id }
        XCTAssertTrue(jobs.isEmpty, "a Moment with a completed understanding must not be re-enqueued")
        try? FileManager.default.removeItem(at: MediaStore.shared.absoluteURL(for: rel))
    }
}

// R7-F — derived AI-state round-trip + understanding restore + hydration gate.
extension StorySyncTests {
    func test_derived_block_roundtrip_guide_coverage() throws {
        let s = try makeStory(owner: "A", title: "Derived")
        ctx.insert(StoryGuideModel(storyId: s.id, guideJSON: "{\"g\":1}", schemaVersion: "story_guide/1"))
        ctx.insert(StoryCoverageModel(storyId: s.id, coverageJSON: "{\"c\":1}",
                   sourceUnderstandingIdsFingerprint: "sfp", creativeIntentFingerprint: "ifp",
                   pendingCount: 0, storyGuideFingerprint: "gfp"))
        try ctx.save()
        let doc = StoryDocCodec.encodeFull(story: s, context: ctx)
        XCTAssertEqual(doc["schema_version"] as? String, "story_doc/2")
        let derived = doc["derived"] as? [String: Any]
        XCTAssertNotNil(derived?["guide"]); XCTAssertNotNil(derived?["coverage"])
        // Wipe local caches and restore from the doc.
        for g in try ctx.fetch(FetchDescriptor<StoryGuideModel>()) { ctx.delete(g) }
        for c in try ctx.fetch(FetchDescriptor<StoryCoverageModel>()) { ctx.delete(c) }
        try ctx.save()
        let n = StoryDocCodec.applyDerived(doc, storyId: s.id, context: ctx)
        XCTAssertGreaterThanOrEqual(n, 2)
        let g2 = try ctx.fetch(FetchDescriptor<StoryGuideModel>()).first { $0.storyId == s.id }
        XCTAssertEqual(g2?.guideJSON, "{\"g\":1}")
        let c2 = try ctx.fetch(FetchDescriptor<StoryCoverageModel>()).first { $0.storyId == s.id }
        XCTAssertEqual(c2?.coverageJSON, "{\"c\":1}")
        XCTAssertEqual(c2?.sourceUnderstandingIdsFingerprint, "sfp")   // provenance preserved
    }

    func test_understanding_restore_reuse_gated_by_cloud_backing() async throws {
        // A cloud-backed Moment (cloudMediaId set) with NO local understanding -> restore should adopt it.
        let rel = MediaStore.shared.newRelativeVideoPath()
        let asset = AssetModel(relativePath: rel, durationSeconds: 5, source: .directed)
        let m = MomentModel(source: .directed, asset: asset); m.cloudMediaId = "cm-1"
        ctx.insert(asset); ctx.insert(m); try ctx.save()
        final class FakeU: UnderstandingSyncing, @unchecked Sendable {
            func batchGet(accessToken: String, momentIds: [String]) async throws -> [CloudUnderstandingRecord] {
                momentIds.map { CloudUnderstandingRecord(momentId: $0, understandingJSON: "{\"u\":1}",
                    schemaVersion: "moment_understanding/1", promptVersion: "p", framePolicy: "f",
                    contentSha256: "sha", modelId: "") }
            }
            func put(accessToken: String, records: [CloudUnderstandingRecord]) async throws {}
        }
        let sync = UnderstandingSync(service: FakeU())
        let n = await sync.restore(momentIds: [m.id], context: ctx, activeOwner: "A", token: { "tok" })
        XCTAssertEqual(n, 1)
        let mu = try ctx.fetch(FetchDescriptor<MomentUnderstandingModel>()).first { $0.momentId == m.id }
        XCTAssertNotNil(mu, "a cloud-backed Moment's understanding must restore (no re-analysis)")
        try? FileManager.default.removeItem(at: MediaStore.shared.absoluteURL(for: rel))
    }

    func test_hydration_gate_blocks_au_for_hydrating_moment() async throws {
        let gate = CloudHydrationGate.shared
        let sid = UUID(); let mid = UUID()
        gate.beginStory(sid, moments: [mid])
        XCTAssertTrue(gate.isHydrating(momentId: mid))
        XCTAssertTrue(gate.isHydrating(storyId: sid))
        gate.endStory(sid, moments: [mid])
        XCTAssertFalse(gate.isHydrating(momentId: mid))
    }

    // Issue 4 — applyDerived DEFAULT keeps a local cache (reuse-first); it never clobbers a provisional one
    // outside hydration.
    func test_applyDerived_default_keeps_local() throws {
        let s = try makeStory(owner: "A", title: "KeepLocal")
        // A local (provisional) guide already present.
        ctx.insert(StoryGuideModel(storyId: s.id, guideJSON: "{\"local\":1}", schemaVersion: "story_guide/1"))
        try ctx.save()
        let doc: [String: Any] = ["schema_version": "story_doc/2",
            "derived": ["guide": ["json": "{\"cloud\":1}", "schema_version": "story_guide/1"]]]
        _ = StoryDocCodec.applyDerived(doc, storyId: s.id, context: ctx)   // preferCloud defaults false
        let g = try ctx.fetch(FetchDescriptor<StoryGuideModel>()).first { $0.storyId == s.id }
        XCTAssertEqual(g?.guideJSON, "{\"local\":1}", "default apply must not clobber a present local cache")
    }

    // Issue 4 §9 — during HYDRATION (preferCloud), a PROVISIONAL local guide is replaced by the verified cloud
    // copy so Device B adopts A's Guide (the exact cross-device divergence bug).
    func test_applyDerived_preferCloud_overwrites_provisional() throws {
        let s = try makeStory(owner: "A", title: "PreferCloud")
        ctx.insert(StoryGuideModel(storyId: s.id, guideJSON: "{\"local\":1}", schemaVersion: "story_guide/1"))
        try ctx.save()
        let doc: [String: Any] = ["schema_version": "story_doc/2",
            "derived": ["guide": ["json": "{\"cloud\":1}", "schema_version": "story_guide/1"]]]
        _ = StoryDocCodec.applyDerived(doc, storyId: s.id, context: ctx, preferCloud: true)
        let g = try ctx.fetch(FetchDescriptor<StoryGuideModel>()).first { $0.storyId == s.id }
        XCTAssertEqual(g?.guideJSON, "{\"cloud\":1}", "hydration must adopt the verified cloud Guide")
    }

    // Issue 4 §10 — even under preferCloud, a USER-AUTHORED local music direction is never clobbered.
    func test_applyDerived_preferCloud_preserves_user_authored_music() throws {
        let s = try makeStory(owner: "A", title: "UserMusic")
        ctx.insert(StoryMusicDirectionModel(storyId: s.id, directionJSON: "{\"mine\":1}",
                                            userAuthored: true, fingerprint: "fp"))
        try ctx.save()
        let doc: [String: Any] = ["schema_version": "story_doc/2",
            "derived": ["music_direction": ["json": "{\"cloud\":1}", "user_authored": false, "fingerprint": "fp2"]]]
        _ = StoryDocCodec.applyDerived(doc, storyId: s.id, context: ctx, preferCloud: true)
        let m = try ctx.fetch(FetchDescriptor<StoryMusicDirectionModel>()).first { $0.storyId == s.id }
        XCTAssertEqual(m?.directionJSON, "{\"mine\":1}", "a user-authored direction is never overwritten")
        XCTAssertTrue(m?.userAuthored ?? false)
    }

    // Issue 4 §13 — the durable hydrationPending flag re-establishes the in-memory barrier after a view
    // recreation / relaunch (seedFromDurable), so a Story that opens before the pull completes still holds.
    func test_hydration_gate_seeds_from_durable_pending_row() throws {
        let gate = CloudHydrationGate.shared
        let s = try makeStory(owner: "A", title: "Durable")
        gate.endStory(s.id, moments: [])    // ensure not already in-memory from a prior test
        let job = StorySyncJobModel(ownerAccountId: "A", storyId: s.id)
        job.hydrationPending = true
        ctx.insert(job); try ctx.save()
        gate.seedFromDurable(context: ctx)
        XCTAssertTrue(gate.isHydrating(storyId: s.id), "a durable hydrationPending row must re-hold the barrier")
        // Clean up in-memory state for other tests.
        gate.endStory(s.id, moments: [])
    }

    // Issue 4 §12 — a Device-B clean pull marks hydrationPending durable, adopts the cloud Guide, and clears
    // the flag; NO regeneration is triggered (ensureGuide is never called here). Zero-Bedrock restore shape.
    func test_pull_hydrates_derived_and_clears_pending() async throws {
        let f = FakeSync(); let c = coord(f)
        let sid = UUID().uuidString
        f.rows[sid] = FakeSync.Row(
            revision: 2,
            doc: ["schema_version": "story_doc/2",
                  "story": ["id": sid, "title": "B-Restore", "status": "active",
                            "intent": ["raw_text": "", "theme": "", "tone": "", "summary": ""]],
                  "moment_refs": [],
                  "outputs": [],
                  "derived": ["guide": ["json": "{\"fromA\":1}", "schema_version": "story_guide/1"]]],
            mut: "x", digest: "x", deleted: false)
        await c.pull(context: ctx, activeOwner: "A", token: { "tok" })
        guard let suid = UUID(uuidString: sid) else { return XCTFail() }
        let g = try ctx.fetch(FetchDescriptor<StoryGuideModel>()).first { $0.storyId == suid }
        XCTAssertEqual(g?.guideJSON, "{\"fromA\":1}", "Device B adopts A's cloud Guide on pull")
        let job = try ctx.fetch(FetchDescriptor<StorySyncJobModel>()).first { $0.storyId == suid }
        XCTAssertEqual(job?.hydrationPending, false, "hydration flag cleared after a successful restore")
        XCTAssertFalse(CloudHydrationGate.shared.isHydrating(storyId: suid), "gate released after hydration")
    }

    // Issue 4 §7 — a DIRTY local record is NOT hydrated/overwritten by the pull (conflict path instead).
    func test_pull_does_not_hydrate_dirty_local() async throws {
        let f = FakeSync(); let c = coord(f)
        let s = try makeStory(owner: "A", title: "Dirty")
        ctx.insert(StoryGuideModel(storyId: s.id, guideJSON: "{\"local\":1}", schemaVersion: "story_guide/1"))
        try ctx.save()
        await c.pushIfDirty(storyId: s.id, context: ctx, owner: "A", token: { "tok" })   // rev 1, clean
        let job = try ctx.fetch(FetchDescriptor<StorySyncJobModel>()).first { $0.storyId == s.id }!
        job.dirty = true; try ctx.save()
        // Server advances with a different derived guide.
        f.rows[s.id.uuidString]?.revision = 2
        f.rows[s.id.uuidString]?.doc["derived"] = ["guide": ["json": "{\"cloud\":1}", "schema_version": "story_guide/1"]]
        await c.pull(context: ctx, activeOwner: "A", token: { "tok" })
        let g = try ctx.fetch(FetchDescriptor<StoryGuideModel>()).first { $0.storyId == s.id }
        XCTAssertEqual(g?.guideJSON, "{\"local\":1}", "a dirty record's local derived state is preserved")
    }
}
