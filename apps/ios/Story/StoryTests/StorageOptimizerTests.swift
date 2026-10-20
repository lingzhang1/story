import XCTest
import SwiftData
@testable import Story

// R5 — StorageOptimizer safe-eviction tests. Backed by REAL tiny files so size/eviction/fileExists are real.
@MainActor
final class StorageOptimizerTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }
    private var tmp: [URL] = []

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
            configurations: config)
    }
    override func tearDown() { for u in tmp { try? FileManager.default.removeItem(at: u) }; tmp = [] }

    /// A cloud_verified, owned, available Moment backed by a real file of `bytes`.
    @discardableResult
    private func makeVerified(owner: String, bytes: Int = 4096) throws -> MomentModel {
        MediaStore.shared.ensureMediaDirectory()
        let rel = MediaStore.shared.newRelativeVideoPath()
        let url = MediaStore.shared.absoluteURL(for: rel)
        try Data(repeating: 0x42, count: bytes).write(to: url)
        tmp.append(url)
        let asset = AssetModel(relativePath: rel, durationSeconds: 3, source: .directed)
        asset.ownerAccountId = owner
        let m = MomentModel(source: .directed, asset: asset)
        m.ownerAccountId = owner
        m.cloudMediaId = "cm-\(UUID().uuidString.prefix(8))"
        m.cloudStateRaw = "cloud_verified"
        ctx.insert(asset); ctx.insert(m); try ctx.save()
        // Seed a preview so eviction (which requires a poster) is not blocked by poster extraction on
        // these non-video fixture bytes.
        let pURL = MediaPreviewStore.shared.previewURL(momentId: m.id)
        try? FileManager.default.createDirectory(at: pURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data([0xFF,0xD8,0xFF]).write(to: pURL); tmp.append(pURL)
        return m
    }

    private func opt(_ owner: String?, inUse: @escaping (UUID) -> Bool = { _ in false }) -> StorageOptimizer {
        StorageOptimizer(context: ctx, activeOwner: owner, isInActiveUse: inUse)
    }

    func test_evicts_verified_owned_available_and_frees_real_bytes() async throws {
        let m = try makeVerified(owner: "A", bytes: 8192)
        let o = opt("A")
        XCTAssertNil(o.evictionRefusal(for: m))
        let freed = await o.evict(moment: m)
        XCTAssertEqual(freed, 8192)
        XCTAssertEqual(m.asset?.localAvailability, .evicted)
        XCTAssertFalse(MediaStore.shared.fileExists(relativePath: m.asset!.relativePath))  // bytes gone
        XCTAssertEqual(m.cloudStateRaw, "cloud_verified")                                  // cloud state UNCHANGED
        XCTAssertEqual(m.ownerAccountId, "A")                                              // ownership UNCHANGED
    }

    func test_refuses_not_cloud_verified() throws {
        let m = try makeVerified(owner: "A")
        m.cloudStateRaw = "uploading"
        XCTAssertEqual(opt("A").evictionRefusal(for: m), .notCloudVerified)
    }

    func test_refuses_local_only() throws {
        let m = try makeVerified(owner: "A")
        m.cloudStateRaw = "local_only"; m.cloudMediaId = nil
        XCTAssertEqual(opt("A").evictionRefusal(for: m), .notCloudVerified)
    }

    func test_refuses_keep_downloaded() throws {
        let m = try makeVerified(owner: "A")
        m.asset?.keepDownloaded = true
        XCTAssertEqual(opt("A").evictionRefusal(for: m), .keepDownloaded)
    }

    func test_refuses_in_active_use() throws {
        let m = try makeVerified(owner: "A")
        let o = opt("A", inUse: { $0 == m.id })
        XCTAssertEqual(o.evictionRefusal(for: m), .inActiveUse)
    }

    func test_refuses_live_upload_job() throws {
        let m = try makeVerified(owner: "A")
        let job = MediaUploadJobModel(ownerAccountId: "A", momentId: m.id, assetId: m.asset!.id,
                                      operationId: "op", relativeMediaPath: m.asset!.relativePath)
        job.state = .running
        ctx.insert(job); try ctx.save()
        XCTAssertEqual(opt("A").evictionRefusal(for: m), .liveJob)
    }

    func test_refuses_not_owned_by_active_account() throws {
        let m = try makeVerified(owner: "A")
        XCTAssertEqual(opt("B").evictionRefusal(for: m), .notOwned)
    }

    func test_refuses_shared_file() throws {
        let m = try makeVerified(owner: "A")
        // A second asset points at the SAME relativePath -> shared, not safe to evict.
        let shared = AssetModel(relativePath: m.asset!.relativePath, durationSeconds: 1, source: .directed)
        ctx.insert(shared); try ctx.save()
        XCTAssertEqual(opt("A").evictionRefusal(for: m), .sharedFile)
    }

    func test_free_up_space_sums_only_eligible() async throws {
        let a = try makeVerified(owner: "A", bytes: 1000)
        let b = try makeVerified(owner: "A", bytes: 2000)
        b.asset?.keepDownloaded = true                 // b is protected -> not freed
        try ctx.save()
        let freed = await opt("A").freeUpSpace(moments: [a, b])
        XCTAssertEqual(freed, 1000)
        XCTAssertEqual(a.asset?.localAvailability, .evicted)
        XCTAssertEqual(b.asset?.localAvailability, .available)
    }

    func test_summary_counts_local_cloud_reclaimable() throws {
        let a = try makeVerified(owner: "A", bytes: 1000)   // eligible
        let b = try makeVerified(owner: "A", bytes: 3000)
        b.asset?.keepDownloaded = true                      // not reclaimable
        try ctx.save()
        let s = opt("A").summary(moments: [a, b])
        XCTAssertEqual(s.localOriginalBytes, 4000)
        XCTAssertEqual(s.cloudBackedBytes, 4000)
        XCTAssertEqual(s.reclaimableBytes, 1000)            // only a
        XCTAssertEqual(s.availableCount, 2)
    }

    func test_evict_is_idempotent() async throws {
        let m = try makeVerified(owner: "A", bytes: 500)
        let o = opt("A")
        let e1 = await o.evict(moment: m); XCTAssertEqual(e1, 500)
        let e2 = await o.evict(moment: m); XCTAssertEqual(e2, 0)               // already evicted -> no-op
        XCTAssertEqual(o.evictionRefusal(for: m), .alreadyEvicted)
    }
}
