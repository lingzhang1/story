import Foundation
import SwiftData
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

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
    /// The plan could not satisfy the hard directives even after repair (backend `invalid_after_repair`) —
    /// typically too many exclusions / an over-constrained instruction. NOT transient: retrying the same
    /// instruction fails identically, so the UI must ask the user to loosen/adjust the instruction, never
    /// offer a plain Retry.
    case directivesUnsatisfiable(String)
    /// invalid_after_repair with NO hard directives in the request — an honest PLANNER/technical failure, not a
    /// user-instruction conflict. Bounded retry is appropriate (a nondeterministic planner may succeed), and
    /// the copy must NOT blame the user's instruction. Issue 2.
    case invalidPlanOutput(String)
    /// The requested edit is not something the renderer can do (color/filters/effects/reframe/stabilize/
    /// overlays — backend `unsupported_operation`). NOT transient: retrying fails identically, so the UI
    /// explains the limitation and never offers a plain Retry. The selected version is kept unchanged.
    case unsupportedOperation(String)
    /// A targeted revise's plan would change clips the user did NOT ask to change (backend
    /// `preservation_violation`). This is NOT material insufficiency and must NOT carry the "can't fill the
    /// target" duration prefix — the current version was kept unchanged and the user should rephrase or use
    /// Create Another Version. NOT transient; no plain Retry.
    case preservationViolation(String)
    /// Deterministic PREFLIGHT verdict: the Story's material can't reach the target's lower tolerance bound.
    /// Carries the conservative achievable estimate, the requested target, and (when a shorter Story is
    /// possible) a suggested target. This is NOT a technical failure — the UI offers an actionable duration
    /// choice, never a plain Retry, and the planner is NEVER called with the impossible target.
    case insufficientMaterial(achievable: Double, requested: Double, suggested: Double?)

    /// A real usage-limit denial (enforce mode): the backend returned 429 quota_exceeded or 503 quota-store
    /// unavailable. NOT a technical failure and NOT material-infeasible — carries an honest, scope-specific
    /// message and never a plain Retry (retrying hits the same cap). The current version is kept unchanged.
    case quotaDenied(String)

    var errorDescription: String? {
        switch self {
        case .missingPrerequisite(let w): return w
        case .planUnavailable: return "The Edit Planner is temporarily unavailable. Please retry."
        case .planInfeasible(let r): return "This Story's material can't fill the target: \(r)"
        case .planTransport(let r): return "Couldn't reach the Edit Planner: \(r)"
        case .invalidPlan(let r): return "The plan can't be rendered: \(r)"
        case .renderFailed(let r): return "Rendering failed: \(r)"
        case .alreadyCreating: return "A video is already being created for this Story."
        case .directivesUnsatisfiable:
            return "Your instruction couldn't be applied to this footage — it may exclude too much or conflict. Try adjusting it (for example, exclude fewer Moments)."
        case .invalidPlanOutput:
            // No user directives were involved — do NOT blame the instruction. Honest technical message.
            return "I couldn't put together a valid edit this time. This is on my side, not your footage — please try again."
        case .unsupportedOperation(let detail):
            // Prefer the backend's specific capability message; fall back to a clear generic one.
            let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return d.isEmpty
                ? "That kind of edit isn't supported yet — this app can re-cut, re-time, reorder, set transitions and change the soundtrack, but not color, filters or visual effects. Your current version was kept."
                : d
        case .preservationViolation:
            // Phase 2: a distinct message — NOT the duration "can't fill the target" copy. The revise would
            // have changed clips the user did not ask to change, so the original was kept.
            return "This change would have altered clips you didn't ask to change, so your current version was kept. Try naming the Moments to keep or move, or use Create Another Version for a fresh edit."
        case .insufficientMaterial(let achievable, let requested, let suggested):
            let a = Int(achievable.rounded()), req = Int(requested.rounded())
            if let s = suggested {
                return "There's about \(a)s of usable footage — not enough for a \(req)s Story. "
                     + "You can create a shorter \(Int(s.rounded()))s Story, or keep shooting."
            }
            return "There's only about \(a)s of usable footage — not enough for a \(req)s Story yet. "
                 + "Shoot or add a little more and try again."
        case .quotaDenied(let m):
            // Surface the honest, scope-specific quota message built by the networking layer; never a retry.
            return m
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

    /// EditPlan Creative Freedom v2: completion class of the most recent SUCCESSFUL plan.
    /// "complete" = every creative objective satisfied; "partial" = technically valid + playable but some
    /// creative objective could not be applied. nil until a run completes (or when the backend predates v2).
    /// A partial result STILL renders as a success — this only drives an honest, concise disclosure note.
    private(set) var lastCompletion: String?
    /// A one-line, user-facing disclosure of the material unmet creative instructions on a PARTIAL success
    /// (nil for a complete success). Shown as a non-blocking note on the result, never an error.
    private(set) var lastPartialDisclosure: String?

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
    /// True when a Create-Another-Version run was launched from the Customize sheet with directives the user
    /// typed FOR THIS operation — those directives are then folded (mode=revise) instead of a blind explore.
    /// Reset by every entry point so a one-tap Explore never inherits them.
    private var pendingDirectedByCustomize: Bool = false
    /// Diversity diagnostics from the most recent Explore run (nil otherwise) — read for device verification.
    private(set) var lastDiversity: RevisionContextBuilder.Diversity?

    /// Compose the effective revision_context sent to the planner: the per-run base context (Explore/Revise,
    /// or nil for an original create) with the Story's PERSISTED explicit Moment-reference directives + soft
    /// creative direction folded into its `directives` / `soft_direction` keys. These are the ONE-TIME Stage 2
    /// (Customize) instructions, so they are folded ONLY for the ORIGINAL create (`operationType == "original"`):
    /// a deliberate "Create Another Version" uses an explore context and a Revise supplies its own directives, so
    /// neither inherits the one-time creation-time instruction (owner test 12). A retry of the original create is
    /// still "original" and correctly re-applies them. Returns nil only when there is neither a base context nor
    /// any foldable instruction (behavior unchanged — the request is byte-identical to today).
    static func composeRevisionContext(base: JSONValue?, story: StoryModel,
                                       operationType: String = "original",
                                       directedByCustomize: Bool = false) -> JSONValue? {
        // Fold the Story's persisted Creative-Direction instructions when they belong to THIS operation:
        //  - an ORIGINAL create (the one-time Stage 2 instruction the user just entered), or
        //  - a Create-Another-Version launched FROM the Customize sheet with directives typed for this run
        //    (directedByCustomize) — "start from Moment 15, then Moment 2" must be honored, not discarded.
        // NOT folded for a one-tap "Create another version" from the Result (directedByCustomize=false) or a
        // Revise (which supplies its own directives), so a stale creation-time instruction never silently leaks
        // into an unrelated later Explore (owner test 12).
        let usesPersisted = (operationType == "original") || (operationType == "another_version" && directedByCustomize)
        let directives = usesPersisted ? ResolvedDirectives.fromWireJSON(story.creativeDirectivesJSON)?.jsonValue() : nil
        let soft: String? = {
            guard usesPersisted else { return nil }
            let t = (story.creativeDirectionText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }()
        guard directives != nil || soft != nil || base != nil else { return nil }
        // Start from the base object (or an empty revise-less object). An original create with directives only
        // uses mode "revise" so the planner reads the hard requirements as REQUIREMENTS, not an explore nudge.
        var obj: [String: JSONValue]
        if case .object(let o)? = base { obj = o } else { obj = [:] }
        if obj["mode"] == nil { obj["mode"] = .string((directives != nil || soft != nil) ? "revise" : "explore") }
        // NOTE (owner decision 2026-10-22): we DO NOT upgrade explore->revise when directives are present.
        // A directed Create Another Version must stay mode=explore — it keeps Explore's "meaningfully different
        // interpretation" objective and does NOT inherit Revise's base-plan preservation framing or continuity
        // gate. The user's structured directives + soft instruction still ride along (folded below) and are
        // enforced by the planner's directive handling (rendered as requirements) and, under EditPlan v2, by
        // the deterministic reorder + creative-intent scorer — all of which run independently of the mode. This
        // removes the former `explore -> revise` reroute that conflated "honor my pins" with "stay similar to
        // the previous version", violating the Revise vs Create-Another-Version semantics.
        // Fold the Story's persisted creation-time directives ONLY when the base context does not already carry
        // its own (a Revise run supplies its own directives from the user's revise instruction — never clobber).
        if obj["directives"] == nil, let directives { obj["directives"] = directives }
        // Fold the soft creative direction when present and the base has not supplied one.
        if obj["soft_direction"] == nil, let soft { obj["soft_direction"] = .string(soft) }
        // Duration-target PROVENANCE (owner decision 2026-10-18): the NUMERIC target length's source, tracked
        // separately from the editorial mode. A `.custom` editorial mode means the user typed an EXACT length
        // (authoritative -> user_exact); Highlights/Full are explicit EDITORIAL preferences whose numeric
        // duration is AI-recommended (-> ai_recommended), so a timing-only revise may legitimately shorten the
        // whole video below it. Absent an editorial mode we say nothing and the planner defaults to the strict
        // user_exact behavior. Never clobber a source the base context already carries.
        if obj["duration_target_source"] == nil {
            switch (story.editorialMode ?? "").lowercased() {
            case "custom":            obj["duration_target_source"] = .string("user_exact")
            case "highlights", "full": obj["duration_target_source"] = .string("ai_recommended")
            default: break
            }
        }
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

    // Phase 2 scope-classifier readers over the revision_context JSONValue.
    /// True when the context carries at least one populated hard directive (opening/ending/include/exclude/order).
    static func revisionHasHardDirectives(_ ctx: JSONValue?) -> Bool {
        guard case .object(let o)? = ctx, case .object(let d)? = o["directives"] else { return false }
        let keys = ["opening", "ending", "must_include", "exclude", "order_after", "order_adjacent"]
        for k in keys {
            switch d[k] {
            case .some(.string(let s)) where !s.isEmpty: return true
            case .some(.array(let a)) where !a.isEmpty: return true
            default: continue
            }
        }
        return false
    }

    /// The free-text soft creative/pacing direction, or "" when absent.
    static func revisionSoftDirection(_ ctx: JSONValue?) -> String {
        guard case .object(let o)? = ctx, case .string(let s)? = o["soft_direction"] else { return "" }
        return s
    }

    /// True when the context carries the exact base EditPlan (required to edit in place and preserve edits).
    static func revisionHasBasePlan(_ ctx: JSONValue?) -> Bool {
        guard case .object(let o)? = ctx else { return false }
        if case .object(let bp)? = o["base_plan"] { return !bp.isEmpty }
        return false
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
        pendingDirectedByCustomize = false
        beginRun(for: story, outputFormat: outputFormat, targetSeconds: targetSeconds, music: music)
    }

    /// Shared run starter used by both an original create and a deliberate another-version. Does NOT touch the
    /// Explore version-context fields, so the caller controls them (createWithMusic clears, createAnotherVersion sets).
    private func beginRun(for story: StoryModel, outputFormat: String,
                          targetSeconds: Double?, music: MusicSelection?) {
        guard !isCreating else { return }
        // Process-global single-flight: refuse if ANOTHER coordinator (a different view, or the app-level
        // recovery driver) is already running/resuming this Story — two concurrent runs would each persist a
        // GeneratedOutput and duplicate the version. Phase 5. If the claim fails we must NOT silently return
        // into a dead .idle state (the Creating screen would spin on "Getting your moments ready…" forever with
        // no failure surfaced) — surface a recoverable failure so the user gets Try again.
        guard Self.claimActive(story.id, by: self) else {
            state = .failed(message: "A video is already being created for this Story. Please wait a moment and try again.")
            lastFailure = .alreadyCreating
            lastStory = story
            return
        }
        lastStory = story
        lastOutputFormat = outputFormat
        lastTargetSeconds = targetSeconds
        pendingMusic = music
        lastMusic = music
        isCreating = true
        cancelRequested = false
        partialRelativePath = nil
        lastFailure = nil
        Self.setKeepAwake(true)   // don't let the screen sleep mid-plan/render (sleep tears down the connection)
        task = Task { [weak self] in
            await self?.run(story: story, outputFormat: outputFormat, targetSeconds: targetSeconds)
        }
    }

    // Process-global set of Story ids with an ACTIVE run/resume, each mapped to the OWNING coordinator (weak).
    // Guards against duplicate concurrent create/resume for the same Story across coordinator instances
    // (per-view + app recovery driver). Self-healing: a claim whose owner was deallocated, or is no longer
    // actually creating, is STALE and can be stolen — otherwise a coordinator that died without its run()
    // `defer` firing (view dismissed, abnormal task teardown) would leak the id and silently brick every future
    // create for that Story (observed as an eternal "Getting your moments ready…" spinner).
    private final class ActiveClaim { weak var owner: StoryCreationCoordinator? }
    private static var activeStories: [UUID: ActiveClaim] = [:]
    private static func claimActive(_ id: UUID, by owner: StoryCreationCoordinator) -> Bool {
        if let existing = activeStories[id] {
            // A live owner that is genuinely still creating holds the claim; refuse.
            if let o = existing.owner, o !== owner, o.isCreating { return false }
            // Otherwise the claim is stale (owner gone / finished) — steal it.
        }
        let claim = ActiveClaim(); claim.owner = owner
        activeStories[id] = claim
        return true
    }
    private static func releaseActive(_ id: UUID) { activeStories.removeValue(forKey: id) }

    /// Keep the device awake during an active Create/Revise so a screen sleep cannot suspend the app and tear
    /// down the in-flight planning/render connection (observed as NSURLError -1005). Cleared when the run ends.
    private static func setKeepAwake(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
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
                              music: MusicSelection? = nil, directedByCustomize: Bool = false) {
        guard !isCreating else { return }
        // Phase 5: a DELIBERATE new version is a NEW operation. Abandon any stale recoverable pending op for
        // this Story first (the user chose to start over rather than resume), so there is never more than one
        // non-terminal operation -> no duplicate expensive jobs. Then mint a NEW operation_id.
        abandonPendingOperations(storyId: story.id)
        story.planOperationId = nil; story.planJobId = nil
        let recents = story.generatedOutputs.sorted { $0.createdAt > $1.createdAt }
        pendingRevisionContext = RevisionContextBuilder.explore(parent: parent, recents: recents)
        pendingParentVersionId = parent.versionId ?? parent.id
        pendingOperationType = "another_version"
        // When the user reached this via the Customize sheet and typed Creative Direction for THIS operation,
        // fold those directives + soft instruction onto the explore context so the planner strongly pursues
        // them (owner decision 2026-10-22: the operation STAYS mode=explore — a meaningfully-different NEW
        // version — it is NOT rerouted to revise). A one-tap "Create another version" from the Result (no
        // Customize sheet) leaves this false, so it stays a blind explore and inherits nothing.
        pendingDirectedByCustomize = directedByCustomize
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
        abandonPendingOperations(storyId: story.id)
        story.planOperationId = nil; story.planJobId = nil
        pendingRevisionContext = RevisionContextBuilder.revise(base: base, directives: directives,
                                                               softDirection: softDirection)
        pendingParentVersionId = base.versionId ?? base.id
        pendingOperationType = "revision"
        pendingDirectedByCustomize = false
        lastDiversity = nil
        beginRun(for: story, outputFormat: outputFormat, targetSeconds: targetSeconds, music: music)
    }

    // MARK: - Pipeline

    private func run(story: StoryModel, outputFormat: String, targetSeconds: Double?) async {
        defer { isCreating = false; task = nil; Self.setKeepAwake(false); Self.releaseActive(story.id) }

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
                revisionContext: Self.composeRevisionContext(base: pendingRevisionContext, story: story,
                                                             operationType: pendingOperationType,
                                                             directedByCustomize: pendingDirectedByCustomize))
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
        // Phase 2 — revision scope routing. For a REVISE, the amount of planning is decided by the actual
        // change scope, not by requested.requiresMultimodal alone: a targeted change (pacing tweak, single-shot
        // swap, localized edit) runs text-light (no contact sheets) over the exact base plan, preserving
        // unaffected edits; only a BROAD "rebuild" reinterpretation sends the full multimodal payload. A visual
        // ask ("most beautiful shot") stays targeted but DOES carry images. Non-revise ops are unchanged.
        let isRevise = (pendingOperationType == "revision")
        let reviseScope: RevisionScope? = isRevise
            ? RevisionScopeClassifier.classify(
                hasHardDirectives: Self.revisionHasHardDirectives(pendingRevisionContext),
                softDirection: Self.revisionSoftDirection(pendingRevisionContext),
                hasBasePlan: Self.revisionHasBasePlan(pendingRevisionContext))
            : nil
        let wantMultimodal: Bool = {
            let base = requested.requiresMultimodal && StoryMultimodalPlanning.enabled
            guard base, let scope = reviseScope else { return base }
            return scope.sendsSheets   // targeted text-light revise -> no sheets; full/visual -> sheets
        }()
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
            // Phase 4 latency: critique roughly DOUBLES model calls (plan -> critique -> revise). For a
            // deliberate "Create Another Version" (Explore) the default is now ONE multimodal planning call —
            // critique is CONDITIONAL, not automatic — while the ORIGINAL create keeps its existing gated
            // behavior. Images, prior-version context/diversity, mandatory deterministic validation and the
            // worker's bounded repair are all preserved; only the automatic critique pass is dropped for
            // Explore. An explicit opt-in (critiqueExploreEnabled, default false) can still force it.
            let critique: Bool = {
                guard wantMultimodal && StoryMultimodalPlanning.critiqueRevisionEnabled else { return false }
                if pendingOperationType == "another_version" {
                    return StoryMultimodalPlanning.critiqueExploreEnabled   // conditional; default OFF
                }
                // Phase 2: a TARGETED revise (Path B) runs critique OFF by default — it is a bounded change,
                // not a creative re-edit. Only a full re-edit (Path C) keeps the original revise behavior.
                if let scope = reviseScope, scope != .fullReedit { return false }
                return true   // original create / full-reedit revision: unchanged
            }()

            // Submit (or recover an in-flight job_id). Submit is IDEMPOTENT on operation_id, so a transport
            // error (e.g. the screen slept and iOS tore down the connection: NSURLError -1005) is safe to retry
            // with the SAME opId — the server either creates the job or returns the one it already made. We
            // retry a couple of times with a short backoff before giving up, so a brief suspension does not lose
            // a revision whose job is already running server-side.
            let jobId: String
            let reusedExistingJob: Bool
            if let existing = story.planJobId {
                jobId = existing   // recovery: a job was already submitted for this attempt
                reusedExistingJob = true
            } else {
                reusedExistingJob = false
                var submitted: String? = nil
                var lastErr: Error? = nil
                for attempt in 0..<3 {
                    if cancelRequested { return finishCancelled() }
                    do {
                        submitted = try await jobClient.submit(build.request, operationId: opId, owner: "dev",
                                                               approach: requested, sheets: sheets,
                                                               creativeBrief: brief, critiqueRevision: critique)
                        break
                    } catch let EditPlanJobError.transport(underlying) {
                        // A user cancel surfaces as NSURLError -999 — not retryable, it IS a cancellation.
                        if cancelRequested || (underlying as NSError).code == NSURLErrorCancelled {
                            return finishCancelled()
                        }
                        lastErr = underlying
                        MediaEngineV1.beacon("editplan-job: submit transport retry \(attempt + 1) "
                            + "code=\((underlying as NSError).code)")
                        try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1)))  // 0.6s,1.2s
                    }
                }
                guard let jid = submitted else {
                    let reason = lastErr.map { String(describing: $0) } ?? "submit failed"
                    return finishFailed(.planTransport(reason))
                }
                jobId = jid
                story.planJobId = jobId; story.planJobStatus = "queued"; try? context.save()
            }
            // Phase 1: durably record this unfinished operation NOW (job handle known) so a background/suspend/
            // force-quit between here and completion is recoverable WITHOUT re-inference. Reuses opId as the
            // idempotency key; a resume reuses this row's jobId, never a new submit.
            upsertPending(story: story, operationId: opId, jobId: jobId, phase: "planning",
                          jobStatus: story.planJobStatus, fingerprint: Self.fingerprint(
                            for: build.includedMedia.map(\.momentId), story: story))
            MediaEngineV1.beacon("editplan-job: submit req=\(requested.rawValue) sheets=\(sheets.count) "
                + "critique=\(critique) job=\(jobId.prefix(8)) "
                + "rev=\(Self.revisionModeTag(build.request.revisionContext)) "
                + "music=\(pendingMusic?.trackId.prefix(10) ?? "none") op=\(pendingOperationType)")

            // Poll to terminal (bounded backoff; transport errors don't end the poll; cancel stops it).
            // STALE-JOB RECOVERY: a REUSED persisted job_id can be gone server-side (expired / pruned / a
            // different container) -> the GET 404s. Rather than dead-ending on "unexpected status 404", clear
            // the stale handle and submit ONE fresh job for the same operation_id (idempotent), then poll that.
            var activeJobId = jobId
            var final: EditPlanJobState
            do {
                final = try await pollWithStatusUpdates(jobId: activeJobId, story: story)
            } catch EditPlanJobError.badStatus(404) where reusedExistingJob {
                if cancelRequested { return finishCancelled() }
                MediaEngineV1.beacon("editplan-job: reused job \(activeJobId.prefix(8)) is GONE (404) -> resubmitting fresh for op=\(opId.prefix(8))")
                story.planJobId = nil; story.planJobStatus = nil; try? context.save()
                do {
                    let fresh = try await jobClient.submit(build.request, operationId: opId, owner: "dev",
                                                           approach: requested, sheets: sheets,
                                                           creativeBrief: brief, critiqueRevision: critique)
                    activeJobId = fresh
                    story.planJobId = fresh; story.planJobStatus = "queued"; try? context.save()
                    upsertPending(story: story, operationId: opId, jobId: fresh, phase: "planning",
                                  jobStatus: "queued", fingerprint: Self.fingerprint(
                                    for: build.includedMedia.map(\.momentId), story: story))
                    final = try await pollWithStatusUpdates(jobId: activeJobId, story: story)
                } catch let EditPlanJobError.transport(underlying) {
                    if cancelRequested || (underlying as NSError).code == NSURLErrorCancelled { return finishCancelled() }
                    return finishFailed(.planTransport(String(describing: underlying)))
                }
            }

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
                // EditPlan v2: capture the completion class + honest partial-success disclosure (if any).
                // Absent on a pre-v2 backend -> lastCompletion stays nil and nothing is shown (success as before).
                lastCompletion = final.diagnostics?["completion"]?.stringValue
                lastPartialDisclosure = (lastCompletion == "partial")
                    ? final.diagnostics?["partial_disclosure"]?.stringValue
                    : nil
                story.planJobStatus = "completed"; try? context.save()
                // Phase 3: durably persist the completed, validated-on-fetch plan at plan_ready BEFORE
                // rendering, so a force-quit during render resumes from the saved plan (no re-poll/re-inference).
                let planJSON = (try? StoryContractCoding.encoder().encode(p)).flatMap { String(data: $0, encoding: .utf8) }
                upsertPending(story: story, operationId: story.planOperationId ?? "", jobId: activeJobId,
                              phase: "plan_ready", jobStatus: "completed", planJSON: planJSON)
            case .failed:
                // Distinguish the failure classes for honest UX (Phase 3). Issue 2: invalid_after_repair is
                // only a USER directive-conflict when the request actually carried HARD directives
                // (opening/ending/include/exclude/order). Without them it is an honest PLANNER/technical failure
                // (bounded retry), never labeled as "your instruction excluded too much".
                markPendingFailed(story: story, category: final.failure?.rawValue)
                switch final.failure {
                case .materialInfeasible: return finishFailed(.planInfeasible(final.failureDetail ?? "material"))
                case .preservationViolation:
                    // Phase 2: distinct from material-infeasible — do NOT prepend the duration "can't fill the
                    // target" copy. The revise would change clips the user did not ask to change; version kept.
                    return finishFailed(.preservationViolation(final.failureDetail ?? ""))
                case .invalidAfterRepair:
                    let hadDirectives = Self.revisionHasHardDirectives(build.request.revisionContext)
                    if hadDirectives {
                        return finishFailed(.directivesUnsatisfiable(final.failureDetail ?? ""))
                    }
                    // No proven directive conflict -> truthful technical failure (bounded retry allowed).
                    return finishFailed(.invalidPlanOutput(final.failureDetail ?? ""))
                case .unsupportedOperation: return finishFailed(.unsupportedOperation(final.failureDetail ?? ""))
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
        } catch let EditPlanJobError.quotaExceeded(scope, _) {
            // Enforce-mode allowance cap (429). Honest, scope-specific message; NOT a retry.
            if cancelRequested { return finishCancelled() }
            return finishFailed(.quotaDenied(EditPlanJobError.quotaExceeded(scope: scope, retryAfter: nil).errorDescription ?? "You've reached a usage limit."))
        } catch EditPlanJobError.quotaStoreUnavailable {
            // Accounting-store outage (503). Transient — the user may try again shortly.
            if cancelRequested { return finishCancelled() }
            return finishFailed(.quotaDenied(EditPlanJobError.quotaStoreUnavailable(retryAfter: nil).errorDescription ?? "Please try again in a moment."))
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

        // ---- PRE-RENDER RESTORE (Phase 2, owner req): the planner is now CLOUD-AWARE and may SELECT a Moment
        // whose original bytes are not on this device (it was eligible via synced AU + cloud duration). The
        // renderer DOES need the bytes, so restore (R6) the originals for exactly the Moments the plan selected
        // BEFORE validating/resolving — never a bulk download, only the chosen set. A Moment that cannot be
        // restored is reported by validate() below as an unresolved asset (honest failure), never a silent skip.
        let selectedAssetIds = Set(plan.segments.map { $0.assetId.lowercased() })
        let selectedMoments = story.moments.filter { selectedAssetIds.contains($0.id.uuidString.lowercased()) }
        let restoreResult = await MomentResolver.resolveEnsuringLocal(
            moments: selectedMoments, context: context,
            activeOwner: AuthStore.shared?.storyUserId,
            token: { await AuthStore.shared?.validAccessToken() })
        // The render media set = whatever is now LOCAL for the selected Moments (post-restore), unioned with
        // build.includedMedia (Moments that were already local). Keyed by id so there are no duplicates.
        var renderMediaById = Dictionary(build.includedMedia.map { ($0.momentId, $0) }) { a, _ in a }
        for md in restoreResult.media { renderMediaById[md.momentId] = md }
        let renderMedia = Array(renderMediaById.values)
        if !restoreResult.unavailable.isEmpty {
            MediaEngineV1.beacon("pre-render restore: \(restoreResult.unavailable.count) selected Moment(s) could not be restored")
        }

        // ---- validating: deterministic, BEFORE AVFoundation; renderer never runs on an invalid plan ----
        planningSubstatus = nil   // planning is done; drop the backend-status sub-line
        state = .validating
        let resolver = MomentResolver.urlResolver(for: renderMedia)
        if let reason = Self.validate(plan: plan, resolver: resolver, includedMedia: renderMedia) {
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
                renderMedia.first { $0.momentId.uuidString.lowercased() == aid.lowercased() }?.durationSeconds
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
        // Phase 3: mark rendering durably so a force-quit mid-render resumes from the saved plan (not a re-plan).
        markPendingRendering(story: story)
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
        // Phase 3 exactly-once: the output is persisted -> finalize (delete) the pending op so no
        // foreground/reopen can ever re-render this plan into a duplicate version.
        finalizePending(story: story)
        try? context.save()
        state = .completed(output)
    }

    // MARK: - Deterministic validator (pre-AVFoundation)

    /// Poll one job to terminal, mirroring its status into the Story + pending row + planning sub-line. Shared
    /// by the initial poll and the stale-job re-submit recovery.
    private func pollWithStatusUpdates(jobId: String, story: StoryModel) async throws -> EditPlanJobState {
        try await jobClient.pollUntilTerminal(
            jobId: jobId, maxSeconds: 900,
            shouldCancel: { [weak self] in self?.cancelRequested ?? false },
            onState: { [weak self] st in
                story.planJobStatus = st.status.rawValue
                self?.updatePendingStatus(story: story, jobStatus: st.status.rawValue)
                self?.planningSubstatus = {
                    switch st.status {
                    case .queued:           return "Queued for planning…"
                    case .running:          return "Planning your Story…"
                    case .cancelRequested:  return "Cancelling…"
                    default:                return nil
                    }
                }()
            })
    }

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
        // R7-D: enqueue the rendered MP4 for VERIFIED cloud backup (auto-enroll is a no-op unless the active
        // account has Auto Backup ON). Fire-and-forget off the render path; the queue reuses the R4 multipart
        // pipeline and NEVER deletes the local MP4. Stamps cloudMediaId + cloudVerifiedAt once verified.
        GeneratedOutputBackupQueue.sharedAutoEnroll(output)
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

// MARK: - Durable pending-operation persistence + recovery (P0 Phases 1-3)
//
// These methods keep ONE PendingOperationModel row per Story in sync with the pipeline, and drive recovery of
// an operation whose app was backgrounded, suspended, or force-quit. Recovery NEVER submits a second model
// request: it reuses the persisted jobId/operationId and only polls/fetches/renders. Single-flight is enforced
// by `isCreating` and a per-Story non-terminal-row guard, so repeated foreground/reopen events cannot create
// duplicate polling or rendering tasks.
extension StoryCreationCoordinator {

    /// Fetch the (at most one) non-terminal pending operation for a Story.
    private func fetchPending(storyId: UUID) -> PendingOperationModel? {
        let desc = FetchDescriptor<PendingOperationModel>(
            predicate: #Predicate { $0.storyId == storyId })
        let rows = (try? context.fetch(desc)) ?? []
        return rows.first { $0.isRecoverable } ?? rows.first
    }

    /// Read-only: does this Story have an operation that can be RESUMED (not yet saved/abandoned)? The UI uses
    /// this to offer "resume" instead of silently re-creating, and to decide whether reopen should recover.
    func hasRecoverablePendingOperation(storyId: UUID) -> Bool {
        guard let row = fetchPending(storyId: storyId) else { return false }
        return row.isRecoverable && row.jobId != nil
    }

    /// Mark every recoverable pending op for a Story as abandoned (user deliberately started a new operation).
    /// Keeps the rows briefly as abandoned tombstones then they are pruned on next fetch upsert; simplest is to
    /// delete them outright since the new operation supersedes.
    func abandonPendingOperations(storyId: UUID) {
        let desc = FetchDescriptor<PendingOperationModel>(predicate: #Predicate { $0.storyId == storyId })
        for row in ((try? context.fetch(desc)) ?? []) where row.isRecoverable {
            context.delete(row)
        }
        try? context.save()
    }

    /// Create-or-update the durable row for the CURRENT in-memory operation context. Called at each pipeline
    /// transition. Captures everything a fresh coordinator needs to resume without re-inference.
    func upsertPending(story: StoryModel, operationId: String, jobId: String?, phase: String,
                       jobStatus: String? = nil, planJSON: String? = nil, fingerprint: String? = nil) {
        let row: PendingOperationModel
        if let existing = fetchPending(storyId: story.id), existing.operationId == operationId {
            row = existing
        } else {
            row = PendingOperationModel(storyId: story.id, operationId: operationId,
                                        operationType: pendingOperationType)
            context.insert(row)
        }
        row.jobId = jobId ?? row.jobId
        row.operationType = pendingOperationType
        row.baseVersionId = pendingParentVersionId?.uuidString ?? row.baseVersionId
        row.requestFingerprint = fingerprint ?? row.requestFingerprint
        row.phase = phase
        if let jobStatus { row.jobStatus = jobStatus }
        if let planJSON { row.planJSON = planJSON }
        row.musicSelectionRef = Self.musicRef(for: pendingMusic) ?? row.musicSelectionRef
        row.soundtrackRole = pendingMusic?.soundtrackRole ?? row.soundtrackRole
        row.nativeAudioPriority = pendingMusic?.nativeAudioPriority ?? row.nativeAudioPriority
        row.outputFormat = lastOutputFormat
        row.targetSeconds = lastTargetSeconds
        row.updatedAt = .now
        try? context.save()
    }

    private func updatePendingStatus(story: StoryModel, jobStatus: String) {
        guard let row = fetchPending(storyId: story.id), row.isRecoverable else { return }
        row.jobStatus = jobStatus
        if jobStatus == "running" && row.phase == "submitted" { row.phase = "planning" }
        row.updatedAt = .now
        try? context.save()
    }

    private func markPendingRendering(story: StoryModel) {
        guard let row = fetchPending(storyId: story.id), row.isRecoverable else { return }
        row.phase = "rendering"; row.updatedAt = .now
        try? context.save()
    }

    private func markPendingFailed(story: StoryModel, category: String?) {
        guard let row = fetchPending(storyId: story.id) else { return }
        row.failureCategory = category; row.jobStatus = "failed"
        // Mark the op TERMINAL (abandoned) so the app-level recovery does NOT re-resume this failed job on
        // every foreground (that caused an infinite resume->failed loop, and once planJobId was cleared it
        // re-submitted a fresh explore job, losing the directive). The user retries via Create another version,
        // which mints a NEW operation. A backend enqueue_lost / provider failure is surfaced once, not looped.
        row.phase = "abandoned"
        row.updatedAt = .now
        try? context.save()
    }

    /// Exactly-once finalize: the output was persisted, so the operation is logically SAVED. Delete every
    /// pending row for this Story so no later foreground/reopen can re-render this plan into a duplicate version.
    private func finalizePending(story: StoryModel) {
        let sid = story.id
        let desc = FetchDescriptor<PendingOperationModel>(predicate: #Predicate { $0.storyId == sid })
        for row in ((try? context.fetch(desc)) ?? []) {
            context.delete(row)
        }
        try? context.save()
    }

    /// Stable string handle for a resolved music selection (so a resumed render can re-resolve the same track).
    static func musicRef(for music: MusicSelection?) -> String? {
        guard let tid = music?.trackId else { return nil }
        return tid.hasPrefix("mymusic:") ? tid : "provider:\(tid)"
    }

    /// RESUME an unfinished operation for a Story after foreground/reopen/relaunch. Reuses the persisted
    /// operationId + jobId — NEVER a new submit. `music` is an optionally pre-resolved selection (the view
    /// re-resolves the persisted track where feasible); when nil the resume renders no-music rather than block.
    ///
    /// - queued/running  -> resume polling the existing job, then validate + render + persist.
    /// - completed/plan_ready -> fetch/use the saved plan, render + persist (no re-poll if planJSON saved).
    /// - failed          -> surface the failure (no new inference).
    /// - expired         -> surface + offer a fresh attempt.
    ///
    /// Single-flight: refuses if a creation is already in flight for this coordinator (duplicate-task guard).
    @discardableResult
    func resumePendingOperation(for story: StoryModel, music: MusicSelection? = nil) -> Bool {
        guard !isCreating else { return false }                 // a run already owns this coordinator
        guard let row = fetchPending(storyId: story.id), row.isRecoverable, let jobId = row.jobId else {
            return false
        }
        guard Self.claimActive(story.id, by: self) else { return false }  // another coordinator already resuming/creating
        // Rehydrate the in-memory operation context from the durable row so persist() keeps lineage/music/type.
        lastStory = story
        lastOutputFormat = row.outputFormat ?? "vertical"
        lastTargetSeconds = row.targetSeconds
        pendingMusic = music
        lastMusic = music
        pendingOperationType = row.operationType
        pendingParentVersionId = row.baseVersionId.flatMap(UUID.init(uuidString:))
        pendingRevisionContext = Self.rebuildRevisionContext(for: story, row: row)
        story.planOperationId = row.operationId
        story.planJobId = jobId
        isCreating = true
        cancelRequested = false
        Self.setKeepAwake(true)
        MediaEngineV1.beacon("editplan-recover: resume op=\(row.operationType) phase=\(row.phase) "
            + "job=\(jobId.prefix(8)) music=\(music == nil ? "none" : "set")")
        task = Task { [weak self] in
            await self?.resumeRun(story: story, row: row)
        }
        return true
    }

    /// Drive a resumed operation to completion. For plan_ready with a saved plan we SKIP planning entirely and
    /// render from the saved plan; otherwise we re-enter the normal run (which reuses jobId -> no re-inference).
    private func resumeRun(story: StoryModel, row: PendingOperationModel) async {
        defer { isCreating = false; task = nil; Self.setKeepAwake(false); Self.releaseActive(story.id) }
        // Fast render-resume: a saved, completed plan -> render directly (Phase 3), no poll, no re-inference.
        if row.phase == "plan_ready" || row.phase == "rendering", let json = row.planJSON,
           let data = json.data(using: .utf8),
           let plan = try? StoryContractCoding.decoder().decode(EditPlanV2.self, from: data) {
            await renderResumedPlan(plan, story: story)
            return
        }
        // Otherwise re-enter the normal pipeline: it rebuilds the request, sees story.planJobId set, and
        // RESUMES POLLING the existing job (never re-submits). Completion -> validate -> render -> persist.
        await run(story: story, outputFormat: lastOutputFormat, targetSeconds: lastTargetSeconds)
    }

    /// Render a recovered plan through the same validate+render+persist tail as a fresh run, so lineage,
    /// soundtrack, parent version, operationType and exactly-once persistence are identical.
    private func renderResumedPlan(_ plan0: EditPlanV2, story: StoryModel) async {
        state = .preparing
        let build: EditPlanRequestBuilder.Build
        do {
            build = try EditPlanRequestBuilder.build(
                story: story, context: context, targetSeconds: lastTargetSeconds, outputFormat: lastOutputFormat,
                musicPlan: nil, musicAssetId: nil, musicAnalysis: nil,
                revisionContext: nil)
        }
        catch { return finishFailed(.planUnavailable) }

        let plan = plan0
        // PRE-RENDER RESTORE (same as the fresh path): a recovered plan may reference a cloud-only Moment the
        // cloud-aware planner selected. Restore the selected Moments' originals via R6 before resolving.
        let selectedAssetIds = Set(plan.segments.map { $0.assetId.lowercased() })
        let selectedMoments = story.moments.filter { selectedAssetIds.contains($0.id.uuidString.lowercased()) }
        let restoreResult = await MomentResolver.resolveEnsuringLocal(
            moments: selectedMoments, context: context,
            activeOwner: AuthStore.shared?.storyUserId,
            token: { await AuthStore.shared?.validAccessToken() })
        var renderMediaById = Dictionary(build.includedMedia.map { ($0.momentId, $0) }) { a, _ in a }
        for md in restoreResult.media { renderMediaById[md.momentId] = md }
        let renderMedia = Array(renderMediaById.values)

        state = .validating
        let resolver = MomentResolver.urlResolver(for: renderMedia)
        if let reason = Self.validate(plan: plan, resolver: resolver, includedMedia: renderMedia) {
            return finishFailed(.invalidPlan(reason))
        }
        state = .rendering(progress: 0)
        markPendingRendering(story: story)
        let effectiveSoundtrack = pendingMusic?.soundtrackURL ?? soundtrackURL
        let inputs = MediaEngineInputs(
            plan: plan, resolveMomentURL: resolver,
            soundtrackURL: effectiveSoundtrack,
            musicAnalysis: pendingMusic?.analysis ?? musicAnalysis,
            soundtrackRole: pendingMusic?.soundtrackRole ?? "supportive",
            nativeAudioPriority: pendingMusic?.nativeAudioPriority ?? "selective")
        let result: RenderResult
        do {
            result = try await renderer.render(inputs,
                progress: { [weak self] p in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .rendering = self.state { self.state = .rendering(progress: Double(p)) }
                    } },
                shouldCancel: { [weak self] in self?.cancelRequested ?? false })
        } catch {
            if cancelRequested { return finishCancelled() }
            return finishFailed(.renderFailed(String(describing: error)))
        }
        if cancelRequested { cleanup(relative: result.relativePath); return finishCancelled() }

        if pendingOperationType == "another_version", let parentId = pendingParentVersionId,
           let parent = story.generatedOutputs.first(where: { ($0.versionId ?? $0.id) == parentId }) {
            lastDiversity = RevisionContextBuilder.diversity(parent: parent, newPlan: plan)
        }
        let output = persist(result: result, plan: plan, story: story, build: build)
        story.planOperationId = nil; story.planJobId = nil; story.planJobStatus = "completed"
        finalizePending(story: story)
        try? context.save()
        state = .completed(output)
    }

    /// Reconstruct the per-run revision context for a resumed Explore/revision operation from the live Story +
    /// durable row. Explore rebuilds from the recorded parent; original/revision carry no reconstructable soft
    /// base here (revision's exact base-plan directives are not reconstructable post-relaunch -> resume renders
    /// the ALREADY-PLANNED result, which is what recovery needs, not a re-plan).
    private static func rebuildRevisionContext(for story: StoryModel, row: PendingOperationModel) -> JSONValue? {
        guard row.operationType == "another_version", let pid = row.baseVersionId.flatMap(UUID.init(uuidString:)),
              let parent = story.generatedOutputs.first(where: { ($0.versionId ?? $0.id) == pid }) else { return nil }
        let recents = story.generatedOutputs.sorted { $0.createdAt > $1.createdAt }
        return RevisionContextBuilder.explore(parent: parent, recents: recents)
    }
}
