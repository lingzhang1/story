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
    #if DEBUG
    @State private var showRenderHarness = false
    #endif

    // R-c Batch B: coordinator-driven create/result navigation. The visible Create
    // button is still an intentional disabled state (Batch C flips availability on
    // Story Home) — but the full path is wired HERE so Batch C only toggles the
    // trigger, not the plumbing. `createRoute` decides, via ReopenDecision, whether
    // to open the Result screen for an existing good output or start a new render.
    @State private var showCreating = false
    @State private var reopenOutput: GeneratedOutputModel?

    private var useCases: StoryUseCases {
        StoryUseCases(repository: StoryRepository(context: context))
    }

    /// Open the create flow. REOPEN: if the Story already has a successful, non-stale, file-present output,
    /// go straight to the Result screen (no re-render); otherwise start the coordinator-driven Creating screen.
    private func startCreate() {
        let decision = ReopenDecision.decide(
            outputs: story.generatedOutputs,
            isStale: { StoryCreationCoordinator.isOutputStale(output: $0, story: story) },
            fileExists: { RenderOutputStore.shared.exists(relative: $0) })
        switch decision {
        case .showResult(let outputId):
            reopenOutput = story.generatedOutputs.first { $0.id == outputId }
        case .create:
            showCreating = true
        }
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
                // R-c Batch B: DEBUG-only entry that exercises the REAL coordinator-driven create/result flow
                // wired behind this screen. The CONSUMER Create action above stays an intentional disabled
                // state — Batch C flips availability on Story Home and routes it to startCreate(); the full
                // path (ReopenDecision -> Creating/Result) is already in place here. Kept separate from and
                // in addition to the Media Engine render-test harness below, which is untouched.
                Button {
                    startCreate()
                } label: {
                    HStack {
                        Text("▶ Create (dev wiring) · Coordinator")
                        Spacer()
                    }
                    .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.cream)
                    .padding(.vertical, 12).padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(StoryTheme.cream.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(story.moments.isEmpty)
                #endif

                #if DEBUG
                // R-b Case G: reachable entry to the Media Engine V1 render test harness. Visible in ANY
                // DEBUG build (every Xcode build-and-run) — NOT gated on aiDebug — so there is no launch
                // argument to set. #if DEBUG keeps it out of Release / consumer flow entirely.
                Divider().overlay(StoryTheme.gold.opacity(0.25))
                Button {
                    showRenderHarness = true
                } label: {
                    HStack {
                        Text("▶ Render Test (dev) · Media Engine V1")
                        Spacer()
                    }
                    .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.ink)
                    .padding(.vertical, 12).padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .background(StoryTheme.gold, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                if AppMode.current.showsDiagnostics {
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
        // R-c Batch B: coordinator-driven routes. New render -> Creating (which on completion pushes Result);
        // reopen of an existing good output -> Result directly (no re-render).
        .navigationDestination(isPresented: $showCreating) {
            StoryCreatingView(story: story)
        }
        .navigationDestination(item: $reopenOutput) { output in
            StoryResultView(story: story, output: output)
        }
        #if DEBUG
        .sheet(isPresented: $showRenderHarness) {
            RenderTestHarnessView(story: story)
        }
        #endif
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
