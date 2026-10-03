import SwiftUI
import SwiftData
import AVKit

// Create My Story — preview (frozen Figma ScreenTMBPreview). Shows the Story
// material and the intended Create action, but real generation (Edit Planner +
// Media Engine) is NOT built, so the generate action is an intentional
// disabled/empty state. Music is disabled (Music Engine). In DEBUG the old
// Milestone-A mock output path remains, clearly marked as dev-only — never
// presented as a real AI-generated Story. See ui-capability-matrix.md.
struct CreateStoryPreviewView: View {
    @Environment(\.modelContext) private var context
    @Bindable var story: StoryModel
    @Environment(\.dismiss) private var dismiss

    private var useCases: StoryUseCases {
        StoryUseCases(repository: StoryRepository(context: context))
    }

    private let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Custom back header (consistent with the rest of the product).
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Text("←").font(StoryTheme.body(18)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                            .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Back")
                    Spacer()
                }
                StoryEyebrow(text: story.title.displayTitle)
                Text("Here's what I'm working with.")
                    .font(StoryTheme.display(24)).foregroundStyle(StoryTheme.cream)

                if story.moments.isEmpty {
                    StoryEmptyState(text: "No moments yet. Shoot one first.")
                } else {
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(story.moments.sorted(by: { $0.createdAt < $1.createdAt })) { m in
                            thumb(m)
                        }
                    }
                    Text("\(story.moments.count) moment\(story.moments.count == 1 ? "" : "s")")
                        .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.textSecondary)
                    Text("Story will choose the moments that work best.")
                        .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.textMuted)
                }

                // Music — frozen surface, disabled (Music Engine).
                StoryUnavailableSection(header: { StoryEyebrow(text: "Music") },
                    message: "Story will score your video to music. Not available yet.")

                // Create — real generation unavailable (Edit Planner + Media).
                VStack(alignment: .leading, spacing: 8) {
                    StoryUnavailableButton(title: "Create my Story",
                                           note: "Story generation is coming in a later update.")
                }
                .padding(.top, 4)

                #if DEBUG
                if AppMode.current.showsDiagnostics {
                    Divider().overlay(StoryTheme.gold.opacity(0.25))
                    StoryEyebrow(text: "DEBUG · dev mock output")
                    Button("Generate mock output (dev only)") {
                        try? useCases.createStoryOutput(for: story)
                    }
                    .font(StoryTheme.body(13)).tint(StoryTheme.gold)
                    if !story.generatedOutputs.isEmpty {
                        Text("mock outputs: \(story.generatedOutputs.count)")
                            .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.textMuted)
                    }
                }
                #endif

                Spacer(minLength: 20)
            }
            .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 8)
        }
        .storyBackground()
        .toolbar(.hidden, for: .navigationBar)
    }

    private func thumb(_ m: MomentModel) -> some View {
        PreviewThumb(moment: m)
    }
}

// Portrait preview tile — real first frame if available, else placeholder tone.
private struct PreviewThumb: View {
    let moment: MomentModel
    @State private var img: UIImage?
    var body: some View {
        Group {
            if let img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(StoryPlaceholderPhoto.name(abs(moment.id.hashValue)))
                    .resizable().scaledToFill().opacity(0.84)
            }
        }
        .frame(height: 150).frame(maxWidth: .infinity).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { img = await MomentThumbnailCache.shared.thumbnail(for: moment) }
    }
}
