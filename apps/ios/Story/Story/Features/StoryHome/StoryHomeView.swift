import SwiftUI
import SwiftData
import AVKit

// Story Home — frozen Figma persistent Story hub (ScreenTMB), implemented
// generically off the real StoryModel. Wired: Shoot a Moment (DIRECT, C1-C3),
// Moments, Complete/Reopen lifecycle, add existing media. Disabled-future
// (ui-capability-matrix): real Story generation, Story Guide, Story Idea,
// music. The TMB chapter/guide copy in Figma is DEMO content — never pasted
// here as fake guidance; the Guide/Idea show a neutral unavailable state.
struct StoryHomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var story: StoryModel

    @State private var showCapture = false
    @State private var showMenu = false
    @State private var showPreview = false
    @State private var pickerItems = false

    private var useCases: StoryUseCases {
        StoryUseCases(repository: StoryRepository(context: context))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Header row: status + menu
                HStack {
                    StoryStatusPill(status: story.status)
                    Spacer()
                    Button { showMenu = true } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(StoryTheme.cream).padding(8)
                    }
                    .accessibilityLabel("Story options")
                }

                // Story summary (the user-facing thesis; NOT raw intent fields)
                Text(story.intentSummary.isEmpty ? story.title : story.intentSummary)
                    .font(StoryTheme.display(24))
                    .foregroundStyle(StoryTheme.cream)
                    .fixedSize(horizontal: false, vertical: true)

                Text(stateLine).font(StoryTheme.body(15)).foregroundStyle(StoryTheme.textSecondary)

                #if DEBUG
                IntentChipsDebug(story: story)   // diagnostics only
                #endif

                // Moments
                StorySectionHeader(text: "Moments (\(story.moments.count))")
                if story.moments.isEmpty {
                    StoryEmptyState(text: "Your moments will appear here. Shoot one to begin.")
                } else {
                    ForEach(story.moments.sorted(by: { $0.createdAt < $1.createdAt })) { m in
                        MomentCardRow(moment: m)
                    }
                }
                Button { pickerItems = true } label: {
                    Text("+ Add photos or videos")
                        .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.gold)
                }

                // Story Guide — neutral unavailable (no StoryBlueprint capability).
                StoryUnavailableSection(header: { StoryEyebrow(text: "Story Guide") },
                    message: "Story will suggest what to capture next as your Story grows. Not available yet.")

                // Actions
                VStack(spacing: 12) {
                    if story.status == .active {
                        StoryPrimaryButton(title: "Shoot a moment") { showCapture = true }
                    }
                    // Create My Story → preview; real generation disabled downstream.
                    StorySecondaryButton(title: "Create my Story") { showPreview = true }
                        .disabled(story.moments.isEmpty)
                        .opacity(story.moments.isEmpty ? 0.4 : 1)
                }
                .padding(.top, 4)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, StoryTheme.screenPadding)
            .padding(.top, 8)
        }
        .storyBackground()
        .navigationTitle(story.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCapture) { ShootMomentView(story: story) }
        .navigationDestination(isPresented: $showPreview) { CreateStoryPreviewView(story: story) }
        .photosPickerSheet(isPresented: $pickerItems) { picked in
            try? useCases.addExistingMedia(to: story, relativePaths: picked)
        }
        .confirmationDialog("Story options", isPresented: $showMenu, titleVisibility: .visible) {
            if story.status == .active {
                Button("Complete Story") { try? useCases.completeStory(story) }
            } else {
                Button("Reopen Story") { try? useCases.reopenStory(story) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(story.status == .active
                 ? "This moves the Story out of your active Stories. You can still view Moments and reopen it anytime."
                 : "Reopen this Story and move it back to active.")
        }
    }

    private var stateLine: String {
        if story.status == .completed { return "Everything from your Story, in one place." }
        if story.moments.isEmpty { return "Your Story is ready to begin." }
        return "Your Story is taking shape."
    }
}

// Moment card (frozen Figma Moment presentation; consumer language, not source enum).
private struct MomentCardRow: View {
    let moment: MomentModel
    var body: some View {
        StoryCard {
            HStack(spacing: 12) {
                if let asset = moment.asset,
                   MediaStore.shared.fileExists(relativePath: asset.relativePath) {
                    VideoPlayer(player: AVPlayer(url: MediaStore.shared.absoluteURL(for: asset.relativePath)))
                        .frame(width: 110, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(StoryTheme.surfaceAlt)
                        .frame(width: 110, height: 74)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(momentLabel).font(StoryTheme.body(15)).foregroundStyle(StoryTheme.cream)
                    if let a = moment.asset {
                        Text(String(format: "%.0fs", a.durationSeconds))
                            .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.textSecondary)
                    }
                }
                Spacer()
            }
        }
    }
    private var momentLabel: String {
        switch moment.source {
        case .directed, .spontaneous: return "Captured moment"
        case .existingMedia, .cameraImport: return "From your library"
        }
    }
}

#if DEBUG
// DEBUG-only: the raw resolved CreativeIntent, for evaluation. Not consumer UX.
private struct IntentChipsDebug: View {
    @Bindable var story: StoryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StoryEyebrow(text: "DEBUG · What Story understood")
            Text((story.intentDesiredFeeling + story.intentEmphasis).joined(separator: " · "))
                .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(StoryTheme.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
#endif
