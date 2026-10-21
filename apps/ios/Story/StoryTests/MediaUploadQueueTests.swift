import XCTest
import SwiftData
@testable import Story

// R4-A — MediaUploadQueue + cross-account immutable-owner rule tests. A fake MediaUploading avoids network/S3;
// a real tiny temp file backs the Asset so sha256/size/fileExists work. Locks the owner's rules: reservation,
// account-scoped scheduling, verified ownership transition, no cross-account mutation, stale-callback guard.
@MainActor
final class MediaUploadQueueTests: XCTestCase {
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
                 AutoBackupSettingModel.self,
            configurations: config)
    }

    override func tearDown() { for u in tmpFiles { try? FileManager.default.removeItem(at: u) }; tmpFiles = [] }

    /// Create a Moment whose Asset points at a REAL tiny file under the media dir (so fileExists/sha256 work).
    private func makeLocalMoment() throws -> MomentModel {
        MediaStore.shared.ensureMediaDirectory()
        let rel = MediaStore.shared.newRelativeVideoPath()
        let url = MediaStore.shared.absoluteURL(for: rel)
        try Data("tiny-fixture-bytes".utf8).write(to: url)
        tmpFiles.append(url)
        let asset = AssetModel(relativePath: rel, durationSeconds: 1, source: .directed)
        let moment = MomentModel(source: .directed, asset: asset)
        ctx.insert(asset); ctx.insert(moment); try ctx.save()
        return moment
    }

    /// A Moment backed by a file larger than the multipart threshold (>16 MiB), so the queue takes the
    /// multipart path. Writes `bytes` of real data (sparse-ish) to a temp media file.
    private func makeLargeMoment(bytes: Int) throws -> MomentModel {
        MediaStore.shared.ensureMediaDirectory()
        let rel = MediaStore.shared.newRelativeVideoPath()
        let url = MediaStore.shared.absoluteURL(for: rel)
        // Write in 1 MiB chunks so we don't hold 'bytes' in memory.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        let chunk = Data(repeating: 0x41, count: 1 << 20)
        var written = 0
        while written < bytes { let n = min(chunk.count, bytes - written); h.write(chunk.prefix(n)); written += n }
        try? h.close()
        tmpFiles.append(url)
        let asset = AssetModel(relativePath: rel, durationSeconds: 60, source: .directed)
        let moment = MomentModel(source: .directed, asset: asset)
        ctx.insert(asset); ctx.insert(moment); try ctx.save()
        return moment
    }

    private func queue(active: @escaping () -> String?,
                       token: @escaping (String) async -> String? = { _ in "tok" },
                       service: MediaUploading,
                       networkAllows: @escaping (String) -> Bool = { _ in true }) -> MediaUploadQueue {
        MediaUploadQueue(context: ctx, service: service, activeOwner: active,
                         tokenForOwner: token, networkAllows: networkAllows)
    }

    // MARK: - enroll = local reservation (not cloud ownership)

    func testEnroll_reservesMomentToActiveAccount_notCloudOwned() throws {
        let m = try makeLocalMoment()
        let q = queue(active: { "A" }, service: FakeService())
        let job = q.enroll(moment: m)
        XCTAssertNotNil(job)
        XCTAssertEqual(m.ownerAccountId, "A", "reserved to A")
        XCTAssertEqual(m.cloudStateRaw, "local_only", "reservation is NOT cloud ownership yet")
        XCTAssertEqual(job?.ownerAccountId, "A")
    }

    func testEnroll_refusesWhenSignedOut() throws {
        let m = try makeLocalMoment()
        XCTAssertNil(queue(active: { nil }, service: FakeService()).enroll(moment: m))
        XCTAssertNil(m.ownerAccountId)
    }

    func testEnroll_refusesMomentReservedByAnotherAccount() throws {
        let m = try makeLocalMoment()
        m.ownerAccountId = "B"; try ctx.save()   // already B's
        XCTAssertNil(queue(active: { "A" }, service: FakeService()).enroll(moment: m),
                     "A cannot claim a Moment reserved by B")
        XCTAssertEqual(m.ownerAccountId, "B")
    }

    func testEnroll_idempotentReusesLiveJob() throws {
        let m = try makeLocalMoment()
        let q = queue(active: { "A" }, service: FakeService())
        let j1 = q.enroll(moment: m); let j2 = q.enroll(moment: m)
        XCTAssertEqual(j1?.id, j2?.id)
        XCTAssertEqual((try ctx.fetch(FetchDescriptor<MediaUploadJobModel>())).count, 1)
    }

    // MARK: - drain + verified transition

    func testDrain_verifiesAndTransitionsToCloudOwned() async throws {
        let m = try makeLocalMoment()
        let q = queue(active: { "A" }, service: FakeService())
        _ = q.enroll(moment: m)
        await q.drain()
        let job = try ctx.fetch(FetchDescriptor<MediaUploadJobModel>()).first!
        XCTAssertEqual(job.state, .verified)
        XCTAssertNotNil(job.cloudMediaId)
        XCTAssertEqual(m.cloudStateRaw, "cloud_verified", "Phase-4 transition after server verify")
        XCTAssertEqual(m.cloudMediaId, job.cloudMediaId)
        XCTAssertEqual(m.asset?.ownerAccountId, "A")
    }

    // MARK: - account-scoped scheduling (rule 2/9)

    func testDrain_doesNotScheduleAnotherAccountsJob() async throws {
        let m = try makeLocalMoment()
        _ = queue(active: { "A" }, service: FakeService()).enroll(moment: m)   // job owned by A
        // Now B is active: draining must NOT touch A's job.
        let svc = FakeService()
        await queue(active: { "B" }, token: { owner in owner == "B" ? "tokB" : nil }, service: svc).drain()
        let job = try ctx.fetch(FetchDescriptor<MediaUploadJobModel>()).first!
        XCTAssertEqual(job.state, .pending, "A's job stays pending while B is active")
        XCTAssertEqual(svc.initiateCount, 0, "no upload initiated for A under B")
        XCTAssertEqual(m.cloudStateRaw, "local_only")
    }

    func testRunningAJobFinishesUnderAEvenAfterSwitch_viaTokenGate() async throws {
        // A enrolls; A active -> verifies. Then B active -> A's verified job is untouched; B sees nothing.
        let m = try makeLocalMoment()
        let qA = queue(active: { "A" }, service: FakeService())
        _ = qA.enroll(moment: m); await qA.drain()
        XCTAssertEqual(m.ownerAccountId, "A")
        // B active: B's drain must not re-run or claim A's verified job.
        let svcB = FakeService()
        await queue(active: { "B" }, token: { $0 == "B" ? "tokB" : nil }, service: svcB).drain()
        XCTAssertEqual(svcB.initiateCount, 0)
        XCTAssertEqual(m.cloudStateRaw, "cloud_verified")   // A's result preserved, unchanged by B
    }

    // MARK: - failure / release

    func testFailedUpload_doesNotBecomeCloudOwned() async throws {
        let m = try makeLocalMoment()
        let q = queue(active: { "A" }, service: FailingService())
        _ = q.enroll(moment: m)
        await q.drain()
        let job = try ctx.fetch(FetchDescriptor<MediaUploadJobModel>()).first!
        XCTAssertNotEqual(job.state, .verified)
        XCTAssertEqual(m.cloudStateRaw, "local_only", "a failed/interrupted upload never silently becomes owned")
    }

    func testCancel_releasesReservationBackToShared() async throws {
        let m = try makeLocalMoment()
        let q = queue(active: { "A" }, service: FailingService())
        let job = q.enroll(moment: m)!
        q.cancel(job: job)
        XCTAssertEqual(job.state, .cancelled)
        XCTAssertNil(m.ownerAccountId, "cancel releases the unverified reservation back to shared local-only")
    }

    // MARK: - R4-A.1 Auto Backup

    func testAutoEnroll_offByDefault_noEnrollment() throws {
        let m = try makeLocalMoment()
        let q = queue(active: { "A" }, service: FakeService())
        XCTAssertNil(q.autoEnrollIfEnabled(moment: m), "Auto Backup is OFF by default")
        XCTAssertNil(m.ownerAccountId)
        XCTAssertEqual((try ctx.fetch(FetchDescriptor<MediaUploadJobModel>())).count, 0)
    }

    func testAutoEnroll_onEnrollsNewMoment() throws {
        AutoBackupStore(context: ctx).setEnabled(true, for: "A")
        let m = try makeLocalMoment()
        let q = queue(active: { "A" }, service: FakeService())
        XCTAssertNotNil(q.autoEnrollIfEnabled(moment: m), "Auto Backup ON -> new Moment auto-enrolled")
        XCTAssertEqual(m.ownerAccountId, "A")
    }

    func testAutoEnroll_signedOut_noEnrollment() throws {
        AutoBackupStore(context: ctx).setEnabled(true, for: "A")
        let m = try makeLocalMoment()
        let q = queue(active: { nil }, service: FakeService())
        XCTAssertNil(q.autoEnrollIfEnabled(moment: m))
    }

    func testWiFiOnlyGate_holdsUploadOnDisallowedNetwork() async throws {
        AutoBackupStore(context: ctx).setEnabled(true, for: "A")   // Wi-Fi only (default)
        let m = try makeLocalMoment()
        let svc = FakeService()
        // networkAllows == false simulates being on cellular with Wi-Fi-only preference.
        let q = queue(active: { "A" }, service: svc, networkAllows: { _ in false })
        _ = q.enroll(moment: m)
        await q.drain()
        let job = try ctx.fetch(FetchDescriptor<MediaUploadJobModel>()).first!
        XCTAssertEqual(job.state, .pending, "held until an allowed network")
        XCTAssertEqual(svc.initiateCount, 0, "no upload on a disallowed network")
        XCTAssertEqual(m.cloudStateRaw, "local_only")
    }

    func testWiFiGate_allowsWhenPermitted() async throws {
        AutoBackupStore(context: ctx).setEnabled(true, for: "A")
        let m = try makeLocalMoment()
        let q = queue(active: { "A" }, service: FakeService(), networkAllows: { _ in true })
        _ = q.enroll(moment: m)
        await q.drain()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MediaUploadJobModel>()).first!.state, .verified)
    }

    func testAutoBackupPreference_isAccountScoped() throws {
        let s = AutoBackupStore(context: ctx)
        s.setEnabled(true, for: "A")
        XCTAssertTrue(s.isEnabled(for: "A"))
        XCTAssertFalse(s.isEnabled(for: "B"), "preference is per-account, not device-global")
        s.setAllowCellular(true, for: "A")
        XCTAssertTrue(s.allowCellular(for: "A"))
        XCTAssertFalse(s.allowCellular(for: "B"))
    }

    func testAutoEnroll_doesNotClaimAnotherAccountsMoment() throws {
        AutoBackupStore(context: ctx).setEnabled(true, for: "A")
        let m = try makeLocalMoment()
        m.ownerAccountId = "B"; try ctx.save()   // already B's
        let q = queue(active: { "A" }, service: FakeService())
        XCTAssertNil(q.autoEnrollIfEnabled(moment: m), "never claims an existing cloud/other-account Moment")
        XCTAssertEqual(m.ownerAccountId, "B")
    }

    // MARK: - R4-B multipart

    func testLargeFile_takesMultipartPath_andVerifies() async throws {
        let m = try makeLargeMoment(bytes: 20 * 1024 * 1024)   // > 16 MiB threshold -> multipart
        let svc = RecordingMultipartService()
        let q = queue(active: { "A" }, service: svc)
        _ = q.enroll(moment: m)
        await q.drain()
        let job = try ctx.fetch(FetchDescriptor<MediaUploadJobModel>()).first!
        XCTAssertEqual(job.state, .verified)
        XCTAssertEqual(svc.initiateMPCount, 1, "multipart path used (not single PUT)")
        XCTAssertTrue(svc.completedMP)
        // 20 MiB / 8 MiB parts = 3 parts, all uploaded (none pre-existing).
        XCTAssertEqual(Set(svc.putParts), [1, 2, 3])
        XCTAssertEqual(m.cloudStateRaw, "cloud_verified")
    }

    func testMultipart_resume_reusesAlreadyUploadedParts() async throws {
        let m = try makeLargeMoment(bytes: 20 * 1024 * 1024)   // 3 parts
        let svc = RecordingMultipartService()
        svc.alreadyUploaded = [1, 2]   // S3 already has parts 1 & 2 (interruption) -> only part 3 re-uploaded
        let q = queue(active: { "A" }, service: svc)
        _ = q.enroll(moment: m)
        await q.drain()
        XCTAssertEqual(svc.putParts, [3], "only the missing part is re-uploaded (part-level resume)")
        XCTAssertTrue(svc.completedMP)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MediaUploadJobModel>()).first!.state, .verified)
    }

    func testSmallFile_stillUsesSinglePut() async throws {
        let m = try makeLocalMoment()   // tiny -> single PUT, multipart never touched
        let svc = RecordingMultipartService()
        let q = queue(active: { "A" }, service: svc)
        _ = q.enroll(moment: m)
        await q.drain()
        XCTAssertEqual(svc.initiateMPCount, 0, "small file must NOT use multipart")
        XCTAssertFalse(svc.completedMP)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MediaUploadJobModel>()).first!.state, .verified)
    }
}

