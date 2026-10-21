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

    // R7-D — a verified cloud backup makes an absent-local output RESTORABLE, not missing (restore, not re-render).
    func test_resultPlayback_restorableWhenLocalGoneButCloudVerified() {
        let s = newStory()
        let o = output(s, rel: "rendered/evicted.mp4")
        o.cloudMediaId = "cm-1"; o.cloudVerifiedAt = .now
        XCTAssertEqual(ResultPlayback.resolve(output: o, fileExists: { _ in false }), .restorable)
    }

    func test_resultPlayback_restorableOnDeviceBWithNoLocalPath() {
        let s = newStory()
        let o = output(s, rel: nil)                 // Device B: never had a local render
        o.cloudMediaId = "cm-2"; o.cloudVerifiedAt = .now
        XCTAssertEqual(ResultPlayback.resolve(output: o, fileExists: { _ in true }), .restorable)
    }

    func test_resultPlayback_missingWhenCloudRefButNotVerified() {
        let s = newStory()
        let o = output(s, rel: "rendered/gone.mp4")
        o.cloudMediaId = "cm-3"; o.cloudVerifiedAt = nil   // ref present but not verified -> not restorable
        XCTAssertEqual(ResultPlayback.resolve(output: o, fileExists: { _ in false }), .missing)
    }

    func test_resultPlayback_playableWinsOverCloud() {
        let s = newStory()
        let o = output(s, rel: "rendered/ok.mp4")
        o.cloudMediaId = "cm-4"; o.cloudVerifiedAt = .now   // backed up AND local present -> play local
        XCTAssertEqual(ResultPlayback.resolve(output: o, fileExists: { _ in true }),
                       .playable(relativePath: "rendered/ok.mp4"))
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

    // MARK: - Issue 1: Customize prefill seeds (an existing target must prefill, never silently reset)

    func test_customizeSeedLength_explicitModeWins() {
        // An existing editorial mode is honored (preserves the user's prior choice).
        XCTAssertEqual(CustomizeYourStoryView.seedLength(editorialMode: "custom", hasRecommendedPoint: true), .custom)
        XCTAssertEqual(CustomizeYourStoryView.seedLength(editorialMode: "highlights", hasRecommendedPoint: true), .highlights)
        XCTAssertEqual(CustomizeYourStoryView.seedLength(editorialMode: "full", hasRecommendedPoint: false), .full)
    }

    func test_customizeSeedLength_fallbackWhenNoMode() {
        // No prior mode -> Full when a recommendation exists, else Custom.
        XCTAssertEqual(CustomizeYourStoryView.seedLength(editorialMode: nil, hasRecommendedPoint: true), .full)
        XCTAssertEqual(CustomizeYourStoryView.seedLength(editorialMode: "", hasRecommendedPoint: false), .custom)
    }

    // Part B — persisted directives are rendered by stable Moment number so the user can see + clear them.
    func test_savedDirectiveLines_rendersAllActiveDirectives() {
        func nm(_ n: Int, _ id: UUID) -> NumberedMoment { NumberedMoment(number: n, id: id, durationSeconds: 5, relativePath: nil) }
        let a = UUID(), b = UUID(), c = UUID()
        let numbering = StoryMomentNumbering(ordered: [nm(1, a), nm(2, b), nm(3, c)])
        var d = ResolvedDirectives()
        d.opening = a; d.orderAdjacent = [[b, a]]; d.mustInclude = [a, b]; d.exclude = [c]
        let lines = CustomizeYourStoryView.savedDirectiveLines(d, numbering: numbering)
        XCTAssertTrue(lines.contains("Start with Moment 1"))
        XCTAssertTrue(lines.contains("Moment 2 right after Moment 1"))
        XCTAssertTrue(lines.contains("Exclude Moment 3"))
        // must_include that is ALSO opening/ending is not double-listed; the standalone include (none here) omitted
        XCTAssertFalse(lines.contains("Include Moment 1, Moment 2"))
        XCTAssertTrue(CustomizeYourStoryView.savedDirectiveLines(nil, numbering: numbering).isEmpty)
    }

    func test_customizeSeedSeconds_explicitTargetWins() {
        // The user's prior EXPLICIT target wins (provenance preserved), even over a recommendation.
        XCTAssertEqual(CustomizeYourStoryView.seedCustomSeconds(explicitTarget: 45, recommendedPoint: 30,
                                                                bandLo: 10, bandHi: 60), 45)
        // Absent an explicit target -> recommended point.
        XCTAssertEqual(CustomizeYourStoryView.seedCustomSeconds(explicitTarget: nil, recommendedPoint: 30,
                                                                bandLo: 10, bandHi: 60), 30)
        // Absent both -> band midpoint.
        XCTAssertEqual(CustomizeYourStoryView.seedCustomSeconds(explicitTarget: nil, recommendedPoint: nil,
                                                                bandLo: 10, bandHi: 30), 20)
    }

    // MARK: - Issue 2: deterministic failure recovery (no plain-retry loop on a proven directive conflict)

    func test_failureRecovery_directiveConflict_routesToAdjust_notRetry() {
        // A PROVEN directive conflict must route to Adjust Instructions (no identical-request retry loop).
        XCTAssertEqual(FailureRecovery.from(.directivesUnsatisfiable("too many excludes")), .adjustInstructions)
    }

    func test_failureRecovery_invalidPlanOutput_isTechnical_notUserError() {
        // invalid_after_repair WITHOUT directives -> honest technical failure (bounded retry), not user error.
        XCTAssertEqual(FailureRecovery.from(.invalidPlanOutput("planner")), .technical)
    }

    func test_failureRecovery_insufficientMaterial_offersDurationChoice() {
        XCTAssertEqual(FailureRecovery.from(.insufficientMaterial(achievable: 100, requested: 240, suggested: 90)),
                       .shorterStory(suggestedSeconds: 90))
        XCTAssertEqual(FailureRecovery.from(.insufficientMaterial(achievable: 3, requested: 240, suggested: nil)),
                       .keepShooting)
    }

    func test_failureRecovery_technicalErrors_offerRetry() {
        XCTAssertEqual(FailureRecovery.from(.planUnavailable), .technical)
        XCTAssertEqual(FailureRecovery.from(.renderFailed("x")), .technical)
        XCTAssertEqual(FailureRecovery.from(.planTransport("x")), .technical)
    }

    // Issue 2: the two invalid_after_repair messages are distinct — directive conflict blames the instruction,
    // the no-directive technical failure explicitly does NOT.
    func test_invalidOutput_message_doesNotBlameUser() {
        let dir = StoryCreationError.directivesUnsatisfiable("").errorDescription ?? ""
        let tech = StoryCreationError.invalidPlanOutput("").errorDescription ?? ""
        XCTAssertTrue(dir.lowercased().contains("instruction"))
        XCTAssertFalse(tech.lowercased().contains("instruction"))
        XCTAssertNotEqual(dir, tech)
    }

    // MARK: - Revise preserves the base version's duration (not a stale Story intent target)

    private func planJSON(targetSeconds: Double) -> String {
        let plan = EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: targetSeconds,
                              outputFormat: "vertical", musicAssetId: nil, feasible: true,
                              segments: [EditSegmentV2(order: 0, assetId: UUID().uuidString,
                                                       sourceStartSeconds: 0, sourceEndSeconds: 3,
                                                       outputDurationSeconds: 3, speed: 1.0,
                                                       nativeAudio: "keep", musicAlignment: nil)])
        let data = try! StoryContractCoding.encoder().encode(plan)
        return String(data: data, encoding: .utf8)!
    }

    /// A revise must target the base PLAN's target_duration_seconds (what it was planned at), so an 85s video
    /// revises at 85s — never a stale Story intent target (the 16.5s bug that dropped 9 clips).
    func test_baseTargetSeconds_prefersBasePlanTarget() {
        let s = newStory()
        let o = GeneratedOutputModel(title: s.title, durationSeconds: 85.055, momentIds: [],
                                     editPlanJSON: planJSON(targetSeconds: 85.0))
        o.story = s; ctx.insert(o)
        XCTAssertEqual(StoryResultView.baseTargetSeconds(for: o), 85.0, accuracy: 0.001,
                       "revise target = base plan's target_duration_seconds")
    }

    /// Legacy output with no stored plan JSON falls back to the rendered duration (never a short default).
    func test_baseTargetSeconds_fallsBackToRenderedDuration() {
        let s = newStory()
        let o = GeneratedOutputModel(title: s.title, durationSeconds: 85.055, momentIds: [],
                                     editPlanJSON: nil)
        o.story = s; ctx.insert(o)
        XCTAssertEqual(StoryResultView.baseTargetSeconds(for: o), 85.055, accuracy: 0.001,
                       "no plan JSON -> rendered duration, not a stale/short target")
    }
}
