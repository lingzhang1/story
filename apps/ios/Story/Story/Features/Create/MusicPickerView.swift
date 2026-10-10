import SwiftUI
import AVKit

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

    init(recommendation: MusicSelectionResolver.Recommendation, onChoose: @escaping (Choice) -> Void) {
        self.recommendation = recommendation
        self.onChoose = onChoose
        // Default to the AI-recommended top track.
        _pendingTrackId = State(initialValue: recommendation.topTrackId ?? recommendation.candidates.first?.trackId ?? "")
    }

    var body: some View {
        ZStack {
            StoryTheme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Each track shapes a different edit — Story cuts the moments and pacing to fit.")
                            .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.36))
                            .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 14).padding(.bottom, 6)
                        ForEach(recommendation.candidates) { track in
                            trackRow(track)
                        }
                    }
                }
                footer
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackToDismiss(dismiss)
        .onDisappear { stopPreview() }
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
                            .opacity(track.trackId == recommendation.topTrackId ? 1 : 0)
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
        let p = AVPlayer(url: url)   // Epidemic previews are signed HLS (.m3u8); AVPlayer handles streaming.
        player = p
        playingTrackId = track.trackId
        p.play()
    }

    private func stopPreview() {
        player?.pause()
        player = nil
        playingTrackId = nil
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
