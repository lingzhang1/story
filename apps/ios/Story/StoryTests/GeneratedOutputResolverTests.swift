import XCTest
import SwiftData
import CryptoKit
@testable import Story

// R7-D — GeneratedOutputResolver tests (restore-on-play of the EXACT rendered MP4). A fake MediaDownloading
// avoids network/S3 but exercises the REAL verify (size + full-file sha256) + atomic install + coalescing +
// cross-account refusal. The resolver NEVER re-renders; it installs the verified bytes and stamps the output.
@MainActor
final class GeneratedOutputResolverTests: XCTestCase {
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
                 AutoBackupSettingModel.self, MediaDownloadJobModel.self,
                 OptimizationSettingModel.self, StorySyncJobModel.self,
                 GeneratedOutputBackupJobModel.self,
            configurations: config)
    }

    override func tearDown() {
        for u in tmpFiles { try? FileManager.default.removeItem(at: u) }
        RenderOutputStore.shared.purgeDownloadTemps()
        tmpFiles = []
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A cloud-only output: no local rendered file, but a verified cloudMediaId. `rel` nil => Device B case
    /// (no prior relativeFilePath; the resolver mints one).
    private func makeCloudOnlyOutput(owner: String, cmid: String, withRel: Bool) throws -> GeneratedOutputModel {
        let story = StoryModel(title: "T", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s"); story.ownerAccountId = owner
        let rel: String? = withRel ? "rendered/\(UUID().uuidString).mp4" : nil
        if let rel { try? FileManager.default.removeItem(at: RenderOutputStore.shared.absoluteURL(for: rel)) }
        let o = GeneratedOutputModel(title: "T", durationSeconds: 5, momentIds: [], relativeFilePath: rel)
        o.ownerAccountId = owner
        o.cloudMediaId = cmid
        o.cloudVerifiedAt = .now
        o.story = story
        ctx.insert(story); ctx.insert(o); story.generatedOutputs.append(o); try ctx.save()
        return o
    }

    // 1. Happy path (Device B, no prior relativeFilePath): download, verify, install, stamp relativeFilePath.
    func test_restore_downloads_verifies_installs_and_stamps() async throws {
        let owner = "A"
        let blob = Data("exact-rendered-mp4-bytes".utf8)
        let o = try makeCloudOnlyOutput(owner: owner, cmid: "cm-1", withRel: false)
        let fake = FakeDL(blob: blob)
        let resolver = GeneratedOutputResolver(service: fake)
        let url = try await resolver.ensureLocal(output: o, context: ctx, activeOwner: owner, token: { "tok" })
        let rel = try XCTUnwrap(o.relativeFilePath)
        XCTAssertTrue(RenderOutputStore.shared.exists(relative: rel), "installed to a freshly-minted path")
        XCTAssertEqual(try Data(contentsOf: url), blob)
        tmpFiles.append(RenderOutputStore.shared.absoluteURL(for: rel))
        XCTAssertEqual(fake.downloadCount, 1)
    }

    // 2. Checksum mismatch must NEVER install (verify before playback/sharing).
    func test_checksum_mismatch_does_not_install() async throws {
        let o = try makeCloudOnlyOutput(owner: "A", cmid: "cm-2", withRel: false)
        let fake = FakeDL(blob: Data("bytes".utf8), sha: String(repeating: "f", count: 64))
        let resolver = GeneratedOutputResolver(service: fake)
        do {
            _ = try await resolver.ensureLocal(output: o, context: ctx, activeOwner: "A", token: { "tok" })
            XCTFail("expected checksum failure")
        } catch {}
        XCTAssertNil(o.relativeFilePath.flatMap { RenderOutputStore.shared.exists(relative: $0) ? $0 : nil })
    }

    // 3. Size mismatch must NEVER install.
    func test_size_mismatch_does_not_install() async throws {
        let o = try makeCloudOnlyOutput(owner: "A", cmid: "cm-3", withRel: false)
        let fake = FakeDL(blob: Data("abc".utf8), size: 9999)
        let resolver = GeneratedOutputResolver(service: fake)
        do {
            _ = try await resolver.ensureLocal(output: o, context: ctx, activeOwner: "A", token: { "tok" })
            XCTFail("expected size failure")
        } catch {}
    }

    // 4. Cross-account refusal: an output owned by B is never restored under A.
    func test_cross_account_refused() async throws {
        let o = try makeCloudOnlyOutput(owner: "B", cmid: "cm-4", withRel: false)
        let fake = FakeDL(blob: Data("x".utf8))
        let resolver = GeneratedOutputResolver(service: fake)
        do {
            _ = try await resolver.ensureLocal(output: o, context: ctx, activeOwner: "A", token: { "tok" })
            XCTFail("expected cross-account refusal")
        } catch GeneratedOutputResolveError.notOwnedByActiveAccount {}
        XCTAssertEqual(fake.presignCount, 0)
    }

    // 5. No cloud copy (not verified) -> noCloudCopy, never a re-render.
    func test_no_cloud_copy_throws() async throws {
        let story = StoryModel(title: "T", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s"); story.ownerAccountId = "A"
        let o = GeneratedOutputModel(title: "T", durationSeconds: 5, momentIds: [], relativeFilePath: nil)
        o.ownerAccountId = "A"; o.story = story
        ctx.insert(story); ctx.insert(o); try ctx.save()
        let resolver = GeneratedOutputResolver(service: FakeDL(blob: Data()))
        do {
            _ = try await resolver.ensureLocal(output: o, context: ctx, activeOwner: "A", token: { "tok" })
            XCTFail("expected noCloudCopy")
        } catch GeneratedOutputResolveError.noCloudCopy {}
    }

    // 6. Fast path: an already-local output does NO network.
    func test_already_local_no_network() async throws {
        RenderOutputStore.shared.ensureDir()
        let (rel, url) = RenderOutputStore.shared.newOutput()
        try Data("local".utf8).write(to: url); tmpFiles.append(url)
        let story = StoryModel(title: "T", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s"); story.ownerAccountId = "A"
        let o = GeneratedOutputModel(title: "T", durationSeconds: 5, momentIds: [], relativeFilePath: rel)
        o.ownerAccountId = "A"; o.story = story
        ctx.insert(story); ctx.insert(o); try ctx.save()
        let fake = FakeDL(blob: Data("unused".utf8))
        let resolver = GeneratedOutputResolver(service: fake)
        _ = try await resolver.ensureLocal(output: o, context: ctx, activeOwner: "A", token: { "tok" })
        XCTAssertEqual(fake.presignCount, 0)
        XCTAssertEqual(fake.downloadCount, 0)
    }

    // 7. Expired presigned GET (403) refreshed once, then succeeds.
    func test_refresh_expired_url_then_succeeds() async throws {
        let blob = Data("refresh".utf8)
        let o = try makeCloudOnlyOutput(owner: "A", cmid: "cm-7", withRel: false)
        let fake = FakeDL(blob: blob); fake.failFirst403 = true
        let resolver = GeneratedOutputResolver(service: fake)
        let url = try await resolver.ensureLocal(output: o, context: ctx, activeOwner: "A", token: { "tok" })
        XCTAssertEqual(try Data(contentsOf: url), blob)
        XCTAssertEqual(fake.presignCount, 2)
        XCTAssertEqual(fake.downloadCount, 2)
        if let rel = o.relativeFilePath { tmpFiles.append(RenderOutputStore.shared.absoluteURL(for: rel)) }
    }

    // 8. Concurrent callers coalesce into ONE download.
    func test_concurrent_coalesce() async throws {
        let blob = Data("coalesce".utf8)
        let o = try makeCloudOnlyOutput(owner: "A", cmid: "cm-8", withRel: false)
        let fake = FakeDL(blob: blob)
        let resolver = GeneratedOutputResolver(service: fake)
        async let a = resolver.ensureLocal(output: o, context: ctx, activeOwner: "A", token: { "tok" })
        async let b = resolver.ensureLocal(output: o, context: ctx, activeOwner: "A", token: { "tok" })
        _ = try await (a, b)
        XCTAssertEqual(fake.downloadCount, 1)
        if let rel = o.relativeFilePath { tmpFiles.append(RenderOutputStore.shared.absoluteURL(for: rel)) }
    }
}

// MARK: - fake MediaDownloading (mirrors the R6 verify contract)

private final class FakeDL: MediaDownloading, @unchecked Sendable {
    let blob: Data
    var declaredSize: Int
    var declaredSha: String
    var presignCount = 0
    var downloadCount = 0
    var failFirst403 = false

    init(blob: Data, size: Int? = nil, sha: String? = nil) {
        self.blob = blob
        self.declaredSize = size ?? blob.count
        self.declaredSha = sha ?? GeneratedOutputResolverTests.sha256Hex(blob)
    }

    func presignDownload(accessToken: String, cloudMediaId: String) async throws -> MediaDownloadTarget {
        presignCount += 1
        return MediaDownloadTarget(url: URL(string: "https://example.test/\(cloudMediaId)")!,
                                   expiresIn: 600, expectedSize: declaredSize,
                                   expectedSha256Hex: declaredSha, contentType: "video/mp4")
    }

    func listMedia(accessToken: String) async throws -> [CloudMediaRecord] { [] }

    func download(target: MediaDownloadTarget, to destURL: URL, progress: ((Double) -> Void)?) async throws {
        downloadCount += 1
        if failFirst403 && downloadCount == 1 { throw MediaDownloadError.s3GetFailed(403) }
        let part = destURL.appendingPathExtension("part")
        try blob.write(to: part)
        if blob.count != target.expectedSize {
            try? FileManager.default.removeItem(at: part)
            throw MediaDownloadError.sizeMismatch(expected: target.expectedSize, got: blob.count)
        }
        if GeneratedOutputResolverTests.sha256Hex(blob).lowercased() != target.expectedSha256Hex.lowercased() {
            try? FileManager.default.removeItem(at: part)
            throw MediaDownloadError.checksumMismatch
        }
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: part, to: destURL)
        progress?(1.0)
    }
}
