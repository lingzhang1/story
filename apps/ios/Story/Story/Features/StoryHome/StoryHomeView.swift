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
            VStack(alignment: .leading, spacing: 0) {
                // Header: ← back · title + Day/status · ••• menu (Figma inline row)
                HStack(alignment: .top, spacing: 12) {
                    Button { dismiss() } label: {
                        Text("←").font(StoryTheme.body(18))
                            .foregroundStyle(StoryTheme.cream.opacity(0.4))
                            .frame(width: 44, height: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(story.title).font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
                        Text(story.status == .completed ? "Completed" : "Active")
                            .font(StoryTheme.body(11)).tracking(0.5)
                            .foregroundStyle(story.status == .completed ? StoryTheme.gold : StoryTheme.cream.opacity(0.22))
                    }
                    Spacer()
                    Button { showMenu = true } label: {
                        Text("•••").font(StoryTheme.body(16))
                            .foregroundStyle(StoryTheme.cream.opacity(0.4))
                            .frame(width: 44, height: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Story options")
                }
                .padding(.top, 8)

                Text(stateLine).font(StoryTheme.display(17))
                    .foregroundStyle(StoryTheme.cream.opacity(0.7))
                    .lineSpacing(2)
                    .padding(.top, 20)

                // Moments mosaic (Figma: 3-col square grid, count overlaid)
                MomentsMosaic(moments: story.moments.sorted(by: { $0.createdAt < $1.createdAt }))
                    .padding(.top, 16)

                // Primary cream pill + quiet secondary text (Figma hierarchy)
                VStack(spacing: 14) {
                    if story.status == .active {
                        StoryPrimaryButton(title: "Shoot a moment") { showCapture = true }
                    }
                    Button { showPreview = true } label: {
                        Text("Create my Story").font(StoryTheme.body(14))
                            .foregroundStyle(story.moments.isEmpty ? StoryTheme.cream.opacity(0.2) : StoryTheme.cream.opacity(0.38))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(story.moments.isEmpty)
                }
                .padding(.top, 20)

                Button { pickerItems = true } label: {
                    Text("+ Add photos or videos")
                        .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.gold)
                }
                .padding(.top, 16)

                Divider().overlay(StoryTheme.cream.opacity(0.06)).padding(.top, 24)

                // Story Idea — neutral unavailable (NOT TMB demo copy)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("✦").font(.system(size: 9)).foregroundStyle(StoryTheme.cream.opacity(0.28))
                        StoryEyebrow(text: "Story Idea")
                    }
                    Text("Ideas for what to capture next")
                        .font(StoryTheme.display(16)).foregroundStyle(StoryTheme.cream.opacity(0.72))
                    Text("Story will suggest ideas as your Story grows. Not available yet.")
                        .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.28))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 20)

                Divider().overlay(StoryTheme.cream.opacity(0.06)).padding(.top, 24)

                // Story Guide — neutral unavailable
                VStack(alignment: .leading, spacing: 6) {
                    StoryEyebrow(text: "Story Guide")
                    Text("A guide to what would make your Story stronger — coming in a later update.")
                        .font(StoryTheme.body(13).italic()).foregroundStyle(StoryTheme.cream.opacity(0.3))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 20)

                #if DEBUG
                if AppMode.current.showsDiagnostics {
                    IntentChipsDebug(story: story).padding(.top, 20)   // AI-debug mode only
                }
                #endif

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
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

// Moments mosaic — frozen Figma ScreenTMB: a true 3-column SQUARE grid
// (gridTemplateColumns repeat(3,1fr), aspectRatio 1, gap 2), up to 6 tiles,
// the moment count overlaid bottom-right under a short gradient. Empty state
// is a dashed 16:5 "Your moments will appear here" panel.
private struct MomentsMosaic: View {
    let moments: [MomentModel]
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        if moments.isEmpty {
            RoundedRectangle(cornerRadius: 14)
                .fill(StoryTheme.cream.opacity(0.03))
                .aspectRatio(16.0/5.0, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(StoryTheme.cream.opacity(0.09)))
                .overlay(Text("Your moments will appear here")
                    .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.18)))
        } else {
            let shown = Array(moments.prefix(6))
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, m in
                    MomentTile(moment: m, fallbackIndex: idx,
                               countOverlay: idx == shown.count - 1 ? moments.count : nil)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

// A single square moment tile: real first-frame thumbnail if available, else a
// neutral placeholder tone. Count badge on the last tile.
private struct MomentTile: View {
    let moment: MomentModel
    let fallbackIndex: Int
    var countOverlay: Int? = nil
    @State private var thumb: UIImage?

    var body: some View {
        ZStack {
            if let thumb {
                Image(uiImage: thumb).resizable().scaledToFill()
            } else {
                Image(StoryPlaceholderPhoto.name(fallbackIndex)).resizable().scaledToFill()
                    .opacity(0.84)
            }
            if let n = countOverlay {
                LinearGradient(colors: [.clear, StoryTheme.ink.opacity(0.68)],
                               startPoint: .center, endPoint: .bottom)
                Text("\(n) moment\(n == 1 ? "" : "s") →")
                    .font(StoryTheme.body(12, .medium)).foregroundStyle(StoryTheme.cream.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .task { thumb = await MomentThumbnailCache.shared.thumbnail(for: moment) }
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
