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
    struct Recommendation {
        let musicPlanJSON: JSONValue
        let candidates: [MusicCandidateDTO]
        let topTrackId: String?
        let topAnalysisJSON: JSONValue?
        let soundtrackRole: String
        let nativeAudioPriority: String
    }

    func recommend(for story: StoryModel, guideFramingSummary: String?) async -> Recommendation? {
        let target = story.intentTargetDurationSeconds ?? 15.0
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
        do { resp = try await candidatesService.candidates(musicPlan: planJSON, targetDurationSeconds: target) }
        catch { return nil }
        guard !resp.candidates.isEmpty else { return nil }

        let strat = Self.audioStrategy(planJSON)
        return Recommendation(
            musicPlanJSON: planJSON,
            candidates: resp.candidates,
            topTrackId: resp.topTrackId ?? resp.candidates.first?.trackId,
            topAnalysisJSON: Self.jsonForAnalysis(resp.topMusicAnalysis),
            soundtrackRole: strat.role,
            nativeAudioPriority: strat.priority)
    }

    /// Resolve a FULL selection for a chosen track: fetch its analysis if needed, download the audio, and
    /// package a MusicSelection. nil on any failure (caller falls back to no-music). `cachedTopAnalysisJSON`
    /// is the top-pick analysis already returned by recommend() — passed to avoid a second call when the user
    /// keeps the recommended track.
    func resolveSelection(recommendation: Recommendation, trackId: String) async
        -> StoryCreationCoordinator.MusicSelection? {
        // analysis for the chosen track (reuse the top-pick analysis when it matches; else fetch).
        let analysisJSON: JSONValue
        if trackId == recommendation.topTrackId, let top = recommendation.topAnalysisJSON {
            analysisJSON = top
        } else {
            do {
                let a = try await candidatesService.analysis(trackId: trackId)
                analysisJSON = Self.jsonForAnalysis(a) ?? .object([:])
            } catch { return nil }
        }
        guard let analysis = Self.decodeAnalysis(analysisJSON) else { return nil }
        // download the authorized audio to a local temp file.
        let url: URL
        do { url = try await candidatesService.downloadSoundtrack(trackId: trackId) }
        catch { return nil }
        let title = recommendation.candidates.first { $0.trackId == trackId }?.title ?? "Soundtrack"
        return StoryCreationCoordinator.MusicSelection(
            musicPlanJSON: recommendation.musicPlanJSON,
            trackId: trackId,
            analysisJSON: analysisJSON,
            analysis: analysis,
            soundtrackURL: url,
            soundtrackRole: recommendation.soundtrackRole,
            nativeAudioPriority: recommendation.nativeAudioPriority,
            trackTitle: title)
    }

    // MARK: - helpers

    private static func encodeJSON<T: Encodable>(_ v: T) -> JSONValue {
        guard let d = try? StoryContractCoding.encoder().encode(v),
              let s = String(data: d, encoding: .utf8) else { return .object([:]) }
        return JSONValue.object(fromJSONString: s)
    }

    private static func jsonForAnalysis(_ a: MusicAnalysisV1?) -> JSONValue? {
        guard let a, let d = try? StoryContractCoding.encoder().encode(AnalysisWire(a)),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return JSONValue.object(fromJSONString: s)
    }

    private static func decodeAnalysis(_ j: JSONValue) -> MusicAnalysisV1? {
        guard let d = try? JSONEncoder().encode(j) else { return nil }
        return try? StoryContractCoding.decoder().decode(MusicAnalysisV1.self, from: d)
    }

    private static func audioStrategy(_ plan: JSONValue) -> (role: String, priority: String) {
        if case let .object(root) = plan, case let .object(s)? = root["audio_strategy"] {
            let role = { if case let .string(r)? = s["soundtrack_role"] { return r }; return "supportive" }()
            let pri = { if case let .string(p)? = s["native_audio_priority"] { return p }; return "selective" }()
            return (role, pri)
        }
        return ("supportive", "selective")
    }

    /// Re-encode the renderer's MusicAnalysisV1 (Decodable-only) back to the snake_case wire shape so it can be
    /// threaded into the planner request as JSONValue.
    private struct AnalysisWire: Encodable {
        let durationSeconds: Double
        let bpm: Double?
        let tempoReliable: Bool
        let beats: [Double]
        let downbeats: [Double]
        init(_ a: MusicAnalysisV1) {
            durationSeconds = a.durationSeconds; bpm = a.bpm; tempoReliable = a.tempoReliable
            beats = a.beats; downbeats = a.downbeats
        }
        enum CodingKeys: String, CodingKey {
            case durationSeconds = "duration_seconds", bpm
            case tempoReliable = "tempo_reliable", beats, downbeats
        }
    }
}
