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
            VStack(alignment: .leading, spacing: 18) {
                // Header: inline title + status + menu (Figma composition)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(story.title).font(StoryTheme.display(26)).foregroundStyle(StoryTheme.cream)
                        Text(story.status == .completed ? "Completed" : "Active")
                            .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.textMuted)
                    }
                    Spacer()
                    Button { showMenu = true } label: {
                        Image(systemName: "ellipsis").foregroundStyle(StoryTheme.cream).padding(8)
                    }.accessibilityLabel("Story options")
                }

                Text(stateLine).font(StoryTheme.display(20)).foregroundStyle(StoryTheme.cream)

                // Moments mosaic (Figma: photo grid, count overlaid on last tile)
                MomentsMosaic(moments: story.moments.sorted(by: { $0.createdAt < $1.createdAt }))

                // Primary + quiet secondary (Figma hierarchy)
                VStack(spacing: 10) {
                    if story.status == .active {
                        StoryPrimaryButton(title: "Shoot a moment") { showCapture = true }
                    }
                    Button { showPreview = true } label: {
                        Text("Create my Story").font(StoryTheme.body(15))
                            .foregroundStyle(story.moments.isEmpty ? StoryTheme.textMuted : StoryTheme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .disabled(story.moments.isEmpty)
                }

                Button { pickerItems = true } label: {
                    Text("+ Add photos or videos")
                        .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.gold)
                }

                Divider().overlay(StoryTheme.cream.opacity(0.08)).padding(.vertical, 2)

                // Story Idea — neutral unavailable (NOT TMB demo copy)
                VStack(alignment: .leading, spacing: 6) {
                    StoryEyebrow(text: "✦ Story Idea")
                    Text("Ideas for what to capture next")
                        .font(StoryTheme.display(18)).foregroundStyle(StoryTheme.textSecondary)
                    Text("Story will suggest ideas as your Story grows. Not available yet.")
                        .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.textMuted)
                }

                Divider().overlay(StoryTheme.cream.opacity(0.08)).padding(.vertical, 2)

                // Story Guide — neutral unavailable
                VStack(alignment: .leading, spacing: 6) {
                    StoryEyebrow(text: "Story Guide")
                    Text("A guide to what would make your Story stronger — coming in a later update.")
                        .font(StoryTheme.body(13).italic()).foregroundStyle(StoryTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                #if DEBUG
                if AppMode.current.showsDiagnostics {
                    IntentChipsDebug(story: story)   // AI-debug mode only
                }
                #endif

                Spacer(minLength: 20)
            }
            .padding(.horizontal, StoryTheme.screenPadding)
            .padding(.top, 8)
        }
        .storyBackground()
        .toolbar(.hidden, for: .navigationBar)
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

// Moments mosaic (frozen Figma: a 3-column photo grid; the moment count is
// overlaid on the last visible tile; graceful empty + partial states).
private struct MomentsMosaic: View {
    let moments: [MomentModel]
    private let cols = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]

    var body: some View {
        if moments.isEmpty {
            RoundedRectangle(cornerRadius: StoryTheme.card)
                .fill(StoryTheme.surfaceAlt)
                .frame(height: 150)
                .overlay(Text("Your moments will appear here")
                    .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textMuted))
        } else {
            let shown = Array(moments.prefix(6))
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, m in
                    tile(m, overlayCount: idx == shown.count - 1 && moments.count > 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: StoryTheme.card))
        }
    }

    private func tile(_ m: MomentModel, overlayCount: Bool) -> some View {
        ZStack {
            if let a = m.asset, MediaStore.shared.fileExists(relativePath: a.relativePath) {
                VideoPlayer(player: AVPlayer(url: MediaStore.shared.absoluteURL(for: a.relativePath)))
            } else {
                StoryTheme.surfaceAlt
            }
            if overlayCount {
                LinearGradient(colors: [.clear, StoryTheme.ink.opacity(0.75)],
                               startPoint: .center, endPoint: .bottom)
                Text("\(moments.count) moment\(moments.count == 1 ? "" : "s") →")
                    .font(StoryTheme.body(12, .medium)).foregroundStyle(StoryTheme.cream)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
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
