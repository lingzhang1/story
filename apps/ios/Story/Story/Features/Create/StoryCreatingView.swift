import SwiftUI
import SwiftData
import UIKit

// StoryCreatingView — R-c Batch B, production "Creating your Story..." screen (frozen Figma Screen10Creating).
//
// OWNS a StoryCreationCoordinator (Batch A) and renders purely off `coordinator.state` — there is NO fake timer
// (the prototype's 1.2%/30ms interval is REPLACED by the real 8-state lifecycle). No developer diagnostics, no raw
// EditPlan, no model/backend names. No-music milestone: no track line, no music sub-lines (Screen10's rotating
// sub-lines only exist when a trackName is present, which R-c never has).
//
// Playback/export is device/Xcode-gated; this file is parse-checked only.

// MARK: - Pure, testable State -> UI phase mapping
//
// The ONLY place coordinator.State is turned into what the screen shows. Extracted as a pure value + function so
// StoryResultFlowTests can assert the mapping without a SwiftUI host.

/// What the Creating screen is doing right now, derived purely from the coordinator state.
enum CreatingPhase: Equatable {
    case indeterminate(status: String)         // preparing / planning / validating — spinner, NO fake percentage
    case determinate(progress: Double)         // rendering — real 0...1 progress bar
    case failed(message: String)               // concise message + Retry + back
    case cancelled                             // return to the Story safely
    case completed                             // transition to Result

    /// Pure mapping. Honest, consumer-safe copy — nothing about planners, models, or HTTP status.
    static func from(_ state: StoryCreationCoordinator.State) -> CreatingPhase {
        switch state {
        case .idle, .preparing:        return .indeterminate(status: "Getting your moments ready…")
        case .planning:                return .indeterminate(status: "Planning your Story…")
        case .validating:              return .indeterminate(status: "Checking the plan…")
        case .rendering(let progress): return .determinate(progress: max(0, min(1, progress)))
        case .failed(let message):     return .failed(message: message)
        case .cancelled:               return .cancelled
        case .completed:               return .completed
        }
    }

    /// Whether a Cancel control should be offered (planning + rendering phases).
    var allowsCancel: Bool {
        switch self {
        case .indeterminate, .determinate: return true
        case .failed, .cancelled, .completed: return false
        }
    }
}

/// Pure mapping from the coordinator's structured failure to the recovery affordances the Failed screen shows.
/// Extracted so tests assert "insufficient material -> duration choice, NOT Retry" without a SwiftUI host.
enum FailureRecovery: Equatable {
    case shorterStory(suggestedSeconds: Double)   // insufficient material, a shorter Story is possible
    case keepShooting                              // insufficient material, not even a minimum Story -> only "keep shooting"
    case technical                                 // recoverable technical failure -> honest "Try again"

    static func from(_ error: StoryCreationError?) -> FailureRecovery {
        if case let .insufficientMaterial(_, _, suggested)? = error {
            if let s = suggested { return .shorterStory(suggestedSeconds: s) }
            return .keepShooting
        }
        return .technical
    }
}

