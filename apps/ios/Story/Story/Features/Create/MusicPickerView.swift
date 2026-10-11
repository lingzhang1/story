import SwiftUI
import AVKit
import AVFoundation

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
        case track(String)   // create WITH this track id
        case noMusic         // create without music
        case cancel          // back out, no change
    }

    @Environment(\.dismiss) private var dismiss
    @State private var pendingTrackId: String
    @State private var player: AVPlayer?
    @State private var playingTrackId: String?

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
                searchBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if isSearchActive {
                            searchResultsList
                        } else {
                            Text("Each track shapes a different edit — Story cuts the moments and pacing to fit.")
                                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.36))
                                .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 14).padding(.bottom, 6)
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
        .onDisappear { searchTask?.cancel(); stopPreview() }
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
            StoryPrimaryButton(title: "Use this music") {
                stopPreview()
                onChoose(.track(pendingTrackId))
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
