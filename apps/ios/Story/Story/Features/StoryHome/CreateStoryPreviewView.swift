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

    // R-c Batch B: coordinator-driven create/result navigation. The visible Create
    // button is still an intentional disabled state (Batch C flips availability on
    // Story Home) — but the full path is wired HERE so Batch C only toggles the
    // trigger, not the plumbing. `createRoute` decides, via ReopenDecision, whether
    // to open the Result screen for an existing good output or start a new render.
    @State private var showCreating = false
    @State private var reopenOutput: GeneratedOutputModel?
    // R-d music picker step. `musicRecommendation` drives the picker sheet; `resolvingMusic` shows a brief
    // "Finding music…" state while recommend() runs; `chosenMusic` is the resolved selection (nil = no-music)
    // handed to the Creating screen, which renders EXACTLY that track (no auto-select, no stale plan).
    @State private var resolvingMusic = false
    @State private var musicRecommendation: MusicSelectionResolver.Recommendation?
    @State private var chosenMusic: StoryCreationCoordinator.MusicSelection?
    @State private var preparingSelection = false
    // R-d.2 duration intelligence: recommendation-first duration step BEFORE music. `durationRec` drives
    // the duration sheet; `recommendingDuration` shows a brief "Sizing your Story…" state; `durationNoMaterial`
    // triggers a keep-shooting alert. The accepted value writes story.intentTargetDurationSeconds (authoritative).
    @State private var recommendingDuration = false
    @State private var durationRec: DurationRecommendation?
    @State private var durationNoMaterial = false

    private var useCases: StoryUseCases {
        StoryUseCases(repository: StoryRepository(context: context))
    }
    private var musicResolver: MusicSelectionResolver { MusicSelectionResolver(context: context) }
    private var durationService: DurationService { DurationService() }

    /// Duplicate-guard reflection: a create/result flow is already presented for this Story, so the Create
    /// action must not launch a second one (the coordinator also guards concurrent runs via `isCreating`).
    private var isCreateFlowActive: Bool {
        showCreating || reopenOutput != nil || resolvingMusic || musicRecommendation != nil || preparingSelection || recommendingDuration || durationRec != nil
    }

    /// Entry from the Create button. On FIRST entry, if a good persisted output already exists, open it
    /// directly (reopen shortcut); otherwise begin the create+picker flow.
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
            beginCreateFlow()
        }
    }

    /// ALWAYS run the music picker + create path, bypassing the reopen shortcut. Used for a fresh create AND
    /// for "Create a new version" (which must make a NEW output, never bounce back to the existing one). R-d:
    /// resolve a recommendation -> picker; if music is unavailable, go straight to honest no-music Creating.
    /// R-d.2: FIRST ensure a Story duration is chosen. If the CreativeIntent already carries an explicit
    /// target it is preserved and we proceed; otherwise we fetch a recommendation and present it (recommendation
    /// -first, no mandatory picker) so the user accepts/overrides before anything downstream runs.
    private func beginCreateFlow() {
        if story.intentTargetDurationSeconds != nil {
            beginMusicFlow()                        // explicit duration precedence — skip the duration step
            return
        }
        promptDuration()
    }

    /// Always show the duration step (recommendation-first), regardless of an already-chosen target. Used by
    /// "Create a new version" so a re-create lets the user rechoose the length — the natural moment to change it.
    private func promptDuration() {
        recommendingDuration = true
        Task {
            let payload = EditPlanRequestBuilder.momentsPayload(for: story, context: context)
            let rec: DurationRecommendation? = await {
                guard let p = payload else { return nil }
                return await durationService.recommend(creativeIntent: p.creativeIntent, moments: p.moments)
            }()
            await MainActor.run {
                recommendingDuration = false
                if payload == nil {
                    durationNoMaterial = true        // nothing usable -> "keep shooting"
                } else {
                    durationRec = rec ?? .init(fallbackEvidenceFor: payload!)   // nil rec -> manual-only sheet
                }
            }
        }
    }

    /// User accepted a duration (recommended / highlights / custom). Persist it as the Story's authoritative
    /// target, then continue into the music + create flow. Never silently overrides an existing explicit target.
    private func acceptDuration(_ seconds: Double) {
        durationRec = nil
        story.intentTargetDurationSeconds = (seconds * 10).rounded() / 10
        try? context.save()
        beginMusicFlow()
    }

    /// Customize Your Story accept: persist BOTH the chosen duration AND the user's EXPLICIT sound preference
    /// (authoritative — survives relaunch/regeneration), then continue the unchanged music flow.
    private func acceptCustomize(seconds: Double, sound: SoundPreference) {
        durationRec = nil
        story.intentTargetDurationSeconds = (seconds * 10).rounded() / 10
        story.soundPreferenceExplicit = sound.rawValue   // explicit choice; never overwritten by inference
        try? context.save()
        beginMusicFlow()
    }

    /// The music + create path (unchanged R-d behavior), reached once a duration exists.
    private func beginMusicFlow() {
        resolvingMusic = true
        Task {
            let rec = await musicResolver.recommend(for: story, guideFramingSummary: nil)
            await MainActor.run {
                resolvingMusic = false
                if let rec, rec.topTrackId != nil {
                    musicRecommendation = rec          // -> picker sheet
                } else {
                    chosenMusic = nil; showCreating = true   // provider unavailable -> honest no-music
                }
            }
        }
    }

    /// The user made a choice in the picker. Resolve the selected track into a full MusicSelection (download),
    /// then start Creating. On .noMusic or a failed resolve, start Creating with no music (never a fake track).
    private func handlePickerChoice(_ choice: MusicPickerView.Choice, _ rec: MusicSelectionResolver.Recommendation) {
        musicRecommendation = nil
        switch choice {
        case .cancel:
            return   // back out — no creation started
        case .noMusic:
            chosenMusic = nil
            DispatchQueue.main.async { showCreating = true }
        case .track(let trackId):
            preparingSelection = true
            Task {
                let sel = await musicResolver.resolveSelection(recommendation: rec, trackId: trackId)
                await MainActor.run {
                    preparingSelection = false
                    chosenMusic = sel          // nil if download/analysis failed -> honest no-music
                    MediaEngineV1.beacon("picker: chose track=\(trackId.prefix(8)) resolved=\(sel == nil ? "NIL" : "ok")")
                    showCreating = true
                }
            }
        case .myMusic(let assetId):
            // Imported track: resolve LOCALLY (no backend MusicPlan). Mix knobs come from the Story's sound
            // preference; analysis is the local energy-only analysis (beats honestly empty).
            chosenMusic = Self.myMusicSelection(assetId: assetId, story: story, context: context)
            MediaEngineV1.beacon("picker: chose myMusic=\(assetId.prefix(8)) resolved=\(chosenMusic == nil ? "NIL" : "ok")")
            DispatchQueue.main.async { showCreating = true }
        }
    }

    /// "Create a new version" from a REOPENED Result: drop Result and FORCE the create+picker flow (never the
    /// reopen shortcut — otherwise it would bounce straight back to the existing output and never re-create).
    private func handleRecreate() {
        reopenOutput = nil
        chosenMusic = nil
        showCreating = false
        // "Create a new version" is the natural moment to rechoose the length, so re-offer the duration step
        // (recommendation-first) even though this Story already has a target — rather than silently reusing it.
        DispatchQueue.main.async { promptDuration() }
    }

    /// Resolve an imported My Music asset into a MusicSelection LOCALLY (no backend MusicPlan). Mix knobs come
    /// from the Story's effective sound preference; analysis is local (duration + honest-empty beats). Returns
    /// nil (-> honest no-music) if the asset is gone or unreadable.
    @MainActor
    static func myMusicSelection(assetId: String, story: StoryModel, context: ModelContext)
        -> StoryCreationCoordinator.MusicSelection? {
        guard let uuid = UUID(uuidString: assetId),
              let asset = try? context.fetch(
                FetchDescriptor<MyMusicAssetModel>(predicate: #Predicate { $0.id == uuid })).first,
              MyMusicStore.shared.exists(asset),
              let analysis = MyMusicStore.localAnalysis(for: asset) else { return nil }
        asset.lastUsedAt = .now
        try? context.save()
        let knobs = story.effectiveSoundPreference.localMixKnobs
        return StoryCreationCoordinator.MusicSelection(
            musicPlanJSON: .object([:]),              // no backend plan for imported music
            trackId: "mymusic:\(asset.id.uuidString)",
            analysisJSON: .object([:]),
            analysis: analysis,
            soundtrackURL: MyMusicStore.shared.absoluteURL(for: asset.relativePath),
            soundtrackRole: knobs.role,
            nativeAudioPriority: knobs.priority,
            trackTitle: asset.displayName)
    }

    /// Collapse the create flow back to Story Home in one tap.
    private func goHome() {
        reopenOutput = nil
        showCreating = false
        chosenMusic = nil
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

                // Music — now AVAILABLE (R-d): Story recommends a soundtrack and you choose it in the next
                // step. Honest copy, no track named here (that happens in the picker after you tap Create).
                VStack(alignment: .leading, spacing: 6) {
                    StoryEyebrow(text: "Music")
                    Text("Story will suggest a soundtrack — you'll choose it next, or create without music.")
                        .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.textMuted)
                }

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
        .swipeBackToDismiss(dismiss)
        // R-d: new render -> picker (sheet) -> Creating with the CHOSEN selection (nil = no-music). Creating
        // renders exactly that track and self-manages its Result. Reopen -> Result directly.
        .navigationDestination(isPresented: $showCreating) {
            StoryCreatingView(story: story, preresolvedMusic: chosenMusic, musicIsPreresolved: true,
                              onRequestRecreate: handleRecreate)
        }
        .navigationDestination(item: $reopenOutput) { output in
            StoryResultView(story: story, output: output, onHome: goHome, onRecreate: handleRecreate)
        }
        .sheet(item: $musicRecommendation) { rec in
            MusicPickerView(recommendation: rec, resolver: musicResolver,
                            targetDurationSeconds: story.intentTargetDurationSeconds ?? 0) { choice in
                handlePickerChoice(choice, rec)
            }
        }
        .sheet(item: $durationRec) { rec in
            CustomizeYourStoryView(
                rec: rec,
                inferredSound: SoundPreference.infer(theme: story.intentTheme, tone: story.intentTone,
                    desiredFeeling: story.intentDesiredFeeling, styleTags: story.intentStyleTags),
                initialExplicitSound: SoundPreference(rawValue: story.soundPreferenceExplicit ?? ""),
                onCreate: { seconds, sound in acceptCustomize(seconds: seconds, sound: sound) },
                onCancel: { durationRec = nil })
                .presentationDetents([.large])
        }
        .alert("Keep shooting", isPresented: $durationNoMaterial) {
            Button("OK", role: .cancel) { durationNoMaterial = false }
        } message: {
            Text("There isn't enough usable footage yet to build a Story. Capture a few more Moments and try again.")
        }
        .overlay {
            if resolvingMusic || preparingSelection || recommendingDuration {
                ZStack {
                    StoryTheme.ink.opacity(0.72).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().tint(StoryTheme.cream)
                        Text(recommendingDuration ? "Sizing your Story…"
                             : (resolvingMusic ? "Finding music for your Story…" : "Preparing your soundtrack…"))
                            .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.7))
                    }
                }
            }
        }
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
