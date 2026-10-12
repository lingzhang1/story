import Foundation
import AVFoundation
import SwiftData

// SoundtrackReplacer — Change Music (Milestone M-e, Phase 3).
//
// Replaces the soundtrack of an EXISTING generated version WITHOUT re-editing the video.
// It reuses the persisted executable EditPlan (GeneratedOutputModel.editPlanJSON) verbatim —
// the narrative Edit Planner is NEVER invoked — so visual selection, order, source in/out,
// speed, transitions and final duration are byte-for-byte identical. Only the soundtrack and
// its mix knobs change. The result is saved as a NEW version; the previous output is preserved.
//
// Music source is one of:
//   - .provider(trackId:, url:, role:, priority:, title:, analysis:)  — a resolved provider track
//   - .myMusic(asset:)                                                — a saved/imported local track
//   - .none                                                           — remove background music
//
// Fitting policy (bounded): the chosen music is used as-is up to the video duration; the renderer
// applies the existing fade/duck behavior. We do NOT retime visual cuts to the music — that is a
// future operation (Create Another Version / Edit with AI).
enum ChangeMusicError: Error, LocalizedError {
    case noPersistedPlan        // legacy output with no editPlanJSON -> cannot reconstruct the edit
    case planUndecodable
    case sourceMediaMissing     // a Moment's file is gone -> cannot re-render faithfully
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPersistedPlan: return "This video was made before version history; its exact edit can't be reused. Re-create it to enable Change Music."
        case .planUndecodable: return "Couldn't read the saved edit for this video."
        case .sourceMediaMissing: return "Some of the original footage for this video is no longer available."
        case .renderFailed(let w): return "Couldn't re-render with the new music (\(w))."
        }
    }
}

@MainActor
final class SoundtrackReplacer {
    enum MusicChoice {
        case provider(trackId: String, url: URL, role: String, priority: String, title: String, analysis: MusicAnalysisV1?)
        case myMusic(asset: MyMusicAssetModel)
        case none
    }

    private let context: ModelContext
    private let renderer: StoryRendering
    init(context: ModelContext, renderer: StoryRendering = MediaEngineRenderer()) {
        self.context = context
        self.renderer = renderer
    }

    /// Re-render `source`'s visual edit with `choice` as the new soundtrack and persist a new version.
    /// Returns the new GeneratedOutputModel. The source output is left untouched.
    func changeMusic(for source: GeneratedOutputModel,
                     in story: StoryModel,
                     choice: MusicChoice,
                     progress: ((Float) -> Void)? = nil,
                     shouldCancel: (() -> Bool)? = nil) async throws -> GeneratedOutputModel {
        // 1. Reconstruct the EXACT visual edit from the persisted plan.
        guard let planJSON = source.editPlanJSON, let data = planJSON.data(using: .utf8) else {
            throw ChangeMusicError.noPersistedPlan
        }
        let plan: EditPlanV2
        do { plan = try JSONDecoder().decode(EditPlanV2.self, from: data) }
        catch { throw ChangeMusicError.planUndecodable }

        // 2. Resolve the Story's moments -> URL resolver (SAME originals; no duplicate source copies).
        let media = MomentResolver.resolve(moments: story.moments)
        let resolver = MomentResolver.urlResolver(for: media)
        // Every assetId the plan references must resolve, or the re-render would silently drop a clip.
        for seg in plan.segments where resolver(seg.assetId) == nil {
            throw ChangeMusicError.sourceMediaMissing
        }

        // 3. Resolve the new soundtrack + mix knobs. Preserve the user's sound-preference-derived
        //    role/priority where the choice doesn't carry its own (My Music / none).
        let fallbackRole = source.soundtrackRole ?? "supportive"
        let fallbackPriority = source.nativeAudioPriority ?? "selective"

        let soundtrackURL: URL?
        let analysis: MusicAnalysisV1?
        let role: String
        let priority: String
        let newTitle: String?
        let musicRef: String

        switch choice {
        case .provider(let trackId, let url, let r, let p, let title, let an):
            soundtrackURL = url; analysis = an; role = r; priority = p
            newTitle = title; musicRef = "provider:\(trackId)"
        case .myMusic(let asset):
            guard MyMusicStore.shared.exists(asset) else { throw ChangeMusicError.sourceMediaMissing }
            soundtrackURL = MyMusicStore.shared.absoluteURL(for: asset.relativePath)
            analysis = MyMusicStore.localAnalysis(for: asset)
            role = fallbackRole; priority = fallbackPriority
            newTitle = asset.displayName; musicRef = "mymusic:\(asset.id.uuidString)"
            asset.lastUsedAt = .now
        case .none:
            soundtrackURL = nil; analysis = nil
            role = fallbackRole; priority = fallbackPriority
            newTitle = nil; musicRef = "none"
        }

        // 4. Re-render through the EXISTING Media Engine with the SAME plan.
        let inputs = MediaEngineInputs(
            plan: plan,
            resolveMomentURL: resolver,
            soundtrackURL: soundtrackURL,
            musicAnalysis: analysis,
            soundtrackRole: role,
            nativeAudioPriority: priority)

        let result: RenderResult
        do {
            result = try await renderer.render(inputs, progress: progress, shouldCancel: shouldCancel)
        } catch { throw ChangeMusicError.renderFailed(String(describing: error)) }

        // 5. Persist a NEW version. parentVersionId = the source's versionId; the plan is COPIED verbatim.
        //    The previous output row is left in place (never overwritten).
        let output = GeneratedOutputModel(
            title: source.title,
            durationSeconds: result.durationSeconds,
            momentIds: source.sourceMomentIds.isEmpty ? source.momentIds : source.sourceMomentIds,
            relativeFilePath: result.relativePath,
            sourceMomentIds: source.sourceMomentIds,
            sourceFingerprint: source.sourceFingerprint,
            editPlanProvenance: source.editPlanProvenance,
            outputFormat: plan.outputFormat,
            renderWidth: Double(result.renderSize.width),
            renderHeight: Double(result.renderSize.height),
            isStale: false,
            soundtrackTitle: newTitle,
            versionId: UUID(),
            parentVersionId: source.versionId,
            operationType: "change_music",
            editPlanJSON: planJSON,                       // the SAME executable edit, carried forward
            soundtrackRole: role,
            nativeAudioPriority: priority,
            soundPreferenceRaw: source.soundPreferenceRaw ?? story.effectiveSoundPreference.rawValue,
            musicAssetRef: musicRef)
        output.story = story
        context.insert(output)
        story.generatedOutputs.append(output)
        story.updatedAt = .now
        try? context.save()
        return output
    }
}
