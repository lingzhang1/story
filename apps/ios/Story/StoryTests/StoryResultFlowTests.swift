import SwiftData
import XCTest
@testable import Story

// StoryResultFlow / Creating-Result decision tests (R-c Batch B §4). DETERMINISTIC, no real playback, no Photos,
// no share — only the PURE decision logic extracted from the two production SwiftUI screens:
//   * CreatingPhase.from(coordinator.State)        — state -> UI phase mapping (+ cancel affordance rule)
//   * ReopenDecision.decide(...)                   — existing good output -> Result; else create
//   * ResultPlayback.resolve(...)                  — file present -> playable; missing -> recoverable
//   * MusicPresentation.decide(...)                — honest no-music vs soundtrack-unavailable copy
//   * RenderOutputStore URL resolution             — Save/Share derive the URL from the store
// Playback / Save-to-Photos / Share success are the device gate and NOT asserted here.
@MainActor
final class StoryResultFlowTests: XCTestCase {

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

    private func newStory() -> StoryModel {
        let s = StoryModel(title: "Learning Guitar", intentRawText: "x", intentTheme: "growth",
                           intentTone: "warm", intentSummary: "y")
        ctx.insert(s)
        return s
    }

    @discardableResult
    private func output(_ story: StoryModel, rel: String?, stale: Bool = false,
                        createdAt: Date = .now, momentIds: [UUID] = []) -> GeneratedOutputModel {
        let o = GeneratedOutputModel(title: story.title, durationSeconds: 8, momentIds: momentIds,
                                     relativeFilePath: rel, sourceMomentIds: momentIds,
                                     sourceFingerprint: "fp", isStale: stale, createdAt: createdAt)
        o.story = story
        ctx.insert(o)
        story.generatedOutputs.append(o)
        return o
    }

    // MARK: - State -> CreatingPhase mapping

    func test_creatingPhase_mapsEveryState() {
        let dummy = GeneratedOutputModel(title: "t", durationSeconds: 3, momentIds: [])
        XCTAssertEqual(CreatingPhase.from(.idle), .indeterminate(status: "Getting your moments ready…"))
        XCTAssertEqual(CreatingPhase.from(.preparing), .indeterminate(status: "Getting your moments ready…"))
        XCTAssertEqual(CreatingPhase.from(.planning), .indeterminate(status: "Planning your Story…"))
        XCTAssertEqual(CreatingPhase.from(.validating), .indeterminate(status: "Checking the plan…"))
        XCTAssertEqual(CreatingPhase.from(.rendering(progress: 0.42)), .determinate(progress: 0.42))
        XCTAssertEqual(CreatingPhase.from(.failed(message: "nope")), .failed(message: "nope"))
        XCTAssertEqual(CreatingPhase.from(.cancelled), .cancelled)
        XCTAssertEqual(CreatingPhase.from(.completed(dummy)), .completed)
    }

    func test_creatingPhase_clampsRenderingProgress() {
        XCTAssertEqual(CreatingPhase.from(.rendering(progress: -0.5)), .determinate(progress: 0))
        XCTAssertEqual(CreatingPhase.from(.rendering(progress: 1.9)), .determinate(progress: 1))
    }

    func test_creatingPhase_cancelAffordanceOnlyWhileWorking() {
        XCTAssertTrue(CreatingPhase.indeterminate(status: "x").allowsCancel)
        XCTAssertTrue(CreatingPhase.determinate(progress: 0.3).allowsCancel)
        XCTAssertFalse(CreatingPhase.failed(message: "x").allowsCancel)
        XCTAssertFalse(CreatingPhase.cancelled.allowsCancel)
        XCTAssertFalse(CreatingPhase.completed.allowsCancel)
    }

    // MARK: - Reopen decision

    func test_reopen_existingGoodOutput_opensResultDirectly() {
        let s = newStory()
        let good = output(s, rel: "rendered/good.mp4")
        let decision = ReopenDecision.decide(outputs: s.generatedOutputs,
                                             isStale: { _ in false },
                                             fileExists: { _ in true })
        XCTAssertEqual(decision, .showResult(outputId: good.id))
    }

