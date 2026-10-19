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
    @State private var cloudGate = CloudAuthGateModel()
    @Bindable var story: StoryModel
    @Environment(\.dismiss) private var dismiss
    /// When set, this host launches a CREATE ANOTHER VERSION from that parent (Explore + Customize), not a
    /// fresh original create. Nil = fresh original create. Either way this screen NEVER reopens an existing
    /// result — StoryHomeView decides reopen vs create at the Create tap; the preview is always a create.
    var forceNewVersionFrom: GeneratedOutputModel? = nil

    // R-c Batch B: coordinator-driven create/result navigation. The visible Create
    // button is still an intentional disabled state (Batch C flips availability on
    // Story Home) — but the full path is wired HERE so Batch C only toggles the
    // trigger, not the plumbing. `createRoute` decides, via ReopenDecision, whether
    // to open the Result screen for an existing good output or start a new render.
    @State private var showCreating = false
    @State private var reopenOutput: GeneratedOutputModel?
    // P0 recovery: when a reopened Story has a recoverable unfinished operation, route into the Creating
    // screen in resume mode (reuse the job, no re-inference) instead of showing the redundant create preview.
    @State private var resumePreresolvedMusic: StoryCreationCoordinator.MusicSelection?
    @State private var showResuming = false
    @State private var recoveryChecked = false
    /// Creative Revision Foundation: the parent output a "Create a new version" (Explore) is derived FROM.
    /// Set by handleRecreate; threaded into StoryCreatingView so the coordinator re-plans version-aware. nil
    /// for a first/original create.
    @State private var recreateSource: GeneratedOutputModel?
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
    // Stage 2 music-routing: set when an explicit Stage 2 music preference conflicts with a user-authored
    // MusicDirection — surfaced as an advisory (owner §2), never a silent overwrite.
    @State private var musicConflictMessage: String?

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
        recreateSource = nil                        // original create — not an Explore version
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
                return await durationService.recommend(creativeIntent: p.creativeIntent, moments: p.moments,
                                                       storyId: story.id, context: context)
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
    /// (authoritative — survives relaunch/regeneration), PLUS the optional Stage 2 Creative Direction (resolved
    /// hard directives + soft free text), then continue the unchanged music flow. The directives/soft are the
    /// ONE-TIME creation-time instructions — composeRevisionContext folds them for the ORIGINAL create only, so
    /// a later "Create Another Version" never inherits them. Draft text + chips persist so a failed generation
    /// or navigation keeps what the user typed.
    private func acceptCustomize(seconds: Double, sound: SoundPreference, mode: String, approach: EditingApproach,
                                 directives: ResolvedDirectives?, soft: String, chipIds: [UUID],
                                 music: ParsedMusicIntent) {
        durationRec = nil
        story.intentTargetDurationSeconds = (seconds * 10).rounded() / 10
        story.soundPreferenceExplicit = sound.rawValue   // explicit choice; never overwritten by inference
        story.editorialMode = mode                        // highlights|full|custom -> edit-plan request breadth
        story.editingApproachExplicit = approach.rawValue // storytelling|visual_first -> planning path
        // Stage 2 Creative Direction — persist resolved HARD directives (stable UUIDs) + the SOFT text draft.
        // nil directives => clear any stale persisted set (empty input preserves prior behavior). Never touches
        // the factual Story description (intentText). Beat-sync lives INSIDE `soft` (edit-planner only) — it is
        // intentionally not routed to music, so matching cuts to the music never changes the soundtrack (§1).
        story.creativeDirectivesJSON = directives?.toWireJSON()
        let trimmedSoft = soft.trimmingCharacters(in: .whitespacesAndNewlines)
        story.creativeDirectionText = trimmedSoft.isEmpty ? nil : trimmedSoft
        try? context.save()
        // Route an EXPLICIT music PREFERENCE to MusicPlan via MusicDirection (owner §1/§2). A user-authored
        // direction is authoritative — do NOT silently overwrite; surface the conflict and keep theirs. When
        // none is user-authored, the deliberate Stage 2 instruction becomes the authored direction so the
        // downstream music recommender uses it. Music-only: this regenerates nothing else (§4) — AU/Guide/
        // Coverage are independent; it just bumps the MusicDirection fingerprint the MusicPlan cache compares.
        if let pref = music.preference {
            let coord = MusicDirectionCoordinator(context: context)
            if coord.isUserAuthored(for: story.id) {
                let existing = coord.direction(for: story.id)?.moodTags ?? []
                // Surface only a MATERIAL conflict (the requested moods are not already covered).
                if !Set(pref.moodTags).isSubset(of: Set(existing)) {
                    musicConflictMessage = "You asked for “\(pref.phrase)” music, but this Story already has a "
                        + "music feel you set earlier. I kept your earlier choice. Change it from the music "
                        + "controls if you want “\(pref.phrase)” instead."
                }
                // else: compatible — nothing to do, the authored direction already covers it.
            } else {
                let moods = pref.moodTags
                let summary = "A \(moods.joined(separator: " · ")) soundtrack"
                let dto = MusicDirectionContractDTO(summary: summary, moodTags: moods, energy: nil,
                                                    progression: nil, rawUserDescription: pref.phrase)
                coord.save(userEdit: dto, for: story.id)   // deliberate Stage 2 instruction -> authored
            }
        }
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
            // A "Your music" row is either an imported file (resolve locally) or a SAVED PROVIDER FAVORITE
            // (re-resolve live from the provider — licensing: no bytes were ever stored).
            if let uuid = UUID(uuidString: assetId),
               let asset = try? context.fetch(
                FetchDescriptor<MyMusicAssetModel>(predicate: #Predicate { $0.id == uuid })).first,
               let providerTrackId = asset.providerTrackId {
                preparingSelection = true
                Task {
                    let sel = await musicResolver.resolveSelection(recommendation: rec, trackId: providerTrackId)
                    await MainActor.run {
                        preparingSelection = false
                        chosenMusic = sel
                        MediaEngineV1.beacon("picker: chose saved-favorite=\(providerTrackId.prefix(8)) resolved=\(sel == nil ? "NIL" : "ok")")
                        showCreating = true
                    }
                }
            } else {
                chosenMusic = Self.myMusicSelection(assetId: assetId, story: story, context: context)
                MediaEngineV1.beacon("picker: chose myMusic=\(assetId.prefix(8)) resolved=\(chosenMusic == nil ? "NIL" : "ok")")
                DispatchQueue.main.async { showCreating = true }
            }
        }
    }

    /// "Create a new version" from a REOPENED Result: drop Result and FORCE the create+picker flow (never the
    /// reopen shortcut — otherwise it would bounce straight back to the existing output and never re-create).
    private func handleRecreate(from source: GeneratedOutputModel?) {
        reopenOutput = nil
        chosenMusic = nil
        showCreating = false
        recreateSource = source     // Explore: re-plan FROM this version; nil => plain re-create
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
        // Pure flow host — NEVER the old "Here's what I'm working with" grid. This screen is reached only when
        // a create is actually needed (StoryHomeView routes an existing result straight to the Result screen),
        // and onAppear immediately starts the flow (duration -> Customize -> music -> Creating). We show only a
        // minimal preparing state behind those sheets so there is no redundant resting page.
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Text("←").font(StoryTheme.body(18)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                        .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Back")
                Spacer()
            }
            .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 8)
            Spacer()
            ProgressView().tint(StoryTheme.gold)
            Text("Preparing your Story…")
                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.55))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .storyBackground()
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackToDismiss(dismiss)
        .onAppear {
            guard !recoveryChecked else { return }
            recoveryChecked = true
            // This host ONLY starts a create (StoryHomeView routes reopen -> Result and in-flight resume
            // elsewhere). It deliberately does NOT do recovery routing — doing so here raced the app-level
            // PendingOperationRecovery on the SAME op and stuck the UI in a "Preparing" loop. A Create Another
            // Version from a parent (Explore + Customize), else a fresh original create.
            // P0 Phase 4: creating a video runs paid AI (duration rec, music recommend, edit-plan) — require
            // sign-in first, then start the flow (resumes once; no duplicate create).
            if let parent = forceNewVersionFrom {
                MediaEngineV1.beacon("preview-route: NEW_VERSION story=\(story.id.uuidString.prefix(8))")
                cloudGate.run { handleRecreate(from: parent) }
            } else {
                MediaEngineV1.beacon("preview-route: CREATE story=\(story.id.uuidString.prefix(8))")
                cloudGate.run { beginCreateFlow() }
            }
        }
        // R-d: new render -> picker (sheet) -> Creating with the CHOSEN selection (nil = no-music). Creating
        // renders exactly that track and self-manages its Result. Reopen -> Result directly.
        // These are presented as fullScreenCover (NOT navigationDestination): this host is itself a pushed
        // view, and a nested navigationDestination set from onAppear / after a sheet dismissal fires
        // unreliably on a pushed view (it silently dropped the Creating push, so the edit-plan job was never
        // submitted). A cover is reliable regardless of nav-stack timing.
        .fullScreenCover(isPresented: $showCreating) {
            StoryCreatingView(story: story, preresolvedMusic: chosenMusic, musicIsPreresolved: true,
                              sourceVersion: recreateSource,
                              onRequestRecreate: { src in handleRecreate(from: src) },
                              onCompleted: { out in showCreating = false; reopenOutput = out })
        }
        .fullScreenCover(item: $reopenOutput) { output in
            StoryResultView(story: story, initialOutput: output, onHome: goHome,
                            onRecreate: { src in handleRecreate(from: src) })
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
                initialEditingApproach: story.effectiveEditingApproach,
                visualFirstAvailable: StoryMultimodalPlanning.enabled,
                numbering: StoryMomentNumbering(story: story.moments),
                momentForId: { id in story.moments.first { $0.id == id } },
                initialCreativeDirection: story.creativeDirectionText ?? "",
                // Seed ONLY must_include as visual chips. Chips are an INCLUDE-only control
                // (CustomizeYourStoryView maps every chip to slot .include), so folding opening/ending/exclude
                // ids in here silently DOWNGRADES them to must_include on every round-trip through this sheet —
                // the opening directive was being destroyed, which is why "Start with Moment N" never moved the
                // clip to the front. opening/ending survive via the typed creativeDirectionText above, not chips.
                initialReferenceChipIds: ResolvedDirectives.fromWireJSON(story.creativeDirectivesJSON)
                    .map { $0.mustInclude } ?? [],
                onCreate: { seconds, sound, mode, approach, directives, soft, chipIds, music in
                    acceptCustomize(seconds: seconds, sound: sound, mode: mode, approach: approach,
                                    directives: directives, soft: soft, chipIds: chipIds, music: music) },
                onCancel: { durationRec = nil })
                .presentationDetents([.large])
                // Force a FRESH view identity each time the sheet opens. CustomizeYourStoryView seeds its
                // `creativeDirection` @State once from initialCreativeDirection; .sheet(item:) alone can reuse
                // the view identity across presentations, so without this the editor keeps a STALE seed and the
                // user's latest typed instruction is silently replaced by a prior operation's persisted text at
                // submit (observed: "Start from Moment 15" submitted instead of the freshly typed input).
                // rec.id is a fresh UUID per presentation, so this re-runs init and re-seeds the editor.
                .id(rec.id)
        }
        .alert("Keep shooting", isPresented: $durationNoMaterial) {
            Button("OK", role: .cancel) { durationNoMaterial = false }
        } message: {
            Text("There isn't enough usable footage yet to build a Story. Capture a few more Moments and try again.")
        }
        .alert("Kept your music choice", isPresented: Binding(
            get: { musicConflictMessage != nil }, set: { if !$0 { musicConflictMessage = nil } })) {
            Button("OK", role: .cancel) { musicConflictMessage = nil }
        } message: { Text(musicConflictMessage ?? "") }
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
        .cloudAuthGate(cloudGate)   // P0 Phase 4: gate the create flow (duration/music/edit-plan AI) behind sign-in
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
