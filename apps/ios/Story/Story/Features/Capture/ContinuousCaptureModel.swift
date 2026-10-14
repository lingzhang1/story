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

    weak var controller: ContinuousCameraController?

    private var context: ModelContext?
    private var captureContext: CaptureContext?
    private let captureSessionId = UUID()

    // Dedup + serialization state.
    private var inFlightURLs = Set<String>()      // temp URLs currently being persisted
    private var persistedURLs = Set<String>()     // temp URLs already persisted (double-callback guard)

    func configure(context: ModelContext, captureContext: CaptureContext) {
        self.context = context
        self.captureContext = captureContext
    }

    func toggleRecording() { controller?.toggleRecording() }

    /// AI Ideas hook — fully wired in Increment 4. No-op now so the camera is
    /// usable without AI and tapping it never blocks recording.
    func getAIShotIdeaTapped() { /* Increment 4 */ }

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
