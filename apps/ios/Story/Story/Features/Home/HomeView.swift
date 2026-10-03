import SwiftUI
import SwiftData

// Home — the frozen Figma entry point (ScreenHome). Two layouts:
//  • no active Story: "What would you like to make?" + the three make-paths.
//  • with Stories: a "Your Stories" list, active first then completed.
// Create Now is a frozen future path (DIRECT-one-off) with no persistent-Story
// backing yet → intentionally disabled. Use-existing (analyze) is disabled
// (AssetUnderstanding). Start a Story is wired to the real C1 flow.
// See ui-capability-matrix.md.
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query private var stories: [StoryModel]

    // Active Stories first (most recent first), then completed below.
    private var sortedStories: [StoryModel] {
        stories.sorted { a, b in
            if a.status != b.status { return a.status == .active }   // active above completed
            return a.createdAt > b.createdAt
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    StoryEyebrow(text: "Story").padding(.top, 32)

                    Text("What would you like to make?")
                        .font(StoryTheme.display(30))
                        .foregroundStyle(StoryTheme.cream)

                    // Make-paths
                    VStack(spacing: 14) {
                        NavigationLink { CreativeDirectionView() } label: {
                            makeCard(eyebrow: "Over time", title: "Start a Story",
                                     sub: "Capture an experience as it unfolds.", enabled: true)
                        }
                        .buttonStyle(.plain)

                        // Create Now — frozen path, no backing yet (disabled).
                        makeCard(eyebrow: "Right now", title: "Create now",
                                 sub: "Make something here, in this moment.", enabled: false)
                            .accessibilityHint("Not available yet")

                        // Use existing (analyze) — disabled (AssetUnderstanding).
                        Text("Use photos & videos I already have")
                            .font(StoryTheme.body(14))
                            .foregroundStyle(StoryTheme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityHint("Not available yet")
                    }

                    if !sortedStories.isEmpty {
                        StorySectionHeader(text: "Your Stories").padding(.top, 4)
                        VStack(spacing: 12) {
                            ForEach(sortedStories) { story in
                                NavigationLink { StoryHomeView(story: story) } label: {
                                    storyRow(story)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, StoryTheme.screenPadding)
            }
            .storyBackground()
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(StoryTheme.gold)
    }

    private func makeCard(eyebrow: String, title: String, sub: String, enabled: Bool) -> some View {
        StoryCard(enabled: enabled) {
            VStack(alignment: .leading, spacing: 6) {
                StoryEyebrow(text: eyebrow)
                Text(title).font(StoryTheme.display(22))
                    .foregroundStyle(enabled ? StoryTheme.cream : StoryTheme.textMuted)
                Text(sub).font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textSecondary)
            }
        }
    }

    private func storyRow(_ story: StoryModel) -> some View {
        StoryCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(story.title).font(StoryTheme.display(20)).foregroundStyle(StoryTheme.cream)
                    Text("\(story.moments.count) moment\(story.moments.count == 1 ? "" : "s")")
                        .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.textSecondary)
                }
                Spacer()
                StoryStatusPill(status: story.status)
            }
        }
    }
}