// MARK: - Fakes

private final class FakeService: MediaUploading {
    var initiateCount = 0
    func initiate(accessToken: String, sha256: String, size: Int,
                  deviceAssetId: String, sourceMomentId: String,
                  mediaKind: String, sourceOutputId: String, contentType: String) async throws -> MediaInitiateResult {
        initiateCount += 1
        return MediaInitiateResult(cloudMediaId: "cmid-\(sha256.prefix(8))",
                                   uploadURL: URL(string: "https://s3.example/put")!, created: true)
    }
    func putToS3(uploadURL: URL, fileURL: URL, sha256Hex: String, contentType: String) async throws {}
    func complete(accessToken: String, cloudMediaId: String) async throws {}
    // multipart (small-file fake: not exercised, provide trivial impls)
    func initiateMultipart(accessToken: String, plan: MultipartPlan, deviceAssetId: String,
                           sourceMomentId: String, mediaKind: String, sourceOutputId: String,
                           contentType: String) async throws -> MultipartInitiateResult {
        MultipartInitiateResult(cloudMediaId: "cmid-mp", uploadId: "u1", partCount: plan.partCount, created: true)
    }
    func presignParts(accessToken: String, cloudMediaId: String, partNumbers: [Int]) async throws -> [Int: URL] {
        Dictionary(uniqueKeysWithValues: partNumbers.map { ($0, URL(string: "https://s3.example/p\($0)")!) })
    }
    func uploadedPartNumbers(accessToken: String, cloudMediaId: String) async throws -> Set<Int> { [] }
    func putPart(uploadURL: URL, fileURL: URL, offset: Int, length: Int, partShaB64: String,
                 contentType: String) async throws {}
    func completeMultipart(accessToken: String, cloudMediaId: String) async throws {}
}

