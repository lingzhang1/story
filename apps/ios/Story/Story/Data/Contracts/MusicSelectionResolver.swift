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
        let nextCursor: String?               // page the recommendations ("Next page"); nil = no further page

        /// An empty recommendation (no provider candidates) — lets the shared picker still offer My Music,
        /// Import and No-music when the provider is unavailable. role/priority default to the balanced middle.
        static func empty(target: Double) -> Recommendation {
            Recommendation(musicPlanJSON: .object([:]), candidates: [], topTrackId: nil,
                           topAnalysis: nil, topAnalysisJSON: nil,
                           soundtrackRole: "supportive", nativeAudioPriority: "selective", nextCursor: nil)
        }
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

        // Ensure the Story has a StoryGuide BEFORE asking MusicPlan. An older/imported Story (e.g. TMB) may
        // have reached music WITHOUT a persisted Guide — then MusicPlan judged native audio from a thin intent
        // and returned low/continuous, drowning meaningful ambience. ensureGuide is generate-once-if-absent
        // (migration-safe); it returns the existing Guide untouched when present. Fire-and-forget on failure
        // (Story stays valid; we then just pass whatever Guide/Coverage exist).
        let guideCoord = StoryGuideCoordinator(context: context)
        let ensuredGuide = await guideCoord.ensureGuide(for: story)

        // Load the Story's persisted StoryGuide + Coverage (snake_case wire JSON) and PASS THEM to MusicPlan.
        // Previously these were empty objects, so MusicPlan judged native-audio priority from a possibly-thin
        // CreativeIntent alone — the native-audio-disappearance root cause. The Guide/Coverage carry the
        // Story's actual narrative + what-it-became, which the frozen music_plan/1 prompt uses to decide
        // whether native audio (a performance, meaningful ambience) must be preserved. No prompt/contract change.
        let guideJSON = loadGuideJSON(for: story.id)
        let coverageJSON = loadCoverageJSON(for: story.id)

        // Sound preference: refresh the INFERRED recommendation (advisory) WITHOUT touching the user's EXPLICIT
        // choice, then pass the EFFECTIVE preference (explicit ?? inferred ?? balanced) to MusicPlan.
        if let inferred = SoundPreference.infer(theme: story.intentTheme, tone: story.intentTone,
                                                desiredFeeling: story.intentDesiredFeeling, styleTags: story.intentStyleTags) {
            if story.soundPreferenceInferred != inferred.rawValue { story.soundPreferenceInferred = inferred.rawValue }
        }
        let effectivePref = story.effectiveSoundPreference.rawValue

        // DEBUG verification: prove (not assume) what the SINGLE MusicPlan request path carried. No media/creds.
        let guideDims = Self.dimensionCount(guideJSON)
        let guidePresent = Self.isNonEmptyObject(guideJSON)
        let covPresent = Self.isNonEmptyObject(coverageJSON)

        // 2. MusicPlan (frozen music_plan/1). 404/503 => no music.
        let planJSON: JSONValue
        do {
            planJSON = try await planService.plan(MusicPlanRequestDTO(
                storyId: story.id, creativeIntent: intentJSON, musicDirection: directionJSON,
                targetDurationSeconds: target, storyGuide: guideJSON, storyCoverage: coverageJSON,
                soundPreference: effectivePref))
        } catch {
            StoryCreativeRefinement.lastMusicPlanInput =
                "build=\(StoryCreativeRefinement.buildIdentifier) ensureGuide=\(ensuredGuide != nil ? "ok" : "nil") guide=\(guidePresent ? "yes(\(guideDims)dims)" : "EMPTY") coverage=\(covPresent ? "yes" : "EMPTY") -> MusicPlan ERROR"
            return nil
        }

        // 3. candidates (+ preview + top analysis). Provider off/unavailable => no music.
        let resp: MusicCandidatesResponseDTO
        let rawTop: JSONValue?
        do { (resp, rawTop) = try await candidatesService.candidates(musicPlan: planJSON, targetDurationSeconds: target) }
        catch { return nil }
        guard !resp.candidates.isEmpty else { return nil }

        let strat = Self.audioStrategy(planJSON)
        StoryCreativeRefinement.lastMusicPlanInput =
            "build=\(StoryCreativeRefinement.buildIdentifier) ensureGuide=\(ensuredGuide != nil ? "ok" : "nil") guide=\(guidePresent ? "yes(\(guideDims)dims)" : "EMPTY") coverage=\(covPresent ? "yes" : "EMPTY") -> role=\(strat.role) priority=\(strat.priority)"
        return Recommendation(
            musicPlanJSON: planJSON,
            candidates: resp.candidates,
            topTrackId: resp.topTrackId ?? resp.candidates.first?.trackId,
            topAnalysis: resp.topMusicAnalysis,
            topAnalysisJSON: rawTop,
            soundtrackRole: strat.role,
            nativeAudioPriority: strat.priority,
            nextCursor: resp.nextCursor)
    }

    /// Fetch the NEXT page of recommendations for the same Story (same MusicPlan), returning a fresh set of
    /// candidate tracks and the following cursor. Reuses the current recommendation's MusicPlan + strategy; the
    /// top-pick analysis is page-1 only (nil here), since a chosen non-top track resolves its own analysis.
    /// Returns nil on failure (caller keeps the current page). `targetDurationSeconds` must match page 1.
    func nextPage(from rec: Recommendation, targetDurationSeconds: Double) async -> Recommendation? {
        guard let cursor = rec.nextCursor else { return nil }
        let resp: MusicCandidatesResponseDTO
        do {
            (resp, _) = try await candidatesService.candidates(
                musicPlan: rec.musicPlanJSON, targetDurationSeconds: targetDurationSeconds, cursor: cursor)
        } catch { return nil }
        guard !resp.candidates.isEmpty else { return nil }
        return Recommendation(
            musicPlanJSON: rec.musicPlanJSON,
            candidates: resp.candidates,
            topTrackId: resp.topTrackId,               // nil on later pages (no AI "Story's pick")
            topAnalysis: nil, topAnalysisJSON: nil,     // analysis is page-1 only
            soundtrackRole: rec.soundtrackRole,
            nativeAudioPriority: rec.nativeAudioPriority,
            nextCursor: resp.nextCursor)
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
            MediaEngineV1.beacon("resolve: top-reuse ok track=\(trackId.prefix(8))")
        } else {
            MediaEngineV1.beacon("resolve: fetch-analysis (top=\(rec.topTrackId?.prefix(8) ?? "nil") hasA=\(rec.topAnalysis != nil) hasAJ=\(rec.topAnalysisJSON != nil))")
            do {
                let both = try await candidatesService.analysisBoth(trackId: trackId)
                analysis = both.analysis; analysisJSON = both.raw
            } catch {
                MediaEngineV1.beacon("resolve: analysis FAILED \(error)")
                return nil
            }
        }
        // download the authorized audio to a local temp file.
        let url: URL
        do { url = try await candidatesService.downloadSoundtrack(trackId: trackId) }
        catch {
            MediaEngineV1.beacon("resolve: download FAILED \(error)")
            return nil
        }
        let title = rec.candidates.first { $0.trackId == trackId }?.title ?? "Soundtrack"
        MediaEngineV1.beacon("resolve: OK url=\(url.lastPathComponent)")
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

    /// True when the JSONValue is an object with at least one key (i.e. a real Guide/Coverage was passed).
    private static func isNonEmptyObject(_ v: JSONValue) -> Bool {
        if case let .object(d) = v { return !d.isEmpty }
        return false
    }

    /// Count StoryGuide dimensions (story_guide/1 carries a "dimensions" array). 0 when absent/empty.
    private static func dimensionCount(_ v: JSONValue) -> Int {
        if case let .object(d) = v, case let .array(a)? = d["dimensions"] { return a.count }
        return 0
    }

    /// Load the Story's persisted StoryGuide wire JSON (story_guide/1) as a JSONValue, or an empty object when
    /// none exists yet. Fetched from SwiftData by storyId (same pattern as StoryGuideCoordinator).
    private func loadGuideJSON(for storyId: UUID) -> JSONValue {
        var desc = FetchDescriptor<StoryGuideModel>(predicate: #Predicate { $0.storyId == storyId })
        desc.fetchLimit = 1
        if let json = (try? context.fetch(desc))?.first?.guideJSON, !json.isEmpty {
            return JSONValue.object(fromJSONString: json)
        }
        return .object([:])
    }

    /// Load the Story's persisted StoryCoverage wire JSON (story_coverage/*) as a JSONValue, or an empty object.
    private func loadCoverageJSON(for storyId: UUID) -> JSONValue {
        var desc = FetchDescriptor<StoryCoverageModel>(predicate: #Predicate { $0.storyId == storyId })
        desc.fetchLimit = 1
        if let json = (try? context.fetch(desc))?.first?.coverageJSON, !json.isEmpty {
            return JSONValue.object(fromJSONString: json)
        }
        return .object([:])
    }

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
