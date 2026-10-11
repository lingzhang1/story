import SwiftUI
import SwiftData
import AVKit

// StoryResultView — R-c Batch B, production Result screen (frozen Figma Screen11Result).
//
// Takes a persisted GeneratedOutputModel and plays the REAL rendered MP4 (resolved via RenderOutputStore),
// offers Save to Photos (PhotosSaver), Share to Files (system share sheet), return Home, and — when the output
// is stale — a Re-create affordance that KEEPS the existing output. Music is presented HONESTLY: this milestone
// renders without music, so copy says "Created without music" and "Change music" is a disabled future feature.
// NEVER a fake track name, NEVER raw EditPlan / model / backend diagnostics. Playback is device-gated; this file
// is parse-checked only.

// MARK: - Pure, testable decision helpers (no SwiftUI, no AVFoundation)

/// How the create/result flow should OPEN for a Story: play an existing good output, or create a new one.
/// Pure so StoryResultFlowTests can assert it without a host app.
enum ReopenDecision: Equatable {
    case showResult(outputId: UUID)   // a successful, non-stale, file-present output exists -> play it, no re-render
    case create                        // nothing usable -> run the coordinator

    /// Decide from the Story's outputs + a file-existence probe (injected so the test is deterministic).
    /// Prefers the NEWEST output that has a file on disk, a non-empty relativeFilePath, and is not stale.
    static func decide(outputs: [GeneratedOutputModel],
                       isStale: (GeneratedOutputModel) -> Bool,
                       fileExists: (String) -> Bool) -> ReopenDecision {
        let candidates = outputs
            .filter { ($0.relativeFilePath?.isEmpty == false) }
            .sorted { $0.createdAt > $1.createdAt }
        for o in candidates {
            guard let rel = o.relativeFilePath, fileExists(rel) else { continue }
            if isStale(o) { continue }
            return .showResult(outputId: o.id)
        }
        return .create
    }
}

/// The playable state of a single output on the Result screen.
enum ResultPlayback: Equatable {
    case playable(relativePath: String)   // file resolved + exists -> AVPlayer
    case missing                           // relativeFilePath nil/empty or file gone -> recoverable "Re-create"

    static func resolve(output: GeneratedOutputModel, fileExists: (String) -> Bool) -> ResultPlayback {
        guard let rel = output.relativeFilePath, !rel.isEmpty, fileExists(rel) else { return .missing }
        return .playable(relativePath: rel)
    }
}

/// Honest music copy for the Result screen. R-c renders WITHOUT music; a future milestone may hit a
/// soundtrack-unavailable case. We distinguish the two in copy and NEVER imply music was included.
enum MusicPresentation: Equatable {
    case createdWithoutMusic           // this milestone: no soundtrack was ever requested
    case soundtrackUnavailable         // future: a soundtrack was intended but could not be included

    var copy: String {
        switch self {
        case .createdWithoutMusic:   return "Created without music"
        case .soundtrackUnavailable: return "Music wasn't available for this version"
        }
    }

    /// R-c decision: an output rendered with no soundtrack is createdWithoutMusic. The `intendedSoundtrack`
    /// seam is future-music — nil in R-c. (We never read a fabricated track name.)
    static func decide(intendedSoundtrack: Bool, soundtrackIncluded: Bool) -> MusicPresentation {
        if intendedSoundtrack && !soundtrackIncluded { return .soundtrackUnavailable }
        return .createdWithoutMusic
    }
}

// MARK: - View

