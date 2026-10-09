import SwiftUI
import SwiftData
import AVKit

// Create My Story — preview (frozen Figma ScreenTMBPreview). Shows the Story
// material and the REAL Create action (R-c Batch C): enabled only when the Story
// is plannable (>=1 Moment with a resolvable local file AND a completed
// MomentUnderstanding — the same rule EditPlanRequestBuilder enforces), routing
// to the Batch-B coordinator flow (StoryCreatingView -> StoryResultView) or, when
// a good persisted output already exists, straight to the Result screen via
// ReopenDecision. Music is disabled (Music Engine). The Milestone-A MOCK output
// path is DEBUG-only (showsDiagnostics block) and is NEVER on the consumer
// production path. See ui-capability-matrix.md.
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

    /// Duplicate-guard reflection: a create/result flow is already presented for this Story, so the Create
    /// action must not launch a second one (the coordinator also guards concurrent runs via `isCreating`).
    private var isCreateFlowActive: Bool { showCreating || reopenOutput != nil }

    /// Open the create flow. REOPEN: if the Story already has a successful, non-stale, file-present output,
    /// go straight to the Result screen (no re-render); otherwise start the coordinator-driven Creating screen.
    private func startCreate() {
        guard !isCreateFlowActive else { return }   // duplicate guard
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

    /// Re-create from a REOPENED Result (stale output): drop Result and enter the Creating screen (child of
    /// this preview), which runs the pipeline and self-manages its own Result.
    private func handleRecreate() {
        reopenOutput = nil
        DispatchQueue.main.async { showCreating = true }
    }

    /// Collapse the create flow back to Story Home in one tap: clear the reopen binding and pop the preview
    /// itself (a pushed destination of Story Home). The new-render path pops itself via Creating's onHome.
    private func goHome() {
        reopenOutput = nil
        showCreating = false
        dismiss()
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

                // Create — REAL consumer action (R-c Batch C). Enabled only when the Story is plannable
                // (>=1 Moment with a resolvable file AND a completed MomentUnderstanding — same rule as
                // EditPlanRequestBuilder). Tap -> ReopenDecision (existing good output -> Result; else Creating).
                // Duplicate guard: the button also disables while a flow is already active for this Story.
                let readiness = StoryCreationReadiness.evaluate(story: story, context: context)
                let canCreate = readiness.isPlannable && !isCreateFlowActive
                VStack(alignment: .leading, spacing: 8) {
                    if canCreate {
                        StoryPrimaryButton(title: "Create my Story") { startCreate() }
                    } else {
                        StoryUnavailableButton(title: "Create my Story", note: readiness.copy)
                    }
                    if readiness.isPlannable, case .pendingAnalysis = readiness {
                        // Honest: a plan uses only the ready moments; the rest are still analyzing.
                        Text(readiness.copy)
                            .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.textMuted)
                    }
                }
                .padding(.top, 4)

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
        // R-c Batch B: coordinator-driven routes. New render -> Creating, which OWNS its Result child and,
        // via Result's onHome, pops BOTH itself and Result back to Story Home (fixes the stuck "Finishing up…"
        // screen). Reopen of an existing good output -> Result directly; its onHome collapses the flow too
        // (Result is a child of this preview, so a plain dismiss would stop at the preview, not Home).
        .navigationDestination(isPresented: $showCreating) {
            StoryCreatingView(story: story)
        }
        .navigationDestination(item: $reopenOutput) { output in
            StoryResultView(story: story, output: output, onHome: goHome, onRecreate: handleRecreate)
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
