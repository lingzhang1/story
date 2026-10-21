import SwiftUI
import SwiftData

// Start a Story — frozen Figma wizard (ScreenStoryIntent → Direction → Context →
// Blueprint). Produces a PERSISTENT Story (distinct from Create Now). Real C1
// resolves the intent at the Context step ("Here's what I understood"); the
// Blueprint arc is a disabled-future surface (no StoryBlueprint capability).
// C3.5.
struct CreativeDirectionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    // P0 Beta Auth Increment 4: gate the cloud-AI "resolve" behind sign-in; present SignInView and resume.
    @Environment(AuthStore.self) private var auth
    @State private var pendingAuthAction: (() -> Void)?
    @State private var resumedPendingAction = false
    @State private var showSignIn = false

    /// Phase 3: when Story creation starts from the Moments Library, the selected Moments are
    /// seeded here. On final confirmation they are linked to the newly-created Story (order
    /// preserved, no media duplication). Empty for the Home "Start a Story" entry.
    var seedMoments: [MomentModel] = []

    enum Step { case describe, feel, context, blueprint }
    @State private var step: Step = .describe
    @State private var title = ""
    @State private var description = ""
    @State private var feeling: String?            // chosen preset tag (optional)
    @State private var isResolving = false
    @State private var errorMessage: String?
    @State private var resolvedStory: StoryModel?       // reflected at Context step
    @State private var navigate = false                 // Start Story -> Story Home
    /// True once the user confirms (taps Start Story). A wizard dismissed BEFORE this with a
    /// Story already created at the Context step deletes that unconfirmed Story on disappear, so
    /// cancelling setup never leaves an orphan "New Story" (Phase 3). Seeded Moments are untouched.
    @State private var confirmed = false
    @State private var guide: StoryGuideDTO?            // real StoryGuide for "Here's what I'll look for"
    @State private var guideLoading = false
    @State private var guideFailed = false
    // M-c: real inferred/edited MusicDirection shown on "Here's what I understood".
    @State private var musicDirection: MusicDirectionContractDTO?
    @State private var musicLoading = false
    @State private var musicSheetOpen = false

    private let presets: [(title: String, desc: String)] = [
        ("Cinematic journey", "Cinematic · Scenic · Journey"),
        ("Energetic adventure", "Energetic · Kinetic · Adventure"),
        ("Personal & emotional", "Personal · Intimate · Emotional"),
        ("Minimal / scenic", "Minimal · Scenic · Quiet"),
    ]

    private var useCases: StoryUseCases {
        // R1: Story creation binds the active account. The Start-a-Story Continue is auth-gated (requireAuthThen)
        // so by the time resolve() calls createStory, this is `.account(story_user_id)`; an unauthenticated path
        // is refused by the repository (StoryCreationRequiresAuth) rather than falling back to a `dev` owner.
        StoryUseCases(repository: StoryRepository(context: context, owner: auth.activeOwner))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                backRow
                switch step {
                case .describe:  describeStep
                case .feel:      feelStep
                case .context:   contextStep
                case .blueprint: blueprintStep
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 8)
        }
        .storyBackground()
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackToDismiss(dismiss)
        .onDisappear {
            // Phase 3: if the wizard is leaving with a Story created (at the Context step) but the
            // user never confirmed (Start Story), discard it so no orphan "New Story" remains. The
            // seeded Moments are independent and are NOT deleted. A confirmed Story is kept.
            if !confirmed, let s = resolvedStory {
                try? useCases.deleteStory(s)
                resolvedStory = nil
            }
        }
        .navigationDestination(isPresented: $navigate) {
            // Reached Story Home THROUGH the wizard (Home→[Library]→wizard→StoryHome). Back must leave the
            // WHOLE create flow, not walk back through describe→feel→blueprint. Pop StoryHome first
            // (navigate=false), then dismiss the wizard on the next runloop so the user lands on whatever
            // presented it (Home, or the Library) in effectively one gesture. Sequencing avoids the ambiguous
            // dismiss() that previously left Back dead while this bool-destination was on screen.
            if let s = resolvedStory {
                StoryHomeView(story: s, onBack: {
                    navigate = false
                    DispatchQueue.main.async { dismiss() }
                })
            }
        }
        .alert("Couldn't create your Story", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Try Again") { Task { await resolve() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .sheet(isPresented: $showSignIn) {
            SignInView(auth: auth,
                       onSignedIn: { resumePendingAuthAction() },
                       onCancel: { cancelPendingAuthAction() })
        }
    }

    /// Require authentication before a cloud-AI action, preserving + resuming it once (P0 Phase 4). In dev
    /// optional-auth the backend still accepts no token, but the app prompts sign-in so the cutover to
    /// required-auth is a one-line flip and the user sees a real prompt rather than a silent anonymous call.
    private func requireAuthThen(_ action: @escaping () -> Void) {
        // Direct, desync-proof gating: if already signed in, run now; otherwise store the action and
        // present the sheet by setting the SAME boolean the .sheet binds to. No mirrored @Observable gate
        // (the old `showSignIn = g.presentingSignIn` mirror could be read before the gate mutated, so the
        // sheet never appeared on a signed-out device — the exact symptom seen in device testing).
        if auth.isSignedIn {
            action()
            return
        }
        pendingAuthAction = action
        resumedPendingAction = false
        showSignIn = true
        #if DEBUG
        print("[AuthGate] Start-a-Story gated: signedOut -> presenting sign-in (showSignIn=\(showSignIn))")
        #endif
    }

    private func resumePendingAuthAction() {
        showSignIn = false
        guard !resumedPendingAction, let action = pendingAuthAction else { return }
        resumedPendingAction = true
        pendingAuthAction = nil
        action()
    }

    private func cancelPendingAuthAction() {
        showSignIn = false
        pendingAuthAction = nil
        resumedPendingAction = false
    }

    private var backRow: some View {
        Button(action: back) {
            Text("← Back").font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textMuted)
        }
    }

    // Step 1 — describe
    private var describeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tell me about\nthis experience.")
                .font(StoryTheme.displayItalic(28)).foregroundStyle(StoryTheme.cream)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("What it is, how long, what you want it to feel like.")
                .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.32))
            StoryTextField(placeholder: "We're hiking the Tour du Mont Blanc for 8 days…",
                           text: $description, minHeight: 220)
            StoryTextField(placeholder: "Give it a title", text: $title, minHeight: 44)
            Spacer(minLength: 8)
            StoryPrimaryButton(title: "Continue") { step = .feel }
                .disabled(cannotContinueDescribe).opacity(cannotContinueDescribe ? 0.4 : 1)
        }
    }
    private var cannotContinueDescribe: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty
        || description.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Confirm "Start Story": Stage 1 is description-only — Moment-specific editing instructions live on the
    /// Stage 2 Customize screen, NOT here. So confirming just marks the Story confirmed and navigates to Story
    /// Home; seeded Library Moments were already attached in resolve(). No directives are persisted here.
    private func confirmStart() {
        confirmed = true
        navigate = true
    }

    // Step 2 — feel (optional preset; any input is enough)
    private var feelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How should this\nStory feel?")
                .font(StoryTheme.displayItalic(27)).foregroundStyle(StoryTheme.cream)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick a feeling, add a reference, or describe it. Any one is enough.")
                .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.32))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(presets, id: \.title) { p in
                    let selected = feeling == p.title
                    let dimmed = feeling != nil && !selected
                    Button { feeling = selected ? nil : p.title } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer(minLength: 0)
                            Text(p.title).font(StoryTheme.display(17))
                                .foregroundStyle(StoryTheme.cream)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(p.desc).font(StoryTheme.body(11))
                                .foregroundStyle(StoryTheme.cream.opacity(0.4))
                                .padding(.top, 5)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .bottomLeading)
                        .padding(.horizontal, 15).padding(.vertical, 16)
                        .background(selected ? StoryTheme.gold.opacity(0.08) : StoryTheme.cream.opacity(0.03))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(selected ? StoryTheme.gold : StoryTheme.cream.opacity(0.1),
                                    lineWidth: selected ? 2 : 1.5))
                        .overlay(alignment: .topTrailing) {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(StoryTheme.ink)
                                    .frame(width: 18, height: 18)
                                    .background(StoryTheme.gold).clipShape(Circle())
                                    .padding(10)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .opacity(dimmed ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Reference media — disabled future (dashed, like Figma + Add a reference).
            Text("+ Add a reference")
                .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.45))
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(StoryTheme.cream.opacity(0.18)))
                .accessibilityHint("Not available yet")
            Text("or describe it").font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
            StoryTextField(placeholder: "Mostly landscapes and the scale of the mountains. Include us naturally. Slow, cinematic feeling.",
                           text: $description, minHeight: 96)
            StoryPrimaryButton(title: "Continue") { requireAuthThen { Task { await resolve() } } }
        }
    }

    // Step 3 — context (reflect the REAL resolved intent)
    private var contextStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isResolving {
                StoryThinkingState(line: "Reading what you wrote…")
                    .frame(maxWidth: .infinity).padding(.top, 60)
            } else if let s = resolvedStory {
                Text("Here's what I understood.")
                    .font(StoryTheme.display(28)).foregroundStyle(StoryTheme.cream)
                Text(s.title.displayTitle).font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
                Text(s.intentSummary).font(StoryTheme.body(16))
                    .foregroundStyle(StoryTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                // Music direction (M-c) — the REAL inferred/edited feel, with Change →.
                MusicDirectionRow(summary: musicSummaryLine, loading: musicLoading) { musicSheetOpen = true }
                StoryPrimaryButton(title: "Looks good") { Task { await enterBlueprint() } }
                StorySecondaryButton(title: "Edit") { step = .describe; resolvedStory = nil }
            }
        }
        .task(id: resolvedStory?.id) { await loadMusicDirection() }
        .sheet(isPresented: $musicSheetOpen) {
            MusicDirectionSheet(
                current: musicDirection,
                onSave: { feel, desc in Task { await saveMusicEdit(feel: feel, description: desc) } },
                onAuto: { Task { await resetMusicToInferred() } }
            )
        }
    }

    // The one-line feel shown in the row: user/inferred summary, or a calm pending line.
    private var musicSummaryLine: String {
        if let md = musicDirection {
            if !md.moodTags.isEmpty {
                return md.moodTags.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " · ")
            }
            return md.summary
        }
        return musicLoading ? "Finding the right feel…" : "Story will choose a fitting feel"
    }

    @MainActor
    private func loadMusicDirection() async {
        guard let s = resolvedStory else { return }
        let coord = MusicDirectionCoordinator(context: context)
        if let existing = coord.direction(for: s.id) { musicDirection = existing; return }
        musicLoading = true
        defer { musicLoading = false }
        musicDirection = await coord.ensure(for: s, guideFramingSummary: guide?.framingSummary)
    }

    // Step 4 — "Here's what I'll look for" (E2-c): the REAL persistent StoryGuide, generated once from
    // CreativeIntent, shown BEFORE Moment #1. Advisory creative map — NOT a required-shot list. No TMB
    // demo content; every line derives from this Story's own Guide.
    private var blueprintStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let s = resolvedStory {
                Text(s.title.displayTitle).font(StoryTheme.body(13)).tracking(0.3)
                    .foregroundStyle(StoryTheme.cream.opacity(0.5))
            }
            Text("Here's what I'll look for.")
                .font(StoryTheme.display(28)).foregroundStyle(StoryTheme.cream)

            if guideLoading {
                StoryThinkingState(line: "Thinking about your Story…")
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else if let g = guide {
                // framing_summary — the Figma companion line.
                if !g.framingSummary.isEmpty {
                    Text(g.framingSummary)
                        .font(StoryTheme.body(15).italic())
                        .foregroundStyle(StoryTheme.cream.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Dimensions: label + purpose, as the creative map (no possibilities/requirements here).
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(g.dimensions) { dim in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dim.label).font(StoryTheme.display(18).italic())
                                .foregroundStyle(StoryTheme.cream.opacity(0.9))
                            Text(dim.purpose).font(StoryTheme.body(13))
                                .foregroundStyle(StoryTheme.cream.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("This can change as your Story unfolds.")
                    .font(StoryTheme.body(12).italic()).foregroundStyle(StoryTheme.cream.opacity(0.4))
                    .padding(.top, 2)
                Text("You're all set.").font(StoryTheme.display(20)).foregroundStyle(StoryTheme.cream)
                    .padding(.top, 6)
                Text("Capture naturally as you go. A guide, not a checklist — capture what feels right.")
                    .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                StoryPrimaryButton(title: "Start Story") { confirmStart() }
            } else {
                // Guide generation failed (retryable) — the Story is still valid; let the user proceed.
                Text("You're all set.").font(StoryTheme.display(20)).foregroundStyle(StoryTheme.cream)
                Text("Capture naturally as you go — your guide will appear shortly.")
                    .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if guideFailed {
                    StorySecondaryButton(title: "Try again") { Task { await generateGuide() } }
                }
                StoryPrimaryButton(title: "Start Story") { confirmStart() }
            }
        }
    }

    private func enterBlueprint() async {
        step = .blueprint
        await generateGuide()
    }

    private func generateGuide() async {
        guard let s = resolvedStory, guide == nil else { return }
        guideFailed = false
        guideLoading = true
        let coordinator = StoryGuideCoordinator(context: context)
        let g = await coordinator.ensureGuide(for: s)
        guideLoading = false
        if let g { guide = g } else { guideFailed = true }
    }

    private func back() {
        switch step {
        case .describe:  dismiss()
        case .feel:      step = .describe
        case .context:   step = .feel
        case .blueprint: step = .context
        }
    }

    private func resolve() async {
        isResolving = true; errorMessage = nil; step = .context
        defer { isResolving = false }
        do {
            // Prepend the chosen feeling to the direction so C1 sees it.
            let dir = feeling.map { "\($0). \(description)" } ?? description
            let story = try await useCases.startStoryWithRealIntent(title: title, direction: dir)
            // Phase 3: attach the library-selected Moments to THIS story once, in selection order
            // (idempotent + no media duplication). Done here so the Guide/blueprint reasons over them.
            if !seedMoments.isEmpty {
                try? useCases.addExistingMoments(seedMoments, to: story)
            }
            resolvedStory = story
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Something went wrong. Please try again."
            step = .feel
        }
    }

    // M-c: persist a user-authored MusicDirection. Overrides inference permanently; regenerates nothing.
    @MainActor
    private func saveMusicEdit(feel: [String], description: String) async {
        guard let s = resolvedStory else { return }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let moods = feel.map { $0.lowercased() }
        let summary = !trimmed.isEmpty ? trimmed
            : (moods.isEmpty ? "A fitting soundtrack" : "A \(moods.joined(separator: " · ")) soundtrack")
        let dto = MusicDirectionContractDTO(
            summary: summary, moodTags: moods, energy: nil, progression: nil,
            rawUserDescription: trimmed.isEmpty ? nil : trimmed)
        let coord = MusicDirectionCoordinator(context: context)
        coord.save(userEdit: dto, for: s.id)
        musicDirection = dto
        musicSheetOpen = false
    }

    // "Let Story choose" — clear the user override and re-infer the default.
    @MainActor
    private func resetMusicToInferred() async {
        guard let s = resolvedStory else { return }
        let coord = MusicDirectionCoordinator(context: context)
        // Clear any existing row so ensure() re-infers a fresh default.
        coord.clear(for: s.id)
        musicDirection = nil
        musicSheetOpen = false
        musicLoading = true
        defer { musicLoading = false }
        musicDirection = await coord.ensure(for: s, guideFramingSummary: guide?.framingSummary)
    }
}

// M-c Music row on "Here's what I understood" — mirrors the frozen Figma MusicDirectionRow:
// eyebrow "♫ Music", the one feel line, a quiet "Change →". No track, no playback.
private struct MusicDirectionRow: View {
    let summary: String
    let loading: Bool
    let onChange: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                StoryEyebrow(text: "♫ Music")
                Text(summary).font(StoryTheme.display(16))
                    .foregroundStyle(StoryTheme.cream.opacity(loading ? 0.4 : 0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Change", action: onChange)
                .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.gold)
                .disabled(loading)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(StoryTheme.cream.opacity(0.06)).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(StoryTheme.cream.opacity(0.06)).frame(height: 1) }
    }
}

