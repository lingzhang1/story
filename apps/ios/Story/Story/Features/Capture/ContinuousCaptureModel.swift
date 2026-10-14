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
        case scanning                 // collecting frames + Director in flight
        case ideas                    // one or more shot ideas available
        case failed(String)           // AI failed/throttled — recording still works
    }
    @Published var aiState: AIState = .off
    @Published var ideaIndex = 0                       // which cached idea is shown
    private(set) var ideas: [DirectorDecisionDTO] = []
    private(set) var ideasOutput: DirectorOutputDTO?   // for concept/shot lookups

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
        ideas = []; ideasOutput = nil; ideaIndex = 0
        aiState = .scanning
        guard let controller else { aiState = .failed("Camera unavailable."); return }
        controller.startScan { [weak self] frames in
            Task { @MainActor in await self?.runDirector(frames: frames) }
        }
    }

    private func runDirector(frames: [UIImage]) async {
        guard let captureContext else { aiState = .off; return }
        guard !frames.isEmpty else { aiState = .failed("Couldn't read the scene. Try again."); return }
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
            let candidates = out.candidates.isEmpty ? [out.decision] : out.candidates
            // Only actionable shot ideas belong in the camera overlay.
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
            // AI failure / quota exhaustion must NOT disable recording — just report.
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
        case .recordingFinished(let url, let duration):
            isRecording = false
            persist(tempURL: url, duration: duration)
        case .captureFailed(let message):
            isRecording = false
            errorMessage = message
            showError = true
        case .interrupted:
            isRecording = false
        }
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