struct StoryCreatingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var story: StoryModel
    /// R-d: a music selection the PICKER already resolved (nil = user chose no-music / unavailable). When
    /// `musicIsPreresolved` is true the Creating screen uses this verbatim and does NOT auto-resolve — the
    /// rendered track is exactly what the user picked. When false (standalone/legacy entry) it falls back to
    /// resolving the recommended track itself.
    var preresolvedMusic: StoryCreationCoordinator.MusicSelection? = nil
    var musicIsPreresolved: Bool = false
    /// Creative Revision Foundation: when set, this run is a deliberate "Create another version" (EXPLORE)
    /// built FROM this parent output — the coordinator re-plans with a version-aware context and sets lineage.
    /// nil => an ordinary original create (unchanged behavior).
    var sourceVersion: GeneratedOutputModel? = nil
    /// R-d: when set, "Create a new version" on the just-rendered Result pops back to the preview and re-enters
    /// the music picker flow (consistent with reopen). Carries the just-rendered output as the Explore parent.
    /// When nil, it re-runs an Explore from that output on this coordinator.
    var onRequestRecreate: ((GeneratedOutputModel) -> Void)? = nil
    /// When the render completes, hand the output UP to the parent so it can present Result in place of this
    /// screen (stack stays Home -> Preview -> Result instead of Home -> Preview -> Creating -> Result, which
    /// left the stuck "Finishing up…" screen behind when Result dismissed). When nil, this view falls back to
    /// pushing Result itself (standalone / test host).
    var onCompleted: ((GeneratedOutputModel) -> Void)? = nil
    /// P0 recovery: when true, this screen RESUMES the Story's existing unfinished edit-plan operation instead
    /// of starting a fresh create — it reuses the persisted job (no re-inference), re-resolves the soundtrack,
    /// and renders the recovered plan. `preresolvedMusic` carries the re-resolved selection when the parent
    /// already resolved it. Used when a Story is reopened with a recoverable pending operation.
    var resumePending: Bool = false

    @State private var coordinator: StoryCreationCoordinator?
    // R-d.2 keep-alive: creating a Story runs a long foreground pipeline (Opus planning + AVAssetExportSession),
    // both of which iOS SUSPENDS when the screen locks/darkens — killing the request (-1005) and the export
    // ("Operation Interrupted"). Disabling the idle timer stops auto-lock mid-create; a background task buys a
    // grace window if the user locks manually. Neither is a true background render, but both stop the common
    // "screen went dark -> I couldn't finish your Story" failure.
    @State private var keepAliveTask: UIBackgroundTaskIdentifier = .invalid
    /// Set when the coordinator reaches .completed — drives navigation to the Result screen (fallback path only).
    @State private var completedOutput: GeneratedOutputModel?
    /// Guard so the completion hand-off fires exactly once.
    @State private var didHandOffCompletion = false
    @State private var createStartedAt = Date()   // for the time-based patience reminder (honest elapsed time)

    private var phase: CreatingPhase {
        guard let coordinator else { return .indeterminate(status: "Getting your moments ready…") }
        let p = CreatingPhase.from(coordinator.state)
        // During planning, prefer the REAL backend job status (queued/running) over the static copy.
        if case .indeterminate = p, coordinator.state == .planning,
           let live = coordinator.planningSubstatus {
            return .indeterminate(status: live)
        }
        return p
    }

    var body: some View {
        ZStack {
            StoryTheme.ink.ignoresSafeArea()
            content
                .padding(.horizontal, 40)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $completedOutput) { output in
            StoryResultView(
                story: story,
                initialOutput: output,
                onHome: {
                    // Pop BOTH Result and this Creating screen so the user lands on Story Home in one tap
                    // (fixes the stuck "Finishing up…" screen that a single dismiss left behind). Clearing
                    // `completedOutput` pops Result; dismissing on the next runloop pops Creating.
                    completedOutput = nil
                    DispatchQueue.main.async { dismiss() }
                },
                onRecreate: { src in
                    // "Create a new version". Route back through the preview's Customize + music flow so the
                    // user can re-choose length/sound/track. The parent's handler sets showCreating=false which
                    // pops THIS Creating screen and then presents Customize — so we must NOT also call our own
                    // dismiss() here (the two raced and dropped the Customize sheet, landing on Story Home).
                    completedOutput = nil
                    if let onRequestRecreate {
                        onRequestRecreate(src)
                    } else {
                        didHandOffCompletion = false
                        coordinator?.createAnotherVersion(for: story, from: src)
                    }
                })
        }
        .task {
            beginKeepAlive()
            // Build the real coordinator once and start the pipeline. Prod planner = EditPlannerService,
            // prod renderer = MediaEngineV1 (device-gated). R-d: resolve a soundtrack FIRST (recommend top
            // track -> download), then start MUSIC-AWARE creation; if music is unavailable (provider off,
            // plan/provider failure) fall back to the device-verified no-music path. Music never blocks.
            if coordinator == nil {
                createStartedAt = Date()   // start the patience timer from the real creation moment
                let coord = StoryCreationCoordinator(planner: EditPlannerService(), context: context)
                coordinator = coord
                if resumePending {
                    // P0 recovery: resume the Story's existing unfinished operation (reuse the job, no new
                    // inference). preresolvedMusic is the re-resolved soundtrack (nil = no-music). If there is
                    // nothing recoverable (race: another coordinator already finished it), fall through to the
                    // normal reopen path by dismissing — the parent routes to the result.
                    if !coord.resumePendingOperation(for: story, music: preresolvedMusic) {
                        dismiss()
                    }
                } else if musicIsPreresolved {
                    // Picker already chose + resolved the track (or no-music). Render exactly that.
                    if let parent = sourceVersion {
                        coord.createAnotherVersion(for: story, from: parent, music: preresolvedMusic)
                    } else {
                        coord.createWithMusic(for: story, music: preresolvedMusic)
                    }
                } else {
                    // Legacy/standalone entry: resolve the recommended track ourselves, else no-music.
                    let resolver = MusicSelectionResolver(context: context)
                    var music: StoryCreationCoordinator.MusicSelection? = nil
                    if let rec = await resolver.recommend(for: story, guideFramingSummary: nil),
                       let top = rec.topTrackId {
                        music = await resolver.resolveSelection(recommendation: rec, trackId: top)
                    }
                    coord.createWithMusic(for: story, music: music)
                }
            }
        }
        .onChange(of: completedState) { _, newValue in
            guard let output = newValue, !didHandOffCompletion else { return }
            didHandOffCompletion = true
            if let onCompleted {
                // Parent presents Result in our place (no stacked Creating screen left behind).
                onCompleted(output)
            } else {
                // Standalone fallback: push Result from here.
                completedOutput = output
            }
        }
        .onDisappear { endKeepAlive() }
    }

    /// Keep the app awake and alive during the long create pipeline. Disable auto-lock (the main cause of a
    /// suspended-mid-render failure) and open a background task so a manual lock gets a grace window instead of
    /// an instant kill. Best-effort — a failure here never blocks creation.
    private func beginKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = true
        if keepAliveTask == .invalid {
            keepAliveTask = UIApplication.shared.beginBackgroundTask(withName: "story-create") {
                endKeepAlive()   // expiration handler — release cleanly if iOS reclaims the time
            }
        }
    }

    private func endKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = false
        if keepAliveTask != .invalid {
            UIApplication.shared.endBackgroundTask(keepAliveTask)
            keepAliveTask = .invalid
        }
    }

    /// Surfaces the completed output (if any) so onChange can push the Result screen.
    private var completedState: GeneratedOutputModel? {
        if case let .completed(output)? = coordinator?.state { return output }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .indeterminate(let status):
            creatingBody(status: status, determinate: false, progress: 0)
        case .determinate(let progress):
            creatingBody(status: "Putting your Story together…", determinate: true, progress: progress)
        case .failed(let message):
            failedBody(message: message)
        case .cancelled:
            // Nothing to show — leave the screen (return to the Story) on next runloop.
            Color.clear.onAppear { dismiss() }
        case .completed:
            // Transition handled by navigationDestination; show the final frame of the bar meanwhile.
            creatingBody(status: "Finishing up…", determinate: true, progress: 1.0)
        }
    }

    // MARK: - Creating (Screen10Creating look)

    /// Escalating, HONEST reassurance keyed off real elapsed seconds (no fake progress). A warm line from the
    /// very start so the opening seconds never read as a dead screen, then gentle reassurance, then explicit
    /// expectation-setting so a 1-2 min plan never reads as "stuck".
    private func patienceNote(elapsed: TimeInterval) -> String? {
        switch elapsed {
        case ..<12:  return "Sit back — we're shaping your moments into a Story."
        case ..<30:  return "Hang tight — this usually takes a moment."
        case ..<60:  return "Still working. Good edits take a little longer."
        case ..<120: return "Almost there — crafting your Story carefully. This can take a minute or two."
        default:     return "Thanks for your patience — finishing up your Story. You can keep waiting or cancel."
        }
    }

    private func creatingBody(status: String, determinate: Bool, progress: Double) -> some View {
        VStack(spacing: 28) {
            Spacer()
            // Centered italic serif line (Fraunces 300 italic), matching Screen10.
            Text("Creating your Story…")
                .font(StoryTheme.displayItalic(24))
                .foregroundStyle(StoryTheme.cream.opacity(0.7))
                .multilineTextAlignment(.center)

            // Honest status sub-line (NOT a music track line). No percentage text.
            Text(status)
                .font(StoryTheme.body(13))
                .foregroundStyle(StoryTheme.cream.opacity(0.35))
                .multilineTextAlignment(.center)

            // Thin horizontal progress bar: determinate during rendering, indeterminate otherwise.
            progressBar(determinate: determinate, progress: progress)
                .frame(height: 1.5)
                .padding(.top, 4)

            // Time-based PATIENCE reminder (honest — driven by real elapsed seconds, NOT a fake percentage).
            // Planning can genuinely take 1-2 min (and longer for visual-first + critique), so a static line
            // reads as "stuck". We stay quiet at first, then gently reassure, then explicitly set expectations.
            // Time-based reassurance (honest — driven by real elapsed seconds, NOT a fake percentage). Shown in
            // every active phase (planning AND rendering), since a long render can also take a minute or two.
            TimelineView(.periodic(from: createStartedAt, by: 1)) { ctx in
                let elapsed = ctx.date.timeIntervalSince(createStartedAt)
                if let note = patienceNote(elapsed: elapsed) {
                    Text(note)
                        .font(StoryTheme.body(12))
                        .foregroundStyle(StoryTheme.cream.opacity(0.3))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .transition(.opacity)
                        .id(note)   // fade between notes as they change
                }
            }

            Spacer()

            if phase.allowsCancel {
                Button {
                    coordinator?.cancel()
                } label: {
                    Text("Cancel")
                        .font(StoryTheme.body(14))
                        .foregroundStyle(StoryTheme.cream.opacity(0.4))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private func progressBar(determinate: Bool, progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(StoryTheme.cream.opacity(0.06))
                if determinate {
                    Capsule()
                        .fill(LinearGradient(colors: [StoryTheme.cream.opacity(0.3), StoryTheme.cream.opacity(0.8)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, min(1, progress)) * geo.size.width)
                        .animation(.linear(duration: 0.15), value: progress)
                } else {
                    // Indeterminate shimmer: a short bar sliding under the planning/validating phases.
                    IndeterminateBar(width: geo.size.width)
                }
            }
        }
    }

    // MARK: - Failed (actionable recovery; NEVER a fabricated montage)

    @ViewBuilder
    private func failedBody(message: String) -> some View {
        // Branch on the STRUCTURED failure: insufficient material gets an actionable duration choice
        // (Create a shorter Story / Keep shooting), everything else keeps the honest Try again.
        switch FailureRecovery.from(coordinator?.lastFailure) {
        case .shorterStory(let suggested):
            insufficientBody(message: message, suggestedSeconds: suggested)
        case .keepShooting:
            insufficientBody(message: message, suggestedSeconds: nil)
        case .technical:
            technicalFailedBody(message: message)
        }
    }

    /// Insufficient-material recovery. "Create a shorter Story" (when a suggestion exists) accepts the
    /// conservative shorter target as a per-attempt override — it does NOT change the Story's saved target.
    /// "Keep shooting" returns to the Story with nothing lost. NO "Try again" here (an identical impossible
    /// target would just fail again and re-call nothing — we never re-ask the planner for the impossible).
    private func insufficientBody(message: String, suggestedSeconds: Double?) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Not quite enough footage yet.")
                .font(StoryTheme.display(22))
                .foregroundStyle(StoryTheme.cream)
                .multilineTextAlignment(.center)
            Text(message)
                .font(StoryTheme.body(14))
                .foregroundStyle(StoryTheme.cream.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let suggested = suggestedSeconds {
                StoryPrimaryButton(title: "Create a \(Int(suggested.rounded()))-second Story") {
                    coordinator?.createShorter(targetSeconds: suggested)
                }
            }
            Button {
                dismiss()   // Keep shooting: back to Story Home, nothing lost.
            } label: {
                Text("Keep shooting")
                    .font(StoryTheme.body(14))
                    .foregroundStyle(StoryTheme.cream.opacity(suggestedSeconds == nil ? 0.7 : 0.4))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
    }

    /// Recoverable technical failure (503 planner outage, transport, render error): concise message + Retry.
    private func technicalFailedBody(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text("I couldn't finish your Story.")
                .font(StoryTheme.display(22))
                .foregroundStyle(StoryTheme.cream)
                .multilineTextAlignment(.center)
            Text(message)
                .font(StoryTheme.body(14))
                .foregroundStyle(StoryTheme.cream.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            StoryPrimaryButton(title: "Try again") { coordinator?.retry() }
            Button {
                dismiss()
            } label: {
                Text("Back to Story")
                    .font(StoryTheme.body(14))
                    .foregroundStyle(StoryTheme.cream.opacity(0.4))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
    }
}

// A small self-animating indeterminate bar (planning/validating have no real percentage).
private struct IndeterminateBar: View {
    let width: CGFloat
    @State private var offset: CGFloat = -0.4
    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [StoryTheme.cream.opacity(0.1), StoryTheme.cream.opacity(0.7),
                                          StoryTheme.cream.opacity(0.1)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: max(40, width * 0.35))
            .offset(x: offset * width)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    offset = 1.1
                }
            }
    }
}
