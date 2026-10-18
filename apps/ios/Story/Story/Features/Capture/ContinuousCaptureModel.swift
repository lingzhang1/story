import SwiftUI
import SwiftData
import UIKit

/// Pure, device-independent formatting for zoom-preset labels (unit-testable). ".5" for sub-1×,
/// integer for whole values ("1", "2"), one decimal otherwise ("1.5"). Kept free of AVFoundation so
/// it can be tested without a camera device (the preset DERIVATION needs real hardware and is a
/// device-acceptance concern, not a unit test).
enum CameraZoomFormat {
    static func label(_ z: Double) -> String {
        if z < 1 { return String(format: ".%d", Int((z * 10).rounded())) }
        if z == z.rounded() { return "\(Int(z))" }
        return String(format: "%.1f", z)
    }
}

// ContinuousCaptureModel — the @MainActor brain behind ContinuousCaptureView.
//
// Owns the single CaptureContext-driven persistence path (identical rules to
// SceneScanFlowView.persistMoment, reused here for continuous capture) plus the
// integrity guarantees that keep five fast recordings honest:
//
//   • One Moment per finished clip. Each adopt→create→enqueue runs on the main
//     actor; a `savingTokens` set + per-URL dedup guarantees a given temp URL is
//     persisted at most once even if a delegate callback is delivered twice.
//   • Saves are SERIALIZED through a simple in-order queue so a second recording
//     finishing fast cannot interleave with the first save and corrupt ordering
//     or produce duplicate links. AU + Photos copy are fired async AFTER the
//     Moment row is committed and never block the next recording.
//   • The recent-Moment thumbnail updates ONLY after a successful persist — never
//     on a failed or in-flight clip (no false success).
//   • A failed clip surfaces an honest alert and the temp file is cleaned up.
@MainActor
final class ContinuousCaptureModel: ObservableObject, ContinuousCameraControllerDelegate {
    @Published var isRecording = false
    @Published var isSaving = false
    @Published var showSaved = false
    @Published var recentThumbnail: UIImage?
    @Published var showError = false
    @Published var errorMessage: String?

    // AI Ideas (optional, user-initiated). The red record button stays live in
    // every AI state — scanning and inference NEVER block recording.
    //
    // Phase 1: generated ideas live in SESSION state (ideas/ideasOutput/ideaIndex) and SURVIVE
    // record/stop cycles. The on-screen presentation is separate: `aiState` drives the overlay,
    // and `ideasCollapsed` hides the full card (e.g. while recording) WITHOUT discarding the ideas,
    // so a small chip can reopen them with NO new inference.
    enum AIState: Equatable {
        case off                      // no AI UI, no ideas held
        case scanning                 // collecting scene frames from the live session
        case thinking                 // frames collected; Director is generating an idea
        case ideas                    // one or more shot ideas available (and shown)
        case failed(String)           // AI failed/throttled — recording still works
    }
    @Published var aiState: AIState = .off
    @Published var ideaIndex = 0                       // which cached idea is shown (preserved)
    @Published var ideasCollapsed = false              // full card hidden but ideas retained (chip reopens)
    @Published var recordingElapsed: TimeInterval = 0  // live REC timer (Phase 2)
    @Published var scanProgress: Double = 0            // 0→1 across the scan window (determinate bar)

    // Camera controls (Package B Increment 1) — thin passthroughs to the shared controller. The
    // controller owns all device config (serialized + lock-guarded); the model only mirrors UI state.
    @Published var torchOn = false                     // reflects the torch button toggle
    @Published var currentUserZoom: Double = 1.0       // the active preset highlighted in the UI
    /// Device-supported zoom presets (e.g. [0.5, 1, 2]) read from the real hardware. [1.0] until ready.
    var zoomPresets: [Double] { controller?.zoomPresets ?? [1.0] }
    /// Whether this device has a torch (UI hides the control when false).
    var hasTorch: Bool { controller?.hasTorch ?? false }

    /// Tap-to-focus at a view point (from the tap gesture). Also shows a brief focus reticle (UI state).
    func focusAndExpose(atViewPoint point: CGPoint) {
        controller?.focusAndExpose(atViewPoint: point)
    }
    /// Snap to a zoom preset (preset button).
    func setZoomPreset(_ userZoom: Double) {
        currentUserZoom = userZoom
        controller?.setUserZoom(userZoom)
    }
    /// Continuous pinch zoom. `base` is captured at gesture start from the controller.
    func pinchZoom(scale: CGFloat, base: CGFloat) {
        controller?.applyPinchZoom(scale: scale, base: base)
    }
    /// The controller's current raw zoom factor (gesture start reads this).
    var currentRawZoom: CGFloat { controller?.currentZoomFactor ?? 1.0 }
    /// Toggle the torch.
    func toggleTorch() {
        torchOn.toggle()
        controller?.setTorch(torchOn)
    }