// M-c Change sheet — mirrors the frozen Figma MusicDirectionSheet: feel chips + optional free-text,
// "Done" (user-authored) or "Let Story choose" (auto). The feeling only — the actual track is a
// later (M-d) concern and stays absent here.
private struct MusicDirectionSheet: View {
    let current: MusicDirectionContractDTO?
    let onSave: ([String], String) -> Void
    let onAuto: () -> Void
    @Environment(\.dismiss) private var dismiss

    private static let feels = ["Cinematic", "Emotional", "Epic", "Dreamy", "Energetic", "Chill"]
    // Inferred mood vocabulary (DeterministicMusicDirectionEngine) -> the nearest UI chip, so the
    // sheet pre-selects what the row shows. Keeps the row, sheet, and saved edit in ONE vocabulary.
    private static let inferredToChip: [String: String] = [
        "cinematic": "Cinematic", "emotional": "Emotional", "intimate": "Emotional",
        "uplifting": "Emotional", "epic": "Epic", "dreamy": "Dreamy", "atmospheric": "Dreamy",
        "energetic": "Energetic", "gritty": "Energetic", "playful": "Energetic",
        "calm": "Chill", "chill": "Chill",
    ]
    @State private var selected: Set<String> = []
    @State private var desc: String = ""

    private var hasInput: Bool { !selected.isEmpty || !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How should the music feel?")
                .font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
            Text("Just the feeling — Story finds the track later.")
                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.35))
            FlowChips(options: Self.feels, selected: $selected)
            TextField("Describe it… (optional)", text: $desc, axis: .vertical)
                .lineLimit(2...4).font(StoryTheme.body(14))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(StoryTheme.cream.opacity(0.04)))
            StoryPrimaryButton(title: "Done") { onSave(Array(selected), desc) }
                .disabled(!hasInput).opacity(hasInput ? 1 : 0.4)
            Button("✦ Let Story choose") { onAuto() }
                .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                .frame(maxWidth: .infinity)
            // Track selection / preview is a later milestone — visibly unavailable, in place.
            StoryUnavailableSection(header: { StoryEyebrow(text: "Choose a track") },
                message: "Track selection and preview aren't available yet.")
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .onAppear {
            if let md = current, md.rawUserDescription != nil || !md.moodTags.isEmpty {
                desc = md.rawUserDescription ?? ""
                // Map each inferred mood tag to its nearest chip; also accept any tag that is already
                // a chip label (user-authored edits store chip labels lowercased).
                selected = Set(md.moodTags.compactMap { tag -> String? in
                    let lower = tag.lowercased()
                    if let chip = Self.inferredToChip[lower] { return chip }
                    let titled = lower.prefix(1).uppercased() + lower.dropFirst()
                    return Self.feels.contains(titled) ? titled : nil
                })
            }
        }
    }
}

// Minimal wrapping chip row for the feel presets.
private struct FlowChips: View {
    let options: [String]
    @Binding var selected: Set<String>
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { f in
                let on = selected.contains(f)
                Button(f) { if on { selected.remove(f) } else { selected.insert(f) } }
                    .font(StoryTheme.body(13))
                    .foregroundStyle(on ? StoryTheme.ink : StoryTheme.cream.opacity(0.6))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(on ? StoryTheme.gold : .clear))
                    .overlay(Capsule().stroke(on ? StoryTheme.gold : StoryTheme.cream.opacity(0.14), lineWidth: 1))
            }
        }
    }
}
