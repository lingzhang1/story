import XCTest
import SwiftData
@testable import Story

// Creative Revision Foundation — RevisionContextBuilder tests (Create Another Version / Explore).
// Logic-only (no model, no render): derive a bounded version-aware context from persisted edit plans and
// compute deterministic diversity diagnostics. Device acceptance covers the live planning + render.
@MainActor
final class RevisionContextBuilderTests: XCTestCase {

    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
            configurations: config)
    }

    // Build a GeneratedOutputModel carrying a real EditPlan/2 wire JSON (snake_case) with the given ordered
    // moment ids — the exact shape editPlanJSON stores and RevisionContextBuilder decodes.
    private func output(momentIds: [String], versionId: UUID = UUID()) -> GeneratedOutputModel {
        let segs = momentIds.enumerated().map { i, aid in
            """
            {"order": \(i), "asset_id": "\(aid)", "source_start_seconds": 0.0, "source_end_seconds": 3.0,
             "output_duration_seconds": 3.0, "speed": 1.0, "native_audio": "keep"}
            """
        }.joined(separator: ",")
        let json = """
        {"schema_version": "edit_plan/2", "target_duration_seconds": \(Double(momentIds.count) * 3.0),
         "output_format": "vertical", "feasible": true, "segments": [\(segs)]}
        """
        let o = GeneratedOutputModel(title: "v", durationSeconds: Double(momentIds.count) * 3.0,
                                     momentIds: momentIds.compactMap { UUID(uuidString: $0) },
                                     relativeFilePath: "out/\(versionId).mp4",
                                     versionId: versionId, operationType: "original", editPlanJSON: json)
        ctx.insert(o)
        return o
    }

    func test_summary_has_sequence_opening_ending() {
        let a = UUID().uuidString, b = UUID().uuidString
        let o = output(momentIds: [a, b])
        guard case let .object(obj)? = RevisionContextBuilder.summary(of: o) else {
            return XCTFail("expected a summary object")
        }
        XCTAssertEqual(obj["opening_moment_id"], .string(a))
        XCTAssertEqual(obj["ending_moment_id"], .string(b))
        XCTAssertEqual(obj["shot_count"], .number(2))
    }

    func test_summary_nil_without_plan() {
        let o = GeneratedOutputModel(title: "legacy", durationSeconds: 10, momentIds: [],
                                     operationType: "original", editPlanJSON: nil)
        ctx.insert(o)
        XCTAssertNil(RevisionContextBuilder.summary(of: o), "no editPlanJSON => no fabricated summary")
    }

    func test_explore_context_mode_and_base_version() {
        let a = UUID().uuidString, b = UUID().uuidString
        let parent = output(momentIds: [a, b])
        guard case let .object(obj)? = RevisionContextBuilder.explore(parent: parent, recents: []) else {
            return XCTFail("expected explore context")
        }
        XCTAssertEqual(obj["mode"], .string("explore"))
        XCTAssertEqual(obj["base_version_id"], .string((parent.versionId ?? parent.id).uuidString))
        if case let .array(sums)? = obj["prior_edit_summaries"] { XCTAssertEqual(sums.count, 1) }
        else { XCTFail("expected prior_edit_summaries array") }
    }

    func test_explore_history_bounded() {
        let a = UUID().uuidString
        let parent = output(momentIds: [a])
        let recents = (0..<10).map { _ in output(momentIds: [UUID().uuidString]) }
        guard case let .object(obj)? = RevisionContextBuilder.explore(parent: parent, recents: recents),
              case let .array(sums)? = obj["prior_edit_summaries"] else {
            return XCTFail("expected bounded summaries")
        }
        XCTAssertLessThanOrEqual(sums.count, RevisionContextBuilder.maxSummaries)
    }

    func test_diversity_identical_is_near_identical() {
        let a = UUID().uuidString, b = UUID().uuidString
        let parent = output(momentIds: [a, b])
        // Decode the parent's own plan as the "new" plan => identical.
        let plan = try! StoryContractCoding.decoder().decode(
            EditPlanV2.self, from: parent.editPlanJSON!.data(using: .utf8)!)
        let d = RevisionContextBuilder.diversity(parent: parent, newPlan: plan)
        XCTAssertEqual(d.momentSetJaccard, 1.0)
        XCTAssertTrue(d.nearIdentical)
        XCTAssertFalse(d.openingChanged)
        XCTAssertFalse(d.orderChanged)
    }

    func test_diversity_reordered_detected() {
        let a = UUID().uuidString, b = UUID().uuidString
        let parent = output(momentIds: [a, b])
        let newPlan = try! StoryContractCoding.decoder().decode(
            EditPlanV2.self, from: output(momentIds: [b, a]).editPlanJSON!.data(using: .utf8)!)
        let d = RevisionContextBuilder.diversity(parent: parent, newPlan: newPlan)
        XCTAssertEqual(d.momentSetJaccard, 1.0)
        XCTAssertTrue(d.openingChanged)
        XCTAssertTrue(d.endingChanged)
        XCTAssertTrue(d.orderChanged)
        XCTAssertFalse(d.nearIdentical)
    }

    func test_diversity_different_set() {
        let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString
        let parent = output(momentIds: [a, b])
        let newPlan = try! StoryContractCoding.decoder().decode(
            EditPlanV2.self, from: output(momentIds: [a, c]).editPlanJSON!.data(using: .utf8)!)
        let d = RevisionContextBuilder.diversity(parent: parent, newPlan: newPlan)
        XCTAssertGreaterThan(d.momentSetJaccard, 0.0)
        XCTAssertLessThan(d.momentSetJaccard, 1.0)
        XCTAssertFalse(d.nearIdentical)
    }
}