private final class FailingService: MediaUploading {
    func initiate(accessToken: String, sha256: String, size: Int,
                  deviceAssetId: String, sourceMomentId: String,
                  mediaKind: String, sourceOutputId: String, contentType: String) async throws -> MediaInitiateResult {
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
                 contentType: String) async throws {
        throw MediaUploadError.s3PutFailed(500)
    }
    func completeMultipart(accessToken: String, cloudMediaId: String) async throws {}
}

/// Records multipart calls + simulates resume: `alreadyUploaded` is returned by uploadedPartNumbers so the
/// queue re-uploads only the rest.
private final class RecordingMultipartService: MediaUploading {
    var alreadyUploaded: Set<Int> = []
    private(set) var putParts: [Int] = []        // which parts the queue actually PUT
    private(set) var initiateMPCount = 0
    private(set) var completedMP = false
    // single-file path unused here
    func initiate(accessToken: String, sha256: String, size: Int, deviceAssetId: String,
                  sourceMomentId: String, mediaKind: String, sourceOutputId: String,
                  contentType: String) async throws -> MediaInitiateResult {
        MediaInitiateResult(cloudMediaId: "x", uploadURL: URL(string: "https://s3.example/put")!, created: true)
    }
    func putToS3(uploadURL: URL, fileURL: URL, sha256Hex: String, contentType: String) async throws {}
    func complete(accessToken: String, cloudMediaId: String) async throws {}
    func initiateMultipart(accessToken: String, plan: MultipartPlan, deviceAssetId: String,
                           sourceMomentId: String, mediaKind: String, sourceOutputId: String,
                           contentType: String) async throws -> MultipartInitiateResult {
        initiateMPCount += 1
        return MultipartInitiateResult(cloudMediaId: "cmid-mp", uploadId: "u1",
                                       partCount: plan.partCount, created: true)
    }
    func presignParts(accessToken: String, cloudMediaId: String, partNumbers: [Int]) async throws -> [Int: URL] {
        Dictionary(uniqueKeysWithValues: partNumbers.map { ($0, URL(string: "https://s3.example/p\($0)")!) })
    }
    func uploadedPartNumbers(accessToken: String, cloudMediaId: String) async throws -> Set<Int> { alreadyUploaded }
    func putPart(uploadURL: URL, fileURL: URL, offset: Int, length: Int, partShaB64: String,
                 contentType: String) async throws {
        putParts.append((offset / (8 * 1024 * 1024)) + 1)
    }
    func completeMultipart(accessToken: String, cloudMediaId: String) async throws { completedMP = true }
}
