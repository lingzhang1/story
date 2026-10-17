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
    let initialOutput: GeneratedOutputModel
    /// Change Music swaps the DISPLAYED output in place (never a stacked cover — that broke the recreate
    /// navigation, landing on Home instead of Customize). The previous version stays in story.generatedOutputs.
    @State private var swappedOutput: GeneratedOutputModel?
    private var output: GeneratedOutputModel { swappedOutput ?? initialOutput }
    /// Collapse the ENTIRE create flow back to Story Home. When this Result was reached via the
    /// Creating screen (new render) the view stack is Home -> Preview -> Result, so a plain `dismiss()`
    /// would only pop one level. The parent (CreateStoryPreviewView) injects a closure that resets the
    /// create-flow bindings AND pops the preview, landing on Story Home in a single tap. Falls back to
    /// `dismiss()` when presented standalone (e.g. a direct reopen or a test host).
    var onHome: (() -> Void)? = nil
    /// Start a re-create (Create a new version), carrying THIS output as the parent to derive the Explore
    /// version-aware context from. Injected so the parent drives the shared Creating screen. Falls back to a
    /// local coordinator + dismiss when absent.
    var onRecreate: ((GeneratedOutputModel) -> Void)? = nil

    private func goHome() {
        if let onHome { onHome() } else { dismiss() }
    }

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var saveOutcome: PhotosSaveOutcome?
    @State private var showShare = false
    @State private var recreateCoordinator: StoryCreationCoordinator?
    @State private var showChangeMusic = false
    @State private var showRevise = false
    @State private var reviseCoordinator: StoryCreationCoordinator?
    @State private var reviseWorking = false
    @State private var reviseError: String?
    // In-flight recovery banner: a pending AI operation for this Story is being finished by the app-level
    // recovery (invisible). We OBSERVE it (no new coordinator) and show a banner so the user knows a new
    // version is coming, then offer to view it when it lands. `baselineOutputCount` is the version count when
    // this screen appeared; a jump means recovery produced a new version.
    @State private var pendingInFlight = false
    @State private var baselineOutputCount = 0
    @State private var newVersionReady: GeneratedOutputModel?

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
        .sheet(isPresented: $showChangeMusic) {
            ChangeMusicSheet(story: story, source: output) { created in
                // Swap the displayed version IN PLACE (no stacked cover). The previous output remains in the
                // Story's version list; recreate() still reaches Customize via the unchanged onRecreate closure.
                swappedOutput = created
                player?.pause(); player = nil; isPlaying = false   // reload player for the new file
            }
        }
        .sheet(isPresented: $showRevise) {
            ReviseStorySheet(story: story, base: output) { directives, instruction in
                startRevise(directives: directives, instruction: instruction)
            }
        }
        .overlay { if reviseWorking { reviseWorkingOverlay } }
        .alert("Couldn't revise", isPresented: Binding(get: { reviseError != nil },
                                                       set: { if !$0 { reviseError = nil } })) {
            Button("OK", role: .cancel) { reviseError = nil }
        } message: { Text(reviseError ?? "") }
    }

    private var resolvedURL: URL? {
        guard let rel = output.relativeFilePath, !rel.isEmpty else { return nil }
        return RenderOutputStore.shared.absoluteURL(for: rel)
    }

    // MARK: - Playable

    private func playableBody(relativePath: String) -> some View {
        VStack(spacing: 0) {
            header
            inFlightBanner
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
            .task(id: relativePath) {
                player = AVPlayer(url: RenderOutputStore.shared.absoluteURL(for: relativePath))
            }
            .task { await observePendingRecovery() }

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

    /// Banner shown when a Create-Another-Version (or any AI op) is still being finished in the background by
    /// the app-level recovery (you backgrounded mid-render). OBSERVER ONLY — it starts no coordinator. When the
    /// recovery lands a new version, it flips to a tappable "View" that swaps the displayed output.
    @ViewBuilder
    private var inFlightBanner: some View {
        if let ready = newVersionReady {
            Button {
                swappedOutput = ready
                newVersionReady = nil
                player?.pause(); player = nil; isPlaying = false
                baselineOutputCount = story.generatedOutputs.count
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(StoryTheme.gold)
                    Text("Your new version is ready — View").font(StoryTheme.body(13, .medium))
                        .foregroundStyle(StoryTheme.cream)
                    Spacer()
                    Text("→").foregroundStyle(StoryTheme.gold)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(StoryTheme.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 10)
        } else if pendingInFlight {
            HStack(spacing: 8) {
                ProgressView().tint(StoryTheme.gold).scaleEffect(0.8)
                Text("Finishing your new version…").font(StoryTheme.body(13))
                    .foregroundStyle(StoryTheme.cream.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(StoryTheme.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 10)
        }
    }

    /// Observe (NOT drive) the app-level recovery: show the banner while a pending op exists, and surface the
    /// new version when the Story's output count grows past the baseline captured on appear. Polls lightly;
    /// starts no coordinator, so it cannot race the recovery owner.
    private func observePendingRecovery() async {
        baselineOutputCount = story.generatedOutputs.count
        let probe = StoryCreationCoordinator(planner: EditPlannerService(), context: context)
        for _ in 0..<150 {   // ~5 min at 2s
            let hasPending = probe.hasRecoverablePendingOperation(storyId: story.id)
            let newest = story.generatedOutputs.sorted { $0.createdAt > $1.createdAt }.first
            if story.generatedOutputs.count > baselineOutputCount, let newest,
               (newest.versionId ?? newest.id) != (output.versionId ?? output.id) {
                pendingInFlight = false
                newVersionReady = newest
                return
            }
            pendingInFlight = hasPending && newVersionReady == nil
            if !hasPending && story.generatedOutputs.count <= baselineOutputCount {
                // No pending op and nothing new — nothing to show (either never had one, or it failed/abandoned).
                pendingInFlight = false
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        pendingInFlight = false
    }

    private var actionPanel: some View {
        VStack(spacing: 10) {
            // Music line: the REAL track title when a soundtrack was baked in (R-d), else honest no-music.
            Text(output.soundtrackTitle.map { "♫ \($0)" } ?? music.copy)
                .font(StoryTheme.body(12))
                .foregroundStyle(StoryTheme.cream.opacity(0.3))

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
                // "Change music" (M-e): swap the soundtrack without re-editing the video — reuses the
                // persisted EditPlan and saves a NEW version. Enabled only when this output carries a
                // persisted executable plan (legacy/mock outputs can't be faithfully re-rendered).
                Button { showChangeMusic = true } label: {
                    Text("♫ Change music")
                        .font(StoryTheme.body(13))
                        .foregroundStyle(output.editPlanJSON != nil ? StoryTheme.gold.opacity(0.85) : StoryTheme.cream.opacity(0.18))
                }
                .buttonStyle(.plain)
                .disabled(output.editPlanJSON == nil)
                .accessibilityHint(output.editPlanJSON != nil ? "Replace the soundtrack; the edit stays the same" : "Not available for this video")

                // "Revise" (Natural-Language Revision): apply a user-directed change (incl. explicit Moment
                // references) to THIS version, preserving unaffected edits. Needs the base plan, so it is
                // enabled only when this output carries a persisted executable plan.
                Button { showRevise = true } label: {
                    Text("✎ Revise")
                        .font(StoryTheme.body(13))
                        .foregroundStyle(output.editPlanJSON != nil ? StoryTheme.gold.opacity(0.85) : StoryTheme.cream.opacity(0.18))
                }
                .buttonStyle(.plain)
                .disabled(output.editPlanJSON == nil)
                .accessibilityHint(output.editPlanJSON != nil ? "Apply a change; the rest of the edit is kept" : "Not available for this video")
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
    private func recreate() {        if let onRecreate {
            onRecreate(output)
            return
        }
        if recreateCoordinator == nil {
            recreateCoordinator = StoryCreationCoordinator(planner: EditPlannerService(), context: context)
        }
        // Local fallback (standalone/test host): Explore from THIS output.
        recreateCoordinator?.createAnotherVersion(for: story, from: output)
        // Hand off to the Creating screen for live progress.
        dismiss()
    }

    // MARK: - Revise (Natural-Language Revision)

    private var reviseWorkingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(StoryTheme.gold)
                Text("Revising your Story…").font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.85))
                Text("Applying your change; the rest of the edit is kept.")
                    .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.cream.opacity(0.45))
            }
        }
    }

    /// Run a Revise against THIS output in place (mirrors Change Music's in-view flow): a local coordinator
    /// re-plans with the exact base plan + resolved directives, and on success the displayed output swaps to
    /// the new version (the base and all prior versions are preserved in the Story's version list).
    private func startRevise(directives: ResolvedDirectives, instruction: String) {
        let coord = reviseCoordinator ?? StoryCreationCoordinator(planner: EditPlannerService(), context: context)
        reviseCoordinator = coord
        reviseWorking = true
        reviseError = nil
        Task { @MainActor in
            // Carry the base version's soundtrack into the revise so the revised video keeps its music
            // (reviseVersion with no music would render silent). My Music resolves locally; a provider track
            // is re-resolved live (download + analysis) exactly as Change Music does. Nil => honestly no music.
            let music = await resolveBaseMusic(for: output)
            coord.reviseVersion(for: story, base: output, directives: directives,
                                softDirection: instruction, music: music)
            while coord.isCreating { try? await Task.sleep(nanoseconds: 200_000_000) }
            reviseWorking = false
            switch coord.state {
            case .completed(let created):
                swappedOutput = created
                player?.pause(); player = nil; isPlaying = false
            case .failed(let message):
                reviseError = message
            default:
                break   // cancelled / other — leave the current version displayed
            }
        }
    }

    /// Re-resolve the base version's soundtrack so a Revise preserves its music. Reads the base output's
    /// persisted musicAssetRef ("mymusic:<id>" | "provider:<trackId>" | "none"); My Music resolves locally,
    /// a provider track re-resolves live via MusicSelectionResolver (same path as Change Music). nil => no music.
    @MainActor
    private func resolveBaseMusic(for base: GeneratedOutputModel) async
        -> StoryCreationCoordinator.MusicSelection? {
        guard let ref = base.musicAssetRef, ref != "none" else { return nil }
        if ref.hasPrefix("mymusic:") {
            let assetId = String(ref.dropFirst("mymusic:".count))
            return CreateStoryPreviewView.myMusicSelection(assetId: assetId, story: story, context: context)
        }
        if ref.hasPrefix("provider:") {
            let trackId = String(ref.dropFirst("provider:".count))
            let resolver = MusicSelectionResolver(context: context)
            guard let rec = await resolver.recommend(for: story, guideFramingSummary: nil) else { return nil }
            return await resolver.resolveSelection(recommendation: rec, trackId: trackId)
        }
        return nil
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
