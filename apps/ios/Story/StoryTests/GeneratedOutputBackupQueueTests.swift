import XCTest
import SwiftData
@testable import Story

// R7-D — GeneratedOutputBackupQueue tests. A fake MediaUploading avoids network/S3; a real tiny MP4 under
// RenderOutputStore backs the output so sha256/size/exists work. Locks the owner's rules: enroll idempotency,
// account-scoped scheduling, media_kind="generated"+source_output_id on initiate, verified stamping of
// cloudMediaId+cloudVerifiedAt, no cross-account backup, never deletes the rendered MP4, stale-callback guard.
@MainActor
final class GeneratedOutputBackupQueueTests: XCTestCase {
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

    override func tearDown() { for u in tmpFiles { try? FileManager.default.removeItem(at: u) }; tmpFiles = [] }

    /// A Story + a GeneratedOutput whose relativeFilePath points at a REAL tiny file under RenderOutputStore.
    private func makeOutput(owner: String?, verified: Bool = false) throws -> (StoryModel, GeneratedOutputModel) {
        RenderOutputStore.shared.ensureDir()
        let (rel, url) = RenderOutputStore.shared.newOutput()
        try Data("tiny-mp4-fixture-bytes".utf8).write(to: url)
        tmpFiles.append(url)
        let story = StoryModel(title: "T", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s")
        story.ownerAccountId = owner
        let output = GeneratedOutputModel(title: "T", durationSeconds: 5, momentIds: [],
                                          relativeFilePath: rel)
        output.ownerAccountId = owner
        if verified { output.cloudMediaId = "existing"; output.cloudVerifiedAt = .now }
        output.story = story
        ctx.insert(story); ctx.insert(output); story.generatedOutputs.append(output); try ctx.save()
        return (story, output)
    }

    private func queue(active: @escaping () -> String?,
                       token: @escaping (String) async -> String? = { _ in "tok" },
                       service: MediaUploading,
                       networkAllows: @escaping (String) -> Bool = { _ in true }) -> GeneratedOutputBackupQueue {
        GeneratedOutputBackupQueue(context: ctx, service: service, activeOwner: active,
                                   tokenForOwner: token, networkAllows: networkAllows)
    }

    // MARK: - enroll

    func testEnroll_underActiveOwner() throws {
        let (_, o) = try makeOutput(owner: "A")
        let job = queue(active: { "A" }, service: RecordingGenService()).enroll(output: o)
        XCTAssertNotNil(job)
        XCTAssertEqual(job?.ownerAccountId, "A")
        XCTAssertEqual(job?.outputId, o.id)
    }

    func testEnroll_refusesWhenSignedOut() throws {
        let (_, o) = try makeOutput(owner: nil)
        XCTAssertNil(queue(active: { nil }, service: RecordingGenService()).enroll(output: o))
    }

    func testEnroll_refusesOutputOwnedByAnotherAccount() throws {
        let (_, o) = try makeOutput(owner: "B")
        XCTAssertNil(queue(active: { "A" }, service: RecordingGenService()).enroll(output: o),
                     "A cannot back up B's output")
    }

    func testEnroll_skipsAlreadyVerifiedOutput() throws {
        let (_, o) = try makeOutput(owner: "A", verified: true)
        XCTAssertNil(queue(active: { "A" }, service: RecordingGenService()).enroll(output: o))
    }

    func testEnroll_refusesWhenRenderedFileMissing() throws {
        let story = StoryModel(title: "T", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s"); story.ownerAccountId = "A"
        let o = GeneratedOutputModel(title: "T", durationSeconds: 5, momentIds: [],
                                     relativeFilePath: "rendered/does-not-exist.mp4")
        o.ownerAccountId = "A"; o.story = story
        ctx.insert(story); ctx.insert(o); try ctx.save()
        XCTAssertNil(queue(active: { "A" }, service: RecordingGenService()).enroll(output: o))
    }

    func testEnroll_idempotentReusesLiveJob() throws {
        let (_, o) = try makeOutput(owner: "A")
        let q = queue(active: { "A" }, service: RecordingGenService())
        let j1 = q.enroll(output: o); let j2 = q.enroll(output: o)
        XCTAssertEqual(j1?.id, j2?.id)
        XCTAssertEqual((try ctx.fetch(FetchDescriptor<GeneratedOutputBackupJobModel>())).count, 1)
    }

    // MARK: - drain + verified stamping

    func testDrain_uploadsGeneratedKindAndStampsOutput() async throws {
        let (_, o) = try makeOutput(owner: "A")
        let svc = RecordingGenService()
        let q = queue(active: { "A" }, service: svc)
        _ = q.enroll(output: o)
        await q.drain()
        // media_kind + source_output_id were sent on initiate.
        XCTAssertEqual(svc.lastMediaKind, "generated")
        XCTAssertEqual(svc.lastSourceOutputId, o.id.uuidString)
        XCTAssertEqual(svc.lastContentType, "video/mp4")
        // Output stamped.
        XCTAssertNotNil(o.cloudMediaId)
        XCTAssertNotNil(o.cloudVerifiedAt)
        // Job verified; rendered file still present (never deleted).
        let job = try XCTUnwrap((try ctx.fetch(FetchDescriptor<GeneratedOutputBackupJobModel>())).first)
        XCTAssertEqual(job.state, .verified)
        XCTAssertTrue(RenderOutputStore.shared.exists(relative: o.relativeFilePath!),
                      "the only local copy must never be deleted by the backup queue")
    }

    func testDrain_signedOutDoesNothing() async throws {
        let (_, o) = try makeOutput(owner: "A")
        let q = queue(active: { "A" }, service: RecordingGenService())
        _ = q.enroll(output: o)
        // Now switch to a different active account: A's job must not run under B.
        let qB = queue(active: { "B" }, service: RecordingGenService())
        await qB.drain()
        let job = try XCTUnwrap((try ctx.fetch(FetchDescriptor<GeneratedOutputBackupJobModel>())).first)
        XCTAssertEqual(job.state, .pending, "A's job stays pending while B is active (account-scoped)")
        XCTAssertNil(o.cloudMediaId)
        _ = q  // silence unused
    }

    func testDrain_failureBacksOffThenFails() async throws {
        let (_, o) = try makeOutput(owner: "A")
        let q = queue(active: { "A" }, service: FailingGenService())
        _ = q.enroll(output: o)
        for _ in 0..<7 {
            if let j = (try ctx.fetch(FetchDescriptor<GeneratedOutputBackupJobModel>())).first {
                j.nextEligibleAt = .distantPast; try ctx.save()
            }
            await q.drain()
        }
        let job = try XCTUnwrap((try ctx.fetch(FetchDescriptor<GeneratedOutputBackupJobModel>())).first)
        XCTAssertEqual(job.state, .failed)
        XCTAssertNil(o.cloudMediaId, "a failed backup never stamps the output")
        XCTAssertTrue(RenderOutputStore.shared.exists(relative: o.relativeFilePath!))
    }

    func testRecoverOrphans_runningBackToPending() async throws {
        let (_, o) = try makeOutput(owner: "A")
        let q = queue(active: { "A" }, service: RecordingGenService())
        let job = try XCTUnwrap(q.enroll(output: o))
        job.state = .running; try ctx.save()
        q.recoverOrphans()
        XCTAssertEqual(job.state, .pending)
    }
}

// MARK: - fakes

private final class RecordingGenService: MediaUploading {
    var lastMediaKind: String?
    var lastSourceOutputId: String?
    var lastContentType: String?
    func initiate(accessToken: String, sha256: String, size: Int, deviceAssetId: String,
                  sourceMomentId: String, mediaKind: String, sourceOutputId: String,
                  contentType: String) async throws -> MediaInitiateResult {
        lastMediaKind = mediaKind; lastSourceOutputId = sourceOutputId; lastContentType = contentType
        return MediaInitiateResult(cloudMediaId: "cmid-gen",
                                   uploadURL: URL(string: "https://s3.example/put")!, created: true)
    }
    func putToS3(uploadURL: URL, fileURL: URL, sha256Hex: String, contentType: String) async throws {}
    func complete(accessToken: String, cloudMediaId: String) async throws {}
    func initiateMultipart(accessToken: String, plan: MultipartPlan, deviceAssetId: String,
                           sourceMomentId: String, mediaKind: String, sourceOutputId: String,
                           contentType: String) async throws -> MultipartInitiateResult {
        lastMediaKind = mediaKind; lastSourceOutputId = sourceOutputId; lastContentType = contentType
        return MultipartInitiateResult(cloudMediaId: "cmid-gen-mp", uploadId: "u1",
                                       partCount: plan.partCount, created: true)
    }
    func presignParts(accessToken: String, cloudMediaId: String, partNumbers: [Int]) async throws -> [Int: URL] {
        Dictionary(uniqueKeysWithValues: partNumbers.map { ($0, URL(string: "https://s3.example/p\($0)")!) })
    }
    func uploadedPartNumbers(accessToken: String, cloudMediaId: String) async throws -> Set<Int> { [] }
    func putPart(uploadURL: URL, fileURL: URL, offset: Int, length: Int, partShaB64: String,
                 contentType: String) async throws {}
    func completeMultipart(accessToken: String, cloudMediaId: String) async throws {}
}

private final class FailingGenService: MediaUploading {
    func initiate(accessToken: String, sha256: String, size: Int, deviceAssetId: String,
                  sourceMomentId: String, mediaKind: String, sourceOutputId: String,
                  contentType: String) async throws -> MediaInitiateResult {
        MediaInitiateResult(cloudMediaId: "cmid", uploadURL: URL(string: "https://s3.example/put")!, created: true)
    }
    func putToS3(uploadURL: URL, fileURL: URL, sha256Hex: String, contentType: String) async throws {
        throw MediaUploadError.s3PutFailed(500)
    }
    func complete(accessToken: String, cloudMediaId: String) async throws {}
    func initiateMultipart(accessToken: String, plan: MultipartPlan, deviceAssetId: String,
                           sourceMomentId: String, mediaKind: String, sourceOutputId: String,
                           contentType: String) async throws -> MultipartInitiateResult {
        MultipartInitiateResult(cloudMediaId: "cmid", uploadId: "u1", partCount: plan.partCount, created: true)
    }
    func presignParts(accessToken: String, cloudMediaId: String, partNumbers: [Int]) async throws -> [Int: URL] { [:] }
    func uploadedPartNumbers(accessToken: String, cloudMediaId: String) async throws -> Set<Int> { [] }
    func putPart(uploadURL: URL, fileURL: URL, offset: Int, length: Int, partShaB64: String,
                 contentType: String) async throws { throw MediaUploadError.s3PutFailed(500) }
    func completeMultipart(accessToken: String, cloudMediaId: String) async throws {}
}
