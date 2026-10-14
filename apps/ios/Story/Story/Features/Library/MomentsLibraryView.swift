import SwiftUI
import SwiftData

// LibraryContext — the ONE Moments-library component adapts to WHERE it was opened from
// (Capture UX corrections, Phase 4). Only the primary action + a couple of affordances
// change; the grid, tiles, preview and multi-select are shared.
//
//   • home        : browse + multi-select; primary action = "Create Story (N)".
//   • story(s)    : browse + multi-select; primary action = "Add to Story (N)". Moments
//                   already linked to `s` are badged "In Story" and are NOT re-added
//                   (dup-link prevented). Calls onChanged after linking so the Story refreshes.
//   • recentBrowse: opened from the camera's recent-Moment thumbnail. Browse-only (tap to
//                   preview), NO Select / Create / Add — closing returns to the camera.
enum LibraryContext {
    case home
    case story(StoryModel)
    case recentBrowse

    var allowsSelection: Bool {
        if case .recentBrowse = self { return false }
        return true
    }
    var associatedStory: StoryModel? {
        if case .story(let s) = self { return s }
        return nil
    }
}

// MomentsLibraryView — the GLOBAL Moments library. Shows EVERY Moment across all Stories,
// newest first, grouped in a square grid. Behavior adapts to LibraryContext (above). Reuses
// MomentManageTile + MomentPreviewView — no new tile/preview UI.
struct MomentsLibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var libraryContext: LibraryContext = .home
    /// Called after Moments are linked to a Story (.story context) so the caller can refresh.
    var onChanged: (() -> Void)? = nil

    @State private var moments: [MomentModel] = []
    @State private var previewMoment: MomentModel?
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var pendingDelete = false
    @State private var createdStory: StoryModel?
    /// Ids already linked to the active Story (.story context) — badged + excluded from re-add.
    @State private var alreadyInStory = Set<UUID>()

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
                    Text(hintText)
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { dismiss() } label: {
                Text(backGlyph).font(StoryTheme.body(18)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                    .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(backLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText).font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
                Text(subtitleText)
                    .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
            }
            Spacer()
            if !moments.isEmpty && libraryContext.allowsSelection {
                Button(selecting ? "Done" : "Select") {
                    withAnimation { selecting.toggle(); if !selecting { selected.removeAll() } }
                }
                .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.gold)
            }
        }
    }

    // Camera thumbnail (.recentBrowse) uses an explicit "camera" affordance so it reads as
    // "back to the camera", not "up a level".
    private var backGlyph: String {
        if case .recentBrowse = libraryContext { return "✕" }
        return "←"
    }
    private var backLabel: String {
        if case .recentBrowse = libraryContext { return "Back to camera" }
        return "Back"
    }

    private var titleText: String {
        switch libraryContext {
        case .home, .story: return "Moments"
        case .recentBrowse: return "Recent Moments"
        }
    }

    private var subtitleText: String {
        switch libraryContext {
        case .home:         return "\(moments.count) in your library"
        case .story(let s): return "Add to \(s.title.displayTitle)"
        case .recentBrowse: return "\(moments.count) in your library"
        }
    }

    private var hintText: String {
        if case .recentBrowse = libraryContext {
            return "Tap a moment to preview · close to return to the camera."
        }
        if selecting {
            switch libraryContext {
            case .story: return "Tap moments to select · add them to this Story."
            default:     return "Tap moments to select · create a Story from them, or delete them."
            }
        }
        switch libraryContext {
        case .story: return "Tap a moment to preview · tap Select to add moments to this Story."
        default:     return "Tap a moment to preview · tap Select to pick moments for a new Story."
        }
    }

    // MARK: - Tiles

    @ViewBuilder
    private func tile(_ m: MomentModel) -> some View {
        let inStory = alreadyInStory.contains(m.id)
        if selecting {
            MomentManageTile(moment: m, onTap: { if !inStory { toggle(m) } }, onRemove: nil)
                .overlay(alignment: .topTrailing) {
                    if inStory {
                        // Already in this Story — badged, not selectable (dup-link prevented).
                        Text("In Story")
                            .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                            .foregroundStyle(StoryTheme.ink)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(StoryTheme.gold.opacity(0.85), in: Capsule())
                            .padding(5)
                    } else {
                        Image(systemName: selected.contains(m.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(m.id) ? StoryTheme.gold : StoryTheme.cream.opacity(0.6))
                            .padding(6)
                    }
                }
                .opacity(inStory ? 0.5 : 1)
        } else {
            MomentManageTile(moment: m, onTap: { previewMoment = m }, onRemove: nil)
                .overlay(alignment: .topTrailing) {
                    if inStory {
                        Text("In Story")
                            .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                            .foregroundStyle(StoryTheme.ink)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(StoryTheme.gold.opacity(0.85), in: Capsule())
                            .padding(5)
                    }
                }
        }
    }

    // MARK: - Selection bar (context-specific primary action)

    private var selectionBar: some View {
        HStack(spacing: 12) {
            switch libraryContext {
            case .home:
                Button(role: .destructive) { pendingDelete = true } label: {
                    Text("Delete").frame(maxWidth: .infinity).padding(.vertical, 13)
                        .overlay(Capsule().stroke(StoryTheme.cream.opacity(0.2), lineWidth: 1.5))
                }.buttonStyle(.plain).foregroundStyle(StoryTheme.cream.opacity(0.75))
                Button { createStoryFromSelection() } label: {
                    Text("Create Story (\(selected.count))").frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Capsule().fill(StoryTheme.cream)).foregroundStyle(StoryTheme.ink)
                }.buttonStyle(.plain)
            case .story:
                Button { addSelectionToStory() } label: {
                    Text("Add to Story (\(selected.count))").frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Capsule().fill(StoryTheme.cream)).foregroundStyle(StoryTheme.ink)
                }.buttonStyle(.plain)
            case .recentBrowse:
                EmptyView()
            }
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
        if let s = libraryContext.associatedStory {
            alreadyInStory = Set(s.momentLinks.compactMap { $0.moment?.id })
        } else {
            alreadyInStory = []
        }
    }

    private func toggle(_ m: MomentModel) {
        if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
    }

    private func createStoryFromSelection() {
        let picked = moments.filter { selected.contains($0.id) }
        guard !picked.isEmpty else { return }
        let story = try? useCases.createStoryFromMoments(
            title: "New Story", direction: "A story from my selected moments.", moments: picked)
        if let story { createdStory = story }
    }

    private func addSelectionToStory() {
        guard let story = libraryContext.associatedStory else { return }
        // Preserve selection order (newest-first grid order of the picked tiles).
        let picked = moments.filter { selected.contains($0.id) && !alreadyInStory.contains($0.id) }
        guard !picked.isEmpty else { return }
        try? useCases.addExistingMoments(picked, to: story)
        onChanged?()
        dismiss()
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