    private(set) var ideas: [DirectorDecisionDTO] = []
    private(set) var ideasOutput: DirectorOutputDTO?   // for concept/shot lookups
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    // Monotonic token: every scan/record transition bumps it so a stale Director response
    // from a cancelled or superseded scan can NEVER replace newer ideas or reopen an overlay.
    private var aiGeneration = 0

    weak var controller: ContinuousCameraController?

    private var context: ModelContext?
    private var captureContext: CaptureContext?
    private let captureSessionId = UUID()
    private let sceneService = SceneUnderstandingService()
    private let directorService = StoryDirectorService()

    // Dedup + serialization state.
    private var inFlightURLs = Set<String>()      // temp URLs currently being persisted
    private var persistedURLs = Set<String>()     // temp URLs already persisted (double-callback guard)

    // Guide/Idea seed: the specific opportunity the user tapped Shoot/Reshoot on (Story Guide
    // possibility or Story Idea Show-me). When present, the camera shows THIS idea IMMEDIATELY on
    // open — NO network call, NO scan — because the possibility already carries its own label +
    // purpose text (loaded on the Story screen). The idea card renders straight from this text, so
    // Reshoot lands on the continuous camera already showing that exact guide idea with zero latency.
    // nil for plain "Shoot a moment" (no seed; the pill shows "Get an AI shot idea").
    private var seededIdea: SeededIdea?
    private var seedConsumed = false

    /// An instant, network-free idea rendered directly from the tapped guide possibility / Story Idea.
    struct SeededIdea: Equatable {
        let title: String        // the possibility/idea label — the card headline
        let body: String         // its semantic purpose — the card instruction line
        let seconds: Int?        // optional target duration (seeds carry none today)
    }

