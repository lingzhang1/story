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
                VStack(alignment: .leading, spacing: 0) {
                    StoryEyebrow(text: "Story").padding(.top, 32).padding(.bottom, 22)

                    if sortedStories.isEmpty {
                        noActiveStoryLayout
                    } else {
                        activeStoryLayout
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .storyBackground()
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(StoryTheme.gold)
    }

    // ── No active Story: creation-first (Figma: title + 2 image cards + link).
    //    NOTE: Figma shows NO "Your Stories" list in this state.
    private var noActiveStoryLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What would you like to make?")
                .font(StoryTheme.display(28))
                .foregroundStyle(StoryTheme.cream)
                .lineSpacing(2)
                .padding(.bottom, 22)

            // Create now — frozen future path, disabled (no persistent backing).
            StoryImageCard(image: "ph_city", eyebrow: "Right now", title: "Create now",
                           sub: "Make something here, in this moment.", enabled: false)
                .padding(.bottom, 10)
                .accessibilityHint("Not available yet")

            // Start a Story — wired to real C1 flow.
            NavigationLink { CreativeDirectionView() } label: {
                StoryImageCard(image: "ph_alpine", eyebrow: "Over time", title: "Start a Story",
                               sub: "Capture an experience as it unfolds.")
            }
            .buttonStyle(.plain)
            .padding(.bottom, 22)

            // Use existing (analyze) — disabled (AssetUnderstanding).
            Text("Use photos & videos I already have")
                .font(StoryTheme.body(13))
                .foregroundStyle(StoryTheme.cream.opacity(0.28))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 32)
                .accessibilityHint("Not available yet")
        }
    }

    // ── Active Story: Continue hero + Create section + Your Stories list.
    private var activeStoryLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            let active = sortedStories.filter { $0.status == .active }
            let completed = sortedStories.filter { $0.status == .completed }

            // Continue — primary hero for the most recent active Story.
            if let hero = active.first {
                StoryEyebrow(text: "Continue").padding(.bottom, 11)
                NavigationLink { StoryHomeView(story: hero) } label: { heroCard(hero) }
                    .buttonStyle(.plain)
                    .padding(.bottom, 32)
            }

            // Create section — compact image cards (both future/disabled here;
            // Start a Story remains the wired path).
            StoryEyebrow(text: "Create").padding(.bottom, 11)
            StoryImageCard(image: "ph_city", eyebrow: "Right now", title: "Create now",
                           sub: "", enabled: false, titleSize: 18)
                .padding(.bottom, 8)
                .accessibilityHint("Not available yet")
            NavigationLink { CreativeDirectionView() } label: {
                StoryImageCard(image: "ph_alpine", eyebrow: "Over time", title: "Start a Story",
                               sub: "", titleSize: 18)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)

            // Your Stories — remaining active + completed below.
            StoryEyebrow(text: "Your Stories").padding(.bottom, 11)
            VStack(spacing: 8) {
                ForEach(Array(active.dropFirst()) + completed) { story in
                    NavigationLink { StoryHomeView(story: story) } label: { storyRow(story) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // Continue hero card: mosaic strip + body (title / state / Continue →).
    private func heroCard(_ story: StoryModel) -> some View {
        VStack(spacing: 0) {
            StoryMosaicStrip(height: 110)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(story.title).font(StoryTheme.display(18)).foregroundStyle(StoryTheme.cream)
                    Text(momentSub(story)).font(StoryTheme.body(11))
                        .foregroundStyle(StoryTheme.cream.opacity(0.5))
                }
                Spacer()
                Text("Continue →").font(StoryTheme.body(13))
                    .foregroundStyle(StoryTheme.cream.opacity(0.38))
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(StoryTheme.cream.opacity(0.03))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(StoryTheme.cream.opacity(0.09), lineWidth: 1))
    }

    private func momentSub(_ story: StoryModel) -> String {
        let n = story.moments.count
        return n == 0 ? "Your Story is taking shape" : "\(n) moment\(n == 1 ? "" : "s")"
    }

    private func storyRow(_ story: StoryModel) -> some View {
        VStack(spacing: 0) {
            StoryMosaicStrip(height: 56, startIndex: story.status == .completed ? 3 : 0)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(story.title).font(StoryTheme.display(14))
                        .foregroundStyle(StoryTheme.cream.opacity(0.6))
                    Text("\(story.status == .completed ? "Completed · " : "")\(story.moments.count) moment\(story.moments.count == 1 ? "" : "s")")
                        .font(StoryTheme.body(10)).foregroundStyle(StoryTheme.cream.opacity(0.2))
                }
                Spacer()
                Text(story.status == .completed ? "View →" : "Open →")
                    .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.cream.opacity(0.2))
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(StoryTheme.cream.opacity(0.02))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StoryTheme.cream.opacity(0.07), lineWidth: 1))
    }
}
