import SwiftUI
import SwiftData

// MomentsLibraryView — the GLOBAL Moments library (Capture Anywhere milestone, Phase 4). Shows EVERY Moment
// across all Stories, newest first, as square tiles. Two modes:
//   • browse  : tap a tile to preview; "Select" enters multi-select.
//   • select  : tap tiles to toggle a checkmark; "Create Story" builds a NEW Story from the selected Moments
//                via the existing creation pipeline (StoryUseCases.createStoryFromMoments → StoryMomentLink,
//                no media duplication); "Delete" removes the selected Moments from the library (destructive:
//                deletes their owned media + AU, cascades links).
// Reuses MomentManageTile + MomentPreviewView from the Story-scoped manage screen — no new tile/preview UI.
struct MomentsLibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var moments: [MomentModel] = []
    @State private var previewMoment: MomentModel?
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var pendingDelete = false
    @State private var createdStory: StoryModel?

    private var useCases: StoryUseCases { StoryUseCases(repository: StoryRepository(context: context)) }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if moments.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: cols, spacing: 2) {
                        ForEach(moments) { m in
                            tile(m)
                        }
                    }
                    .padding(.top, 18)
                    Text(selecting
                         ? "Tap moments to select · Create a Story from them or delete them from your library."
                         : "Tap a moment to preview · tap Select to pick moments for a new Story.")
                        .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
                        .padding(.top, 14)
                }
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
        }
        .storyBackground()
        .swipeBackToDismiss(dismiss)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { if selecting && !selected.isEmpty { selectionBar } }
        .fullScreenCover(item: $previewMoment) { m in MomentPreviewView(moment: m) }
        .navigationDestination(item: $createdStory) { s in StoryHomeView(story: s) }
        .confirmationDialog("Delete \(selected.count) moment\(selected.count == 1 ? "" : "s") from your library?",
                            isPresented: $pendingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes the original media and analysis, and removes these moments from any Story that used them. Already-created videos are unaffected.")
        }
        .onAppear(perform: reload)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { dismiss() } label: {
                Text("←").font(StoryTheme.body(18)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                    .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 2) {
                Text("Moments").font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
                Text("\(moments.count) in your library")
                    .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
            }
            Spacer()
            if !moments.isEmpty {
                Button(selecting ? "Done" : "Select") {
                    withAnimation { selecting.toggle(); if !selecting { selected.removeAll() } }
                }
                .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.gold)
            }
        }
    }

    @ViewBuilder
    private func tile(_ m: MomentModel) -> some View {
        if selecting {
            MomentManageTile(moment: m, onTap: { toggle(m) }, onRemove: nil)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected.contains(m.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(m.id) ? StoryTheme.gold : StoryTheme.cream.opacity(0.6))
                        .padding(6)
                }
        } else {
            MomentManageTile(moment: m, onTap: { previewMoment = m }, onRemove: nil)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) { pendingDelete = true } label: {
                Text("Delete").frame(maxWidth: .infinity).padding(.vertical, 13)
                    .overlay(Capsule().stroke(StoryTheme.cream.opacity(0.2), lineWidth: 1.5))
            }.buttonStyle(.plain).foregroundStyle(StoryTheme.cream.opacity(0.75))
            Button { createStoryFromSelection() } label: {
                Text("Create Story (\(selected.count))").frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Capsule().fill(StoryTheme.cream)).foregroundStyle(StoryTheme.ink)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No moments yet").font(StoryTheme.display(18)).foregroundStyle(StoryTheme.cream.opacity(0.7))
            Text("Capture a moment to start your library.")
                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.35))
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    // MARK: - Actions

    private func reload() {
        moments = (try? useCases.allMoments()) ?? []
    }

    private func toggle(_ m: MomentModel) {
        if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
    }

    private func createStoryFromSelection() {
        let picked = moments.filter { selected.contains($0.id) }
        guard !picked.isEmpty else { return }
        // Minimal intent for a library-origin Story; the user refines on the Story screen / Customize.
        let story = try? useCases.createStoryFromMoments(
            title: "New Story", direction: "A story from my selected moments.", moments: picked)
        if let story { createdStory = story }
    }

    private func deleteSelected() {
        for m in moments where selected.contains(m.id) {
            try? useCases.deleteMomentFromLibrary(m)
        }
        selected.removeAll()
        selecting = false
        reload()
    }
}
