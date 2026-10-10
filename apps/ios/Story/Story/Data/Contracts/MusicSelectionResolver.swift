import Foundation
import SwiftData

// MusicSelectionResolver (R-d Batch C) — the UI-side orchestration that turns a Story into a resolved
// StoryCreationCoordinator.MusicSelection the creation pipeline can render with.
//
//   ensure MusicDirection (authoritative; user-authored overrides inferred)
//     -> POST /v1/music-plan        (frozen music_plan/1)
//     -> POST /v1/music/candidates  (ranked tracks + preview + top-pick analysis)
//     -> download the chosen track  (POST /v1/music/soundtrack -> local temp file)
//     -> MusicSelection
//
// GRACEFUL: every music failure (direction unavailable, plan 503, provider 404/503, download error) returns
// nil so the caller runs the device-verified NO-MUSIC path. Music never blocks Story creation (R-d §8).
// The resolver also exposes `candidates(...)` so the UX can show the recommendation + let the user pick
// another or create without music BEFORE committing to a download.
@MainActor
final class MusicSelectionResolver {
    private let context: ModelContext
    private let planService: MusicPlanning
    private let candidatesService: MusicCandidatesService
    private let directionCoordinator: MusicDirectionCoordinator

    init(context: ModelContext,
         planService: MusicPlanning = MusicPlanService(),
         candidatesService: MusicCandidatesService = MusicCandidatesService()) {
        self.context = context
        self.planService = planService
        self.candidatesService = candidatesService
        self.directionCoordinator = MusicDirectionCoordinator(context: context)
    }

    /// The MusicPlan + ranked candidates for a Story, for the selection UX. nil => music unavailable
    /// (the UX shows "create without music" only). Does NOT download anything yet.
    struct Recommendation: Identifiable {
        let id = UUID()
        let musicPlanJSON: JSONValue
        let candidates: [MusicCandidateDTO]
        let topTrackId: String?
        let topAnalysis: MusicAnalysisV1?     // decoded, for the renderer (no re-encode)
        let topAnalysisJSON: JSONValue?       // raw wire JSON, for the planner request (no re-encode)
        let soundtrackRole: String
        let nativeAudioPriority: String
    }

    func recommend(for story: StoryModel, guideFramingSummary: String?) async -> Recommendation? {
        // R-d.2: the Story target is authoritative and chosen upstream (explicit intent or accepted
        // recommendation). Without one, do NOT invent 15s — skip music (the create flow asks for a duration
        // first); a nil target here means "no duration chosen yet", handled by the caller as manual selection.
        guard let target = story.intentTargetDurationSeconds else { return nil }
        // 1. authoritative MusicDirection (ensures/infers once; user-authored returned untouched).
        guard let direction = await directionCoordinator.ensure(for: story, guideFramingSummary: guideFramingSummary)
        else { return nil }
        let directionJSON = Self.encodeJSON(direction)
        let intentJSON = Self.encodeJSON(CreativeIntentContractDTO(from: story))

        // 2. MusicPlan (frozen music_plan/1). 404/503 => no music.
        let planJSON: JSONValue
        do {
            planJSON = try await planService.plan(MusicPlanRequestDTO(
                storyId: story.id, creativeIntent: intentJSON, musicDirection: directionJSON,
                targetDurationSeconds: target, storyGuide: .object([:]), storyCoverage: .object([:])))
        } catch { return nil }

        // 3. candidates (+ preview + top analysis). Provider off/unavailable => no music.
        let resp: MusicCandidatesResponseDTO
        let rawTop: JSONValue?
        do { (resp, rawTop) = try await candidatesService.candidates(musicPlan: planJSON, targetDurationSeconds: target) }
        catch { return nil }
        guard !resp.candidates.isEmpty else { return nil }

        let strat = Self.audioStrategy(planJSON)
        return Recommendation(
            musicPlanJSON: planJSON,
            candidates: resp.candidates,
            topTrackId: resp.topTrackId ?? resp.candidates.first?.trackId,
            topAnalysis: resp.topMusicAnalysis,
            topAnalysisJSON: rawTop,
            soundtrackRole: strat.role,
            nativeAudioPriority: strat.priority)
    }

    /// Resolve a FULL selection for a chosen track: use the top-pick analysis when the chosen track IS the top
    /// pick (no extra call, no re-encode), else fetch that track's analysis. Then download the audio and
    /// package a MusicSelection. nil on any failure (caller falls back to no-music).
    func resolveSelection(recommendation rec: Recommendation, trackId: String) async
        -> StoryCreationCoordinator.MusicSelection? {
        let analysis: MusicAnalysisV1
        let analysisJSON: JSONValue
        if trackId == rec.topTrackId, let a = rec.topAnalysis, let aj = rec.topAnalysisJSON {
            analysis = a; analysisJSON = aj
        } else {
            do {
                let both = try await candidatesService.analysisBoth(trackId: trackId)
                analysis = both.analysis; analysisJSON = both.raw
            } catch { return nil }
        }
        // download the authorized audio to a local temp file.
        let url: URL
        do { url = try await candidatesService.downloadSoundtrack(trackId: trackId) }
        catch { return nil }
        let title = rec.candidates.first { $0.trackId == trackId }?.title ?? "Soundtrack"
        return StoryCreationCoordinator.MusicSelection(
            musicPlanJSON: rec.musicPlanJSON,
            trackId: trackId,
            analysisJSON: analysisJSON,
            analysis: analysis,
            soundtrackURL: url,
            soundtrackRole: rec.soundtrackRole,
            nativeAudioPriority: rec.nativeAudioPriority,
            trackTitle: title)
    }

    // MARK: - helpers

    private static func encodeJSON<T: Encodable>(_ v: T) -> JSONValue {
        guard let d = try? StoryContractCoding.encoder().encode(v),
              let s = String(data: d, encoding: .utf8) else { return .object([:]) }
        return JSONValue.object(fromJSONString: s)
    }

    private static func audioStrategy(_ plan: JSONValue) -> (role: String, priority: String) {
        if case let .object(root) = plan, case let .object(s)? = root["audio_strategy"] {
            let role = { if case let .string(r)? = s["soundtrack_role"] { return r }; return "supportive" }()
            let pri = { if case let .string(p)? = s["native_audio_priority"] { return p }; return "selective" }()
            return (role, pri)
        }
        return ("supportive", "selective")
    }
}
