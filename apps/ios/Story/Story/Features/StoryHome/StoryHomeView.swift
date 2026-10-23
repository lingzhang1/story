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
    /// Back action. Default (nil) = pop one level via `dismiss()` — correct when StoryHomeView was pushed
    /// directly from the app Home list. When reached THROUGH the creation wizard, the caller injects a closure
    /// that dismisses the WHOLE creation flow so Back returns straight to app Home instead of walking back
    /// through the wizard's describe→feel→context steps.
    var onBack: (() -> Void)? = nil

    @State private var showCapture = false
    @State private var showMenu = false
    @State private var showPreview = false
    /// When Create decides a good output already exists, push the Result directly (the "Here's what I'm
    /// working with" preview is never shown as a resting page).
    @State private var reopenOutput: GeneratedOutputModel?
    /// Set when "Create another version" is tapped on the Result — carried into the create host so it launches
    /// a new-version (Explore + Customize) flow rather than a fresh original create. Cleared after each use.
    @State private var recreateParent: GeneratedOutputModel?
    @State private var pickerItems = false
    @State private var showMoments = false
    @State private var showAddMoments = false      // Phase 3: "Add Moments" source chooser
    @State private var showStoryMomentsPicker = false   // Phase 3: From Story Moments (library .story)
    @State private var confirmLifecycle = false
    /// R-c.1 UX: live import progress so the user sees "Adding your videos…" instead of a frozen Home while
    /// picked videos are copied out of Photos (can be an iCloud download). nil = no import in flight.
    @State private var importProgress: ImportProgress?
    // E2-c: an opportunity-driven capture (Story Idea Show-me / Guide possibility Shoot). When set,
    // the scan flow carries this selected_opportunity into Director. Identifiable wrapper for cover(item:).
    @State private var pendingOpportunity: OpportunityLaunch?

    // Milestone E2 — persistent StoryGuide + Coverage/2 (real Story Guide + Story Idea).
    @State private var guide: StoryGuideDTO?
    @State private var guideV2: StoryGuideV2DTO?          // AI shooting script (when STORY_GUIDE_V2 on)
    @State private var coverage: StoryCoverageV2DTO?
    @State private var coverageLoading = false
    // One scene-image service for the whole screen (its metadata cache is shared across scene cards).
    private let sceneImages = SceneImageService()

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
                    Button { if let onBack { onBack() } else { dismiss() } } label: {
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
                    // R-c Batch C: readiness-gated real Create. Plannable iff >=1 Moment has BOTH a resolvable
                    // local file AND a completed MomentUnderstanding (same rule as EditPlanRequestBuilder).
                    let readiness = StoryCreationReadiness.evaluate(story: story, context: context)
                    VStack(spacing: 4) {
                        Button { startCreateOrOpen() } label: {
                            Text("Create my Story").font(StoryTheme.body(14))
                                .foregroundStyle(readiness.isPlannable ? StoryTheme.cream.opacity(0.7) : StoryTheme.cream.opacity(0.2))
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!readiness.isPlannable)
                        .accessibilityHint(readiness.isPlannable ? "" : readiness.copy)
                        // Honest status line — never a generic "coming later".
                        Text(readiness.copy)
                            .font(StoryTheme.body(11))
                            .foregroundStyle(readiness.isPlannable ? StoryTheme.cream.opacity(0.3) : StoryTheme.textMuted)
                    }
                }
                .padding(.top, 20)

                Button { showAddMoments = true } label: {
                    Text("+ Add Moments")
                        .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.gold)
                }
                .padding(.top, 16)

                Divider().overlay(StoryTheme.cream.opacity(0.06)).padding(.top, 24)

                // Story Idea — real StoryCoverage.story_idea. ONE optional card,
                // shown ONLY when non-null; omitted entirely otherwise (no "no ideas"
                // placeholder — do-nothing intelligence is no interruption).
                if let idea = coverage?.storyIdea {
                    // Story Idea -> Show me (Director entry point A): carry the Idea's semantic
                    // opportunity (title + description; target dimension if present) into Director.
                    StoryIdeaSection(idea: idea) {
                        pendingOpportunity = OpportunityLaunch(opportunity: SelectedOpportunityDTO(
                            storyGuideDimensionId: idea.targetStoryGuideDimensionId,
                            label: idea.title, purpose: idea.description,
                            capturePossibilityLabel: nil))
                    }
                    Divider().overlay(StoryTheme.cream.opacity(0.06)).padding(.top, 24)
                }

                // Story Guide — the persistent StoryGuide creative map (renders as soon as the
                // Guide exists, independent of Coverage) + optional Coverage/2 overlay (state tags +
                // represented-possibility affordances). Advisory, never a checklist.
                if StoryGuideFeatures.guideV2Enabled, guideV2 != nil {
                    // AI shooting script (story_guide/2): cinematic scene cards with lazy reference images.
                    StoryGuideV2Section(
                        guide: guideV2, coverage: coverage, isLoading: coverageLoading,
                        eventLabel: story.title,
                        onShoot: { scene, poss in
                            pendingOpportunity = OpportunityLaunch(opportunity: SelectedOpportunityDTO(
                                storyGuideDimensionId: scene.id,
                                label: poss?.label ?? scene.title,
                                purpose: poss?.semanticPurpose ?? scene.whatToCapture,
                                capturePossibilityLabel: poss?.label))
                        },
                        onRetry: { Task { await refreshGuideAndCoverage() } },
                        fetchImage: { scene in
                            guard let q = scene.visualReferenceQuery else { return nil }
                            return await sceneImages.fetch(query: q, storyId: story.id, sceneId: scene.id)
                        },
                        trackImageUse: { img in await sceneImages.track(downloadLocation: img.downloadLocation) },
                        onUpdateGuide: { instruction in
                            // Guide v2.1 refinement: async, non-blocking; current script stays until a valid
                            // refined one replaces it. Returns a short summary, or nil on a recoverable failure.
                            let coordinator = StoryGuideCoordinator(context: context)
                            do {
                                let outcome = try await coordinator.refineGuideV2(for: story, instruction: instruction)
                                await MainActor.run { guideV2 = outcome.guide }
                                // Mark the Story dirty so R7 syncs the refined guide + scene history.
                                StorySyncCoordinator.shared.touch(storyId: story.id, context: context,
                                    activeOwner: story.ownerAccountId, token: { await AuthStore.shared?.validAccessToken() })
                                let added = outcome.changes.filter { $0.disposition == "added" }.count
                                let improved = outcome.changes.filter { $0.disposition == "improved" }.count
                                let archived = outcome.archivedSceneIds.count
                                var parts: [String] = []
                                if added > 0 { parts.append("\(added) added") }
                                if improved > 0 { parts.append("\(improved) improved") }
                                if archived > 0 { parts.append("\(archived) archived") }
                                return parts.isEmpty ? "Guide updated." : "Updated · " + parts.joined(separator: " · ")
                            } catch {
                                return nil   // current guide untouched; the section shows a recoverable error
                            }
                        },
                        isPinned: { sceneId in StoryGuideCoordinator(context: context).isPinned(storyId: story.id, sceneId: sceneId) },
                        onTogglePin: { sceneId in
                            _ = StoryGuideCoordinator(context: context).togglePin(storyId: story.id, sceneId: sceneId)
                            StorySyncCoordinator.shared.touch(storyId: story.id, context: context,
                                activeOwner: story.ownerAccountId, token: { await AuthStore.shared?.validAccessToken() })
                        },
                        eventContext: story.eventContext ?? "",
                        onSaveEventContext: { text in
                            story.eventContext = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
                            try? context.save()
                        })
                } else {
                StoryGuideSection(guide: guide, coverage: coverage, isLoading: coverageLoading, onShoot: { dim, poss in
                    // Guide possibility -> Shoot (Director entry point B): purpose = possibility
                    // semantic_purpose ?? owning dimension purpose; carry the possibility label.
                    pendingOpportunity = OpportunityLaunch(opportunity: SelectedOpportunityDTO(
                        storyGuideDimensionId: dim.id, label: poss.label,
                        purpose: poss.semanticPurpose ?? dim.purpose,
                        capturePossibilityLabel: poss.label))
                }, onRetry: {
                    Task { await refreshGuideAndCoverage() }   // #1: recover a failed/interrupted Guide
                })
                }

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
        .overlay(alignment: .top) { importBanner }
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { if let onBack { onBack() } else { dismiss() } }
        .task(id: story.id) { await loadCoverage() }
        .fullScreenCover(isPresented: $showCapture, onDismiss: {
            // Returning from capture: the new Moment's AU runs async — poll until it lands so
            // Coverage + the Story Idea recompute (fixes 'Idea won't update after a Moment').
            Task { await refreshAfterCapture() }
        }) { ShootMomentView(story: story) }
        .fullScreenCover(item: $pendingOpportunity, onDismiss: {
            Task { await refreshAfterCapture() }
        }) { launch in
            // Opportunity-driven capture (Story Idea Show-me / Guide possibility Shoot/Reshoot).
            // Uses the SAME continuous camera as "Shoot a moment" (no old scan-first Start/Skip
            // Scan screen); the chosen opportunity seeds the in-camera AI idea as the default for
            // this specific guide item (scan-free), so Reshoot lands straight on the camera already
            // showing that idea.
            ContinuousCaptureView(captureContext: .story(story), seedOpportunity: launch.opportunity)
        }
        .navigationDestination(isPresented: $showPreview) {
            CreateStoryPreviewView(story: story, forceNewVersionFrom: recreateParent)
        }
        .navigationDestination(item: $reopenOutput) { output in
            StoryResultView(story: story, initialOutput: output,
                            onHome: {
                                // Pop the Result first (clear the item binding), THEN run the Story's own back
                                // so "Home" reaches the app Home instead of leaving the Result stuck on screen.
                                reopenOutput = nil
                                DispatchQueue.main.async { if let onBack { onBack() } else { dismiss() } }
                            },
                            onRecreate: { parent in
                                // "Create another version" from the Result -> push the create host as a
                                // NEW-VERSION flow (Explore + Customize), not a fresh original create.
                                reopenOutput = nil
                                recreateParent = parent
                                DispatchQueue.main.async { showPreview = true }
                            })
        }
        .navigationDestination(isPresented: $showMoments) { MomentsManageView(story: story) }
        .photosPickerSheet(isPresented: $pickerItems, onProgress: { p in
            // Non-blocking live signal while videos copy out of Photos. Clear ~1.2s after finish so a
            // success/partial-failure line is briefly visible, then falls away.
            importProgress = p.finished && p.done == 0 && p.failed == 0 ? nil : p
            if p.finished {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if importProgress?.finished == true { importProgress = nil }
                }
            }
        }) { picked in
            // Import: persist the Moments FIRST (files already durable in MediaStore), THEN enqueue AU for the
            // imported VIDEOS — same frozen pipeline as directed captures, but contextless (no Shot/Beat). AU
            // runs in the background; the import never blocks on it. Coverage recomputes when the MU lands.
            let created = (try? useCases.addExistingMedia(to: story, relativePaths: picked)) ?? []
            if !created.isEmpty {
                let auQueue = AssetUnderstandingQueue(context: context)
                auQueue.enqueueImportedVideos(created)
                Task { await auQueue.drain() }        // opportunistic; failures leave the job PENDING
                Task { await refreshAfterCapture() }  // reuse the capture poll: AU lands -> Coverage/Idea update
            }
        }
        .sheet(isPresented: $showMenu) {
            StoryOptionsSheet(
                status: story.status,
                onComplete: { showMenu = false; try? useCases.completeStory(story) },
                onReopen: { showMenu = false; try? useCases.reopenStory(story) })
                .presentationDetents([.height(story.status == .active ? 300 : 260)])
                .presentationBackground(StoryTheme.surfaceAlt)
        }
        // Phase 3: "Add Moments" source chooser → From Story Moments (library .story) | From Photos.
        .sheet(isPresented: $showAddMoments) {
            AddMomentsSheet(
                onFromStoryMoments: { showStoryMomentsPicker = true },
                onFromPhotos: { pickerItems = true })
                .presentationDetents([.height(300)])
                .presentationBackground(StoryTheme.surfaceAlt)
        }
        .fullScreenCover(isPresented: $showStoryMomentsPicker, onDismiss: {
            Task { await refreshAfterCapture() }   // new links → recompute coverage/idea
        }) {
            NavigationStack {
                MomentsLibraryView(libraryContext: .story(story))
            }
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
    /// Create decides the route AT TAP TIME (synchronously, so navigation fires reliably — a nested
    /// navigationDestination set later inside a pushed view's onAppear does NOT, which is why the old preview
    /// grid kept resting). If a good, non-stale output whose file is on disk already exists, push the Result
    /// directly; otherwise push the create-flow host (which auto-starts duration + Customize + music; the
    /// "Here's what I'm working with" grid is never a resting page).
    private func startCreateOrOpen() {
        let decision = ReopenDecision.decide(
            outputs: story.generatedOutputs,
            isStale: { StoryCreationCoordinator.isOutputStale(output: $0, story: story) },
            fileExists: { RenderOutputStore.shared.exists(relative: $0) })
        switch decision {
        case .showResult(let outputId):
            reopenOutput = story.generatedOutputs.first { $0.id == outputId }
        case .create:
            recreateParent = nil   // fresh original create (not a Create-Another-Version)
            showPreview = true
        }
    }

    private func loadCoverage() async {
        // Issue 4: if this Story is still hydrating from the cloud (durable barrier seeded from the sync rows),
        // do NOT enqueue AU backfill or run Guide/Coverage generation yet — a restore is about to supply the
        // reusable results. Briefly wait for hydration to settle (bounded), then proceed. A hydration timeout
        // does NOT force regeneration here — refreshGuideAndCoverage still holds via the per-entry gates, and
        // ensureGuide returns the neutral/retry state rather than inferring.
        if CloudHydrationGate.shared.isHydratingAfterSeed(storyId: story.id, context: context) {
            for _ in 0..<20 {   // up to ~10s, 0.5s steps — restore is a couple of network round-trips
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                if !CloudHydrationGate.shared.isHydrating(storyId: story.id) { break }
            }
            // After hydration, adopt whatever was restored (guide/coverage render from the cloud copy).
            await refreshGuideAndCoverage()
            return
        }
        // R-c.1 legacy backfill: videos imported BEFORE import-AU shipped have no MomentUnderstanding and no
        // job. Enqueue them once (idempotent — a Moment already understood or already queued is skipped, so
        // this is a no-op on subsequent opens and never duplicates analysis). Then drain opportunistically.
        let auQueue = AssetUnderstandingQueue(context: context)
        let backfilled = auQueue.backfillImports(for: story, context: context)
        if backfilled > 0 { Task { await auQueue.drain() } }
        await refreshGuideAndCoverage()
    }

    /// Ensure the Guide (renders immediately), then recompute Coverage/2 when there is understood
    /// material. Robust against task cancellation: coverageLoading is always cleared.
    private func refreshGuideAndCoverage() async {
        let engine = coverageEngine
        coverage = engine.cachedCoverage(for: story.id)   // immediate (may be nil)

        let coordinator = StoryGuideCoordinator(context: context)
        if let existing = coordinator.guide(for: story.id) { guide = existing }  // show at once if present
        coverageLoading = (guide == nil)
        // Guide v2 (AI shooting script): when enabled, prefer the scene-based Guide. It persists into the SAME
        // model row, so Coverage fingerprinting + R7 sync are unchanged. A v2 failure (incl. the backend route
        // gated off) falls back to the v1 creative-map path below — never a fabricated Guide.
        if StoryGuideFeatures.guideV2Enabled {
            if let existingV2 = coordinator.guideV2(for: story.id) { guideV2 = existingV2 }
            coverageLoading = (guideV2 == nil && guide == nil)
            if let gv2 = await coordinator.ensureGuideV2(for: story) {
                guideV2 = gv2
                coverageLoading = false
            }
            // When a v2 shooting script is in effect, do NOT run the v1 ensureGuide path — it would fail to
            // decode the v2 row as v1 dimensions and try to regenerate, overwriting the scene-based Guide.
            if let gv2 = guideV2 {
                // Music backfill (same as the v1 tail): ensure a default MusicDirection exists, non-blocking.
                let musicCoord = MusicDirectionCoordinator(context: context)
                if musicCoord.direction(for: story.id) == nil,
                   !CloudHydrationGate.shared.isHydratingAfterSeed(storyId: story.id, context: context) {
                    Task { await musicCoord.ensure(for: story, guideFramingSummary: gv2.framingSummary) }
                }
                // Coverage: the existing Coverage/2 state (cached) is shown as-is, keyed by stable scene id —
                // we do NOT regenerate the Guide on ordinary Coverage updates (owner Phase 5). The Coverage/2
                // mapper already keys state by the Guide's stable ids, which v2 scenes preserve.
                return
            }
        }
        let g = await coordinator.ensureGuide(for: story)
        coverageLoading = false          // ALWAYS clear (success, failure, or cancellation)
        guard let g else { return }      // Guide unavailable (retryable) — neutral state + Retry button
        guide = g
        // M-c legacy migration: ensure a default MusicDirection exists for Stories created before
        // MusicDirection shipped. Fire-and-forget, non-blocking; infers ONCE if absent, leaves any
        // user-authored direction untouched. No UI on Story Home (the MUSIC surface is on Creative
        // Direction) — this only backfills so a future MusicPlan has a direction to read.
        let musicCoord = MusicDirectionCoordinator(context: context)
        if musicCoord.direction(for: story.id) == nil,
           !CloudHydrationGate.shared.isHydratingAfterSeed(storyId: story.id, context: context) {
            Task { await musicCoord.ensure(for: story, guideFramingSummary: g.framingSummary) }
        }
        let guideFingerprint = coordinator.guideFingerprint(for: story.id)

        let inputs = engine.currentInputs(for: story)
        guard !inputs.completedMUValues.isEmpty else {
            MediaEngineV1.beacon("coverage: moments=\(story.moments.count) completedAU=0 pending=\(inputs.pendingCount) -> SKIP recompute (no AU)")
            return
        }   // Guide supplies content; no Mapper/Judge
        let wasStale = engine.isStale(for: story, guideFingerprint: guideFingerprint)
        let fresh = await engine.recomputeIfNeeded(for: story, guide: g, guideFingerprint: guideFingerprint)
        if let fresh { coverage = fresh }                         // keep previous on failure
        let repCount = (coverage?.dimensionCoverage ?? []).reduce(0) { $0 + $1.representedPossibilityIds.count }
        let states = (coverage?.dimensionCoverage ?? []).map { "\($0.state)" }.joined(separator: ",")
        let guideDims = g.dimensions.count
        let guidePoss = g.dimensions.reduce(0) { $0 + $1.capturePossibilities.count }
        // Sample the content richness of the first understanding actually sent to coverage: if observed.summary
        // is empty, the mapper sees blanks and maps nothing (represented=0 despite AU present).
        var firstSummaryLen = -1
        var firstSubj = -1, firstEv = -1, firstUseful = -1
        if case .object(let o)? = inputs.completedMUValues.first {
            if case .object(let obs)? = o["observed"] {
                if case .string(let s)? = obs["summary"] { firstSummaryLen = s.count }
                if case .array(let a)? = obs["subjects"] { firstSubj = a.count }
                if case .array(let a)? = obs["events"] { firstEv = a.count }
                if case .array(let a)? = obs["useful_segments"] { firstUseful = a.count }
            } else if case .string(let s)? = o["summary"] {
                firstSummaryLen = -(s.count)   // negative => summary at TOP level (shape drift)
            }
        }
        MediaEngineV1.beacon("coverage: moments=\(story.moments.count) completedAU=\(inputs.completedMUValues.count) "
            + "pending=\(inputs.pendingCount) stale=\(wasStale) dims=\((coverage?.dimensionCoverage ?? []).count) "
            + "represented=\(repCount) firstSummaryLen=\(firstSummaryLen) states=[\(states)] "
            + "subj=\(firstSubj) ev=\(firstEv) useful=\(firstUseful) guideDims=\(guideDims) guidePoss=\(guidePoss)")
    }

    /// After returning from capture, the new Moment's Asset Understanding runs ASYNCHRONOUSLY and is
    /// usually NOT complete yet. Poll a few times so Coverage (and the Story Idea) recompute once AU
    /// lands — otherwise the Idea/Guide-state would stay stale until the next manual revisit.

    // R-c.1 UX: a non-blocking banner shown while picked videos copy out of Photos (so the user isn't left
    // staring at an unchanged Home wondering if the import failed). Driven purely by importProgress.
    @ViewBuilder
    private var importBanner: some View {
        if let p = importProgress {
            Text(StoryImportCopy.line(for: p))
                .font(StoryTheme.body(13))
                .foregroundStyle(StoryTheme.cream.opacity(0.9))
                .padding(.vertical, 10).padding(.horizontal, 18)
                .background(StoryTheme.surfaceAlt, in: Capsule())
                .overlay(Capsule().stroke(StoryTheme.cream.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: importProgress)
                .accessibilityLabel(StoryImportCopy.line(for: p))
        }
    }

    private func refreshAfterCapture() async {
        let engine = coverageEngine
        var lastCompleted = engine.currentInputs(for: story).completedMUValues.count
        await refreshGuideAndCoverage()
        // Up to ~60s of opportunistic polling for the just-captured Moment's AU to finish.
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)   // 5s
            if Task.isCancelled { return }
            let now = engine.currentInputs(for: story).completedMUValues.count
            if now != lastCompleted {
                lastCompleted = now
                await refreshGuideAndCoverage()                 // AU landed -> recompute coverage + idea
                return
            }
        }
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

// E2-c: Identifiable wrapper so an opportunity-driven capture can drive fullScreenCover(item:).
struct OpportunityLaunch: Identifiable {
    let id = UUID()
    let opportunity: SelectedOpportunityDTO
}
