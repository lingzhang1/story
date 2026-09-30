import XCTest
import SwiftData
@testable import Story

// Foundation tests for the Milestone A slice. These use an in-memory
// ModelContainer so they run without touching disk or the device.
//
// Covered (spec Part 7 — iOS):
//   - Story creation / persistence
//   - Moment creation / persistence
//   - GeneratedOutput persistence
//   - active/completed status model (Create != Complete)
//   - media-path resolution

@MainActor
final class StoryFoundationTests: XCTestCase {
    private var container: ModelContainer!
    private var repo: StoryRepository!
    private var useCases: StoryUseCases!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
            configurations: config
        )
        repo = StoryRepository(context: container.mainContext)
        useCases = StoryUseCases(repository: repo)
    }

    func testCreateStory() throws {
        let story = try useCases.startStory(title: "TMB", direction: "hiking mont blanc")
        XCTAssertEqual(story.title, "TMB")
        XCTAssertEqual(story.status, .active)
        XCTAssertFalse(story.intentTheme.isEmpty)
        XCTAssertFalse(story.intentTone.isEmpty)
    }

    func testStoryPersistsAndRefetches() throws {
        let story = try useCases.startStory(title: "TMB", direction: "hiking mont blanc")
        let id = story.id
        let fetched = try repo.fetchStories()
        XCTAssertTrue(fetched.contains { $0.id == id })
    }

    func testCreativeIntentIsDeterministic() throws {
        let engine = MockStoryEngine()
        let a = engine.deriveCreativeIntent(from: "same text")
        let b = engine.deriveCreativeIntent(from: "same text")
        XCTAssertEqual(a, b)
    }

    func testAddMomentPersists() throws {
        let story = try useCases.startStory(title: "TMB", direction: "hiking")
        let moment = try useCases.shootMoment(
            for: story, relativePath: "media/test.mov", durationSeconds: 6.0)
        XCTAssertEqual(story.moments.count, 1)
        XCTAssertEqual(moment.asset?.relativePath, "media/test.mov")
        XCTAssertEqual(moment.asset?.durationSeconds, 6.0)
    }

    func testMomentSurvivesRefetch() throws {
        let story = try useCases.startStory(title: "TMB", direction: "hiking")
        _ = try useCases.shootMoment(for: story, relativePath: "media/a.mov", durationSeconds: 5)
        let refetched = try repo.fetchStories().first { $0.id == story.id }
        XCTAssertEqual(refetched?.moments.count, 1)
        XCTAssertEqual(refetched?.moments.first?.asset?.relativePath, "media/a.mov")
    }

    func testCreateOutputPersistsAndDoesNotCompleteStory() throws {
        let story = try useCases.startStory(title: "TMB", direction: "hiking")
        _ = try useCases.shootMoment(for: story, relativePath: "media/a.mov", durationSeconds: 5)
        let output = try useCases.createStoryOutput(for: story)

        XCTAssertEqual(story.generatedOutputs.count, 1)
        XCTAssertEqual(output.momentIds.count, 1)
        // INVARIANT: Create != Complete.
        XCTAssertEqual(story.status, .active)
    }

    func testMultipleOutputsAllowed() throws {
        let story = try useCases.startStory(title: "TMB", direction: "hiking")
        _ = try useCases.shootMoment(for: story, relativePath: "media/a.mov", durationSeconds: 5)
        _ = try useCases.createStoryOutput(for: story)
        _ = try useCases.createStoryOutput(for: story)
        XCTAssertEqual(story.generatedOutputs.count, 2)
        XCTAssertEqual(story.status, .active)
    }

    func testStatusModel() throws {
        let story = try useCases.startStory(title: "TMB", direction: "hiking")
        XCTAssertEqual(story.status, .active)
        story.status = .completed
        XCTAssertEqual(story.statusRaw, "completed")
        XCTAssertEqual(story.status, .completed)
    }

    func testMediaPathResolution() throws {
        let store = MediaStore.shared
        let rel = store.newRelativeVideoPath()
        XCTAssertTrue(rel.hasPrefix("media/"))
        XCTAssertTrue(rel.hasSuffix(".mov"))
        let abs = store.absoluteURL(for: rel)
        XCTAssertTrue(abs.path.contains("media/"))
        // Non-existent file resolves but does not exist.
        XCTAssertFalse(store.fileExists(relativePath: rel))
    }
}
