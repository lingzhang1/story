import Foundation
import Foundation
import CryptoKit
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
        // LATENCY P0: the MusicPlan LLM call is ~10s and was re-run on EVERY music open. Cache it per Story
        // keyed by a canonical fingerprint of ALL inputs that feed /v1/music-plan. A hit reuses the persisted
        // plan verbatim (no model call); any input change misses and recomputes. The frozen prompt/contract
        // are untouched — this only avoids RE-asking for an answer we already have.
        let planFingerprint = Self.musicPlanFingerprint(
            intent: intentJSON, direction: directionJSON, guide: guideJSON,
            coverage: coverageJSON, soundPreference: effectivePref, target: target)
        let planJSON: JSONValue
        if let cached = Self.cachedMusicPlan(storyId: story.id, fingerprint: planFingerprint, context: context) {
            planJSON = cached
            MediaEngineV1.beacon("musicplan: cache HIT fp=\(planFingerprint.prefix(8))")
        } else {
            // De-dupe concurrent identical requests (two rapid "find music" opens) so only ONE inference runs.
            if let inflight = Self.inFlightMusicPlans[planFingerprint] {
                planJSON = (try? await inflight.value) ?? .object([:])
                if case .object(let o) = planJSON, o.isEmpty { return nil }
            } else {
                let task = Task<JSONValue, Error> {
                    try await planService.plan(MusicPlanRequestDTO(
                        storyId: story.id, creativeIntent: intentJSON, musicDirection: directionJSON,
                        targetDurationSeconds: target, storyGuide: guideJSON, storyCoverage: coverageJSON,
                        soundPreference: effectivePref))
                }
                Self.inFlightMusicPlans[planFingerprint] = task
                defer { Self.inFlightMusicPlans[planFingerprint] = nil }
                do {
                    planJSON = try await task.value
                } catch {
                    StoryCreativeRefinement.lastMusicPlanInput =
                        "build=\(StoryCreativeRefinement.buildIdentifier) ensureGuide=\(ensuredGuide != nil ? "ok" : "nil") guide=\(guidePresent ? "yes(\(guideDims)dims)" : "EMPTY") coverage=\(covPresent ? "yes" : "EMPTY") -> MusicPlan ERROR"
                    return nil
                }
                // Persist ONLY a valid, non-empty plan (never cache a partial/empty result).
                if case .object(let o) = planJSON, !o.isEmpty {
                    Self.storeMusicPlan(storyId: story.id, fingerprint: planFingerprint, plan: planJSON, context: context)
                    MediaEngineV1.beacon("musicplan: cache MISS->stored fp=\(planFingerprint.prefix(8))")
                }
            }
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

    /// Resolve a KNOWN provider track directly by its id, WITHOUT running a fresh recommendation. Used when a
    /// Revise must carry the base version's existing soundtrack forward: re-recommending (resolveSelection's
    /// path) can return a DIFFERENT top pick or fail entirely on a transient provider hiccup, silently dropping
    /// music from the revised video. This path only needs the base's persisted role/priority/title/plan, so it
    /// downloads + analyses the exact same track and never depends on the recommender. nil => download/analysis
    /// failed (caller then runs the honest no-music path, same as before).
    func resolveKnownTrack(trackId: String, musicPlanJSON: JSONValue,
                           soundtrackRole: String, nativeAudioPriority: String,
                           title: String) async -> StoryCreationCoordinator.MusicSelection? {
        let analysis: MusicAnalysisV1
        let analysisJSON: JSONValue
        do {
            let both = try await candidatesService.analysisBoth(trackId: trackId)
            analysis = both.analysis; analysisJSON = both.raw
        } catch {
            MediaEngineV1.beacon("resolveKnown: analysis FAILED \(error)")
            return nil
        }
        let url: URL
        do { url = try await candidatesService.downloadSoundtrack(trackId: trackId) }
        catch {
            MediaEngineV1.beacon("resolveKnown: download FAILED \(error)")
            return nil
        }
        MediaEngineV1.beacon("resolveKnown: OK track=\(trackId.prefix(8)) url=\(url.lastPathComponent)")
        return StoryCreationCoordinator.MusicSelection(
            musicPlanJSON: musicPlanJSON,
            trackId: trackId,
            analysisJSON: analysisJSON,
            analysis: analysis,
            soundtrackURL: url,
            soundtrackRole: soundtrackRole,
            nativeAudioPriority: nativeAudioPriority,
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

    // MARK: - MusicPlan cache (latency P0)

    /// In-flight MusicPlan inferences keyed by fingerprint, so two near-simultaneous "find music" opens share
    /// ONE model call instead of each spending ~10s. MainActor-isolated (the resolver is @MainActor).
    private static var inFlightMusicPlans: [String: Task<JSONValue, Error>] = [:]

    /// Canonical fingerprint of EVERY input that feeds /v1/music-plan. Any change (intent, direction, guide,
    /// coverage, sound preference, target, prompt version) produces a different hash -> cache miss -> recompute.
    /// Deterministic (sorted-keys JSON + SHA256), so it is stable across app launches.
    static func musicPlanFingerprint(intent: JSONValue, direction: JSONValue, guide: JSONValue,
                                     coverage: JSONValue, soundPreference: String, target: Double,
                                     promptVersion: String = "music_plan/1") -> String {
        // Provenance / volatile keys that change run-to-run (or when a Guide/Coverage/Direction is re-stamped)
        // but do NOT affect the MusicPlan's content. Stripping them recursively is what makes a reopen with
        // unchanged inputs hash IDENTICALLY — otherwise `generated_at` alone forces a cache miss every time
        // (observed: two reopens produced two different fingerprints and both missed).
        let volatileKeys: Set<String> = ["generated_at", "generatedat", "created_at", "createdat",
                                         "updated_at", "updatedat", "timestamp", "id", "model_id", "modelid",
                                         "prompt_version", "promptversion", "schema_version", "schemaversion",
                                         "correlation_id", "correlationid"]
        func strip(_ v: JSONValue) -> JSONValue {
            switch v {
            case .object(let d):
                var out: [String: JSONValue] = [:]
                for (k, val) in d where !volatileKeys.contains(k.lowercased()) { out[k] = strip(val) }
                return .object(out)
            case .array(let a):
                return .array(a.map(strip))
            default:
                return v
            }
        }
        func canon(_ v: JSONValue) -> String {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            return (try? enc.encode(strip(v))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        let joined = [promptVersion, String(format: "%.1f", target), soundPreference,
                      canon(intent), canon(direction), canon(guide), canon(coverage)].joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Return the cached MusicPlan JSON for this Story IF the stored fingerprint matches; else nil (miss).
    static func cachedMusicPlan(storyId: UUID, fingerprint: String, context: ModelContext) -> JSONValue? {
        let desc = FetchDescriptor<MusicPlanCacheModel>(predicate: #Predicate { $0.storyId == storyId })
        guard let row = (try? context.fetch(desc))?.first, row.inputFingerprint == fingerprint,
              let data = row.planJSON.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return v
    }

    /// Upsert the cached MusicPlan (one row per Story). Only called with a validated, non-empty plan.
    static func storeMusicPlan(storyId: UUID, fingerprint: String, plan: JSONValue, context: ModelContext) {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(plan), let json = String(data: data, encoding: .utf8) else { return }
        let desc = FetchDescriptor<MusicPlanCacheModel>(predicate: #Predicate { $0.storyId == storyId })
        if let row = (try? context.fetch(desc))?.first {
            row.planJSON = json; row.inputFingerprint = fingerprint; row.updatedAt = .now
        } else {
            context.insert(MusicPlanCacheModel(storyId: storyId, planJSON: json, inputFingerprint: fingerprint))
        }
        try? context.save()
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
