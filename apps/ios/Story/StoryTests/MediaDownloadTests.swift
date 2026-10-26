import XCTest
import SwiftData
import CryptoKit
@testable import Story

// R6 — Cloud media download & restoration tests. A fake MediaDownloading avoids network/S3 but exercises the
// REAL verification + atomic install + coalescing + ownership rules. No large videos in memory: fixtures are
// small, but the code path under test is the same one a 400 MB file takes.
@MainActor
final class MediaDownloadTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }
    private var tmpFiles: [URL] = []

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
                 MyMusicAssetModel.self, PendingOperationModel.self,
                 MusicPlanCacheModel.self, DurationRecCacheModel.self, MediaUploadJobModel.self,
                 AutoBackupSettingModel.self, MediaDownloadJobModel.self, OptimizationSettingModel.self, StorySyncJobModel.self,
            configurations: config)
    }

    override func tearDown() {
        for u in tmpFiles { try? FileManager.default.removeItem(at: u) }
        MediaStore.shared.purgeDownloadTemps()
        tmpFiles = []
    }

    // A cloud-only Moment: Asset points at a relativePath whose file is ABSENT on disk, with cloudMediaId set.
    private func makeCloudOnlyMoment(owner: String, cloudMediaId: String) throws -> (MomentModel, String) {
        let rel = MediaStore.shared.newRelativeVideoPath()
        try? FileManager.default.removeItem(at: MediaStore.shared.absoluteURL(for: rel))
        let asset = AssetModel(relativePath: rel, durationSeconds: 5, source: .directed)
        asset.ownerAccountId = owner
        let moment = MomentModel(source: .directed, asset: asset)
        moment.ownerAccountId = owner
        moment.cloudMediaId = cloudMediaId
        moment.cloudStateRaw = "cloud_verified"
        ctx.insert(asset); ctx.insert(moment); try ctx.save()
        tmpFiles.append(MediaStore.shared.absoluteURL(for: rel))
        return (moment, rel)
    }

    private nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // A fake download service that "downloads" from an in-memory blob, honoring the same verify contract as the
    // real one. Counts calls for the coalescing + URL-refresh assertions.
    final class FakeDownloader: MediaDownloading, @unchecked Sendable {
        let blob: Data
        var declaredSize: Int
        var declaredSha: String
        var presignCount = 0
        var downloadCount = 0
        var failFirstDownloadWith403 = false
        var mediaRecords: [CloudMediaRecord] = []
        var listCount = 0

        init(blob: Data, size: Int? = nil, sha: String? = nil) {
            self.blob = blob
            self.declaredSize = size ?? blob.count
            self.declaredSha = sha ?? MediaDownloadTests.sha256Hex(blob)
        }

        func presignDownload(accessToken: String, cloudMediaId: String) async throws -> MediaDownloadTarget {
            presignCount += 1
            return MediaDownloadTarget(url: URL(string: "https://example.test/\(cloudMediaId)")!,
                                       expiresIn: 600, expectedSize: declaredSize,
                                       expectedSha256Hex: declaredSha, contentType: "video/quicktime")
        }

        func listMedia(accessToken: String) async throws -> [CloudMediaRecord] {
            listCount += 1
            return mediaRecords
        }

        func download(target: MediaDownloadTarget, to destURL: URL, progress: ((Double) -> Void)?) async throws {
            downloadCount += 1
            if failFirstDownloadWith403 && downloadCount == 1 { throw MediaDownloadError.s3GetFailed(403) }
            try blob.write(to: destURL.appendingPathExtension("part"))
            let written = blob.count
            if written != target.expectedSize {
                try? FileManager.default.removeItem(at: destURL.appendingPathExtension("part"))
                throw MediaDownloadError.sizeMismatch(expected: target.expectedSize, got: written)
            }
            if MediaDownloadTests.sha256Hex(blob).lowercased() != target.expectedSha256Hex.lowercased() {
                try? FileManager.default.removeItem(at: destURL.appendingPathExtension("part"))
                throw MediaDownloadError.checksumMismatch
            }
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: destURL.appendingPathExtension("part"), to: destURL)
            progress?(1.0)
        }
    }

    // 1. Happy path: a cloud-only Moment is downloaded, verified, atomically installed, and now resolves local.
    func test_ensureLocal_downloads_verifies_and_installs() async throws {
        let owner = "owner-A"
        let blob = Data("the-original-video-bytes-R6".utf8)
        let (moment, rel) = try makeCloudOnlyMoment(owner: owner, cloudMediaId: "cm-1")
        XCTAssertFalse(MediaStore.shared.fileExists(relativePath: rel))

        let fake = FakeDownloader(blob: blob)
        let resolver = MediaResolver(service: fake)
        let url = try await resolver.ensureLocal(moment: moment, context: ctx, activeOwner: owner, token: { "tok" })
        XCTAssertTrue(MediaStore.shared.fileExists(relativePath: rel))
        XCTAssertEqual(try Data(contentsOf: url), blob)
        let job = try ctx.fetch(FetchDescriptor<MediaDownloadJobModel>()).first
        XCTAssertEqual(job?.state, .verified)
        XCTAssertEqual(fake.downloadCount, 1)
    }

    // 2. Corruption rejected: a sha mismatch must NEVER install a file (safeguard #2).
    func test_checksum_mismatch_does_not_install() async throws {
        let owner = "owner-A"
        let blob = Data("real-bytes".utf8)
        let (moment, rel) = try makeCloudOnlyMoment(owner: owner, cloudMediaId: "cm-2")
        let fake = FakeDownloader(blob: blob, sha: String(repeating: "f", count: 64))
        let resolver = MediaResolver(service: fake)
        do {
            _ = try await resolver.ensureLocal(moment: moment, context: ctx, activeOwner: owner, token: { "tok" })
            XCTFail("expected checksum failure")
        } catch {}
        XCTAssertFalse(MediaStore.shared.fileExists(relativePath: rel))
        let job = try ctx.fetch(FetchDescriptor<MediaDownloadJobModel>()).first
        XCTAssertEqual(job?.state, .failed)
    }

    // 3. Size mismatch rejected (safeguard #2).
    func test_size_mismatch_does_not_install() async throws {
        let owner = "owner-A"
        let blob = Data("abcdef".utf8)
        let (moment, rel) = try makeCloudOnlyMoment(owner: owner, cloudMediaId: "cm-3")
        let fake = FakeDownloader(blob: blob, size: 999)
        let resolver = MediaResolver(service: fake)
        do {
            _ = try await resolver.ensureLocal(moment: moment, context: ctx, activeOwner: owner, token: { "tok" })
            XCTFail("expected size failure")
        } catch {}
        XCTAssertFalse(MediaStore.shared.fileExists(relativePath: rel))
    }

    // 4. Cross-account: a Moment owned by B is never downloaded under A's session (req #6/#10).
    func test_cross_account_refused() async throws {
        let (moment, rel) = try makeCloudOnlyMoment(owner: "owner-B", cloudMediaId: "cm-4")
        let fake = FakeDownloader(blob: Data("x".utf8))
        let resolver = MediaResolver(service: fake)
        do {
            _ = try await resolver.ensureLocal(moment: moment, context: ctx, activeOwner: "owner-A", token: { "tok" })
            XCTFail("expected cross-account refusal")
        } catch MediaResolveError.notOwnedByActiveAccount {}
        XCTAssertEqual(fake.presignCount, 0)
        XCTAssertFalse(MediaStore.shared.fileExists(relativePath: rel))
    }

    // 5. Expired presigned GET (403) is refreshed once, then succeeds (req #4).
    func test_refresh_expired_presigned_url_then_succeeds() async throws {
        let owner = "owner-A"
        let blob = Data("refresh-me".utf8)
        let (moment, rel) = try makeCloudOnlyMoment(owner: owner, cloudMediaId: "cm-5")
        let fake = FakeDownloader(blob: blob)
        fake.failFirstDownloadWith403 = true
        let resolver = MediaResolver(service: fake)
        let url = try await resolver.ensureLocal(moment: moment, context: ctx, activeOwner: owner, token: { "tok" })
        XCTAssertTrue(MediaStore.shared.fileExists(relativePath: rel))
        XCTAssertEqual(try Data(contentsOf: url), blob)
        XCTAssertEqual(fake.presignCount, 2)
        XCTAssertEqual(fake.downloadCount, 2)
    }

    // 6. Concurrent callers for the same asset are coalesced into ONE download (req #3).
    func test_concurrent_requests_coalesce() async throws {
        let owner = "owner-A"
        let blob = Data("coalesce".utf8)
        let (moment, _) = try makeCloudOnlyMoment(owner: owner, cloudMediaId: "cm-6")
        let fake = FakeDownloader(blob: blob)
        let resolver = MediaResolver(service: fake)
        async let a = resolver.ensureLocal(moment: moment, context: ctx, activeOwner: owner, token: { "tok" })
        async let b = resolver.ensureLocal(moment: moment, context: ctx, activeOwner: owner, token: { "tok" })
        _ = try await (a, b)
        XCTAssertEqual(fake.downloadCount, 1)
    }

    // 7. Fast path: an already-local Moment does NO network.
    func test_already_local_no_network() async throws {
        MediaStore.shared.ensureMediaDirectory()
        let rel = MediaStore.shared.newRelativeVideoPath()
        try Data("local".utf8).write(to: MediaStore.shared.absoluteURL(for: rel))
        tmpFiles.append(MediaStore.shared.absoluteURL(for: rel))
        let asset = AssetModel(relativePath: rel, durationSeconds: 1, source: .directed)
        let moment = MomentModel(source: .directed, asset: asset)
        ctx.insert(asset); ctx.insert(moment); try ctx.save()
        let fake = FakeDownloader(blob: Data("unused".utf8))
        let resolver = MediaResolver(service: fake)
        _ = try await resolver.ensureLocal(moment: moment, context: ctx, activeOwner: "owner-A", token: { "tok" })
        XCTAssertEqual(fake.presignCount, 0)
        XCTAssertEqual(fake.downloadCount, 0)
    }

    // 8. Reconcile: a local Moment that LOST its verified stamp (store migration / reinstall) is re-stamped
    // cloud_verified from the server's /v1/media record (matched by source_moment_id). Root-cause fix for the
    // "uploaded before but shows local-only" regression.
    func test_reconcile_restores_verified_stamp_from_server() async throws {
        let owner = "owner-A"
        // A local Moment whose local state says local_only (as after a migration reset), but the server has it.
        let rel = MediaStore.shared.newRelativeVideoPath()
        let asset = AssetModel(relativePath: rel, durationSeconds: 5, source: .directed)
        let moment = MomentModel(source: .directed, asset: asset)
        moment.cloudStateRaw = "local_only"          // stamp was lost locally
        moment.cloudMediaId = nil
        ctx.insert(asset); ctx.insert(moment); try ctx.save()

        let fake = FakeDownloader(blob: Data("x".utf8))
        fake.mediaRecords = [CloudMediaRecord(cloudMediaId: "cm-server-1", state: "cloud_verified",
                                              sizeBytes: 123, sourceMomentId: moment.id.uuidString)]
        let resolver = MediaResolver(service: fake)
        let n = await resolver.reconcileCloudState(context: ctx, activeOwner: owner, token: { "tok" })
        XCTAssertEqual(n, 1)
        XCTAssertEqual(moment.cloudStateRaw, "cloud_verified")
        XCTAssertEqual(moment.cloudMediaId, "cm-server-1")
        XCTAssertEqual(moment.ownerAccountId, owner)
        // Idempotent: a second reconcile stamps nothing new.
        let n2 = await resolver.reconcileCloudState(context: ctx, activeOwner: owner, token: { "tok" })
        XCTAssertEqual(n2, 0)
    }

    // 9. Reconcile NEVER re-keys another account's Moment (immutable-owner rule).
    func test_reconcile_never_rekeys_other_account() async throws {
        let rel = MediaStore.shared.newRelativeVideoPath()
        let asset = AssetModel(relativePath: rel, durationSeconds: 5, source: .directed)
        asset.ownerAccountId = "owner-B"
        let moment = MomentModel(source: .directed, asset: asset)
        moment.ownerAccountId = "owner-B"           // owned by B
        moment.cloudStateRaw = "local_only"
        ctx.insert(asset); ctx.insert(moment); try ctx.save()
        let fake = FakeDownloader(blob: Data("x".utf8))
        fake.mediaRecords = [CloudMediaRecord(cloudMediaId: "cm-x", state: "cloud_verified",
                                              sizeBytes: 1, sourceMomentId: moment.id.uuidString)]
        let resolver = MediaResolver(service: fake)
        let n = await resolver.reconcileCloudState(context: ctx, activeOwner: "owner-A", token: { "tok" })
        XCTAssertEqual(n, 0)                         // A must not claim B's Moment
        XCTAssertEqual(moment.ownerAccountId, "owner-B")
    }
}