    func configure(context: ModelContext, captureContext: CaptureContext,
                   seedOpportunity: SelectedOpportunityDTO? = nil) {
        self.context = context
        self.captureContext = captureContext
        if let opp = seedOpportunity, !seedConsumed {
            // Build the idea card from text we ALREADY have — no Director call, no spinner.
            let title = opp.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (opp.purpose ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { self.seededIdea = SeededIdea(title: title, body: body, seconds: nil) }
        }
    }

    /// Show the seeded guide idea as the DEFAULT in-camera idea, instantly, once, on first appear.
    /// Pure local state change — no network, so the card appears the moment Reshoot opens the camera.
    func seedGuideIdeaIfNeeded() {
        guard !seedConsumed, seededIdea != nil else { return }
        seedConsumed = true
        aiState = .ideas
    }

    func toggleRecording() { controller?.toggleRecording() }

    /// Whether we hold a shot idea that can be reopened without a new scan (drives the chip):
    /// either live cached Director ideas OR an instant seeded guide idea.
    var hasCachedIdeas: Bool { !ideas.isEmpty || seededIdea != nil }

    /// AI Ideas — user-initiated. If ideas are already cached and merely collapsed, REOPEN them
    /// (no inference). Otherwise start a fresh scene scan on the LIVE session (does not stop any
    /// in-progress recording), then run the Director.
    func getAIShotIdeaTapped() {
        if hasCachedIdeas {
            reopenIdeas()
            return
        }
        guard aiState == .off || isFailed else { return }
        startScan()
    }

    /// Reopen the cached ideas overlay WITHOUT running new inference (Phase 1: the upper-right chip).
    func reopenIdeas() {
        guard hasCachedIdeas else { return }
        ideasCollapsed = false
        aiState = .ideas
    }

    /// "Rescan" — EXPLICIT fresh scene evidence + new Director call. The only path that replaces
    /// cached ideas, so old ideas are never silently presented as a newly-scanned scene (Phase 1).
    func scanAgain() { startScan() }

    /// "Next idea" — advance through the already-available cached ideas (no new call).
    func nextIdea() {
        guard !ideas.isEmpty else { return }
        ideaIndex = (ideaIndex + 1) % ideas.count
    }

    /// Dismiss the overlay. If ideas are cached, this COLLAPSES (keeps them for the chip); if a
    /// scan/think is in flight it cancels and clears. Never discards cached ideas.
    func dismissIdeas() {
        if hasCachedIdeas {
            ideasCollapsed = true
            aiState = .off
            return
        }
        aiGeneration &+= 1               // invalidate any in-flight scan/Director response
        controller?.cancelScan()
        aiState = .off
    }

    /// Cancel an in-flight AI request (scanning/thinking) explicitly — clears nothing cached.
    func cancelAIRequest() {
        aiGeneration &+= 1
        controller?.cancelScan()
        aiState = hasCachedIdeas ? .off : .off
        if hasCachedIdeas { ideasCollapsed = true }
    }

    private var isFailed: Bool { if case .failed = aiState { return true } else { return false } }

    // MARK: - Current idea accessors (for the overlay)
    //
    // A SEEDED idea (from a Guide Reshoot / Story Idea) renders instantly from local text and takes
    // precedence until the user Rescans — then live Director `ideas` replace it (seed cleared).

    var currentIdeaTitle: String {
        if let s = seededIdea, ideas.isEmpty { return s.title }
        return ideasOutput?.concept.title ?? "Shot idea"
    }
    var currentIdeaBody: String {
        if let s = seededIdea, ideas.isEmpty { return s.body }
        guard ideaIndex < ideas.count else { return "" }
        return ideas[ideaIndex].shot?.instruction ?? ideasOutput?.concept.summary ?? ""
    }
    var currentIdeaSeconds: Int? {
        if seededIdea != nil, ideas.isEmpty { return seededIdea?.seconds }
        guard ideaIndex < ideas.count else { return nil }
        if let d = ideas[ideaIndex].shot?.targetDurationSeconds, d > 0 { return Int(d.rounded()) }
        return nil
    }
    var ideaCount: Int { ideas.count }

    /// A compact one-line reminder of the active idea, for the minimized recording state.
    var currentIdeaReminder: String? {
        if let s = seededIdea, ideas.isEmpty { return s.title.isEmpty ? nil : s.title }
        guard hasCachedIdeas else { return nil }
        let t = currentIdeaTitle
        return t.isEmpty ? nil : t
    }

    private func startScan() {
        aiGeneration &+= 1
        let gen = aiGeneration
        ideas = []; ideasOutput = nil; ideaIndex = 0
        seededIdea = nil            // Rescan replaces the seeded guide idea with live, scene-specific ideas
        scanProgress = 0
        aiState = .scanning
        guard let controller else { aiState = .failed("Camera unavailable."); return }
        controller.startScan(progress: { [weak self] p in
            Task { @MainActor in
                guard let self, gen == self.aiGeneration, self.aiState == .scanning else { return }
                self.scanProgress = p
            }
        }, completion: { [weak self] frames in
            Task { @MainActor in
                guard let self, gen == self.aiGeneration else { return }  // superseded/cancelled
                // Frames are in; the Director is now thinking.
                self.aiState = .thinking
                await self.runDirector(frames: frames, generation: gen)
            }
        })
    }

    /// "Done" — end the scan early and use the frames collected so far (proactive end, Phase 3).
    func finishScanNow() {
        guard aiState == .scanning else { return }
        controller?.finishScanNow()
    }

    /// The scan window length (seconds), for labeling the progress UI.
    var scanWindowSeconds: Double { controller?.scanWindowSeconds ?? 4.0 }

    private func runDirector(frames: [UIImage], generation gen: Int) async {
        guard gen == aiGeneration else { return }                 // stale — drop silently
        guard let captureContext else { aiState = .off; return }
        guard !frames.isEmpty else {
            if gen == aiGeneration { aiState = .failed("Couldn't read the scene. Try again.") }
            return
        }
        do {
            let selected = SceneFrameProcessor.select(from: frames, max: 5)
            let su = try await sceneService.analyze(
                frames: selected, captureSessionId: captureSessionId,
                mode: "shoot_moment", storyId: captureContext.associatedStory?.id)
            let out = try await directorService.initialize(
                creativeIntent: captureContext.directorIntent(),
                sceneUnderstanding: su,
                targetDurationSeconds: captureContext.targetDurationSeconds,
                selectedOpportunity: nil)
            // The user may have started recording or dismissed while we were thinking — if so,
            // this response is stale and must NOT reopen an overlay (Phase 2).
            guard gen == aiGeneration else { return }
            let candidates = out.candidates.isEmpty ? [out.decision] : out.candidates
            let shots = candidates.filter { $0.action == .captureShot || $0.action == .retryShot }
            if shots.isEmpty {
                aiState = .failed("No strong shot here. Try moving or scanning again.")
            } else {
                ideas = shots
                ideasOutput = out
                ideaIndex = 0
                ideasCollapsed = false
                aiState = .ideas
            }
        } catch {
            // AI failure / quota exhaustion must NOT disable recording — just report, if still current.
            guard gen == aiGeneration else { return }
            aiState = .failed("AI ideas are unavailable right now.")
        }
    }

    // MARK: - ContinuousCameraControllerDelegate

    nonisolated func captureEvent(_ event: ContinuousCaptureEvent) {
        Task { @MainActor in self.handle(event) }
    }

    private func handle(_ event: ContinuousCaptureEvent) {
        switch event {
        case .ready:
            break
        case .recordingStarted:
            isRecording = true
            // Phase 1+2: starting a recording cancels any IN-FLIGHT scan/inference (bump the
            // generation so a late Director response can't replace newer ideas or reopen the
            // overlay), and COLLAPSES the full idea card — but PRESERVES cached ideas + the
            // selected index so they can be reopened after recording with no new scan.
            aiGeneration &+= 1
            controller?.cancelScan()
            if aiState == .scanning || aiState == .thinking {
                // No cached result from this in-flight request — just hide the request UI.
                aiState = hasCachedIdeas ? .off : .off
                if hasCachedIdeas { ideasCollapsed = true }
            } else if aiState == .ideas {
                ideasCollapsed = true          // keep ideas, hide the card
                aiState = .off
            } else {
                aiState = .off
            }
            startRecordingTimer()
        case .recordingFinished(let url, let duration):
            isRecording = false
            stopRecordingTimer()
            persist(tempURL: url, duration: duration)
        case .captureFailed(let message):
            isRecording = false
            stopRecordingTimer()
            errorMessage = message
            showError = true
        case .interrupted:
            isRecording = false
            stopRecordingTimer()
        }
    }

    // MARK: - Recording timer (live REC elapsed, Phase 2)

    private func startRecordingTimer() {
        recordingStartedAt = Date()
        recordingElapsed = 0
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartedAt else { return }
                self.recordingElapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
        recordingElapsed = 0
    }

    /// mm:ss elapsed string for the REC indicator.
    var recordingTimeString: String {
        let total = Int(recordingElapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Persistence (ONE path, serialized, deduped)

    private func persist(tempURL: URL, duration: Double) {
        let key = tempURL.path
        // Double-callback / rapid-tap dedup: never persist the same temp URL twice.
        guard !persistedURLs.contains(key), !inFlightURLs.contains(key) else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        guard let context, let captureContext else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        inFlightURLs.insert(key)
        isSaving = true

        let useCases = StoryUseCases(repository: StoryRepository(context: context))
        do {
            // Finalize media on disk FIRST — if adoption fails, nothing is claimed.
            let relativePath = try MediaStore.shared.adoptCapturedFile(tempURL: tempURL)

            // ONE persistence path; context picks the association (Increment 1 rules).
            let moment: MomentModel
            if let story = captureContext.associatedStory {
                moment = try useCases.shootMoment(for: story, relativePath: relativePath,
                                                  durationSeconds: duration)
            } else {
                moment = try useCases.shootStandaloneMoment(relativePath: relativePath,
                                                            durationSeconds: duration)
            }

            persistedURLs.insert(key)
            inFlightURLs.remove(key)

            // AU enqueue — AFTER the Moment is committed; never blocks the next
            // recording. Contextless here (no requested shot/beat in continuous mode).
            let auQueue = AssetUnderstandingQueue(context: context)
            auQueue.enqueue(momentId: moment.id, relativeMediaPath: relativePath,
                            sourceCaptureId: captureSessionId, captureContext: nil)
            Task.detached { await auQueue.drain() }

            // Add-only Photos copy — fire-and-forget, degrades silently.
            let adoptedURL = MediaStore.shared.absoluteURL(for: relativePath)
            PhotosSaver.saveVideoCopy(at: adoptedURL) { _ in }

            // Subtle save feedback + recent thumbnail AFTER success only.
            isSaving = !inFlightURLs.isEmpty
            flashSaved()
            Task { await updateRecentThumbnail(for: moment) }

        } catch {
            inFlightURLs.remove(key)
            isSaving = !inFlightURLs.isEmpty
            try? FileManager.default.removeItem(at: tempURL)
            errorMessage = "That clip couldn't be saved. Please try again."
            showError = true
        }
    }

    private func flashSaved() {
        withAnimation { showSaved = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run { withAnimation { self.showSaved = false } }
        }
    }

    private func updateRecentThumbnail(for moment: MomentModel) async {
        if let img = await MomentThumbnailCache.shared.thumbnail(for: moment) {
            await MainActor.run { self.recentThumbnail = img }
        }
    }
}
