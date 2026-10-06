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
    @State private var showMoments = false
    @State private var confirmLifecycle = false

    // Milestone E — Story Coverage (real Story Guide + Story Idea).
    @State private var coverage: StoryCoverageDTO?
    @State private var coverageLoading = false

    private var coverageEngine: StoryCoverageEngine {
        StoryCoverageEngine(context: context)
    }

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
                        Text(story.title.displayTitle).font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
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
                Button { if !story.moments.isEmpty { showMoments = true } } label: {
                    MomentsMosaic(moments: story.moments.sorted(by: { $0.createdAt < $1.createdAt }))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

                // Story Idea — real StoryCoverage.story_idea. ONE optional card,
                // shown ONLY when non-null; omitted entirely otherwise (no "no ideas"
                // placeholder — do-nothing intelligence is no interruption).
                if let idea = coverage?.storyIdea {
                    StoryIdeaSection(idea: idea) { showCapture = true }
                    Divider().overlay(StoryTheme.cream.opacity(0.06)).padding(.top, 24)
                }

                // Story Guide — real StoryCoverage (ordinary language; no ids /
                // scores / percentages / progress / required-shot counts / jargon).
                StoryGuideSection(coverage: coverage, isLoading: coverageLoading)

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
        .task(id: story.id) { await loadCoverage() }
        .fullScreenCover(isPresented: $showCapture, onDismiss: {
            // Returning from capture: a new Moment may have been added and its AU may
            // have completed -> coverage is likely stale. Recompute opportunistically.
            Task { await loadCoverage() }
        }) { ShootMomentView(story: story) }
        .navigationDestination(isPresented: $showPreview) { CreateStoryPreviewView(story: story) }
        .navigationDestination(isPresented: $showMoments) { MomentsManageView(story: story) }
        .photosPickerSheet(isPresented: $pickerItems) { picked in
            try? useCases.addExistingMedia(to: story, relativePaths: picked)
        }
        .sheet(isPresented: $showMenu) {
            StoryOptionsSheet(
                status: story.status,
                onComplete: { showMenu = false; try? useCases.completeStory(story) },
                onReopen: { showMenu = false; try? useCases.reopenStory(story) })
                .presentationDetents([.height(story.status == .active ? 300 : 260)])
                .presentationBackground(StoryTheme.surfaceAlt)
        }
    }

    // MARK: - Story Coverage lifecycle (Milestone E §5)
    //
    //   - Show the CURRENT cached coverage immediately (no model call).
    //   - If STALE, keep the last valid coverage visible while recomputing in the
    //     background; swap in the fresh snapshot when it arrives.
    //   - If NO coverage exists, show the neutral/loading Guide state while computing.
    //   - A failed recompute preserves the previous valid coverage (never fabricates).
    //   - Only recompute when there is at least one understood Moment to reason from;
    //     an empty / all-pending Story shows the neutral state (pending = unknown).
    private func loadCoverage() async {
        let engine = coverageEngine
        coverage = engine.cachedCoverage(for: story.id)   // immediate (may be nil)

        let inputs = engine.currentInputs(for: story)
        let hasUnderstood = !inputs.completedMUValues.isEmpty
        guard hasUnderstood else {
            // Nothing understood yet -> neutral state; do not call the model.
            coverageLoading = false
            return
        }
        guard engine.isStale(for: story) else { return }   // cache current: done

        coverageLoading = (coverage == nil)                // loading text only if nothing to show
        let fresh = await engine.recomputeIfNeeded(for: story)
        coverageLoading = false
        if let fresh { coverage = fresh }                  // keep previous on failure (fresh==cached)
    }

    private var stateLine: String {
        if story.status == .completed { return "Everything from your Story, in one place." }
        if story.moments.isEmpty { return "Your Story is ready to begin." }
        return "Your Story is taking shape."
    }
}

// Story options — frozen Figma bottom sheet (ScreenTMB menu). Edit Story details
// + Creative direction are future surfaces (disabled); Complete/Reopen is the
// wired action, routed through a styled two-step confirm.
private struct StoryOptionsSheet: View {
    let status: StoryStatus
    var onComplete: () -> Void
    var onReopen: () -> Void
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    private var isActive: Bool { status == .active }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(StoryTheme.cream.opacity(0.12))
                .frame(width: 36, height: 4).padding(.top, 10).padding(.bottom, 14)

            if confirming {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isActive ? "Complete this Story?" : "Reopen this Story?")
                        .font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
                    Text(isActive
                         ? "This Story moves out of your active Stories. You can still view Moments, create videos, or reopen it anytime."
                         : "This Story returns to your active Stories.")
                        .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                    StoryPrimaryButton(title: isActive ? "Complete Story" : "Reopen Story") {
                        isActive ? onComplete() : onReopen()
                    }.padding(.top, 10)
                    Button { confirming = false } label: {
                        Text("Cancel").font(StoryTheme.body(14))
                            .foregroundStyle(StoryTheme.cream.opacity(0.4))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            } else {
                VStack(spacing: 0) {
                    sheetRow("Edit Story details", disabled: true) {}
                    sheetRow("Creative direction", disabled: true) {}
                    Divider().overlay(StoryTheme.cream.opacity(0.07)).padding(.vertical, 6)
                    sheetRow(isActive ? "Complete Story" : "Reopen Story",
                             tint: isActive ? StoryTheme.cream.opacity(0.75) : StoryTheme.gold) {
                        confirming = true
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sheetRow(_ title: String, tint: Color = StoryTheme.cream.opacity(0.8),
                          disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(StoryTheme.body(15))
                    .foregroundStyle(disabled ? StoryTheme.cream.opacity(0.28) : tint)
                Spacer()
                if disabled {
                    Text("Soon").font(StoryTheme.body(11))
                        .foregroundStyle(StoryTheme.cream.opacity(0.2))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityHint(disabled ? "Not available yet" : "")
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
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Image(StoryPlaceholderPhoto.name(fallbackIndex)).resizable().scaledToFill()
                        .opacity(0.84)
                }
            }
            .overlay {
                if let n = countOverlay {
                    LinearGradient(colors: [.clear, StoryTheme.ink.opacity(0.68)],
                                   startPoint: .center, endPoint: .bottom)
                    Text("\(n) moment\(n == 1 ? "" : "s") →")
                        .font(StoryTheme.body(12, .medium)).foregroundStyle(StoryTheme.cream.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
                }
            }
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
