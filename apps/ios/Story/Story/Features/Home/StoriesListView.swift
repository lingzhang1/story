import SwiftUI
import SwiftData

// StoriesListView — the "Stories" destination from Home (Figma MVP V0.2.2):
// the user's projects and films, active first then completed. Rows open the
// existing StoryHomeView unchanged. Extracted from the old HomeView
// active-Story layout so Home itself stays the two-primary / two-secondary hub.
struct StoriesListView: View {
    @Query private var stories: [StoryModel]

    private var sortedStories: [StoryModel] {
        stories.sorted { a, b in
            if a.status != b.status { return a.status == .active }
            return a.createdAt > b.createdAt
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                StoryEyebrow(text: "Your Stories").padding(.top, 24).padding(.bottom, 16)

                if sortedStories.isEmpty {
                    VStack(spacing: 8) {
                        Text("No Stories yet")
                            .font(StoryTheme.display(20)).foregroundStyle(StoryTheme.cream)
                        Text("Start a Story from Home to see your projects and films here.")
                            .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    VStack(spacing: 8) {
                        ForEach(sortedStories) { story in
                            NavigationLink { StoryHomeView(story: story) } label: {
                                storyRow(story).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
        .storyBackground()
        .navigationTitle("Stories")
        .navigationBarTitleDisplayMode(.inline)
        .tint(StoryTheme.gold)
    }

    private func storyRow(_ story: StoryModel) -> some View {
        VStack(spacing: 0) {
            StoryMosaicStrip(height: 72, startIndex: story.status == .completed ? 3 : 0)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(story.title.displayTitle).font(StoryTheme.display(15))
                        .foregroundStyle(StoryTheme.cream.opacity(0.8))
                    Text("\(story.status == .completed ? "Completed · " : "")\(story.moments.count) moment\(story.moments.count == 1 ? "" : "s")")
                        .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.cream.opacity(0.3))
                }
                Spacer()
                Text(story.status == .completed ? "View →" : "Open →")
                    .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 13)
            .frame(maxWidth: .infinity)
            .background(StoryTheme.cream.opacity(0.02))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StoryTheme.cream.opacity(0.07), lineWidth: 1))
    }
}
