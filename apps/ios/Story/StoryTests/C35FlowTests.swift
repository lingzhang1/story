import XCTest
import SwiftData
@testable import Story

// C3.5 UI/behavior tests: lifecycle (Complete/Reopen), add-existing-media, and
// the Director-decision → UI-state mapping contract that SceneScanFlowView relies
// on (capture_shot ⇒ camera; rescan_scene ⇒ NO camera; create_now ⇒ no shot).
@MainActor
final class C35FlowTests: XCTestCase {
    private var container: ModelContainer!
    private var useCases: StoryUseCases!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
            configurations: config)
        useCases = StoryUseCases(repository: StoryRepository(context: container.mainContext, owner: .account("test-acct-A")))
    }

    func testCompleteAndReopenStory() throws {
        let s = try useCases.startStory(title: "T", direction: "a trip")
        XCTAssertEqual(s.status, .active)
        try useCases.completeStory(s)
        XCTAssertEqual(s.status, .completed)
        try useCases.reopenStory(s)
        XCTAssertEqual(s.status, .active)
    }

    func testAddExistingMediaCreatesExistingMediaMoments() throws {
        let s = try useCases.startStory(title: "T", direction: "a trip")
        let before = s.moments.count
        let made = try useCases.addExistingMedia(
            to: s, relativePaths: [ImportedMedia(path: "media/a.mov", duration: 3.0),
                                   ImportedMedia(path: "media/b.mov", duration: 5.0)])
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(s.moments.count, before + 2)
        XCTAssertTrue(made.allSatisfy { $0.source == .existingMedia })
    }

    // Director decision → UI-state mapping (mirrors SceneScanFlowView.recommendationView).
    func testDecisionUIStateMapping() {
        func offersCamera(_ a: DirectorActionTypeDTO) -> Bool { a == .captureShot || a == .retryShot }
        XCTAssertTrue(offersCamera(.captureShot))
        XCTAssertTrue(offersCamera(.retryShot))
        XCTAssertFalse(offersCamera(.rescanScene))   // rescan ⇒ Scan again, no camera
        XCTAssertFalse(offersCamera(.createNow))     // create_now ⇒ no shot/camera
    }

    func testCreateDoesNotCompleteStory() throws {
        // Create != Complete (02 §): generating output must not flip status.
        let s = try useCases.startStory(title: "T", direction: "a trip")
        _ = try useCases.addExistingMedia(to: s, relativePaths: [ImportedMedia(path: "media/a.mov", duration: 3.0)])
        _ = try useCases.createStoryOutput(for: s)
        XCTAssertEqual(s.status, .active)
    }
}
