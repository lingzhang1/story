import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

// Change Music + My Music UI (Milestone M-e, Phases 2-3).
//
// ChangeMusicSheet is presented from the Result screen. It lets the user re-soundtrack an EXISTING
// version WITHOUT re-editing the video: pick a saved My Music track, import a new one, or choose
// no music, then it re-renders via SoundtrackReplacer (which reuses the persisted EditPlan verbatim)
// and saves a NEW version. (Picking another PROVIDER track from the recommendation list is reachable
// through the existing Music Picker flow at create time; this sheet focuses on My Music + no-music,
// which is the net-new M-e surface. Provider re-selection can be added here later without changing
// the engine, which already supports .provider.)
//
// Dark editorial language (StoryTheme). No sliders, no percentages, no raw BPM.

struct ChangeMusicSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var story: StoryModel
    let source: GeneratedOutputModel
    /// Called with the newly created version on success, so the Result screen can switch to it.
    var onNewVersion: (GeneratedOutputModel) -> Void

    @Query(sort: \MyMusicAssetModel.lastUsedAt, order: .reverse) private var library: [MyMusicAssetModel]
    @State private var importing = false
    @State private var working = false
    @State private var errorText: String?
    @State private var preview = AudioPreview()

    private var canChange: Bool { source.editPlanJSON != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                StoryTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        if !canChange {
                            Text("This video was made before version history, so its exact edit can't be reused. Create it again to enable Change Music.")
                                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.gold.opacity(0.85))
                                .padding(.vertical, 8)
                        } else {
                            sectionTitle("From your music")
                            if library.isEmpty {
                                Text("No imported music yet. Import a track from Files to use it here and in future Stories.")
                                    .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                            } else {
                                ForEach(library) { asset in myMusicRow(asset) }
                            }

                            importRow
                            noMusicRow
                        }

                        if let e = errorText {
                            Text(e).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.gold)
                        }
                    }
                    .padding(StoryTheme.screenPadding)
                }
                if working { workingOverlay }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { preview.stop(); dismiss() }
                        .foregroundStyle(StoryTheme.cream.opacity(0.7))
                }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                          allowsMultipleSelection: false) { handleImport($0) }
            .alert("Rename track", isPresented: Binding(get: { renaming != nil },
                                                        set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let a = renaming {
                        let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { a.displayName = t; try? context.save() }
                    }
                    renaming = nil
                }
            }
        }
        .onDisappear { preview.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Change music").font(StoryTheme.display(26)).foregroundStyle(StoryTheme.cream)
            Text("Swap the soundtrack. Your edit — the cuts, timing and pacing — stays exactly the same.")
                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.45))
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(StoryTheme.body(11, .medium))
            .foregroundStyle(StoryTheme.cream.opacity(0.35)).tracking(1.2).padding(.top, 6)
    }

    private func myMusicRow(_ asset: MyMusicAssetModel) -> some View {
        HStack(spacing: 12) {
            Button {
                togglePreview(asset)
            } label: {
                Image(systemName: preview.playingId == asset.id ? "pause.circle.fill" : "play.circle")
                    .font(.system(size: 26)).foregroundStyle(StoryTheme.gold)
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.displayName).font(StoryTheme.body(15)).foregroundStyle(StoryTheme.cream)
                    .lineLimit(1)
                Text("My Music · \(timeLabel(asset.durationSeconds))")
                    .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.cream.opacity(0.35))
            }
            Spacer()
            Button { apply(.myMusic(asset: asset)) } label: {
                Text("Use").font(StoryTheme.body(13, .medium)).foregroundStyle(StoryTheme.ink)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Capsule().fill(StoryTheme.gold))
            }.buttonStyle(.plain).disabled(working)
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(StoryTheme.cream.opacity(0.04)))
        .contextMenu {
            Button("Rename") { rename(asset) }
            Button("Remove", role: .destructive) { MyMusicStore.shared.remove(asset, from: context) }
        }
    }

    private var importRow: some View {
        Button { importing = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 20)).foregroundStyle(StoryTheme.cream.opacity(0.7))
                Text("Import from Files…").font(StoryTheme.body(15)).foregroundStyle(StoryTheme.cream)
                Spacer()
            }
            .padding(.vertical, 13).padding(.horizontal, 14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StoryTheme.cream.opacity(0.14), lineWidth: 1.5))
        }.buttonStyle(.plain).disabled(working)
    }

    private var noMusicRow: some View {
        Button { apply(.none) } label: {
            HStack(spacing: 12) {
                Image(systemName: "speaker.slash").font(.system(size: 18)).foregroundStyle(StoryTheme.cream.opacity(0.6))
                Text("No background music").font(StoryTheme.body(15)).foregroundStyle(StoryTheme.cream.opacity(0.85))
                Spacer()
            }
            .padding(.vertical, 13).padding(.horizontal, 14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StoryTheme.cream.opacity(0.1), lineWidth: 1.5))
        }.buttonStyle(.plain).disabled(working)
    }

    private var workingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(StoryTheme.gold)
                Text("Re-rendering with the new music…")
                    .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.8))
                Text("Your edit stays the same.")
                    .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.cream.opacity(0.4))
            }
        }
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e): errorText = "Import failed: \(e.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let asset = try MyMusicStore.shared.importAudio(from: url, into: context)
                errorText = nil
                // Immediately offer it: a fresh import is usually what the user wants to apply.
                apply(.myMusic(asset: asset))
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func apply(_ choice: SoundtrackReplacer.MusicChoice) {
        guard !working else { return }
        preview.stop()
        working = true; errorText = nil
        Task { @MainActor in
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

    private func togglePreview(_ asset: MyMusicAssetModel) {
        if preview.playingId == asset.id { preview.stop(); return }
        guard MyMusicStore.shared.exists(asset) else { errorText = "That track's file is missing."; return }
        preview.play(url: MyMusicStore.shared.absoluteURL(for: asset.relativePath), id: asset.id)
    }

    @State private var renaming: MyMusicAssetModel?
    @State private var renameText: String = ""
    private func rename(_ asset: MyMusicAssetModel) {
        renameText = asset.displayName
        renaming = asset
    }

    private func timeLabel(_ s: Double) -> String {
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Tiny AVPlayer-backed preview that routes through the .playback audio session so it is audible even
/// with the hardware mute switch on (same fix as the Music Picker). Releases the session on stop.
@MainActor
final class AudioPreview: ObservableObject {
    @Published var playingId: UUID?
    private var player: AVPlayer?

    func play(url: URL, id: UUID) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: url)
        player = p; playingId = id
        p.play()
    }

    func stop() {
        player?.pause(); player = nil; playingId = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