struct StoryResultView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var story: StoryModel
    let output: GeneratedOutputModel
    /// Collapse the ENTIRE create flow back to Story Home. When this Result was reached via the
    /// Creating screen (new render) the view stack is Home -> Preview -> Result, so a plain `dismiss()`
    /// would only pop one level. The parent (CreateStoryPreviewView) injects a closure that resets the
    /// create-flow bindings AND pops the preview, landing on Story Home in a single tap. Falls back to
    /// `dismiss()` when presented standalone (e.g. a direct reopen or a test host).
    var onHome: (() -> Void)? = nil
    /// Start a re-create. Injected so the parent can drive the shared Creating screen instead of this
    /// view pushing its own. Falls back to the local coordinator + `dismiss()` when absent.
    var onRecreate: (() -> Void)? = nil

    private func goHome() {
        if let onHome { onHome() } else { dismiss() }
    }

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var saveOutcome: PhotosSaveOutcome?
    @State private var showShare = false
    @State private var recreateCoordinator: StoryCreationCoordinator?

    private var playback: ResultPlayback {
        ResultPlayback.resolve(output: output) { RenderOutputStore.shared.exists(relative: $0) }
    }

    // R-c renders without music; R-d may bake a real soundtrack. Honest: show the actual track title when the
    // output carries one, else the no-music line. NEVER a fabricated name.
    private var music: MusicPresentation {
        MusicPresentation.decide(intendedSoundtrack: false, soundtrackIncluded: output.soundtrackTitle != nil)
    }

    private var lengthLabel: String {
        "\(Int(output.durationSeconds.rounded())) sec"
    }

    private var isStale: Bool {
        output.isStale || StoryCreationCoordinator.isOutputStale(output: output, story: story)
    }

    var body: some View {
        ZStack {
            StoryTheme.ink.ignoresSafeArea()
            switch playback {
            case .playable(let rel):
                playableBody(relativePath: rel)
            case .missing:
                missingBody
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Swipe-right-to-go-back, matching the ← Home button (collapses the whole create flow, not one level).
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.width > 80 && value.translation.width > abs(value.translation.height) {
                        goHome()
                    }
                }
        )
        .sheet(isPresented: $showShare) {
            if let url = resolvedURL { ShareSheet(items: [url]) }
        }
    }

    private var resolvedURL: URL? {
        guard let rel = output.relativeFilePath, !rel.isEmpty else { return nil }
        return RenderOutputStore.shared.absoluteURL(for: rel)
    }

    // MARK: - Playable

    private func playableBody(relativePath: String) -> some View {
        VStack(spacing: 0) {
            header
            // Large video surface — tap to play/pause (mirrors the harness AVPlayer pattern).
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                        .onDisappear { player.pause() }
                } else {
                    StoryTheme.surface
                }
                if !isPlaying {
                    Circle()
                        .fill(StoryTheme.ink.opacity(0.45))
                        .frame(width: 64, height: 64)
                        .overlay(Image(systemName: "play.fill").font(.system(size: 24)).foregroundStyle(StoryTheme.cream))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { togglePlay() }
            .task {
                if player == nil {
                    player = AVPlayer(url: RenderOutputStore.shared.absoluteURL(for: relativePath))
                }
            }

            actionPanel
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Button { goHome() } label: {
                Text("← Home").font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.55))
            }
            .buttonStyle(.plain)
            Spacer()
            Text(story.title.displayTitle).font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
            Spacer()
            Text(lengthLabel).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
        }
        .padding(.horizontal, StoryTheme.screenPadding)
        .padding(.top, 20)
    }

    private var actionPanel: some View {
        VStack(spacing: 10) {
            // Music line: the REAL track title when a soundtrack was baked in (R-d), else honest no-music.
            Text(output.soundtrackTitle.map { "♫ \($0)" } ?? music.copy)
                .font(StoryTheme.body(12))
                .foregroundStyle(StoryTheme.cream.opacity(0.3))

            #if DEBUG
            // Audio diagnostics from the LAST render, shown HERE on the completed screen (not just the
            // pre-render preview) so "why does the final video have no native audio" is answerable where the
            // user actually ends up. lastMusicNote carries soundtrack role/priority + whether the file reached
            // the renderer; lastOutcomeNotes only populates when the V2-b refinement flag is on.
            if !StoryCreativeRefinement.lastMusicNote.isEmpty {
                Text("🎵 \(StoryCreativeRefinement.lastMusicNote)")
                    .font(StoryTheme.body(10)).foregroundStyle(StoryTheme.cream.opacity(0.35))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !StoryCreativeRefinement.lastOutcomeNotes.isEmpty {
                Text("✂️ " + StoryCreativeRefinement.lastOutcomeNotes.joined(separator: " · "))
                    .font(StoryTheme.body(10)).foregroundStyle(StoryTheme.cream.opacity(0.35))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            #endif

            if isStale {
                // Stale: surface WHY a new version is worth making, but the action below is the same.
                Text("Your moments changed since this was made.")
                    .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.gold.opacity(0.8))
            }

            // Save is always primary (Figma Screen11Result). The real export stays the saved result.
            StoryPrimaryButton(title: "Save") { saveToPhotos() }

            // Create a new version — ALWAYS available (Figma): re-runs the pipeline and ADDS a new
            // GeneratedOutputModel without deleting this one, so the user can iterate instead of being stuck
            // with the single first render. (Previously this only appeared when the output was stale, which is
            // why there was "no way to recreate".) Secondary outline style per the mock.
            Button { recreate() } label: {
                Text("Create a new version")
                    .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.6))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .overlay(Capsule().stroke(StoryTheme.cream.opacity(0.14), lineWidth: 1.5))
            }
            .buttonStyle(.plain)

            Button { showShare = true } label: {
                Text("Share to Files")
                    .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.5))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .overlay(Capsule().stroke(StoryTheme.cream.opacity(0.1), lineWidth: 1.5))
            }
            .buttonStyle(.plain)

            HStack(spacing: 18) {
                // "Change music" — DISABLED future feature (R-d). Never implies music is present.
                Text("♫ Change music")
                    .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.18))
                    .accessibilityHint("Not available yet")
            }
            .padding(.top, 2)

            if let outcome = saveOutcome { saveStatusLine(outcome) }
        }
        .padding(.horizontal, StoryTheme.screenPadding)
        .padding(.top, 16)
        .padding(.bottom, 40)
        .background(StoryTheme.ink)
    }

    @ViewBuilder
    private func saveStatusLine(_ outcome: PhotosSaveOutcome) -> some View {
        let text: String = {
            switch outcome {
            case .saved: return "Saved to Photos."
            case .permissionDenied: return "Photos access is needed to save. Enable it in Settings."
            case .failed: return "Couldn't save to Photos. Please try again."
            case .skipped: return "Nothing to save yet."
            }
        }()
        Text(text).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.45))
    }

    // MARK: - Missing (recoverable — NEVER a fake result)

    private var missingBody: some View {
        VStack(spacing: 20) {
            header
            Spacer()
            Text("This video is no longer available.")
                .font(StoryTheme.display(20)).foregroundStyle(StoryTheme.cream)
                .multilineTextAlignment(.center)
            Text("The rendered file wasn't found on this device.")
                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                .multilineTextAlignment(.center)
            Spacer()
            StoryPrimaryButton(title: "Re-create") { recreate() }
                .padding(.horizontal, StoryTheme.screenPadding)
                .padding(.bottom, 40)
        }
    }

    // MARK: - Actions

    private func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause() } else {
            if player.currentTime() >= (player.currentItem?.duration ?? .zero) {
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    private func saveToPhotos() {
        guard let url = resolvedURL else { saveOutcome = .skipped("source file missing"); return }
        PhotosSaver.saveVideoCopy(at: url) { outcome in
            Task { @MainActor in saveOutcome = outcome }
        }
    }

    /// Re-create: run the coordinator again. We do NOT delete the existing output — the coordinator only ADDs a
    /// new successful GeneratedOutputModel once its render succeeds (Batch A invariant). Prefer the parent-driven
    /// path (reuses the shared Creating screen, so the view stack doesn't accumulate); fall back to a local
    /// coordinator + dismiss when presented standalone.
    private func recreate() {
        if let onRecreate {
            onRecreate()
            return
        }
        if recreateCoordinator == nil {
            recreateCoordinator = StoryCreationCoordinator(planner: EditPlannerService(), context: context)
        }
        recreateCoordinator?.create(for: story)
        // Hand off to the Creating screen for live progress.
        dismiss()
    }
}

// MARK: - Share sheet (UIActivityViewController wrapped for SwiftUI)

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
