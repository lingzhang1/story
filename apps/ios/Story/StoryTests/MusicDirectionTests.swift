import XCTest
import SwiftData
@testable import Story

// M-c MusicDirection lifecycle tests. Groups:
//   1. Inference: ensure() infers once + persists (not user-authored).
//   2. Persistence/relaunch: a persisted direction is returned without re-inferring.
//   3. User override: save(userEdit:) marks userAuthored; ensure() never overwrites it.
//   4. Legacy migration: a Story with no direction gets a default inferred (no recreation).
//   5. Fingerprint: changes when the direction changes (future MusicPlan staleness).
//   6. DTO decode: wire music_direction JSON round-trips.
@MainActor
final class MusicDirectionTests: XCTestCase {
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

    private final class FakeInfer: MusicDirectionInferring {
        var calls = 0
        var error: Error?
        init(error: Error? = nil) { self.error = error }
        func infer(_ request: MusicDirectionRequestDTO) async throws -> MusicDirectionContractDTO {
            calls += 1
            if let error { throw error }
            return MusicDirectionContractDTO(
                summary: "An emotional soundtrack for this story", moodTags: ["emotional"],
                energy: .medium, progression: nil, rawUserDescription: nil)
        }
    }

    private func newStory() -> StoryModel {
        let s = StoryModel(title: "T", intentRawText: "learning guitar", intentTheme: "",
                           intentTone: "", intentSummary: "learning guitar")
        ctx.insert(s); try? ctx.save()
        return s
    }

    func testEnsureInfersOnceAndPersists() async {
        let fake = FakeInfer()
        let coord = MusicDirectionCoordinator(context: ctx, service: fake)
        let s = newStory()
        let d1 = await coord.ensure(for: s, guideFramingSummary: "a first song")
        XCTAssertEqual(d1?.moodTags, ["emotional"])
        XCTAssertFalse(coord.isUserAuthored(for: s.id))
        // second ensure does NOT re-infer (persisted).
        _ = await coord.ensure(for: s, guideFramingSummary: "a first song")
        XCTAssertEqual(fake.calls, 1)
    }

    func testPersistedDirectionReturnedWithoutInference() async {
        let fake = FakeInfer()
        let coord = MusicDirectionCoordinator(context: ctx, service: fake)
        let s = newStory()
        _ = await coord.ensure(for: s, guideFramingSummary: nil)
        // simulate relaunch: a fresh coordinator over the same context
        let coord2 = MusicDirectionCoordinator(context: ctx, service: FakeInfer())
        XCTAssertNotNil(coord2.direction(for: s.id))
    }

    func testUserOverrideNeverOverwrittenByInference() async {
        let fake = FakeInfer()
        let coord = MusicDirectionCoordinator(context: ctx, service: fake)
        let s = newStory()
        let edit = MusicDirectionContractDTO(summary: "A dreamy soundtrack", moodTags: ["dreamy"],
                                             energy: nil, progression: nil, rawUserDescription: "dreamy and soft")
        coord.save(userEdit: edit, for: s.id)
        XCTAssertTrue(coord.isUserAuthored(for: s.id))
        // ensure() must return the user's choice untouched, never calling infer.
        let after = await coord.ensure(for: s, guideFramingSummary: "x")
        XCTAssertEqual(after?.moodTags, ["dreamy"])
        XCTAssertEqual(fake.calls, 0)
        XCTAssertTrue(coord.isUserAuthored(for: s.id))
    }

    func testLegacyMigrationInfersDefaultNoRecreation() async {
        // A Story that already exists with no direction row = legacy. ensure() backfills a default.
        let s = newStory()
        let coord = MusicDirectionCoordinator(context: ctx, service: FakeInfer())
        XCTAssertNil(coord.direction(for: s.id))
        let d = await coord.ensure(for: s, guideFramingSummary: nil)
        XCTAssertNotNil(d)
        XCTAssertFalse(coord.isUserAuthored(for: s.id))  // inferred default, not user-authored
    }

    func testFingerprintChangesWithDirection() async {
        let coord = MusicDirectionCoordinator(context: ctx, service: FakeInfer())
        let s = newStory()
        _ = await coord.ensure(for: s, guideFramingSummary: nil)
        let fp1 = coord.fingerprint(for: s.id)
        coord.save(userEdit: MusicDirectionContractDTO(summary: "A chill soundtrack", moodTags: ["chill"],
                   energy: nil, progression: nil, rawUserDescription: nil), for: s.id)
        let fp2 = coord.fingerprint(for: s.id)
        XCTAssertFalse(fp1.isEmpty)
        XCTAssertNotEqual(fp1, fp2)   // future MusicPlan cache can detect the change
    }

    func testInferenceFailureLeavesStoryValid() async {
        let coord = MusicDirectionCoordinator(context: ctx,
            service: FakeInfer(error: MusicDirectionServiceError.badStatus(503)))
        let s = newStory()
        let d = await coord.ensure(for: s, guideFramingSummary: nil)
        XCTAssertNil(d)                       // no fabrication
        XCTAssertNil(coord.direction(for: s.id))  // retryable, Story unaffected
    }

    func testDTODecodeWireJSON() throws {
        let json = """
        {"summary":"An emotional soundtrack","mood_tags":["emotional","intimate"],"energy":"low","progression":null,"raw_user_description":null}
        """.data(using: .utf8)!
        let dto = try StoryContractCoding.decoder().decode(MusicDirectionContractDTO.self, from: json)
        XCTAssertEqual(dto.moodTags, ["emotional", "intimate"])
        XCTAssertEqual(dto.energy, .low)
    }
}
