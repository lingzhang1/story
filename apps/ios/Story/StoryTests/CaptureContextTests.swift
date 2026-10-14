import XCTest
import SwiftData
@testable import Story

// CaptureContext tests (Capture Anywhere, Priority 2/3). Pure logic — no camera,
// no network. Proves the ONE guarantee that keeps standalone AI honest: a
// standalone capture's Director intent carries NO Story identity and NO prior
// Story's creative context (no stale-context leak), while a Story capture does.
@MainActor
final class CaptureContextTests: XCTestCase {

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

    private func makeStory(_ title: String, summary: String) -> StoryModel {
        let s = StoryModel(title: title, intentRawText: summary, intentTheme: "th",
                           intentTone: "to", intentSummary: summary)
        ctx.insert(s); return s
    }

    // Standalone with no direction → neutral intent, ephemeral id, no Story summary.
    func test_standaloneIntent_isNeutral_noStoryLeak() {
        let story = makeStory("Alpine Journey", summary: "Cinematic hike across the Alps")
        let storyIntent = CaptureContext.story(story).directorIntent()

        let standalone = CaptureContext.standalone(direction: nil).directorIntent()
        XCTAssertNotEqual(standalone.id, storyIntent.id, "standalone must not reuse the Story's intent id")
        XCTAssertNotEqual(standalone.summary, storyIntent.summary,
                          "standalone must not inherit the Story's creative summary (stale leak)")
        XCTAssertFalse(standalone.summary.contains("Alps"), "no prior-Story text leaks into standalone")
        XCTAssertNil(standalone.subject)
        XCTAssertTrue(standalone.desiredFeeling.isEmpty)
        XCTAssertTrue(standalone.styleTags.isEmpty)
    }

    // Standalone WITH user direction → that text is the intent (and nothing else).
    func test_standaloneIntent_usesUserDirectionOnly() {
        let standalone = CaptureContext.standalone(direction: "slow pan of the ridge").directorIntent()
        XCTAssertEqual(standalone.summary, "slow pan of the ridge")
        XCTAssertEqual(standalone.rawUserDescription, "slow pan of the ridge")
    }

    // Two standalone intents get DISTINCT ephemeral ids (never a persisted Story id).
    func test_standaloneIntent_idsAreEphemeralAndDistinct() {
        let a = CaptureContext.standalone(direction: nil).directorIntent()
        let b = CaptureContext.standalone(direction: nil).directorIntent()
        XCTAssertNotEqual(a.id, b.id)
    }

    // Story context exposes the Story + its target duration; standalone exposes neither.
    func test_associationAndTargetDuration() {
        let story = makeStory("S", summary: "x")
        XCTAssertNotNil(CaptureContext.story(story).associatedStory)
        XCTAssertFalse(CaptureContext.story(story).isStandalone)
        XCTAssertNil(CaptureContext.standalone(direction: nil).associatedStory)
        XCTAssertTrue(CaptureContext.standalone(direction: nil).isStandalone)
        XCTAssertNil(CaptureContext.standalone(direction: nil).targetDurationSeconds)
    }
}
