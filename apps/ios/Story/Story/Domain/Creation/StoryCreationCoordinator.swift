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
    /// Honest, consumer-safe sub-line for the planning phase, driven by the REAL backend job status
    /// (queued -> "Queued for planning", running -> "Planning your Story", and once the critique pass starts
    /// "Refining the edit"). nil outside planning. No model/HTTP/stage-internal names.
    private(set) var planningSubstatus: String?
    /// Duplicate-job guard: true while a creation is in flight for this coordinator's Story.
    private(set) var isCreating: Bool = false
    /// The structured error behind the CURRENT `.failed` state (nil otherwise). The UI reads this to decide
    /// whether to show a plain Retry (recoverable technical failure) or the actionable duration choice
    /// (insufficient material). `state` keeps carrying only the human message, so existing behavior/tests hold.
    private(set) var lastFailure: StoryCreationError?

    /// MVP multimodal: diagnostics from the most recent planning phase (nil until a run plans). Read for
    /// device-acceptance verification; carries NO image content.
    private(set) var lastPlanningDiagnostics: StoryPlanningDiagnostics?

    // Seams
    private let planner: EditPlanning
    private let jobClient: EditPlanJobClienting
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
    // Creative Revision Foundation: a per-run version-aware context + the user-selected parent version. Set
    // only on a deliberate "Create another version" (Explore). nil => an original create (behavior unchanged).
    private var pendingRevisionContext: JSONValue?
    private var pendingParentVersionId: UUID?
    private var pendingOperationType: String = "original"
    /// Diversity diagnostics from the most recent Explore run (nil otherwise) — read for device verification.
    private(set) var lastDiversity: RevisionContextBuilder.Diversity?

    /// Compose the effective revision_context sent to the planner: the per-run base context (Explore/Revise,
    /// or nil for an original create) with the Story's PERSISTED explicit Moment-reference directives folded
    /// into its `directives` key. The directives are resolved stable UUIDs captured in Creative Direction, so
    /// they apply to BOTH an original creation and a version re-create. Returns nil only when there is neither
    /// a base context nor any directives (behavior unchanged — the request is byte-identical to today).
    static func composeRevisionContext(base: JSONValue?, story: StoryModel) -> JSONValue? {
        let directives = ResolvedDirectives.fromWireJSON(story.creativeDirectivesJSON)?.jsonValue()
        guard directives != nil || base != nil else { return nil }
        // Start from the base object (or an empty revise-less object). An original create with directives only
        // uses mode "revise" so the planner reads the hard requirements as REQUIREMENTS, not an explore nudge.
        var obj: [String: JSONValue]
        if case .object(let o)? = base { obj = o } else { obj = [:] }
        if obj["mode"] == nil { obj["mode"] = .string(directives != nil ? "revise" : "explore") }
        // Fold the Story's persisted creation-time directives ONLY when the base context does not already carry
        // its own (a Revise run supplies its own directives from the user's revise instruction — never clobber).
        if obj["directives"] == nil, let directives { obj["directives"] = directives }
        return .object(obj)
    }

    /// Compact diagnostic tag for the submit beacon: what revision_context the device is actually sending.
    /// e.g. "revise+dir+base", "explore", or "none". Proves end-to-end whether Revise directives arrive.
    static func revisionModeTag(_ ctx: JSONValue?) -> String {
        guard case .object(let o)? = ctx else { return "none" }
        var mode = "?"
        if case .string(let m)? = o["mode"] { mode = m }
        var tag = mode
        if o["directives"] != nil { tag += "+dir" }
        if o["base_plan"] != nil { tag += "+base" }
        return tag
    }

    init(
        planner: EditPlanning,
        renderer: StoryRendering = MediaEngineRenderer(),
        context: ModelContext,
        jobClient: EditPlanJobClienting = EditPlanJobClient(),
        musicDirection: JSONValue? = nil,
        musicPlan: JSONValue? = nil,
        selectedMusicAssetId: String? = nil,
        musicAnalysis: MusicAnalysisV1? = nil,
        soundtrackURL: URL? = nil
    ) {
        self.planner = planner
        self.jobClient = jobClient
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
        // Original create (or a retry of one): clear any Explore version-context so stale context never leaks.
        pendingRevisionContext = nil
        pendingParentVersionId = nil
        pendingOperationType = "original"
        beginRun(for: story, outputFormat: outputFormat, targetSeconds: targetSeconds, music: music)
    }

    /// Shared run starter used by both an original create and a deliberate another-version. Does NOT touch the
    /// Explore version-context fields, so the caller controls them (createWithMusic clears, createAnotherVersion sets).
    private func beginRun(for story: StoryModel, outputFormat: String,
                          targetSeconds: Double?, music: MusicSelection?) {
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
        // Also tell the backend to cancel the in-flight planning job so the worker finalizes `cancelled` and
        // cleans its staged visual evidence — otherwise a running job would keep burning model time server-side.
        if let jid = lastStory?.planJobId {
            Task { await jobClient.cancel(jobId: jid) }
        }
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

    /// Create another version (Creative Revision Foundation — EXPLORE). Re-plans with a version-aware context
    /// derived from the user-SELECTED parent output (+ a bounded set of recent versions of this Story), under an
    /// explicit alternative-edit objective. ADDITIVE: a new GeneratedOutput is appended on success; the parent
    /// and all prior versions are preserved. A FRESH operation_id is minted (deliberate new execution — never a
    /// fingerprint bypass). Reuses the SAME planner/validation/render path; music + user settings preserved.
    func createAnotherVersion(for story: StoryModel, from parent: GeneratedOutputModel,
                              outputFormat: String = "vertical", targetSeconds: Double? = nil,
                              music: MusicSelection? = nil) {
        guard !isCreating else { return }
        // Deliberate new version => NEW operation_id (clear any carried-over handle so a fresh job is minted).
        story.planOperationId = nil; story.planJobId = nil
        let recents = story.generatedOutputs.sorted { $0.createdAt > $1.createdAt }
        pendingRevisionContext = RevisionContextBuilder.explore(parent: parent, recents: recents)
        pendingParentVersionId = parent.versionId ?? parent.id
        pendingOperationType = "another_version"
        lastDiversity = nil
        beginRun(for: story, outputFormat: outputFormat, targetSeconds: targetSeconds, music: music)
    }

    /// Revise a SELECTED version with a user-directed change (Natural-Language Revision). Carries mode="revise"
    /// + the EXACT base plan + resolved hard directives + the soft request, so the planner APPLIES the change
    /// while preserving unaffected edits and the backend validates the hard directives deterministically.
    /// ADDITIVE: a new GeneratedOutput is appended; the base and all prior versions are preserved. A FRESH
    /// operation_id is minted. Reuses the SAME planner/validation/render path; music + user settings preserved.
    func reviseVersion(for story: StoryModel, base: GeneratedOutputModel,
                       directives: ResolvedDirectives, softDirection: String,
                       outputFormat: String = "vertical", targetSeconds: Double? = nil,
                       music: MusicSelection? = nil) {
        guard !isCreating else { return }
        story.planOperationId = nil; story.planJobId = nil
        pendingRevisionContext = RevisionContextBuilder.revise(base: base, directives: directives,
                                                               softDirection: softDirection)
        pendingParentVersionId = base.versionId ?? base.id
        pendingOperationType = "revision"
        lastDiversity = nil
        beginRun(for: story, outputFormat: outputFormat, targetSeconds: targetSeconds, music: music)
    }

    // MARK: - Pipeline

    private func run(story: StoryModel, outputFormat: String, targetSeconds: Double?) async {
        defer { isCreating = false; task = nil }

        // ---- preparing: gather REAL persisted inputs; missing prerequisite -> honest failure ----
        state = .preparing
        let build: EditPlanRequestBuilder.Build
        do {
            // Imported My Music has no backend MusicPlan — its selection carries an empty music_plan object.
            // Pass nil to the planner in that case so the edit is planned like the parity/no-music path; the
            // imported soundtrack is a render-time overlay (the renderer uses soundtrackURL, not the plan).
            let planForBuilder: JSONValue? = {
                guard let p = pendingMusic?.musicPlanJSON else { return nil }
                if case .object(let o) = p, o.isEmpty { return nil }
                return p
            }()
            let assetIdForBuilder = pendingMusic?.trackId.hasPrefix("mymusic:") == true ? nil : pendingMusic?.trackId
            build = try EditPlanRequestBuilder.build(
                story: story, context: context, targetSeconds: targetSeconds, outputFormat: outputFormat,
                musicPlan: planForBuilder,
                musicAssetId: assetIdForBuilder,
                musicAnalysis: planForBuilder == nil ? nil : pendingMusic?.analysisJSON,
                revisionContext: Self.composeRevisionContext(base: pendingRevisionContext, story: story))
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
        var plan: EditPlanV2
        let requested = story.effectiveEditingApproach
        let wantMultimodal = requested.requiresMultimodal && StoryMultimodalPlanning.enabled
        do {
            // ---- ASYNC Edit Planning (Phase 2): submit a job, poll to completion. Removes the ~120s App
            // Runner ceiling; the worker runs the SAME core. BOTH approaches use this one path. ----
            // Build visual evidence for visual_first (unchanged budget preflight); text-only sends no sheets.
            var sheets: [MomentContactSheet] = []
            var budgetDiag = (tier: "text_only", applied: [String](), textOnly: 0, imageBytes: 0)
            if wantMultimodal {
                let budget = await MultimodalVisualBudget.build(Self.visualBudgetInputs(from: build))
                sheets = budget.sheets
                budgetDiag = (budget.selectedTier, budget.appliedSteps, budget.momentsTextOnly,
                              budget.sheets.reduce(0) { $0 + $1.jpeg.count })
            }
            // operation_id = idempotency key. Persist BEFORE submit so a crash/restart/retry/dup-tap reuses the
            // SAME job (no duplicate inference). Reuse the Story's existing id on recovery; mint one otherwise.
            if story.planOperationId == nil {
                story.planOperationId = UUID().uuidString
                try? context.save()
            }
            let opId = story.planOperationId!
            let brief = wantMultimodal ? StoryMultimodalPlanning.creativeBrief : nil
            let critique = wantMultimodal && StoryMultimodalPlanning.critiqueRevisionEnabled

            // Submit (or recover an in-flight job_id). A transport error here is safe to retry with the same opId.
            let jobId: String
            if let existing = story.planJobId {
                jobId = existing   // recovery: a job was already submitted for this attempt
            } else {
                jobId = try await jobClient.submit(build.request, operationId: opId, owner: "dev", approach: requested,
                                                   sheets: sheets, creativeBrief: brief, critiqueRevision: critique)
                story.planJobId = jobId; story.planJobStatus = "queued"; try? context.save()
            }
            MediaEngineV1.beacon("editplan-job: submit req=\(requested.rawValue) sheets=\(sheets.count) "
                + "critique=\(critique) job=\(jobId.prefix(8)) "
                + "rev=\(Self.revisionModeTag(build.request.revisionContext)) "
                + "music=\(pendingMusic?.trackId.prefix(10) ?? "none") op=\(pendingOperationType)")

            // Poll to terminal (bounded backoff; transport errors don't end the poll; cancel stops it).
            let final = try await jobClient.pollUntilTerminal(
                jobId: jobId, maxSeconds: 900,
                shouldCancel: { [weak self] in self?.cancelRequested ?? false },
                onState: { [weak self] st in
                    story.planJobStatus = st.status.rawValue
                    // Reflect the REAL backend stage in the planning sub-line (honest; backend only distinguishes
                    // queued vs running — critique happens inside one 'running' invocation and is NOT separately
                    // observable, so we do not fabricate a 'Refining' stage the server can't report).
                    self?.planningSubstatus = {
                        switch st.status {
                        case .queued:           return "Queued for planning…"
                        case .running:          return "Planning your Story…"
                        case .cancelRequested:  return "Cancelling…"
                        default:                return nil
                        }
                    }()
                })

            switch final.status {
            case .completed:
                guard let p = final.plan else { return finishFailed(.planUnavailable) }
                plan = p
                let actualRaw = (final.diagnostics?["planning_mode"]?.stringValue == "multimodal")
                    ? EditingApproach.visualFirst : .storytelling
                lastPlanningDiagnostics = StoryPlanningDiagnostics(
                    usedMultimodal: actualRaw == .visualFirst,
                    sheetCount: Int(final.diagnostics?["sheet_count"]?.doubleValue ?? 0),
                    imageBytes: budgetDiag.imageBytes, momentsTextOnly: budgetDiag.textOnly,
                    selectedTier: budgetDiag.tier, appliedSteps: budgetDiag.applied,
                    fallbackReason: nil, creativeBriefVersion: StoryMultimodalPlanning.creativeBriefVersion,
                    requestedApproach: requested, actualApproach: actualRaw)
                story.planJobStatus = "completed"; try? context.save()
            case .failed:
                // Distinguish the failure classes for honest UX (Phase 3).
                switch final.failure {
                case .materialInfeasible: return finishFailed(.planInfeasible(final.failureDetail ?? "material"))
                case .providerExhausted:  return finishFailed(.planUnavailable)   // quota — try later
                default:                   return finishFailed(.planUnavailable)
                }
            case .cancelled:
                return finishCancelled()
            case .expired, .queued, .running, .cancelRequested:
                return finishFailed(.planTransport("planning did not complete (status \(final.status.rawValue))"))
            }
        } catch is CancellationError {
            return finishCancelled()
        } catch is CancellationError {
            return finishCancelled()
        } catch EditPlanJobError.conflict {
            if cancelRequested { return finishCancelled() }
            return finishFailed(.planTransport("this Story is already being created"))
        } catch EditPlanJobError.pollTimeout {
            if cancelRequested { return finishCancelled() }
            // The job may still be running server-side — do NOT lose it; the Story keeps its job_id for reopen.
            return finishFailed(.planTransport("still working — reopen to continue"))
        } catch let EditPlanJobError.transport(underlying) {
            // A user cancel aborts the in-flight URLSession task with NSURLError -999 "cancelled" — that is a
            // CANCELLATION, not a failure. Land in .cancelled (-> Story Home), never the error screen.
            if cancelRequested || (underlying as NSError).code == NSURLErrorCancelled {
                return finishCancelled()
            }
            return finishFailed(.planTransport(String(describing: underlying)))
        } catch EditPlanJobError.badStatus(let code) {
            if cancelRequested { return finishCancelled() }
            return finishFailed(.planTransport("unexpected status \(code)"))
        } catch EditPlanJobError.decoding(let underlying) {
            if cancelRequested { return finishCancelled() }
            return finishFailed(.planTransport("couldn't read the plan: \(underlying)"))
        } catch {
            if cancelRequested || (error as NSError).code == NSURLErrorCancelled {
                return finishCancelled()
            }
            return finishFailed(.planTransport(String(describing: error)))
        }
        if cancelRequested { return finishCancelled() }

        // ---- validating: deterministic, BEFORE AVFoundation; renderer never runs on an invalid plan ----
        planningSubstatus = nil   // planning is done; drop the backend-status sub-line
        state = .validating
        let resolver = MomentResolver.urlResolver(for: build.includedMedia)
        if let reason = Self.validate(plan: plan, resolver: resolver, includedMedia: build.includedMedia) {
            return finishFailed(.invalidPlan(reason))
        }
        if cancelRequested { return finishCancelled() }

        // ---- creative refinement (V2-b, architecture B): DETERMINISTIC, opt-in, OFF by default ----
        // Runs AFTER the frozen Edit Planner v4 + validation, BEFORE rendering. Proposes conservative
        // source in/out nudges toward motion-settle / audio-onset points, then re-validates; on ANY failure
        // (or when disabled) the ORIGINAL executable plan is used unchanged. Narrative selection, order,
        // output durations, speed, transitions and music alignment are all preserved. A straight cut remains
        // a valid result. Gate: StoryCreativeRefinement.enabled (default false until device-accepted).
        if StoryCreativeRefinement.enabled {
            let sourceDur: (String) -> Double? = { aid in
                build.includedMedia.first { $0.momentId.uuidString.lowercased() == aid.lowercased() }?.durationSeconds
            }
            let outcome = CreativeRefinementV2b.refine(
                plan: plan, enabled: true, resolveURL: resolver,
                actionTimestamps: build.auActionTimestamps,     // AU event starts/ends per asset ([] when absent)
                sourceDuration: sourceDur,
                usefulRanges: build.auUsefulRanges,             // AU useful_segments per asset ([] when absent)
                evidenceProvider: AVFoundationEvidence.sample)
            StoryCreativeRefinement.lastOutcomeNotes = outcome.validationNotes
            plan = outcome.plan                                 // refined OR original (safe either way)
        }

        // ---- rendering: real renderer with progress + cancel flag (music seam threaded) ----
        state = .rendering(progress: 0)
        let effectiveSoundtrack = pendingMusic?.soundtrackURL ?? soundtrackURL
        // Music diagnostic breadcrumb: why does the final video have (or lack) music? Records whether a
        // soundtrack URL reached the renderer and whether that local file actually has bytes — so a silent
        // output is diagnosable on device (StoryCreativeRefinement.lastMusicNote) instead of guessed.
        if let u = effectiveSoundtrack {
            let sz = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? nil
            StoryCreativeRefinement.lastMusicNote =
                "soundtrack URL present: \(u.lastPathComponent); file bytes=\(sz.map(String.init) ?? "MISSING/unreadable"); role=\(pendingMusic?.soundtrackRole ?? "-") priority=\(pendingMusic?.nativeAudioPriority ?? "-")"
        } else {
            StoryCreativeRefinement.lastMusicNote = "NO soundtrack URL reached the renderer (pendingMusic=\(pendingMusic == nil ? "nil" : "set")) -> no-music render"
        }
        let inputs = MediaEngineInputs(
            plan: plan,
            resolveMomentURL: resolver,
            soundtrackURL: effectiveSoundtrack,                            // R-d: resolved local audio; else nil (no-music)
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
        // Creative Revision Foundation: for an Explore run, record how different this plan is from the
        // user-selected parent (deterministic; human judgment decides worth). near_identical is the signal the
        // UI uses to AVOID silently presenting a basically-identical edit as a creative alternative.
        if pendingOperationType == "another_version", let parentId = pendingParentVersionId,
           let parent = story.generatedOutputs.first(where: { ($0.versionId ?? $0.id) == parentId }) {
            lastDiversity = RevisionContextBuilder.diversity(parent: parent, newPlan: plan)
        }

        let output = persist(result: result, plan: plan, story: story, build: build)
        // The attempt is done — clear the in-flight job handles so a reopened completed Story never re-polls.
        // (A deliberate new version mints a fresh operation_id on its next create.)
        story.planOperationId = nil; story.planJobId = nil; story.planJobStatus = "completed"
        try? context.save()
        state = .completed(output)
    }

    // MARK: - Deterministic validator (pre-AVFoundation)

    /// Validate a plan WITHOUT AVFoundation. Returns a human reason on the FIRST failure, or nil if valid.
    /// Checks: feasible flag; every referenced Moment resolves to a local file; source ranges valid
    /// (end > start when both present); speed in [0.5, 2.0]; per-segment output duration > 0 and the plan's
    /// total feasible vs the summed source material; transitions in {cut,fade,dissolve}; native_audio in
    /// MVP multimodal: assemble the adaptive-visual-budget inputs for the INCLUDED Moments (those actually in
    /// the planner request). Source URL is resolved from the Moment's local relativePath via MediaStore;
    /// richness uses the SAME AU useful_segments the planner sees (events aren't in the request, so eventCount
    /// is 0 — honest, never fabricated). A Moment with no resolvable file is skipped (it is also not in the
    /// request). Deterministic.
    static func visualBudgetInputs(from build: EditPlanRequestBuilder.Build) -> [VisualBudgetInput] {
        let ranges = build.auUsefulRanges   // [lowercased id: [(a,b)]]
        var out: [VisualBudgetInput] = []
        for m in build.includedMedia {
            guard MediaStore.shared.fileExists(relativePath: m.relativePath) else { continue }
            let url = MediaStore.shared.absoluteURL(for: m.relativePath)
            let key = m.momentId.uuidString.lowercased()
            out.append(VisualBudgetInput(
                momentId: m.momentId, url: url, durationSeconds: m.durationSeconds,
                usefulSegmentCount: ranges[key]?.count ?? 0, eventCount: 0))
        }
        return out
    }

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

        // M-e: persist the EXACT executable plan so a soundtrack-only re-render (Change Music) can reuse the
        // visual edit verbatim without re-invoking the Edit Planner. This is the post-refinement plan — the one
        // the renderer actually consumed. Encoded with the canonical snake_case encoder (EditPlan/2 wire shape).
        let planJSON: String? = (try? StoryContractCoding.encoder().encode(plan)).flatMap { String(data: $0, encoding: .utf8) }
        let musicRef: String = {
            guard let tid = pendingMusic?.trackId else { return "none" }
            // Imported My Music carries a "mymusic:<uuid>" trackId already; a provider track is a bare id.
            return tid.hasPrefix("mymusic:") ? tid : "provider:\(tid)"
        }()

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
            soundtrackTitle: pendingMusic?.trackTitle,
            versionId: nil,                             // new render: versionId defaults to the row id
            parentVersionId: pendingParentVersionId,    // Explore: the user-selected parent; nil for original
            operationType: pendingOperationType,        // "another_version" for Explore; else "original"
            editPlanJSON: planJSON,
            soundtrackRole: pendingMusic?.soundtrackRole,
            nativeAudioPriority: pendingMusic?.nativeAudioPriority,
            soundPreferenceRaw: story.effectiveSoundPreference.rawValue,
            musicAssetRef: musicRef)
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
        planningSubstatus = nil
        lastFailure = error
        state = .failed(message: error.errorDescription ?? "Creation failed.")
    }

    private func finishCancelled() {
        if let rel = partialRelativePath { cleanup(relative: rel) }
        planningSubstatus = nil
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
