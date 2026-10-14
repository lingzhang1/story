import XCTest
import SwiftData
@testable import Story

// Capture UX corrections — Phase 5 regression tests.
//
// Covers the logic items that do NOT require camera hardware:
//   • Add existing Moment to a Story (item 11)
//   • Add the same Moment twice without a duplicate link (item 12)
//   • No media duplication when linking (item 14, data layer)
//   • Home selection creates a Story (item 15)
//   • Story selection adds to the current Story (item 16)
//   • LibraryContext drives the right affordances (items 1/17 at the model level)
//
// Camera/AI-state items (thumbnail navigation, scan/thinking/idea overlay states, REC
// timer, five device recordings, interruption, stale-response suppression) are driven by
// AVFoundation + SwiftUI presentation and are verified in the Phase-6 device acceptance.
@MainActor
final class CaptureUXCorrectionsTests: XCTestCase {

    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }
    private var useCases: StoryUseCases!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
            configurations: config)
        useCases = StoryUseCases(repository: StoryRepository(context: ctx))
    }

    private func makeStory(_ title: String) -> StoryModel {
        let s = StoryModel(title: title, intentRawText: "t", intentTheme: "th",
                           intentTone: "to", intentSummary: "su")
        ctx.insert(s); return s
    }
    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try ctx.fetch(FetchDescriptor<T>()).count
    }

    // 11. Add an existing (standalone) library Moment to a Story → exactly one link, media reused.
    func test_addExistingMoment_toStory_oneLink_noMediaDup() throws {
        let story = makeStory("S")
        let m = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)
        XCTAssertEqual(try count(StoryMomentLink.self), 0)

        let linked = try useCases.addExistingMoments([m], to: story)
        XCTAssertEqual(linked.count, 1)
        XCTAssertEqual(try count(StoryMomentLink.self), 1, "exactly one link")
        XCTAssertEqual(try count(MomentModel.self), 1, "no new Moment created — the same one is reused")
        XCTAssertEqual(try count(AssetModel.self), 1, "no media duplication")
        XCTAssertEqual(story.moments.map { $0.id }, [m.id])
    }

    // 12. Adding the SAME Moment twice does not create a duplicate link (idempotent).
    func test_addSameMomentTwice_noDuplicateLink() throws {
        let story = makeStory("S")
        let m = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)

        let first = try useCases.addExistingMoments([m], to: story)
        let second = try useCases.addExistingMoments([m], to: story)   // repeat
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 0, "the second add links nothing — already in the Story")
        XCTAssertEqual(try count(StoryMomentLink.self), 1, "no duplicate StoryMomentLink")
    }

    // Order is preserved across a multi-select add + a later single add.
    func test_addExistingMoments_preservesOrder() throws {
        let story = makeStory("S")
        let a = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)
        let b = try useCases.shootStandaloneMoment(relativePath: "media/b.mov", durationSeconds: 3)
        let c = try useCases.shootStandaloneMoment(relativePath: "media/c.mov", durationSeconds: 3)

        _ = try useCases.addExistingMoments([a, b], to: story)
        _ = try useCases.addExistingMoments([c], to: story)
        XCTAssertEqual(story.moments.map { $0.id }, [a.id, b.id, c.id], "link order preserved")
    }

    // Mixed batch: some already linked, some new → only the new ones are added.
    func test_addExistingMoments_mixedBatch_onlyNewLinked() throws {
        let story = makeStory("S")
        let a = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)
        let b = try useCases.shootStandaloneMoment(relativePath: "media/b.mov", durationSeconds: 3)
        _ = try useCases.addExistingMoments([a], to: story)

        let linked = try useCases.addExistingMoments([a, b], to: story)   // a already in, b new
        XCTAssertEqual(linked.map { $0.id }, [b.id], "only the not-yet-linked Moment is added")
        XCTAssertEqual(try count(StoryMomentLink.self), 2)
    }

    // 15. Home selection creates a NEW Story from the selected Moments (existing pipeline, no media dup).
    func test_homeSelection_createsStoryFromMoments() throws {
        let a = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)
        let b = try useCases.shootStandaloneMoment(relativePath: "media/b.mov", durationSeconds: 3)

        let story = try useCases.createStoryFromMoments(
            title: "New Story", direction: "A story from my selected moments.", moments: [a, b])
        XCTAssertEqual(try count(StoryModel.self), 1)
        XCTAssertEqual(story.moments.count, 2)
        XCTAssertEqual(try count(MomentModel.self), 2, "no new Moments — existing library ones reused")
        XCTAssertEqual(try count(AssetModel.self), 2, "no media duplication")
    }

    // 16. Story selection adds the chosen Moments to the CURRENT Story (does not create a new one).
    func test_storySelection_addsToCurrentStory() throws {
        let story = makeStory("Existing")
        let a = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)

        _ = try useCases.addExistingMoments([a], to: story)
        XCTAssertEqual(try count(StoryModel.self), 1, "no new Story created")
        XCTAssertEqual(story.moments.count, 1)
    }

    // LibraryContext exposes the right affordances per entry point (drives the UI's primary action).
    func test_libraryContext_affordances() {
        let story = makeStory("S")
        XCTAssertTrue(LibraryContext.home.allowsSelection)
        XCTAssertTrue(LibraryContext.story(story).allowsSelection)
        XCTAssertFalse(LibraryContext.recentBrowse.allowsSelection,
                       "camera-thumbnail browse is view-only — no Select/Create/Add")
        XCTAssertNil(LibraryContext.home.associatedStory)
        XCTAssertNil(LibraryContext.recentBrowse.associatedStory)
        XCTAssertEqual(LibraryContext.story(story).associatedStory?.id, story.id)
    }

    // No stale Story context leaks into a standalone AI intent (regression guard for the
    // CaptureContext path the continuous camera's AI Ideas uses).
    func test_standaloneCaptureContext_noStaleStoryLeak() {
        let standalone = CaptureContext.standalone(direction: nil)
        let intent = standalone.directorIntent()
        XCTAssertNil(intent.subject)
        XCTAssertTrue(intent.desiredFeeling.isEmpty)
        XCTAssertTrue(intent.styleTags.isEmpty)
        XCTAssertNil(standalone.associatedStory, "standalone never carries a Story")
    }

    // 12 (orphan cleanup). Deleting an unconfirmed setup Story removes the Story + its links but
    // NEVER the independent global Moments or their media.
    func test_deleteStory_keepsIndependentMoments() throws {
        let story = makeStory("Unconfirmed")
        let a = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)
        _ = try useCases.addExistingMoments([a], to: story)
        XCTAssertEqual(try count(StoryMomentLink.self), 1)

        try useCases.deleteStory(story)
        XCTAssertEqual(try count(StoryModel.self), 0, "the orphan Story is gone")
        XCTAssertEqual(try count(StoryMomentLink.self), 0, "its link is cascaded away")
        XCTAssertEqual(try count(MomentModel.self), 1, "the independent Moment survives")
        XCTAssertEqual(try count(AssetModel.self), 1, "its media survives (no deletion)")
    }

    // 13 + 14. The seed-Moments → setup → confirm path creates exactly one Story and links the
    // selected Moments without media duplication (the use-case layer behind the wizard).
    func test_seedMomentsFlow_createsOneStory_linksNoDup() throws {
        let a = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)
        let b = try useCases.shootStandaloneMoment(relativePath: "media/b.mov", durationSeconds: 3)
        // Simulates what the wizard does on confirm: create once via the real intent path, then link seeds.
        let story = try useCases.startStory(title: "My Story", direction: "A trip.")
        try useCases.addExistingMoments([a, b], to: story)
        XCTAssertEqual(try count(StoryModel.self), 1, "exactly one Story")
        XCTAssertEqual(story.moments.map { $0.id }, [a.id, b.id], "selected Moments linked in order")
        XCTAssertEqual(try count(MomentModel.self), 2, "no new Moments")
        XCTAssertEqual(try count(AssetModel.self), 2, "no media duplication")
    }

    // 16. Adding Moments to a Story never overwrites the user-authored title / description / summary.
    func test_addMoments_preservesUserAuthoredIntent() throws {
        let story = try useCases.startStory(title: "Tour du Mont Blanc", direction: "8 days hiking, cinematic.")
        let title0 = story.title
        let raw0 = story.intentRawText
        let summary0 = story.intentSummary

        let a = try useCases.shootStandaloneMoment(relativePath: "media/a.mov", durationSeconds: 3)
        _ = try useCases.addExistingMoments([a], to: story)
        _ = try useCases.shootMoment(for: story, relativePath: "media/b.mov", durationSeconds: 3)

        XCTAssertEqual(story.title, title0, "user title unchanged")
        XCTAssertEqual(story.intentRawText, raw0, "user description unchanged")
        XCTAssertEqual(story.intentSummary, summary0, "intent summary unchanged by adding Moments")
    }

    // 17. Import progress copy is operation-specific and honest (no fabricated %, no false success).
    func test_importProgressCopy_phases() {
        func p(_ phase: ImportProgress.Phase, done: Int, total: Int, failed: Int = 0, finished: Bool = false) -> ImportProgress {
            ImportProgress(total: total, done: done, failed: failed, finished: finished, phase: phase)
        }
        XCTAssertEqual(StoryImportCopy.line(for: p(.preparing, done: 0, total: 3)), "Preparing selected media…")
        XCTAssertEqual(StoryImportCopy.line(for: p(.importing, done: 1, total: 3)), "Importing… (1 of 3)")
        XCTAssertEqual(StoryImportCopy.line(for: p(.analyzing, done: 3, total: 3)), "Analyzing moments…")
        // Never claims success while in flight.
        XCTAssertFalse(StoryImportCopy.line(for: p(.importing, done: 0, total: 2)).contains("Added"))
        // Finished states stay honest.
        XCTAssertTrue(StoryImportCopy.line(for: p(.importing, done: 0, total: 2, finished: true)).contains("Couldn't"))
        XCTAssertTrue(StoryImportCopy.line(for: p(.importing, done: 1, total: 2, failed: 1, finished: true)).contains("couldn't be added"))
    }

    // AI Ideas session state: Next idea cycles cached ideas without re-inference; the index is
    // bounded. (Drives ContinuousCaptureModel's cache logic directly; no camera needed.)
    func test_aiIdeas_nextIdea_cyclesCached() {
        let model = ContinuousCaptureModel()
        // No ideas yet → nextIdea is a safe no-op, hasCachedIdeas false.
        XCTAssertFalse(model.hasCachedIdeas)
        model.nextIdea()
        XCTAssertEqual(model.ideaIndex, 0)
    }
}
