import SwiftUI
import SwiftData
import AVFoundation

// Change Music (Milestone M-e, Phase 3) — now built on the SHARED MusicPickerView so it offers the SAME
// sources as the create-time picker: provider recommendations (+ search/pages), imported My Music, Import
// from Files, and No music. Whatever the user picks, the video is RE-SOUNDTRACKED without re-editing — the
// persisted EditPlan is reused verbatim (the narrative Edit Planner is never invoked) and the result is saved
// as a NEW version (the previous output is preserved).
//
// This is the convergence the owner asked for: create-time music selection and Change Music share one surface.
struct ChangeMusicSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthStore.self) private var auth
    @State private var gate: AuthGate?
    @State private var showSignIn = false
    @Bindable var story: StoryModel
    let source: GeneratedOutputModel
    /// Called with the newly created version on success, so the Result screen can switch to it.
    var onNewVersion: (GeneratedOutputModel) -> Void

    @State private var recommendation: MusicSelectionResolver.Recommendation?
    @State private var loadingRecs = true
    @State private var working = false
    @State private var errorText: String?

    private var resolver: MusicSelectionResolver { MusicSelectionResolver(context: context) }
    private var canChange: Bool { source.editPlanJSON != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                StoryTheme.ink.ignoresSafeArea()

                if !canChange {
                    legacyNotice
                } else if let rec = recommendation {
                    // The shared picker. Its My Music + Import + No-music surfaces work even when the provider
                    // recommendation list is empty; the provider rows populate from `rec`.
                    MusicPickerView(recommendation: rec,
                                    resolver: resolver,
                                    targetDurationSeconds: story.intentTargetDurationSeconds ?? source.durationSeconds,
                                    onChoose: handleChoice)
                } else if loadingRecs {
                    loadingState
                } else {
                    // Provider unavailable / no duration: still allow My Music + Import + No music via an
                    // empty-recommendation picker (never block Change Music on the provider).
                    MusicPickerView(recommendation: .empty(target: source.durationSeconds),
                                    resolver: nil,
                                    targetDurationSeconds: source.durationSeconds,
                                    onChoose: handleChoice)
                }

                if working { workingOverlay }
            }
            .navigationBarBackButtonHidden(true)
        }
        .task {
            // P0 Phase 4: Change Music calls paid music recommendation — require sign-in first, then load.
            let g = AuthGate(auth: auth); gate = g
            g.run { Task { await loadRecommendations() } }
            showSignIn = g.presentingSignIn
        }
        .sheet(isPresented: $showSignIn) {
            SignInView(auth: auth,
                       onSignedIn: { showSignIn = false; gate?.didSignIn() },
                       onCancel: { showSignIn = false; gate?.cancel(); dismiss() })
        }
        .alert("Couldn't change music", isPresented: Binding(get: { errorText != nil },
                                                             set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private var legacyNotice: some View {
        VStack(spacing: 16) {
            Text("Change music").font(StoryTheme.display(26)).foregroundStyle(StoryTheme.cream)
            Text("This video was made before version history, so its exact edit can't be reused. Create it again to enable Change Music.")
                .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.5))
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Close") { dismiss() }.foregroundStyle(StoryTheme.gold)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(StoryTheme.gold)
            Text("Finding music…").font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.6))
        }
    }

    private var workingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(StoryTheme.gold)
                Text("Re-rendering with the new music…").font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.85))
                Text("Your edit stays exactly the same.").font(StoryTheme.body(11)).foregroundStyle(StoryTheme.cream.opacity(0.45))
            }
        }
    }

    // MARK: - Logic

    private func loadRecommendations() async {
        guard canChange else { loadingRecs = false; return }
        let rec = await resolver.recommend(for: story, guideFramingSummary: nil)
        await MainActor.run { recommendation = rec; loadingRecs = false }
    }

    private func handleChoice(_ choice: MusicPickerView.Choice) {
        switch choice {
        case .cancel:
            dismiss()
        case .noMusic:
            apply(.none)
        case .myMusic(let assetId):
            guard let uuid = UUID(uuidString: assetId),
                  let asset = try? context.fetch(
                    FetchDescriptor<MyMusicAssetModel>(predicate: #Predicate { $0.id == uuid })).first else {
                errorText = "That track couldn't be found."; return
            }
            if let providerTrackId = asset.providerTrackId {
                // Saved favorite -> re-resolve live from the provider (no stored bytes).
                guard let rec = recommendation else { errorText = "Music isn't available right now."; return }
                working = true
                Task { @MainActor in
                    guard let sel = await resolver.resolveSelection(recommendation: rec, trackId: providerTrackId) else {
                        working = false; errorText = "Couldn't prepare that saved track."; return
                    }
                    await runReplace(.provider(trackId: sel.trackId, url: sel.soundtrackURL,
                                               role: sel.soundtrackRole, priority: sel.nativeAudioPriority,
                                               title: sel.trackTitle, analysis: sel.analysis))
                }
            } else {
                apply(.myMusic(asset: asset))
            }
        case .track(let trackId):
            // Provider track: resolve (download + plan-derived role/priority) off the current recommendation.
            guard let rec = recommendation else { errorText = "Music isn't available right now."; return }
            working = true
            Task { @MainActor in
                guard let sel = await resolver.resolveSelection(recommendation: rec, trackId: trackId) else {
                    working = false; errorText = "Couldn't prepare that track."; return
                }
                await runReplace(.provider(trackId: sel.trackId, url: sel.soundtrackURL,
                                           role: sel.soundtrackRole, priority: sel.nativeAudioPriority,
                                           title: sel.trackTitle, analysis: sel.analysis))
            }
        }
    }

    private func apply(_ choice: SoundtrackReplacer.MusicChoice) {
        guard !working else { return }
        working = true
        Task { @MainActor in await runReplace(choice) }
    }

    @MainActor
    private func runReplace(_ choice: SoundtrackReplacer.MusicChoice) async {
        working = true; errorText = nil
        do {
            let replacer = SoundtrackReplacer(context: context)
            let newVersion = try await replacer.changeMusic(for: source, in: story, choice: choice)
            working = false
            onNewVersion(newVersion)
            dismiss()
        } catch {
            working = false
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
