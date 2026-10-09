import Foundation
import SwiftData
import CoreGraphics

// StoryCreationCoordinator — R-c Batch A.
//
// The consumer Create-My-Story engine: it drives ONE Story from its already-
// persisted inputs (resolved CreativeIntent + completed MomentUnderstanding[] +
// local assets) through PLAN -> VALIDATE -> RENDER -> a real persisted
// GeneratedOutputModel. It makes NO creative decisions (the Edit Planner plans)
// and NO rendering decisions (MediaEngineV1 renders the frozen plan); it
// orchestrates, validates deterministically before touching AVFoundation, and
// persists the result.
//
// NO-MUSIC milestone, but MUSIC-READY: every music input is an OPTIONAL seam
// (defaulted nil). R-c always passes nil; when a future MusicPlan engine supplies
// a soundtrackURL / analysis, those thread straight into MediaEngineInputs with
// no new domain contract and no change to this state machine.
//
// This is NOT UI (Batch B owns screens). It is @MainActor + Observable so a Batch B
// view can observe `state` / `isCreating` directly.

// MARK: - Seams (protocols so tests inject fakes; prod wires the real services)

/// The render seam. Wraps `MediaEngineV1.render` so a test can substitute a fake
/// that returns a RenderResult (or throws) WITHOUT running AVFoundation.
protocol StoryRendering {
    func render(_ inputs: MediaEngineInputs,
                progress: ((Float) -> Void)?,
                shouldCancel: (() -> Bool)?) async throws -> RenderResult
}

/// Production renderer: the real MediaEngineV1. Device/Xcode-gated at runtime.
struct MediaEngineRenderer: StoryRendering {
    func render(_ inputs: MediaEngineInputs,
                progress: ((Float) -> Void)?,
                shouldCancel: (() -> Bool)?) async throws -> RenderResult {
        try await MediaEngineV1().render(inputs, progress: progress, shouldCancel: shouldCancel)
    }
}

// MARK: - Errors surfaced into `failed(message:)`

enum StoryCreationError: Error, LocalizedError, Equatable {
    case missingPrerequisite(String)   // no usable Moments, no target duration, etc. — honest, never invented
    case planUnavailable               // planner 503 — the server refused to fabricate a plan
    case planInfeasible(String)        // planner 422 — carries the server reason
    case planTransport(String)         // transport / unexpected planner failure
    case invalidPlan(String)           // our deterministic validator rejected the plan (pre-AVFoundation)
    case renderFailed(String)          // the renderer threw
    case alreadyCreating               // duplicate-job guard
    /// Deterministic PREFLIGHT verdict: the Story's material can't reach the target's lower tolerance bound.
    /// Carries the conservative achievable estimate, the requested target, and (when a shorter Story is
    /// possible) a suggested target. This is NOT a technical failure — the UI offers an actionable duration
    /// choice, never a plain Retry, and the planner is NEVER called with the impossible target.
    case insufficientMaterial(achievable: Double, requested: Double, suggested: Double?)

    var errorDescription: String? {
        switch self {
        case .missingPrerequisite(let w): return w
        case .planUnavailable: return "The Edit Planner is temporarily unavailable. Please retry."
        case .planInfeasible(let r): return "This Story's material can't fill the target: \(r)"
        case .planTransport(let r): return "Couldn't reach the Edit Planner: \(r)"
        case .invalidPlan(let r): return "The plan can't be rendered: \(r)"
        case .renderFailed(let r): return "Rendering failed: \(r)"
        case .alreadyCreating: return "A video is already being created for this Story."
        case .insufficientMaterial(let achievable, let requested, let suggested):
            let a = Int(achievable.rounded()), req = Int(requested.rounded())
            if let s = suggested {
                return "There's about \(a)s of usable footage — not enough for a \(req)s Story. "
                     + "You can create a shorter \(Int(s.rounded()))s Story, or keep shooting."
            }
            return "There's only about \(a)s of usable footage — not enough for a \(req)s Story yet. "
                 + "Shoot or add a little more and try again."
        }
    }
}

