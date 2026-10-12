import SwiftUI
import AVKit
import AVFoundation
import SwiftData
import UniformTypeIdentifiers

// MusicPickerView — R-d final picker (frozen Figma ScreenTMBMusic "Recommended for your Story").
//
// Replaces the silent auto-selection with a visible recommendation step: the AI-ranked TOP track is selected
// by DEFAULT; the user can preview any candidate, pick a different one, or create WITHOUT music. The screen
// shows only consumer-facing info (title, length, a short mood line) — NEVER raw BPM / beats / MusicAnalysis.
//
// Outcome is handed back via onChoose(.track(id)) / onChoose(.noMusic) / onChoose(.cancel). The CALLER
// (CreateStoryPreviewView) owns resolving the chosen track into a MusicSelection and starting creation, so the
// displayed selection is exactly what renders (no stale plan for another track).
struct MusicPickerView: View {
    let recommendation: MusicSelectionResolver.Recommendation
    let onChoose: (Choice) -> Void

    enum Choice: Equatable {
        case track(String)          // create WITH this provider track id
        case myMusic(String)        // create WITH this imported My Music asset id (UUID string)
        case noMusic                // create without music
        case cancel                 // back out, no change
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var pendingTrackId: String
    @State private var player: AVPlayer?
    @State private var playingTrackId: String?

    // M-e: imported "My Music" is a FIRST-CLASS source in this picker (create time AND Change Music), shown
    // alongside the provider recommendations. The library persists across Stories; import is via the Files picker.
    @Query(sort: \MyMusicAssetModel.createdAt, order: .reverse) private var myMusic: [MyMusicAssetModel]
    @State private var importingFile = false
    @State private var importError: String?
    @State private var myMusicPlayingId: UUID?
    @State private var pickerTab: PickerTab = .songs

    // Free-text search + load-more pagination (overlays the recommended list when a query is active).
    @State private var searchText: String = ""
    @State private var searchResults: [MusicCandidateDTO] = []
    @State private var searchCursor: String? = nil
    @State private var searching: Bool = false
    @State private var loadingMore: Bool = false
    @State private var searchError: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil
    private let music = MusicCandidatesService()

    // "Next page" over the RECOMMENDATIONS: each page replaces the list with a different ranked set for the
    // same Story. Page 1 is the injected recommendation; later pages are fetched via the resolver.
    @State private var pages: [MusicSelectionResolver.Recommendation]
    @State private var pageIndex: Int = 0
    @State private var loadingPage: Bool = false
    private let resolver: MusicSelectionResolver?
    private let targetDurationSeconds: Double
    /// The recommendation currently shown (the active page).
    private var currentRec: MusicSelectionResolver.Recommendation { pages[pageIndex] }

    /// True while the user is actively searching (non-empty query). Drives list switch recommended <-> results.
    private var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    init(recommendation: MusicSelectionResolver.Recommendation,
         resolver: MusicSelectionResolver? = nil, targetDurationSeconds: Double = 0,
         onChoose: @escaping (Choice) -> Void) {
        self.recommendation = recommendation
        self.resolver = resolver
        self.targetDurationSeconds = targetDurationSeconds
        self.onChoose = onChoose
        _pages = State(initialValue: [recommendation])
        // Default to the AI-recommended top track.
        _pendingTrackId = State(initialValue: recommendation.topTrackId ?? recommendation.candidates.first?.trackId ?? "")
    }

