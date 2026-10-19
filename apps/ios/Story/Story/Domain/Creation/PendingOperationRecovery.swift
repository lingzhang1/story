import Foundation
import SwiftData

// PendingOperationRecovery — P0 Phase 2/3 driver.
//
// On app foreground (scenePhase == .active) or Story reopen, find unfinished AI operations (PendingOperationModel
// rows that are not saved/abandoned) and RESUME them so a completed backend plan is never silently lost because
// the app was backgrounded, suspended, or force-quit. This mirrors AssetUnderstandingQueue.recoverOrphans +
// drain: it is non-blocking, opportunistic, and idempotent.
//
// CRITICAL GUARANTEES (owner mandate):
//   - NEVER submits a second model request. Resume reuses the persisted operationId + jobId and only
//     polls/fetches/renders (the coordinator's resumePendingOperation enforces this).
//   - NOT an indefinitely-running loop and NOT reliant on background URLSession / beginBackgroundTask. It runs
//     ONE pass when the app becomes active; active polling stops when the app is suspended (the poll Task is
//     suspended with the app) and a fresh pass resumes it on the next .active.
//   - Single-flight: an in-progress recovery set prevents repeated foreground/reopen events from creating
//     duplicate polling or rendering tasks for the same Story.
@MainActor
final class PendingOperationRecovery {
    private let context: ModelContext

    // In-flight guard shared across recovery passes in this process: a Story whose resume is running is not
    // resumed again by a second foreground event. Coordinators are retained for the lifetime of their resume.
    private static var inFlight: Set<UUID> = []
    private static var retained: [UUID: StoryCreationCoordinator] = [:]

    init(context: ModelContext) { self.context = context }

    /// Fetch Stories that have a recoverable pending operation, resume each once.
    func recoverAll() {
        let desc = FetchDescriptor<PendingOperationModel>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let rows = ((try? context.fetch(desc)) ?? []).filter { $0.isRecoverable && $0.jobId != nil }
        guard !rows.isEmpty else { return }
        // One resume per Story (dedupe multiple rows defensively).
        var seen = Set<UUID>()
        for row in rows where !seen.contains(row.storyId) {
            seen.insert(row.storyId)
            resume(storyId: row.storyId)
        }
    }

    /// Resume the recoverable operation for one Story. Safe to call repeatedly — the in-flight guard makes a
    /// second call a no-op until the first resume finishes.
    func resume(storyId: UUID) {
        guard !Self.inFlight.contains(storyId) else { return }
        let storyDesc = FetchDescriptor<StoryModel>(predicate: #Predicate { $0.id == storyId })
        guard let story = (try? context.fetch(storyDesc))?.first else { return }

        let coord = StoryCreationCoordinator(planner: EditPlannerService(), context: context)
        guard coord.hasRecoverablePendingOperation(storyId: storyId) else { return }

        Self.inFlight.insert(storyId)
        Self.retained[storyId] = coord
        MediaEngineV1.beacon("editplan-recover: foreground pass resuming story=\(storyId.uuidString.prefix(8))")

        Task { @MainActor in
            defer { Self.inFlight.remove(storyId); Self.retained[storyId] = nil }
            // Re-resolve the operation's soundtrack (same path as Revise/Change Music) so a resumed render keeps
            // its music WHERE FEASIBLE; nil renders no-music rather than block the recovery of the video.
            let music = await Self.resolveMusicForResume(storyId: storyId, story: story, context: context)
            guard coord.resumePendingOperation(for: story, music: music) else { return }
            while coord.isCreating { try? await Task.sleep(nanoseconds: 300_000_000) }
            MediaEngineV1.beacon("editplan-recover: resume finished story=\(storyId.uuidString.prefix(8)) "
                + "state=\(String(describing: coord.state))")
        }
    }

    /// Re-resolve the pending op's soundtrack from its persisted musicSelectionRef
    /// ("mymusic:<id>" | "provider:<trackId>" | nil) WITHOUT a fresh MusicPlan. The plan was already planned
    /// music-aware; recovery only needs the soundtrack file + decoded analysis + the two mixing knobs, which we
    /// persisted at plan_ready. A provider track resolves via the TRACK-SCOPED analysisBoth + downloadSoundtrack
    /// (no recommend()/MusicPlan). My Music resolves locally. nil => no music (never blocks recovery). This is
    /// what keeps `original` recovery from unnecessarily rerunning MusicPlan.
    static func resolveMusicForResume(storyId: UUID, story: StoryModel, context: ModelContext) async
        -> StoryCreationCoordinator.MusicSelection? {
        let desc = FetchDescriptor<PendingOperationModel>(predicate: #Predicate { $0.storyId == storyId })
        guard let row = ((try? context.fetch(desc)) ?? []).first(where: { $0.isRecoverable }),
              let ref = row.musicSelectionRef, ref != "none" else { return nil }
        if ref.hasPrefix("mymusic:") {
            let assetId = String(ref.dropFirst("mymusic:".count))
            return CreateStoryPreviewView.myMusicSelection(assetId: assetId, story: story, context: context)
        }
        guard ref.hasPrefix("provider:") else { return nil }
        let trackId = String(ref.dropFirst("provider:".count))
        let candidates = MusicCandidatesService()
        // Track-scoped analysis + audio — NO MusicPlan recommend() call.
        guard let both = try? await candidates.analysisBoth(trackId: trackId),
              let url = try? await candidates.downloadSoundtrack(trackId: trackId) else {
            MediaEngineV1.beacon("editplan-recover: provider music re-resolve FAILED track=\(trackId.prefix(8)) -> no-music")
            return nil
        }
        return StoryCreationCoordinator.MusicSelection(
            musicPlanJSON: .object([:]),                 // planning is done; not used at render
            trackId: trackId,
            analysisJSON: both.raw,
            analysis: both.analysis,
            soundtrackURL: url,
            soundtrackRole: row.soundtrackRole ?? "supportive",
            nativeAudioPriority: row.nativeAudioPriority ?? "selective",
            trackTitle: "Soundtrack")
    }
}
