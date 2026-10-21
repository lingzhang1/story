import SwiftData
import XCTest
@testable import Story

// Phase 4 — Cloud-Aware Planner Eligibility (P0 R7 integration-regression fix).
//
// The regression: EditPlanRequestBuilder.build() (and the sibling eligibility builders) required a LOCAL media
// file, so a cloud-only Moment (bytes evicted / not yet restored after R7 sync) was silently dropped from the
// planner payload — even when its Asset Understanding was fully synced and its duration known. A directive
// naming such a Moment ("end with Moment 2") then failed `directive_ref_ineligible` -> invalid_after_repair.
//
// The fix: planner eligibility = completed AU + a known duration (local probe OR AssetModel cloud metadata) +
// a RENDERABLE source (bytes local OR cloud-restorable via R6) — INDEPENDENT of whether the original is on disk
// now. Original bytes are restored through R6 before RENDERING, not for planning.
//
// These tests use the in-memory SwiftData harness (same as StoryCreationReadinessTests) and assert the planner
// moments[] payload — NOT Bedrock, NOT network.
@MainActor
final class CloudAwareEligibilityTests: XCTestCase {

    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
            configurations: config)
    }

    // MARK: - Fixtures

    private func newStory() -> StoryModel {
        let s = StoryModel(title: "TMB", intentRawText: "x", intentTheme: "growth",
                           intentTone: "warm", intentSummary: "y")
        s.intentTargetDurationSeconds = 16.5
        ctx.insert(s)
        return s
    }

    /// A LOCAL Moment: real (placeholder) bytes on disk + a duration.
    @discardableResult
    private func localMoment(_ story: StoryModel, rel: String, dur: Double) -> MomentModel {
        let abs = MediaStore.shared.absoluteURL(for: rel)
        try? FileManager.default.createDirectory(at: abs.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: abs.path, contents: Data([0x00]))
        let asset = AssetModel(relativePath: rel, durationSeconds: dur, source: .directed)
        let m = MomentModel(source: .directed, asset: asset); ctx.insert(m)
        if let lnk = story.attach(m) { ctx.insert(lnk) }
        return m
    }

    /// A CLOUD-ONLY Moment: NO local bytes, but cloud-verified + a cloudMediaId + a persisted duration
    /// (metadata). Models an evicted / R7-restored shell whose original is restorable via R6.
    @discardableResult
    private func cloudOnlyMoment(_ story: StoryModel, dur: Double) -> MomentModel {
        let asset = AssetModel(relativePath: "media/cloud-\(UUID()).mov", durationSeconds: dur, source: .directed)
        asset.localAvailability = .evicted
        let m = MomentModel(source: .directed, asset: asset)
        m.cloudStateRaw = "cloud_verified"
        m.cloudMediaId = "cloud-\(UUID().uuidString)"
        ctx.insert(m)
        if let lnk = story.attach(m) { ctx.insert(lnk) }
        return m
    }

    /// A Moment with NO bytes AND NOT cloud-backed — genuinely unrenderable (bytes gone forever).
    @discardableResult
    private func goneMoment(_ story: StoryModel, dur: Double) -> MomentModel {
        let asset = AssetModel(relativePath: "media/gone-\(UUID()).mov", durationSeconds: dur, source: .directed)
        let m = MomentModel(source: .directed, asset: asset)   // cloudStateRaw stays "local_only", no cloudMediaId
        ctx.insert(m)
        if let lnk = story.attach(m) { ctx.insert(lnk) }
        return m
    }

    private func completeAU(_ moment: MomentModel) {
        let json = """
        {"moment_id":"\(moment.id.uuidString)","observed":{"summary":"a","subjects":[],"events":[],
         "temporal_order_note":"","useful_segments":[{"start_time":0.0,"end_time":3.0,"why_useful":"x"}]}}
        """
        ctx.insert(MomentUnderstandingModel(momentId: moment.id, schemaVersion: "moment_understanding/1",
            framePolicy: "p", promptVersion: "au/1", modelId: "x", nFrames: 24, understandingJSON: json))
    }

    private func payloadIds(_ story: StoryModel) throws -> [String] {
        let build = try EditPlanRequestBuilder.build(story: story, context: ctx)
        return build.request.moments.compactMap { mv in
            if case let .object(m) = mv, case let .string(id)? = m["id"] { return id.lowercased() }
            return nil
        }
    }

    // MARK: - Phase 4 tests

    /// #1–#3: a Story with local + cloud-only Moments, ALL with synced AU, sends ALL of them to the planner.
    func test_cloudOnlyMomentWithAU_isEligible() throws {
        let s = newStory()
        let local = localMoment(s, rel: "media/ca-local-1.mov", dur: 6); completeAU(local)
        let cloud = cloudOnlyMoment(s, dur: 7); completeAU(cloud)      // no local bytes, cloud-verified, AU synced
        let ids = try payloadIds(s)
        XCTAssertTrue(ids.contains(local.id.uuidString.lowercased()), "local Moment eligible")
        XCTAssertTrue(ids.contains(cloud.id.uuidString.lowercased()),
                      "cloud-only Moment with synced AU MUST be eligible (R7 regression fix)")
        XCTAssertEqual(ids.count, 2)
    }

    /// #4–#6: a directive referencing a cloud-only Moment is NOT silently excluded; directiveEligibility
    /// reports it eligible (allEligible == true) so create/revise proceeds with it in moments[].
    func test_directive_referencing_cloudOnlyMoment_isEligible() throws {
        let s = newStory()
        let local = localMoment(s, rel: "media/ca-dir-1.mov", dur: 6); completeAU(local)
        let cloud = cloudOnlyMoment(s, dur: 7); completeAU(cloud)
        // Directive: end with the CLOUD-ONLY Moment (the TMB "end with Moment 2" shape).
        var dirs = ResolvedDirectives(); dirs.opening = local.id; dirs.ending = cloud.id
        s.creativeDirectivesJSON = dirs.toWireJSON()
        let elig = EditPlanRequestBuilder.directiveEligibility(for: s, context: ctx)
        XCTAssertTrue(elig.allEligible, "a cloud-only AU-synced referenced Moment is eligible, not blocked")
        // And it IS in the payload.
        let ids = try payloadIds(s)
        XCTAssertTrue(ids.contains(cloud.id.uuidString.lowercased()))
    }

    /// Device-A/Device-B equivalence: the same Story (same AU, same durations) yields the same eligible set
    /// whether a Moment's bytes are local or cloud-only. We model "device B" by flipping bytes local<->cloud.
    func test_deviceAB_equivalentEligibleSet() throws {
        // Device A: both local.
        let a = newStory()
        let a1 = localMoment(a, rel: "media/ab-a-1.mov", dur: 6); completeAU(a1)
        let a2 = localMoment(a, rel: "media/ab-a-2.mov", dur: 7); completeAU(a2)
        let aCount = try payloadIds(a).count
        // Device B: same two Moments, one evicted to cloud-only.
        let b = newStory()
        let b1 = localMoment(b, rel: "media/ab-b-1.mov", dur: 6); completeAU(b1)
        let b2 = cloudOnlyMoment(b, dur: 7); completeAU(b2)
        let bCount = try payloadIds(b).count
        XCTAssertEqual(aCount, bCount, "eligible count must not depend on local availability")
        XCTAssertEqual(aCount, 2)
    }

    /// #10: a Moment with no completed AU produces an HONEST pending state — excluded from the payload,
    /// never silently invented. (Pending, not a crash, not a fabricated clip.)
    func test_missingAU_isExcludedNotInvented() throws {
        let s = newStory()
        let ready = localMoment(s, rel: "media/ca-au-1.mov", dur: 6); completeAU(ready)
        let noAU = cloudOnlyMoment(s, dur: 7)   // cloud-verified but AU NOT synced
        let ids = try payloadIds(s)
        XCTAssertTrue(ids.contains(ready.id.uuidString.lowercased()))
        XCTAssertFalse(ids.contains(noAU.id.uuidString.lowercased()),
                       "a Moment without AU is excluded (honest pending), not sent with invented content")
    }

    /// A Moment whose bytes are gone forever (no local file AND not cloud-backed) is NOT eligible even with
    /// AU — it could never render. Keeps the honest failure path (owner: do not plan unrenderable footage).
    func test_goneMoment_withAU_isNotEligible() throws {
        let s = newStory()
        let ready = localMoment(s, rel: "media/ca-gone-ok.mov", dur: 6); completeAU(ready)
        let gone = goneMoment(s, dur: 7); completeAU(gone)   // AU present, duration known, but unrenderable
        let ids = try payloadIds(s)
        XCTAssertTrue(ids.contains(ready.id.uuidString.lowercased()))
        XCTAssertFalse(ids.contains(gone.id.uuidString.lowercased()),
                       "a Moment with no obtainable bytes is not plannable (cannot render)")
    }

    /// A FULLY cloud-only Story (every eligible Moment's bytes evicted) is still PLANNABLE — build() must not
    /// throw noUsableMoments just because nothing is local. (Was the bug: the guard checked the local set.)
    func test_fullyCloudOnlyStory_isPlannable() throws {
        let s = newStory()
        let c1 = cloudOnlyMoment(s, dur: 6); completeAU(c1)
        let c2 = cloudOnlyMoment(s, dur: 7); completeAU(c2)
        let ids = try payloadIds(s)   // must not throw
        XCTAssertEqual(Set(ids), Set([c1.id.uuidString.lowercased(), c2.id.uuidString.lowercased()]))
    }

    /// #8: Customize "Moment N" numbering is built from the SAME cloud-aware eligible set, so an
    /// opening/ending reference to a cloud-only Moment resolves to a real number (never off-by-one vs planner).
    func test_usableNumbering_includesCloudOnly() {
        let s = newStory()
        let local = localMoment(s, rel: "media/ca-num-1.mov", dur: 6); completeAU(local)
        let cloud = cloudOnlyMoment(s, dur: 7); completeAU(cloud)
        let nums = EditPlanRequestBuilder.usableNumberedMoments(for: s, context: ctx)
        XCTAssertEqual(nums.count, 2, "numbering includes the cloud-only Moment")
        XCTAssertTrue(nums.contains { $0.id == cloud.id })
        XCTAssertTrue(nums.contains { $0.id == cloud.id && $0.localAvailable == false },
                      "cloud-only Moment carries localAvailable=false for the cloud badge")
    }
}