// MARK: - Coordinator

@MainActor
@Observable
final class StoryCreationCoordinator {

    /// The EXACT 8-state lifecycle (R-c Batch A spec).
    enum State: Equatable {
        case idle
        case preparing
        case planning
        case validating
        case rendering(progress: Double)
        case completed(GeneratedOutputModel)
        case failed(message: String)
        case cancelled

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.preparing, .preparing), (.planning, .planning),
                 (.validating, .validating), (.cancelled, .cancelled):
                return true
            case let (.rendering(a), .rendering(b)): return a == b
            case let (.completed(a), .completed(b)): return a.id == b.id
            case let (.failed(a), .failed(b)): return a == b
            default: return false
            }
        }
    }

    // Observable surface for Batch B.
    private(set) var state: State = .idle
    /// Duplicate-job guard: true while a creation is in flight for this coordinator's Story.
    private(set) var isCreating: Bool = false
    /// The structured error behind the CURRENT `.failed` state (nil otherwise). The UI reads this to decide
    /// whether to show a plain Retry (recoverable technical failure) or the actionable duration choice
    /// (insufficient material). `state` keeps carrying only the human message, so existing behavior/tests hold.
    private(set) var lastFailure: StoryCreationError?

    // Seams
    private let planner: EditPlanning
    private let renderer: StoryRendering
    private let context: ModelContext

    // Optional MUSIC seam — R-c always nil; threaded into MediaEngineInputs when present.
    private let musicDirection: JSONValue?
    private let musicPlan: JSONValue?
    private let selectedMusicAssetId: String?
    private let musicAnalysis: MusicAnalysisV1?
    private let soundtrackURL: URL?

    /// R-d: a music selection RESOLVED by the UI (MusicPlan + chosen track + its analysis + a downloaded
    /// local soundtrack file). Set per-run via create(for:music:). When nil the pipeline runs the
    /// device-verified no-music path unchanged. The planner plans MUSIC-AWARE and the renderer mixes the
    /// soundtrack only when this is present; a music failure upstream simply leaves it nil (no-music fallback).
    struct MusicSelection {
        let musicPlanJSON: JSONValue       // frozen music_plan/1 (threaded into the planner request)
        let trackId: String                // selected Epidemic track id
        let analysisJSON: JSONValue        // frozen music_analysis/1 for the planner request
        let analysis: MusicAnalysisV1      // decoded, for the renderer's beat/highlight alignment
        let soundtrackURL: URL             // local downloaded audio file for the render
        let soundtrackRole: String         // from the plan's audio_strategy
        let nativeAudioPriority: String
        let trackTitle: String
    }
    private var pendingMusic: MusicSelection?

    // In-flight task + cancel flag + the partial output path to clean up on cancel/failure.
    private var task: Task<Void, Never>?
    private var cancelRequested = false
    private var partialRelativePath: String?

    // Remember the last request so retry() can re-run without the caller re-supplying it.
    private var lastStory: StoryModel?
    private var lastOutputFormat: String = "vertical"
    private var lastTargetSeconds: Double?
    private var lastMusic: MusicSelection?

    init(
        planner: EditPlanning,
        renderer: StoryRendering = MediaEngineRenderer(),
        context: ModelContext,
        musicDirection: JSONValue? = nil,
        musicPlan: JSONValue? = nil,
        selectedMusicAssetId: String? = nil,
        musicAnalysis: MusicAnalysisV1? = nil,
        soundtrackURL: URL? = nil
    ) {
        self.planner = planner
        self.renderer = renderer
        self.context = context
        self.musicDirection = musicDirection
        self.musicPlan = musicPlan
        self.selectedMusicAssetId = selectedMusicAssetId
        self.musicAnalysis = musicAnalysis
        self.soundtrackURL = soundtrackURL
    }

    // MARK: - Public API

    /// Begin creating a video for `story`. Refuses a second concurrent creation
    /// (duplicate-job guard). Returns immediately; progress is observable via `state`.
    func create(for story: StoryModel, outputFormat: String = "vertical", targetSeconds: Double? = nil) {
        createWithMusic(for: story, outputFormat: outputFormat, targetSeconds: targetSeconds, music: nil)
    }

    /// R-d: begin creation with a RESOLVED music selection (or nil for no-music). The UI resolves music
    /// (MusicPlan -> candidates -> pick -> download) and hands it in; the pipeline then plans music-aware and
    /// renders with the soundtrack. A nil selection is the exact no-music path.
    func createWithMusic(for story: StoryModel, outputFormat: String = "vertical",
                         targetSeconds: Double? = nil, music: MusicSelection?) {
        guard !isCreating else { return }
        lastStory = story
        lastOutputFormat = outputFormat
        lastTargetSeconds = targetSeconds
        pendingMusic = music
        lastMusic = music
        isCreating = true
        cancelRequested = false
        partialRelativePath = nil
        lastFailure = nil
        task = Task { [weak self] in await self?.run(story: story, outputFormat: outputFormat, targetSeconds: targetSeconds) }
    }

    /// Cancel the in-flight creation: cancels the task, cleans any partial output,
    /// preserves Moments, lands in `.cancelled`.
    func cancel() {
        guard isCreating else { return }
        cancelRequested = true
        task?.cancel()
    }

    /// Retry after a recoverable failure. No-op unless we are in `.failed` with a remembered request.
    func retry() {
        guard case .failed = state, let story = lastStory, !isCreating else { return }
        createWithMusic(for: story, outputFormat: lastOutputFormat, targetSeconds: lastTargetSeconds, music: lastMusic)
    }

    /// Accept a SHORTER duration after an insufficient-material preflight verdict and re-run. The shorter value
    /// is passed as a per-attempt `targetSeconds` override ONLY — the Story's own CreativeIntent target
    /// (`intentTargetDurationSeconds`) is NOT mutated, so the user's original intent is preserved unless they
    /// explicitly edit it. No-op unless we are in `.failed` after an insufficient-material verdict.
    func createShorter(targetSeconds: Double) {
        guard case .failed = state, let story = lastStory, !isCreating else { return }
        guard case .insufficientMaterial = lastFailure else { return }
        createWithMusic(for: story, outputFormat: lastOutputFormat, targetSeconds: targetSeconds, music: lastMusic)
    }

    // MARK: - Pipeline

    private func run(story: StoryModel, outputFormat: String, targetSeconds: Double?) async {
        defer { isCreating = false; task = nil }

        // ---- preparing: gather REAL persisted inputs; missing prerequisite -> honest failure ----
        state = .preparing
        let build: EditPlanRequestBuilder.Build
        do {
            build = try EditPlanRequestBuilder.build(
                story: story, context: context, targetSeconds: targetSeconds, outputFormat: outputFormat,
                musicPlan: pendingMusic?.musicPlanJSON,
                musicAssetId: pendingMusic?.trackId,
                musicAnalysis: pendingMusic?.analysisJSON)
        } catch let e as EditPlanRequestBuilder.BuildError {
            return finishFailed(.missingPrerequisite(e.errorDescription ?? "Missing prerequisites for creation."))
        } catch {
            return finishFailed(.missingPrerequisite("Couldn't assemble the creation request: \(error)"))
        }
        if cancelRequested { return finishCancelled() }

        // ---- feasibility preflight: deterministic, BEFORE the planner. If the material can't reach the
        // target's lower tolerance bound, DON'T call Opus with an impossible target — surface an actionable
        // duration choice (shorter Story / keep shooting). Uses the SAME request.moments the planner would get. ----
        if let target = build.resolvedTargetSeconds {
            switch DurationFeasibility.evaluate(materials: build.materials, targetSeconds: target) {
            case .feasible:
                break   // proceed to planning
            case .shorterPossible(let achievable, let suggested, let requested):
                return finishFailed(.insufficientMaterial(achievable: achievable, requested: requested, suggested: suggested))
            case .insufficient(let achievable, let requested):
                return finishFailed(.insufficientMaterial(achievable: achievable, requested: requested, suggested: nil))
            }
        }
        if cancelRequested { return finishCancelled() }

        // ---- planning: call the Edit Planner; typed failures -> failed; NEVER fabricate a montage ----
        state = .planning
        let plan: EditPlanV2
        do {
            plan = try await planner.plan(build.request)
        } catch EditPlannerServiceError.unavailable {
            return finishFailed(.planUnavailable)
        } catch EditPlannerServiceError.infeasible(let reason) {
            return finishFailed(.planInfeasible(reason))
        } catch let EditPlannerServiceError.transport(underlying) {
            return finishFailed(.planTransport(String(describing: underlying)))
        } catch EditPlannerServiceError.badStatus(let code) {
            return finishFailed(.planTransport("unexpected status \(code)"))
        } catch EditPlannerServiceError.decoding(let underlying) {
            return finishFailed(.planTransport("couldn't read the plan: \(underlying)"))
        } catch {
            return finishFailed(.planTransport(String(describing: error)))
        }
        if cancelRequested { return finishCancelled() }

        // ---- validating: deterministic, BEFORE AVFoundation; renderer never runs on an invalid plan ----
        state = .validating
        let resolver = MomentResolver.urlResolver(for: build.includedMedia)
        if let reason = Self.validate(plan: plan, resolver: resolver, includedMedia: build.includedMedia) {
            return finishFailed(.invalidPlan(reason))
        }
        if cancelRequested { return finishCancelled() }

        // ---- rendering: real renderer with progress + cancel flag (music seam threaded) ----
        state = .rendering(progress: 0)
        let inputs = MediaEngineInputs(
            plan: plan,
            resolveMomentURL: resolver,
            soundtrackURL: pendingMusic?.soundtrackURL ?? soundtrackURL,   // R-d: resolved local audio; else nil (no-music)
            musicAnalysis: pendingMusic?.analysis ?? musicAnalysis,         // R-d: selected-track analysis; else nil
            soundtrackRole: pendingMusic?.soundtrackRole ?? "supportive",
            nativeAudioPriority: pendingMusic?.nativeAudioPriority ?? "selective")

        let result: RenderResult
        do {
            result = try await renderer.render(
                inputs,
                progress: { [weak self] p in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .rendering = self.state { self.state = .rendering(progress: Double(p)) }
                    }
                },
                shouldCancel: { [weak self] in self?.cancelRequested ?? false })
        } catch {
            if cancelRequested { return finishCancelled() }
            return finishFailed(.renderFailed(String(describing: error)))
        }
        if cancelRequested {
            // Cancelled after a successful export: clean the just-produced file.
            cleanup(relative: result.relativePath)
            return finishCancelled()
        }

        // ---- completed: persist a REAL GeneratedOutputModel; do NOT overwrite a prior success until now ----
        let output = persist(result: result, plan: plan, story: story, build: build)
        state = .completed(output)
    }

    // MARK: - Deterministic validator (pre-AVFoundation)

    /// Validate a plan WITHOUT AVFoundation. Returns a human reason on the FIRST failure, or nil if valid.
    /// Checks: feasible flag; every referenced Moment resolves to a local file; source ranges valid
    /// (end > start when both present); speed in [0.5, 2.0]; per-segment output duration > 0 and the plan's
    /// total feasible vs the summed source material; transitions in {cut,fade,dissolve}; native_audio in
    /// {keep,duck,mute}.
    static func validate(plan: EditPlanV2,
                         resolver: (String) -> URL?,
                         includedMedia: [MomentMedia]) -> String? {
        guard plan.feasible else { return "planner marked the plan infeasible" }
        guard !plan.segments.isEmpty else { return "plan has no segments" }

        // Map Moment id (lowercased) -> source duration, for the duration-feasibility check.
        let durationById = Dictionary(uniqueKeysWithValues:
            includedMedia.map { ($0.momentId.uuidString.lowercased(), $0.durationSeconds) })

        var sourceSum = 0.0
        var outputSum = 0.0
        for seg in plan.segments.sorted(by: { $0.order < $1.order }) {
            // referenced Moment resolves to a local file
            guard resolver(seg.assetId) != nil else {
                return "segment \(seg.order) references Moment \(seg.assetId) with no local file"
            }
            // source range validity
            if let a = seg.sourceStartSeconds, let b = seg.sourceEndSeconds, b <= a {
                return "segment \(seg.order) has an invalid source range (end <= start)"
            }
            if let a = seg.sourceStartSeconds, a < 0 {
                return "segment \(seg.order) has a negative source start"
            }
            // speed in [0.5, 2.0] (V1 renderer limit)
            if let s = seg.speed, s < 0.5 || s > 2.0 {
                return "segment \(seg.order) speed \(s) out of range [0.5, 2.0]"
            }
            // per-segment output duration must be positive
            guard seg.outputDurationSeconds > 0 else {
                return "segment \(seg.order) has non-positive output duration"
            }
            // transition type
            if let t = seg.transition?.type, !["cut", "fade", "dissolve"].contains(t) {
                return "segment \(seg.order) has unsupported transition '\(t)'"
            }
            // native audio
            guard ["keep", "duck", "mute"].contains(seg.nativeAudio) else {
                return "segment \(seg.order) has unsupported native_audio '\(seg.nativeAudio)'"
            }
            // source material available for the requested span (speed-adjusted). An output segment of
            // duration d at speed s consumes d*s seconds of source; it cannot exceed the clip length.
            let srcDur = durationById[seg.assetId.lowercased()]
            if let avail = srcDur, avail > 0 {
                let consumed = seg.outputDurationSeconds * (seg.speed ?? 1.0)
                if consumed > avail + 0.05 {
                    return "segment \(seg.order) needs \(String(format: "%.2f", consumed))s of source but the clip is only \(String(format: "%.2f", avail))s"
                }
            }
            sourceSum += (srcDur ?? seg.outputDurationSeconds)
            outputSum += seg.outputDurationSeconds
        }

        // whole-plan duration feasibility: total output cannot exceed the summed source material
        if outputSum > sourceSum + 0.1 {
            return "total output \(String(format: "%.2f", outputSum))s exceeds available source \(String(format: "%.2f", sourceSum))s"
        }
        return nil
    }

    // MARK: - Persistence

    private func persist(result: RenderResult,
                         plan: EditPlanV2,
                         story: StoryModel,
                         build: EditPlanRequestBuilder.Build) -> GeneratedOutputModel {
        let momentIds = build.includedMedia.map(\.momentId)
        let fingerprint = Self.fingerprint(for: momentIds, story: story)
        let provenance = Self.provenance(plan: plan)

        let output = GeneratedOutputModel(
            title: story.title,
            durationSeconds: result.durationSeconds,
            momentIds: momentIds,                       // back-compat mirror
            relativeFilePath: result.relativePath,
            sourceMomentIds: momentIds,
            sourceFingerprint: fingerprint,
            editPlanProvenance: provenance,
            outputFormat: plan.outputFormat,
            renderWidth: Double(result.renderSize.width),
            renderHeight: Double(result.renderSize.height),
            isStale: false,
            soundtrackTitle: pendingMusic?.trackTitle)
        output.story = story
        context.insert(output)
        story.generatedOutputs.append(output)
        story.updatedAt = .now
        // INVARIANT (02 §): Create != Complete — status is deliberately unchanged.
        // Prior successful outputs are LEFT in place; we only ever ADD a new one once the render succeeds.
        try? context.save()
        return output
    }

    /// SHORT provenance: schema_version + planner model/none + planned duration (NOT raw plan JSON).
    static func provenance(plan: EditPlanV2) -> String {
        let model = plan.musicAssetId == nil ? "none" : "music"
        return "\(plan.schemaVersion); model=\(model); planned=\(String(format: "%.2f", plan.targetDurationSeconds))s"
    }

    // MARK: - Lifecycle terminal helpers

    private func finishFailed(_ error: StoryCreationError) {
        if let rel = partialRelativePath { cleanup(relative: rel) }
        lastFailure = error
        state = .failed(message: error.errorDescription ?? "Creation failed.")
    }

    private func finishCancelled() {
        if let rel = partialRelativePath { cleanup(relative: rel) }
        state = .cancelled
    }

    private func cleanup(relative: String) {
        let url = RenderOutputStore.shared.absoluteURL(for: relative)
        try? FileManager.default.removeItem(at: url)
        partialRelativePath = nil
    }

    // MARK: - Staleness fingerprint (pure, static, testable)
    //
    // MVP FINGERPRINT SEMANTICS
    // -------------------------
    // The fingerprint is a stable hash of, for each INCLUDED Moment (sorted by id
    // so order is irrelevant):
    //     <moment id> | <asset.relativePath> | <asset.durationSeconds>
    //
    // Consequences, by design:
    //   * Adding or removing a Moment changes the set -> fingerprint changes -> stale.
    //   * SOURCE-MEDIA REPLACEMENT UNDER AN UNCHANGED MOMENT ID INVALIDATES THE
    //     OUTPUT: swapping the file (new relativePath) or re-trimming it to a new
    //     duration changes the per-Moment line even though the Moment id is the same.
    //   * We deliberately DO NOT fold StoryGuide dimension ids into the fingerprint
    //     (a Guide re-dimensioning that leaves the actual media untouched does not,
    //     for MVP, invalidate an already-rendered video).
    //   * A Moment with no asset contributes a stable "<id>|-|0" line (so a Moment
    //     losing its media still changes the fingerprint).
    //
    // The hash is a dependency-free stable digest. Swift's Hasher is NOT stable
    // across launches, so we hash the canonical string with a deterministic FNV-1a
    // — reproducible across processes, which staleness detection requires.

    /// Compute the fingerprint for an explicit set of Moment ids against a Story's
    /// current Moments. Only ids present on the Story contribute (an id not found
    /// contributes a "<id>|-|0" line, so a vanished Moment still shifts the hash).
    static func fingerprint(for momentIds: [UUID], story: StoryModel) -> String {
        let byId = Dictionary(uniqueKeysWithValues: story.moments.map { ($0.id, $0) })
        let lines = momentIds
            .sorted { $0.uuidString < $1.uuidString }
            .map { id -> String in
                if let m = byId[id] {
                    let rel = m.asset?.relativePath ?? "-"
                    let dur = m.asset?.durationSeconds ?? 0
                    return "\(id.uuidString)|\(rel)|\(dur)"
                }
                return "\(id.uuidString)|-|0"
            }
        return fnv1aHex(lines.joined(separator: "\n"))
    }

    /// Is a stored output stale vs the Story's CURRENT included Moments? Recomputes
    /// the fingerprint from the output's own `sourceMomentIds` against the live
    /// Story and compares to the stored `sourceFingerprint`.
    static func isOutputStale(output: GeneratedOutputModel, story: StoryModel) -> Bool {
        let ids = output.sourceMomentIds.isEmpty ? output.momentIds : output.sourceMomentIds
        let current = fingerprint(for: ids, story: story)
        return current != output.sourceFingerprint
    }

    /// Deterministic, cross-process-stable 64-bit FNV-1a digest, hex-encoded.
    static func fnv1aHex(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
