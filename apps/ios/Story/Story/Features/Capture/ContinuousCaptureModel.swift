import SwiftUI
import SwiftData
import UIKit

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
    enum AIState: Equatable {
        case off                      // no AI UI
        case scanning                 // collecting scene frames from the live session
        case thinking                 // frames collected; Director is generating an idea
        case ideas                    // one or more shot ideas available
        case failed(String)           // AI failed/throttled — recording still works
    }
    @Published var aiState: AIState = .off
    @Published var ideaIndex = 0                       // which cached idea is shown
    @Published var recordingElapsed: TimeInterval = 0  // live REC timer (Phase 2)
    private(set) var ideas: [DirectorDecisionDTO] = []
    private(set) var ideasOutput: DirectorOutputDTO?   // for concept/shot lookups
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    // Monotonic token: every scan/record transition bumps it so a stale Director response
    // from a cancelled or superseded scan can NEVER reopen the overlay (Phase 2 requirement:
    // "prevent stale AI responses from reopening overlays during recording").
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

    func configure(context: ModelContext, captureContext: CaptureContext) {
        self.context = context
        self.captureContext = captureContext
    }

    func toggleRecording() { controller?.toggleRecording() }

    /// AI Ideas — user-initiated. Starts a scene scan on the LIVE session (does not
    /// stop any in-progress recording), then runs the Director. Scene-only intent for
    /// standalone (no stale Story leak), Story intent + guide for .story.
    func getAIShotIdeaTapped() {
        guard aiState == .off || isFailed else { return }
        startScan()
    }

    /// "Scan again for another idea" — fresh scene evidence, new Director call.
    func scanAgain() { startScan() }

    /// "Next idea" — advance through the already-available cached ideas (no new call).
    func nextIdea() {
        guard !ideas.isEmpty else { return }
        ideaIndex = (ideaIndex + 1) % ideas.count
    }

    /// Dismiss the AI overlay entirely; the camera stays ready to record.
    func dismissIdeas() {
        aiGeneration &+= 1               // invalidate any in-flight scan/Director response
        controller?.cancelScan()
        aiState = .off
        ideas = []
        ideasOutput = nil
        ideaIndex = 0
    }

    /// "Let's shoot" — close the idea overlay and return to a ready-to-record camera.
    func letsShoot() { dismissIdeas() }

    private var isFailed: Bool { if case .failed = aiState { return true } else { return false } }

    // MARK: - Current idea accessors (for the overlay)

    var currentIdeaTitle: String {
        ideasOutput?.concept.title ?? "Shot idea"
    }
    var currentIdeaBody: String {
        guard ideaIndex < ideas.count else { return "" }
        return ideas[ideaIndex].shot?.instruction ?? ideasOutput?.concept.summary ?? ""
    }
    var currentIdeaSeconds: Int? {
        guard ideaIndex < ideas.count else { return nil }
        if let d = ideas[ideaIndex].shot?.targetDurationSeconds, d > 0 { return Int(d.rounded()) }
        return nil
    }
    var ideaCount: Int { ideas.count }

    private func startScan() {
        aiGeneration &+= 1
        let gen = aiGeneration
        ideas = []; ideasOutput = nil; ideaIndex = 0
        aiState = .scanning
        guard let controller else { aiState = .failed("Camera unavailable."); return }
        controller.startScan { [weak self] frames in
            Task { @MainActor in
                guard let self, gen == self.aiGeneration else { return }  // superseded/cancelled
                // Frames are in; the Director is now thinking.
                self.aiState = .thinking
                await self.runDirector(frames: frames, generation: gen)
            }
        }
    }

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
            // Phase 2: starting a recording SUSPENDS any pending AI work. Bump the generation
            // so a late Director response cannot reopen the overlay over a live recording, and
            // collapse the overlay to the minimized REC state.
            aiGeneration &+= 1
            controller?.cancelScan()
            if aiState != .off { aiState = .off; ideas = []; ideasOutput = nil; ideaIndex = 0 }
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