    func test_reopen_missingFile_fallsToCreate() {
        let s = newStory()
        output(s, rel: "rendered/gone.mp4")
        let decision = ReopenDecision.decide(outputs: s.generatedOutputs,
                                             isStale: { _ in false },
                                             fileExists: { _ in false })   // file not on disk
        XCTAssertEqual(decision, .create)
    }

    func test_reopen_staleOutput_fallsToCreate() {
        let s = newStory()
        output(s, rel: "rendered/stale.mp4", stale: true)
        let decision = ReopenDecision.decide(outputs: s.generatedOutputs,
                                             isStale: { $0.isStale },
                                             fileExists: { _ in true })
        XCTAssertEqual(decision, .create)   // stale is not reopened; the flow offers a fresh render
    }

    func test_reopen_noOutputs_create() {
        let s = newStory()
        let decision = ReopenDecision.decide(outputs: s.generatedOutputs,
                                             isStale: { _ in false }, fileExists: { _ in true })
        XCTAssertEqual(decision, .create)
    }

    func test_reopen_picksNewestGoodOutput() {
        let s = newStory()
        let old = output(s, rel: "rendered/old.mp4", createdAt: Date(timeIntervalSince1970: 1000))
        let new = output(s, rel: "rendered/new.mp4", createdAt: Date(timeIntervalSince1970: 2000))
        let decision = ReopenDecision.decide(outputs: s.generatedOutputs,
                                             isStale: { _ in false }, fileExists: { _ in true })
        XCTAssertEqual(decision, .showResult(outputId: new.id))
        _ = old
    }

    func test_reopen_skipsNilRelativePath() {
        let s = newStory()
        output(s, rel: nil)   // mock/legacy row with no file
        let decision = ReopenDecision.decide(outputs: s.generatedOutputs,
                                             isStale: { _ in false }, fileExists: { _ in true })
        XCTAssertEqual(decision, .create)
    }

    // MARK: - Result playback resolution

    func test_resultPlayback_playableWhenFileExists() {
        let s = newStory()
        let o = output(s, rel: "rendered/ok.mp4")
        XCTAssertEqual(ResultPlayback.resolve(output: o, fileExists: { _ in true }),
                       .playable(relativePath: "rendered/ok.mp4"))
    }

    func test_resultPlayback_missingWhenFileGone() {
        let s = newStory()
        let o = output(s, rel: "rendered/ok.mp4")
        XCTAssertEqual(ResultPlayback.resolve(output: o, fileExists: { _ in false }), .missing)
    }

    func test_resultPlayback_missingWhenNoRelativePath() {
        let s = newStory()
        let o = output(s, rel: nil)
        XCTAssertEqual(ResultPlayback.resolve(output: o, fileExists: { _ in true }), .missing)
    }

    // MARK: - Music presentation (honest copy)

    func test_music_noMusic_isCreatedWithoutMusic() {
        XCTAssertEqual(MusicPresentation.decide(intendedSoundtrack: false, soundtrackIncluded: false),
                       .createdWithoutMusic)
        XCTAssertEqual(MusicPresentation.createdWithoutMusic.copy, "Created without music")
    }

    func test_music_intendedButMissing_isSoundtrackUnavailable() {
        XCTAssertEqual(MusicPresentation.decide(intendedSoundtrack: true, soundtrackIncluded: false),
                       .soundtrackUnavailable)
        XCTAssertNotEqual(MusicPresentation.soundtrackUnavailable.copy, MusicPresentation.createdWithoutMusic.copy)
    }

    func test_music_copyNeverImpliesAFakeTrack() {
        // Neither copy string contains a track-name placeholder or implies Epidemic music was used.
        for p in [MusicPresentation.createdWithoutMusic, .soundtrackUnavailable] {
            XCTAssertFalse(p.copy.contains("♫"))
            XCTAssertFalse(p.copy.lowercased().contains("track:"))
        }
    }

    // MARK: - Save/Share derive the URL from RenderOutputStore

    func test_outputURL_resolvedFromRenderOutputStore() {
        let rel = "rendered/share-me.mp4"
        let url = RenderOutputStore.shared.absoluteURL(for: rel)
        XCTAssertTrue(url.path.hasSuffix(rel))                       // Save/Share build the activity URL from this
        XCTAssertTrue(url.isFileURL)
    }
}
