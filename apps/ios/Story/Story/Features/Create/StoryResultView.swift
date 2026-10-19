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
    // Redesign MVP: the REAL persisted phase of the in-flight op (submitted|planning|plan_ready|rendering) so
    // the status card shows the actual stage, never a made-up % or ETA. nil when no op is in flight.
    @State private var generationPhase: String?
    @State private var generationFailed: String?        // failureCategory of a failed op (honest message)
    @State private var showExport = false                // consolidated Save-or-Share sheet

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
            ReviseStorySheet(story: story, base: output, versionLabel: baseVersionLabel) { directives, instruction in
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
            generationStatusCard
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

            versionChipRow
            actionPanel
        }
    }

    /// Ready versions for this Story, newest last (V1, V2, …) so chip numbers match creation order. Uses the
    /// view's relationship (fine for display; the ready-swap path re-fetches). A single version shows no row.
    private var versions: [GeneratedOutputModel] {
        story.generatedOutputs.sorted { $0.createdAt < $1.createdAt }
    }

    /// The display label ("V3") of the version currently selected for editing — the SAME numbering as the chip
    /// row (position in the sorted list). Passed to Revise so it can show "Editing Version N".
    private var baseVersionLabel: String {
        let currentId = output.versionId ?? output.id
        if let idx = versions.firstIndex(where: { ($0.versionId ?? $0.id) == currentId }) {
            return "V\(idx + 1)"
        }
        return "this version"
    }

    /// Inline version selector (redesign MVP). Simplest UI for the version count: nothing for 1 version, a
    /// chip row for a few. Marks the one being viewed; tapping swaps the player (no auto-interrupt). A pending
    /// op shows a trailing "Creating…" chip so pending vs ready is visible. Selecting a chip also makes it the
    /// base for Revise / Change Music (both act on `output`).
    @ViewBuilder
    private var versionChipRow: some View {
        if versions.count > 1 || pendingInFlight {
            let currentId = output.versionId ?? output.id
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(versions.enumerated()), id: \.element.id) { idx, v in
                        let selected = (v.versionId ?? v.id) == currentId
                        Button {
                            guard !selected else { return }
                            swappedOutput = v
                            newVersionReady = nil
                            player?.pause(); player = nil; isPlaying = false
                        } label: {
                            HStack(spacing: 4) {
                                Text("V\(idx + 1)").font(StoryTheme.body(13, selected ? .semibold : .regular))
                                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                            }
                            .foregroundStyle(selected ? StoryTheme.ink : StoryTheme.cream.opacity(0.7))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(selected ? StoryTheme.cream : StoryTheme.surfaceAlt)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Version \(idx + 1)\(selected ? ", selected" : "")")
                    }
                    if pendingInFlight {
                        HStack(spacing: 5) {
                            ProgressView().tint(StoryTheme.gold).scaleEffect(0.7)
                            Text("Creating…").font(StoryTheme.body(13))
                        }
                        .foregroundStyle(StoryTheme.cream.opacity(0.5))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .overlay(Capsule().stroke(StoryTheme.cream.opacity(0.12), lineWidth: 1))
                        .accessibilityLabel("A new version is being created")
                    }
                }
                .padding(.horizontal, StoryTheme.screenPadding)
            }
            .padding(.top, 10)
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
    /// Phase-driven status card (redesign MVP). Three mutually-exclusive first-class states, each reflecting
    /// PERSISTED operation state — never a made-up % or ETA, never "ready" before the playable output exists:
    ///   • a newer version is READY -> a prominent card whose SOLE primary action is "View New Version"
    ///     (persists until the user views or dismisses it; tapping swaps the player, no auto-interrupt);
    ///   • an op is GENERATING -> a status card showing the real stage (Planning / Rendering) + "leave & come
    ///     back" reassurance (the current video stays playable below);
    ///   • the op FAILED -> an honest message keyed off failureCategory (recovery never shows a duplicate).
    @ViewBuilder
    private var generationStatusCard: some View {
        if let ready = newVersionReady {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(StoryTheme.gold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your new version is ready").font(StoryTheme.body(15, .semibold))
                            .foregroundStyle(StoryTheme.cream)
                        Text("Your previous version is saved.").font(StoryTheme.body(12))
                            .foregroundStyle(StoryTheme.cream.opacity(0.55))
                    }
                    Spacer()
                }
                Button {
                    swappedOutput = ready
                    newVersionReady = nil
                    player?.pause(); player = nil; isPlaying = false
                    baselineOutputCount = story.generatedOutputs.count
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle.fill")
                        Text("View New Version").font(StoryTheme.body(16, .semibold))
                    }
                    .foregroundStyle(StoryTheme.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(StoryTheme.cream).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View the new version")
            }
            .padding(14)
            .background(StoryTheme.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(StoryTheme.gold.opacity(0.4), lineWidth: 1))
            .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 10)
            .accessibilityElement(children: .combine)
        } else if let failed = generationFailed {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StoryTheme.gold)
                    Text("Couldn't finish the new version").font(StoryTheme.body(14, .semibold))
                        .foregroundStyle(StoryTheme.cream)
                    Spacer()
                }
                Text(failureMessage(failed)).font(StoryTheme.body(12))
                    .foregroundStyle(StoryTheme.cream.opacity(0.6))
            }
            .padding(14)
            .background(StoryTheme.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 10)
            .accessibilityElement(children: .combine)
        } else if pendingInFlight {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView().tint(StoryTheme.gold).scaleEffect(0.9)
                    Text(stageLabel(generationPhase)).font(StoryTheme.body(14, .medium))
                        .foregroundStyle(StoryTheme.gold)
                    Spacer()
                    Text("Working in background").font(StoryTheme.body(11))
                        .foregroundStyle(StoryTheme.cream.opacity(0.4))
                }
                Text("Your current video is still available. You can leave and come back.")
                    .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.55))
            }
            .padding(14)
            .background(StoryTheme.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StoryTheme.gold.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Creating a new version. \(stageLabel(generationPhase)) Your current video is still available.")
        }
    }

    /// Honest failure copy keyed off the backend failure_category (never a generic "retry" for an
    /// unsatisfiable directive set).
    private func failureMessage(_ category: String) -> String {
        switch category {
        case "invalid_after_repair":
            return "Your instruction couldn't be applied to this footage — try adjusting it (for example, exclude fewer Moments)."
        case "material_infeasible":
            return "There isn't enough usable footage for that length — try a shorter video."
        case "unsupported_operation":
            return "That kind of edit isn't supported yet — this app can re-cut, re-time, reorder, set transitions and change the soundtrack, but not color, filters or visual effects. Your current version was kept."
        default:
            return "Something went wrong creating the new version. You can try again."
        }
    }

    /// Observe (NOT drive) the app-level recovery: show the banner while a pending op exists, and surface the
    /// new version once it lands. The recovery persists the new output via a DIFFERENT ModelContext, so the
    /// view's cached `story.generatedOutputs` relationship does NOT update — we must RE-FETCH from the context
    /// each poll. Starts no coordinator, so it cannot race the recovery owner.
    private func observePendingRecovery() async {
        let sid = story.id
        let currentId = output.versionId ?? output.id
        func freshOutputs() -> [GeneratedOutputModel] {
            let desc = FetchDescriptor<GeneratedOutputModel>()
            let all = (try? context.fetch(desc)) ?? []
            return all.filter { $0.story?.id == sid }
        }
        // Read the REAL in-flight op row for this Story so the status card shows the actual phase (or a failure)
        // instead of a binary "finishing…". Recomputed each poll (recovery may write via another context).
        func pendingRow() -> PendingOperationModel? {
            let desc = FetchDescriptor<PendingOperationModel>(predicate: #Predicate { $0.storyId == sid })
            return (try? context.fetch(desc))?.first { $0.isRecoverable }
        }
        baselineOutputCount = freshOutputs().count
        let probe = StoryCreationCoordinator(planner: EditPlannerService(), context: context)
        for _ in 0..<150 {   // ~5 min at 2s
            let hasPending = probe.hasRecoverablePendingOperation(storyId: sid)
            let outs = freshOutputs()
            let newest = outs.sorted { $0.createdAt > $1.createdAt }.first
            // A new version landed (count grew AND the newest isn't the one we're showing) -> surface it.
            if outs.count > baselineOutputCount, let newest, (newest.versionId ?? newest.id) != currentId {
                pendingInFlight = false; generationPhase = nil; generationFailed = nil
                newVersionReady = newest
                return
            }
            let row = pendingRow()
            generationPhase = (hasPending && newVersionReady == nil) ? row?.phase : nil
            generationFailed = row?.failureCategory
            pendingInFlight = hasPending && newVersionReady == nil
            // Done with nothing new: the op finished/failed/abandoned (pending row gone) and no extra output.
            if !hasPending && outs.count <= baselineOutputCount {
                pendingInFlight = false; generationPhase = nil
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        pendingInFlight = false; generationPhase = nil
    }

    /// Human-readable stage for a persisted phase — the REAL stage, no percentage, no ETA (owner rule).
    private func stageLabel(_ phase: String?) -> String {
        switch phase {
        case "submitted", "planning": return "Planning your edit…"
        case "plan_ready", "rendering": return "Rendering your video…"
        default: return "Working…"
        }
    }

    private var actionPanel: some View {
        VStack(spacing: 12) {
            // Music provenance line: the REAL track title when a soundtrack was baked in, else honest no-music.
            Text(output.soundtrackTitle.map { "♫ \($0)" } ?? music.copy)
                .font(StoryTheme.body(12))
                .foregroundStyle(StoryTheme.cream.opacity(0.3))

            if isStale {
                Text("Your moments changed since this was made.")
                    .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.gold.opacity(0.8))
            }

            // EDITING — the central Story features, first-class. Both need a persisted executable plan.
            let canEdit = output.editPlanJSON != nil
            HStack(spacing: 10) {
                editingCard(icon: "pencil.and.scribble", title: "Revise", subtitle: "Describe changes",
                            enabled: canEdit) { showRevise = true }
                editingCard(icon: "music.note", title: "Music", subtitle: "Change soundtrack",
                            enabled: canEdit) { showChangeMusic = true }
            }

            // EXPLORATION — secondary. Disabled while an op is already in flight (duplicate-tap guard).
            Button { if !pendingInFlight { recreate() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .semibold))
                    Text("Create Another Version").font(StoryTheme.body(14, .medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12))
                }
                .foregroundStyle(pendingInFlight ? StoryTheme.cream.opacity(0.25) : StoryTheme.cream.opacity(0.7))
                .padding(.horizontal, 16).padding(.vertical, 13)
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(StoryTheme.cream.opacity(0.12), lineWidth: 1))
                .contentShape(Rectangle())   // whole capsule is tappable, not just the icon/text glyphs
            }
            .buttonStyle(.plain)
            .disabled(pendingInFlight)

            // PRIMARY export — one consolidated entry (Save to Photos OR Share) instead of two competing
            // buttons. Both export the SAME finished MP4; the sheet offers the destinations.
            Button { showExport = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .semibold))
                    Text("Save or Share").font(StoryTheme.body(16, .semibold))
                }
                .foregroundStyle(StoryTheme.cream)
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(StoryTheme.surfaceAlt).clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if let outcome = saveOutcome { saveStatusLine(outcome) }
        }
        .padding(.horizontal, StoryTheme.screenPadding)
        .padding(.top, 16)
        .padding(.bottom, 40)
        .background(StoryTheme.ink)
        .confirmationDialog("Save or Share", isPresented: $showExport, titleVisibility: .visible) {
            Button("Save to Photos") { saveToPhotos() }
            Button("Share to Files…") { showShare = true }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// A first-class editing tile (Revise / Music). Disabled (dimmed) when the output has no persisted plan.
    @ViewBuilder
    private func editingCard(icon: String, title: String, subtitle: String,
                             enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { if enabled { action() } } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(StoryTheme.body(15, .semibold))
                Text(subtitle).font(StoryTheme.body(11)).foregroundStyle(StoryTheme.cream.opacity(0.45))
            }
            .foregroundStyle(enabled ? StoryTheme.cream : StoryTheme.cream.opacity(0.22))
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StoryTheme.cream.opacity(enabled ? 0.14 : 0.06), lineWidth: 1))
            .contentShape(Rectangle())   // whole tile tappable, not just the glyphs
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityHint(enabled ? "" : "Not available for this video")
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
        // Phase 1/5: CAPTURE the selected base version NOW, by value, before any async work. `output` is a
        // computed property (swappedOutput ?? initialOutput) that changes if the user taps a different version
        // chip mid-job — reading it again inside the Task could bind the revise to the wrong parent. The sheet
        // was opened on THIS version; the whole operation must use exactly it.
        let base = output
        let coord = reviseCoordinator ?? StoryCreationCoordinator(planner: EditPlannerService(), context: context)
        reviseCoordinator = coord
        reviseWorking = true
        reviseError = nil
        Task { @MainActor in
            // Carry the base version's soundtrack into the revise so the revised video keeps its music
            // (reviseVersion with no music would render silent). My Music resolves locally; a provider track
            // is re-resolved live (download + analysis) exactly as Change Music does. Nil => honestly no music.
            let music = await resolveBaseMusic(for: base)
            coord.reviseVersion(for: story, base: base, directives: directives,
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
            // Resolve the EXACT base track directly — do NOT re-run a recommendation. A fresh recommend could
            // return a different top pick or fail on a transient provider hiccup, silently dropping the music
            // (observed: a Revise rendered silent though the base had a soundtrack). The base output persisted
            // everything we need (role/priority/title + the plan inside editPlanJSON).
            let resolver = MusicSelectionResolver(context: context)
            let planJSON = basePlanMusicJSON(base)
            return await resolver.resolveKnownTrack(
                trackId: trackId,
                musicPlanJSON: planJSON,
                soundtrackRole: base.soundtrackRole ?? "supportive",
                nativeAudioPriority: base.nativeAudioPriority ?? "selective",
                title: base.soundtrackTitle ?? "Soundtrack")
        }
        return nil
    }

    /// The music_plan object from the base output's persisted edit plan, so a Revise reuses the SAME music plan
    /// the base rendered with. Falls back to an empty object (the renderer treats music as a render-time
    /// overlay via soundtrackURL, so an empty plan still renders the carried track).
    private func basePlanMusicJSON(_ base: GeneratedOutputModel) -> JSONValue {
        guard let s = base.editPlanJSON, let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let mp = obj["music_plan"] else { return .object([:]) }
        if let mpData = try? JSONSerialization.data(withJSONObject: mp),
           let v = try? JSONDecoder().decode(JSONValue.self, from: mpData) { return v }
        return .object([:])
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
