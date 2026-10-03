import SwiftUI
import SwiftData

// Moments — frozen Figma full-screen moment grid (ScreenMoments). Shows every
// Moment in the Story as square tiles; tapping a tile offers remove-from-Story
// (local/mechanical, StoryUseCases.removeMoment — no generation, no AI). The
// Story's status is never changed here.
struct MomentsManageView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var story: StoryModel

    @State private var pendingRemove: MomentModel?

    private var useCases: StoryUseCases {
        StoryUseCases(repository: StoryRepository(context: context))
    }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var moments: [MomentModel] {
        story.moments.sorted(by: { $0.createdAt < $1.createdAt })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Button { dismiss() } label: {
                        Text("←").font(StoryTheme.body(18)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                            .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Back")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Moments").font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
                        Text("\(moments.count) in \(story.title.displayTitle)")
                            .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
                    }
                    Spacer()
                }
                .padding(.top, 8)

                if moments.isEmpty {
                    StoryEmptyState(text: "No moments yet. Shoot one from your Story.")
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: cols, spacing: 2) {
                        ForEach(moments) { m in
                            MomentManageTile(moment: m) { pendingRemove = m }
                        }
                    }
                    .padding(.top, 18)
                    Text("Tap the ✕ on a moment to remove it from this Story.")
                        .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
                        .padding(.top, 14)
                }
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
        }
        .storyBackground()
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Remove this moment?",
                            isPresented: Binding(get: { pendingRemove != nil },
                                                 set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from Story", role: .destructive) {
                if let m = pendingRemove { try? useCases.removeMoment(m, from: story) }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("The moment is removed from this Story. This does not delete the original from your library.")
        }
    }
}

private struct MomentManageTile: View {
    let moment: MomentModel
    var onRemove: () -> Void
    @State private var thumb: UIImage?
    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let thumb { Image(uiImage: thumb).resizable().scaledToFill() }
                else { StoryTheme.surfaceAlt }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(StoryTheme.cream)
                        .frame(width: 26, height: 26)
                        .background(StoryTheme.ink.opacity(0.55), in: Circle())
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove this moment")
            }
            .task { thumb = await MomentThumbnailCache.shared.thumbnail(for: moment) }
    }
}