    var body: some View {
        ZStack {
            StoryTheme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                tabBar
                searchBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if isSearchActive {
                            searchResultsList
                        } else if pickerTab == .myMusic {
                            // My Music tab: imported tracks + saved favorites + Import. (No long packed list.)
                            myMusicSection
                        } else {
                            // Songs tab: provider recommendations only.
                            Text("Each track shapes a different edit — Story cuts the moments and pacing to fit.")
                                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.36))
                                .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 12).padding(.bottom, 6)
                            if currentRec.candidates.isEmpty {
                                Text("No suggestions right now — switch to My Music, or create without music.")
                                    .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                                    .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 10)
                            }
                            ForEach(currentRec.candidates) { track in
                                trackRow(track)
                            }
                            pager
                        }
                    }
                }
                footer
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackToDismiss(dismiss)
        .fileImporter(isPresented: $importingFile,
                      allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                      allowsMultipleSelection: false) { handleFileImport($0) }
        .onDisappear { searchTask?.cancel(); stopPreview(); stopMyMusicPreview() }
    }

    private enum PickerTab { case songs, myMusic }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Songs", .songs)
            tabButton("My Music", .myMusic)
        }
        .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 10)
    }

    private func tabButton(_ title: String, _ tab: PickerTab) -> some View {
        let active = pickerTab == tab
        return Button {
            stopPreview(); stopMyMusicPreview()
            pickerTab = tab
        } label: {
            VStack(spacing: 7) {
                Text(title).font(StoryTheme.body(14, active ? .semibold : .regular))
                    .foregroundStyle(active ? StoryTheme.cream : StoryTheme.cream.opacity(0.4))
                Rectangle().fill(active ? StoryTheme.gold : .clear).frame(height: 2)
            }
            .frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
    }

    // MARK: - recommendation pager (Next page = different options)

    @ViewBuilder private var pager: some View {
        if resolver != nil {
            HStack(spacing: 12) {
                if pageIndex > 0 {
                    Button { stopPreview(); pageIndex -= 1 } label: {
                        Text("‹ Back").font(StoryTheme.body(14, .semibold)).foregroundStyle(StoryTheme.cream.opacity(0.7))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("Page \(pageIndex + 1)").font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
                Spacer()
                // Next is available if we're not on the last-known page, or the current page has a cursor to fetch.
                if pageIndex < pages.count - 1 || currentRec.nextCursor != nil {
                    Button { goNextPage() } label: {
                        if loadingPage { ProgressView().tint(StoryTheme.gold) }
                        else { Text("Next page ›").font(StoryTheme.body(14, .semibold)).foregroundStyle(StoryTheme.gold) }
                    }.buttonStyle(.plain).disabled(loadingPage)
                }
            }
            .padding(.horizontal, StoryTheme.screenPadding).padding(.vertical, 16)
        }
    }

    private func goNextPage() {
        stopPreview()
        // already fetched this next page -> just advance
        if pageIndex < pages.count - 1 { pageIndex += 1; return }
        guard let resolver, currentRec.nextCursor != nil, !loadingPage else { return }
        loadingPage = true
        Task {
            let next = await resolver.nextPage(from: currentRec, targetDurationSeconds: targetDurationSeconds)
            await MainActor.run {
                loadingPage = false
                if let next, !next.candidates.isEmpty {
                    pages.append(next)
                    pageIndex += 1
                }
            }
        }
    }

    // MARK: - search bar + results

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(StoryTheme.cream.opacity(0.4))
            TextField("", text: $searchText, prompt: Text("Search all music")
                        .foregroundColor(StoryTheme.cream.opacity(0.35)))
                .foregroundStyle(StoryTheme.cream)
                .font(StoryTheme.body(15))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { runSearch(reset: true) }
                .onChange(of: searchText) { _, _ in scheduleSearch() }
            if !searchText.isEmpty {
                Button { clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(StoryTheme.cream.opacity(0.4))
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(StoryTheme.cream.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 12)
    }

    @ViewBuilder private var searchResultsList: some View {
        if searching && searchResults.isEmpty {
            HStack { Spacer(); ProgressView().tint(StoryTheme.cream); Spacer() }
                .padding(.top, 28)
        } else if let err = searchError, searchResults.isEmpty {
            Text(err).font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.5))
                .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 20)
        } else if searchResults.isEmpty {
            Text("No tracks match “\(searchText)”.")
                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 20)
        } else {
            Text("Results").font(StoryTheme.body(10)).tracking(1.3)
                .foregroundStyle(StoryTheme.cream.opacity(0.22))
                .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 14).padding(.bottom, 4)
            ForEach(searchResults) { track in trackRow(track) }
            if searchCursor != nil {
                Button { loadMore() } label: {
                    HStack {
                        Spacer()
                        if loadingMore { ProgressView().tint(StoryTheme.cream) }
                        else { Text("Load more").font(StoryTheme.body(14, .semibold)).foregroundStyle(StoryTheme.gold) }
                        Spacer()
                    }.padding(.vertical, 14)
                }.buttonStyle(.plain).disabled(loadingMore)
            }
        }
    }

    // Debounce typing: cancel the in-flight schedule and re-run after a short pause.
    private func scheduleSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchResults = []; searchCursor = nil; searchError = nil; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            runSearch(reset: true)
        }
    }

    private func runSearch(reset: Bool) {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true; searchError = nil
        if reset { searchResults = []; searchCursor = nil }
        Task {
            do {
                let page = try await music.searchPage(query: q, pageSize: 12, cursor: nil)
                await MainActor.run {
                    searchResults = page.candidates
                    searchCursor = page.nextCursor
                    searching = false
                }
            } catch {
                await MainActor.run {
                    searching = false
                    searchError = (error as? MusicServiceError)?.errorDescription ?? "Search unavailable."
                }
            }
        }
    }

    private func loadMore() {
        guard let cursor = searchCursor, !loadingMore else { return }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        loadingMore = true
        Task {
            do {
                let page = try await music.searchPage(query: q, pageSize: 12, cursor: cursor)
                await MainActor.run {
                    searchResults.append(contentsOf: page.candidates)
                    searchCursor = page.nextCursor
                    loadingMore = false
                }
            } catch {
                await MainActor.run { loadingMore = false }
            }
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchText = ""; searchResults = []; searchCursor = nil; searchError = nil; searching = false
    }

    // MARK: - My Music (imported) — shared source, non-search mode

    @ViewBuilder private var myMusicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Imported & saved tracks — reusable in every Story.")
                    .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                Spacer()
                Text("build \(StoryCreativeRefinement.buildIdentifier)")
                    .font(StoryTheme.body(9)).foregroundStyle(StoryTheme.cream.opacity(0.18))
            }
            .padding(.top, 12)

            if myMusic.isEmpty {
                Text("Nothing here yet. Import your own audio, or save a track from Songs with ☆.")
                    .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.35)).padding(.top, 4)
            } else {
                ForEach(myMusic) { asset in myMusicRow(asset) }
            }

            Button { importingFile = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 19)).foregroundStyle(StoryTheme.cream.opacity(0.7))
                    Text("Import from Files…").font(StoryTheme.body(15)).foregroundStyle(StoryTheme.cream)
                    Spacer()
                }
                .padding(.vertical, 13).padding(.horizontal, 14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(StoryTheme.cream.opacity(0.14), lineWidth: 1.5))
            }.buttonStyle(.plain)

            if let e = importError {
                Text(e).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.gold)
            }
        }
        .padding(.horizontal, StoryTheme.screenPadding)
        .padding(.bottom, 10)
    }

    private func myMusicRow(_ asset: MyMusicAssetModel) -> some View {
        HStack(spacing: 12) {
            Button {
                if myMusicPlayingId == asset.id { stopMyMusicPreview() }
                else { startMyMusicPreview(asset) }
            } label: {
                Image(systemName: myMusicPlayingId == asset.id ? "pause.circle.fill" : "play.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(asset.isProviderFavorite ? StoryTheme.gold.opacity(0.3) : StoryTheme.gold)
            }.buttonStyle(.plain).disabled(asset.isProviderFavorite)   // favorites have no local bytes to preview

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.displayName).font(StoryTheme.body(15)).foregroundStyle(StoryTheme.cream).lineLimit(1)
                Text("\(asset.isProviderFavorite ? "Saved" : "My Music") · \(Self.time(asset.durationSeconds))")
                    .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.cream.opacity(0.35))
            }
            Spacer()
            Button { stopPreview(); stopMyMusicPreview(); onChoose(.myMusic(asset.id.uuidString)) } label: {
                Text("Use").font(StoryTheme.body(13, .medium)).foregroundStyle(StoryTheme.ink)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Capsule().fill(StoryTheme.gold))
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(StoryTheme.cream.opacity(0.04)))
        .contextMenu {
            Button("Remove", role: .destructive) { MyMusicStore.shared.remove(asset, from: modelContext) }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e): importError = "Import failed: \(e.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let asset = try MyMusicStore.shared.importAudio(from: url, into: modelContext)
                importError = nil
                // A fresh import is usually what the user wants to use right now.
                stopPreview(); stopMyMusicPreview(); onChoose(.myMusic(asset.id.uuidString))
            } catch {
                importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func startMyMusicPreview(_ asset: MyMusicAssetModel) {
        stopPreview()
        guard MyMusicStore.shared.exists(asset) else { importError = "That track's file is missing."; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: MyMusicStore.shared.absoluteURL(for: asset.relativePath))
        player = p; myMusicPlayingId = asset.id; p.play()
    }

    private func stopMyMusicPreview() {
        if myMusicPlayingId != nil { player?.pause(); player = nil; myMusicPlayingId = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
    }

    private static func time(_ s: Double) -> String {
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Whether this provider track is already saved as a favorite in Your music.
    private func isSaved(_ track: MusicCandidateDTO) -> Bool {
        myMusic.contains { $0.providerTrackId == track.trackId }
    }

    /// Save/unsave a provider track as a licensing-safe favorite (reference only, no bytes).
    private func toggleSaveFavorite(_ track: MusicCandidateDTO) {
        if let existing = myMusic.first(where: { $0.providerTrackId == track.trackId }) {
            MyMusicStore.shared.remove(existing, from: modelContext)   // a reference has no file; row is removed
        } else {
            MyMusicStore.shared.saveProviderFavorite(trackId: track.trackId, title: track.title,
                                                     durationSeconds: track.durationSeconds, into: modelContext)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { stopPreview(); onChoose(.cancel) } label: {
                Text("←").font(StoryTheme.body(18)).foregroundStyle(StoryTheme.cream.opacity(0.3))
                    .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 5) {
                Text("CHOOSE MUSIC").font(StoryTheme.body(10)).tracking(1.3)
                    .foregroundStyle(StoryTheme.cream.opacity(0.22))
                Text("Recommended for your Story")
                    .font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
            }
            Spacer()
        }
        .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 8)
    }

    private func trackRow(_ track: MusicCandidateDTO) -> some View {
        let selected = pendingTrackId == track.trackId
        let playing = playingTrackId == track.trackId
        return Button {
            pendingTrackId = track.trackId
        } label: {
            HStack(alignment: .top, spacing: 14) {
                // Play/pause preview dot.
                Button {
                    if playing { stopPreview() } else { startPreview(track) }
                } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle")
                        .font(.system(size: 30)).foregroundStyle(StoryTheme.cream.opacity(0.8))
                }
                .buttonStyle(.plain)
                .disabled(track.previewURLString == nil)
                .accessibilityLabel(playing ? "Pause preview" : "Preview \(track.title)")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(track.title).font(StoryTheme.display(18)).foregroundStyle(StoryTheme.cream)
                        Spacer()
                        // Save to My Music (★) — licensing-safe REFERENCE, not a byte copy. Filled when saved.
                        Button { toggleSaveFavorite(track) } label: {
                            Image(systemName: isSaved(track) ? "star.fill" : "star")
                                .font(.system(size: 15)).foregroundStyle(StoryTheme.gold.opacity(isSaved(track) ? 0.9 : 0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSaved(track) ? "Saved to My Music" : "Save to My Music")
                        Text(Self.lengthLabel(track.durationSeconds))
                            .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
                    }
                    Text(Self.moodLine(track))
                        .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.5))
                    if selected {
                        Text("Story's pick").font(StoryTheme.displayItalic(13))
                            .foregroundStyle(StoryTheme.cream.opacity(0.45)).padding(.top, 6)
                            .opacity(track.trackId == currentRec.topTrackId ? 1 : 0)
                    }
                }
                if selected {
                    Text("Selected ✓").font(StoryTheme.body(12, .semibold))
                        .foregroundStyle(StoryTheme.gold).padding(.top, 4)
                }
            }
            .padding(.vertical, 16).padding(.horizontal, 14)
            .background(selected ? StoryTheme.gold.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(selected ? StoryTheme.gold.opacity(0.22) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, StoryTheme.screenPadding - 14)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if pickerTab == .songs && !pendingTrackId.isEmpty {
                StoryPrimaryButton(title: "Use this music") {
                    stopPreview()
                    onChoose(.track(pendingTrackId))
                }
            }
            Button { stopPreview(); onChoose(.noMusic) } label: {
                Text("Create without music")
                    .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.5))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 12).padding(.bottom, 40)
        .background(StoryTheme.ink)
    }

    // MARK: - preview playback

    private func startPreview(_ track: MusicCandidateDTO) {
        guard let s = track.previewURLString, let url = URL(string: s) else { return }
        stopPreview()
        // Route preview audio through the .playback category so it is audible even with the hardware mute
        // switch ON (the default ambient category is silenced by the mute switch — the usual cause of a
        // preview that "won't play"). Best-effort: a session failure must not crash the picker.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: url)   // Epidemic previews are signed HLS (.m3u8); AVPlayer handles streaming.
        player = p
        playingTrackId = track.trackId
        p.play()
    }

    private func stopPreview() {
        player?.pause()
        player = nil
        playingTrackId = nil
        // Release the audio session so it does not keep other audio ducked after previewing.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - consumer copy (NO BPM / beats / analysis)

    private static func lengthLabel(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A short, human mood line — vocal presence only (never numeric analysis).
    private static func moodLine(_ t: MusicCandidateDTO) -> String {
        switch (t.vocalType ?? "NONE").uppercased() {
        case "NONE": return "Instrumental"
        case "PRESENCE": return "Light vocals"
        case "LEAD": return "Vocal-led"
        default: return "Instrumental"
        }
    }
}
