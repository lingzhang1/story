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
