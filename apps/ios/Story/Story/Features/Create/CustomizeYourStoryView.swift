import SwiftUI

// Customize Your Story — replaces the compact DurationChoiceView sheet. Two sections, both built from existing
// intelligence (no new universal defaults): Section A Story Length (Highlights / Full Story / Custom) off the
// Duration Intelligence recommendation; Section B Sound (Immersive / Balanced / Music-led) showing the Story's
// INFERRED recommendation while letting the user override it. Dark editorial Figma language; whole rows are
// tappable; obvious selected states; concise explanations; NO sliders/percentages/jargon in the main flow
// (an exact-seconds field stays behind the Custom row). The Music Picker flow downstream is unchanged.
struct CustomizeYourStoryView: View {
    let rec: DurationRecommendation
    let inferredSound: SoundPreference?         // advisory recommendation (nil => none inferred)
    let initialExplicitSound: SoundPreference?  // the user's prior explicit choice, if any
    let initialEditingApproach: EditingApproach // the Story's current approach (default .storytelling)
    /// Whether the Visual-first option can be honored right now (StoryMultimodalPlanning.enabled). When false
    /// the Editing Approach section is HIDDEN entirely — we never present an option that silently can't run.
    let visualFirstAvailable: Bool
    /// STABLE Moment-number snapshot for Creative Direction (Stage 2). Empty => the section is hidden (no
    /// referenceable Moments). Typed "Moment N" references resolve against THIS snapshot.
    let numbering: StoryMomentNumbering
    /// Resolve a stable Moment id -> MomentModel for the visual picker's live thumbnails (no media copy).
    let momentForId: (UUID) -> MomentModel?
    /// Draft Creative Direction text to repopulate (survives navigation / failed generation).
    let initialCreativeDirection: String
    /// Draft reference chips to repopulate (stable ids; display numbers re-derived from `numbering`).
    let initialReferenceChipIds: [UUID]
    /// Returns chosen duration (seconds), sound, length wire, editing approach, resolved HARD directives (nil
    /// when none), the SOFT creative-direction text, the chip ids, and the parsed MUSIC intent — so the caller
    /// persists the draft, forwards directives + soft_direction to the edit planner, and routes an explicit
    /// music preference to MusicPlan (owner Music-Routing §1).
    let onCreate: (Double, SoundPreference, String, EditingApproach, ResolvedDirectives?, String, [UUID], ParsedMusicIntent) -> Void
    let onCancel: () -> Void

    enum LengthChoice: Hashable { case highlights, full, custom
        var wire: String { switch self { case .highlights: return "highlights"; case .full: return "full"; case .custom: return "custom" } }
    }

    @State private var length: LengthChoice
    @State private var sound: SoundPreference
    @State private var approach: EditingApproach
    @State private var customSeconds: Double
    // Stage 2 Creative Direction (optional). Draft text + reference chips, resolved to directives on Create.
    @State private var creativeDirection: String
    @State private var chips: [MomentReferenceChipModel]
    @State private var showReferencePicker = false
    @State private var clarification: String?
    // Interpretation lifecycle (owner safeguards #1/#2): guard duplicate taps, drop stale async responses, and
    // carry a retryable failure. `interpretToken` is bumped on every input edit / dismissal so a response that
    // resolves AFTER the user changed the text or left the sheet is discarded instead of submitting.
    @State private var isInterpreting = false
    @State private var interpretToken = UUID()
    @State private var retryableInstruction: String?   // non-nil => a Retry affordance is shown

    init(rec: DurationRecommendation, inferredSound: SoundPreference?, initialExplicitSound: SoundPreference?,
         initialEditingApproach: EditingApproach = .default, visualFirstAvailable: Bool = false,
         numbering: StoryMomentNumbering = StoryMomentNumbering(ordered: []),
         momentForId: @escaping (UUID) -> MomentModel? = { _ in nil },
         initialCreativeDirection: String = "", initialReferenceChipIds: [UUID] = [],
         onCreate: @escaping (Double, SoundPreference, String, EditingApproach, ResolvedDirectives?, String, [UUID], ParsedMusicIntent) -> Void,
         onCancel: @escaping () -> Void) {
        self.rec = rec; self.inferredSound = inferredSound; self.initialExplicitSound = initialExplicitSound
        self.initialEditingApproach = initialEditingApproach; self.visualFirstAvailable = visualFirstAvailable
        self.numbering = numbering; self.momentForId = momentForId
        self.initialCreativeDirection = initialCreativeDirection; self.initialReferenceChipIds = initialReferenceChipIds
        self.onCreate = onCreate; self.onCancel = onCancel
        // Default length: Full Story when a recommended point exists, else Custom.
        _length = State(initialValue: rec.recommendedPointSeconds != nil ? .full : .custom)
        // Default sound: the user's explicit choice if any, else the inferred recommendation, else balanced.
        _sound = State(initialValue: initialExplicitSound ?? inferredSound ?? .balanced)
        // Default approach: the Story's current approach (defaults to .storytelling). If Visual-first is not
        // available, force storytelling so a hidden section can never leave a non-honorable selection.
        _approach = State(initialValue: visualFirstAvailable ? initialEditingApproach : .storytelling)
        let seed = rec.recommendedPointSeconds
            ?? ((rec.evidence.feasibleBandSeconds.first ?? 10) + (rec.evidence.feasibleBandSeconds.last ?? 30)) / 2
        _customSeconds = State(initialValue: seed.rounded())
        // Seed Creative Direction draft (survives navigation / failed generation). Chips re-derive their display
        // number from the current numbering snapshot; an id no longer present is dropped (surfaced on Create).
        _creativeDirection = State(initialValue: initialCreativeDirection)
        _chips = State(initialValue: numbering.items
            .filter { initialReferenceChipIds.contains($0.id) }
            .map { MomentReferenceChipModel(id: $0.id, displayNumber: $0.number) })
    }

    private var ceiling: Double { max(rec.recommendation?.feasibleCeilingSeconds ?? 60, rec.evidence.feasibleBandSeconds.last ?? 60) }
    private var floor: Double { max(3, rec.evidence.feasibleBandSeconds.first ?? 5) }
    private var fullSeconds: Double? { rec.recommendedPointSeconds }
    private var highlightsSeconds: Double? { rec.highlightsPointSeconds }
    private var clampedCustom: Double { min(max(customSeconds.rounded(), floor), ceiling) }

    private var chosenSeconds: Double {
        switch length {
        case .highlights: return highlightsSeconds ?? clampedCustom
        case .full:       return fullSeconds ?? clampedCustom
        case .custom:     return clampedCustom
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Customize Your Story").font(StoryTheme.display(26)).foregroundStyle(StoryTheme.cream)
                    Text("A few choices before your Story comes together.")
                        .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textSecondary)
                }

                // SECTION — Creative Direction (OPTIONAL; Stage 2) — TOP of the sheet (the primary creative
                // input). Shown only when there are referenceable Moments. Natural-language instructions + typed
                // "Moment N" references + a visual picker; typed references resolve against the stable numbering
                // snapshot. Hard references that don't resolve BLOCK Create (never silently dropped). Empty =>
                // request byte-identical to today.
                if numbering.count > 0 {
                    section(title: "Creative Direction",
                            subtitle: "Optional. Guide the edit in your own words, or reference Moments by number.") {
                        StoryTextField(placeholder: "Start with Moment 5, then Moment 2. Make the cuts faster…",
                                       text: $creativeDirection, minHeight: 110)
                            // Editing the instruction invalidates any in-flight interpretation (owner #1): a
                            // response that resolves after this edit must NOT submit the old text.
                            .onChange(of: creativeDirection) { _, _ in
                                interpretToken = UUID()
                                if retryableInstruction != nil { retryableInstruction = nil; clarification = nil }
                            }
                        Button { showReferencePicker = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 13, weight: .semibold))
                                Text("Add Moment reference").font(StoryTheme.body(13, .medium))
                            }
                            .foregroundStyle(StoryTheme.gold)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .overlay(Capsule().stroke(StoryTheme.gold.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        MomentReferenceChipRow(chips: chips) { id in chips.removeAll { $0.id == id } }
                        if let clarification {
                            Text(clarification).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.danger)
                        }
                        // Service failure (503/transport): the draft is preserved; offer an explicit Retry
                        // rather than silently proceeding or discarding the instruction (owner #2).
                        if retryableInstruction != nil {
                            Button { attemptCreate() } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                                    Text("Retry").font(StoryTheme.body(13, .medium))
                                }
                                .foregroundStyle(StoryTheme.gold)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .overlay(Capsule().stroke(StoryTheme.gold.opacity(0.5), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // SECTION — Editing approach (the primary structural decision). Shown ONLY when Visual-first
                // can actually be honored (the feature flag is the deployment safety gate), so an unavailable
                // option is never presented. Both approaches preserve length, music, and original sounds.
                if visualFirstAvailable {
                    section(title: "Editing approach", subtitle: "How should Story choose and arrange your footage?") {
                        approachRow(.storytelling)
                        approachRow(.visualFirst)
                        Text("Both approaches preserve your chosen length, music, and original sounds.")
                            .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.textMuted)
                    }
                }

                // SECTION A — Story Length
                section(title: "Story length", subtitle: "Choose how much of the experience to show.") {
                    if let hi = highlightsSeconds {
                        row(selected: length == .highlights, title: "Highlights",
                            detail: "The most memorable moments", trailing: "~\(Int(hi.rounded()))s") { length = .highlights }
                    }
                    if let full = fullSeconds {
                        row(selected: length == .full, title: "Full Story",
                            detail: "More of the journey, details and atmosphere",
                            trailing: "~\(Int(full.rounded()))s") { length = .full }
                    }
                    row(selected: length == .custom, title: "Custom",
                        detail: "Set a specific length", trailing: "Your choice") { length = .custom }

                    if length == .custom {
                        HStack(spacing: 12) {
                            TextField("seconds", value: $customSeconds, format: .number)
                                .keyboardType(.numberPad)
                                .font(StoryTheme.display(20)).foregroundStyle(StoryTheme.cream)
                                .frame(width: 90).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(StoryTheme.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 10))
                            Text("seconds").font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textSecondary)
                            Spacer()
                            Stepper("", value: $customSeconds, in: floor...ceiling, step: 1).labelsHidden()
                        }
                        Text("\(Int(floor))–\(Int(ceiling))s fits your footage")
                            .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.textMuted)
                    }
                }

                // SECTION B — Sound
                section(title: "Sound", subtitle: "How should your Story feel and sound?") {
                    soundRow(.immersive, "Immersive", "Bring natural sounds, voices and atmosphere forward")
                    soundRow(.balanced, "Balanced", "Blend original sounds with background music")
                    soundRow(.musicLed, "Music-led", "Let the soundtrack lead the experience")
                }

                Button { attemptCreate() } label: {
                    HStack(spacing: 8) {
                        if isInterpreting { ProgressView().tint(StoryTheme.ink) }
                        Text(isInterpreting ? "Understanding…" : "Create my Story")
                            .font(StoryTheme.body(17, .semibold)).foregroundStyle(StoryTheme.ink)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(StoryTheme.cream).clipShape(Capsule())
                    .opacity(isInterpreting ? 0.7 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isInterpreting)   // duplicate-tap protection (#1)

                Button("Cancel") { interpretToken = UUID(); onCancel() }
                    .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textMuted)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationBackground(StoryTheme.ink)
        .onDisappear { interpretToken = UUID() }   // drop any in-flight interpretation on dismissal (#1)
        .sheet(isPresented: $showReferencePicker) {
            MomentReferencePicker(
                numbering: numbering,
                momentForId: momentForId,
                alreadyReferenced: Set(chips.map(\.id)),
                onConfirm: { ids in
                    chips = numbering.items.filter { ids.contains($0.id) }
                        .map { MomentReferenceChipModel(id: $0.id, displayNumber: $0.number) }
                })
        }
    }

    /// Resolve the typed references + chips against the stable snapshot. Hard references that cannot resolve
    /// Interpret the instruction through the SHARED InterpretationCoordinator, then hand the resolved directives
    /// to the caller. Owner safeguards: an immutable snapshot of the visible text + chips + numbering is taken
    /// BEFORE the async call; a duplicate tap is ignored while interpreting; a response whose token no longer
    /// matches (text edited or sheet dismissed) is DROPPED; a service failure keeps the draft and offers Retry;
    /// unresolved references BLOCK submit with clarification. Never silently downgrade a hard clause.
    private func attemptCreate() {
        guard !isInterpreting else { return }                 // duplicate-tap protection (#1)
        // Immutable submission snapshot (#1): the exact values the user sees right now.
        let snapshotText = creativeDirection.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotChips = chips
        let snapshotNumbering = numbering
        let token = UUID()
        interpretToken = token
        clarification = nil
        retryableInstruction = nil
        isInterpreting = true

        Task {
            let outcome = await InterpretationCoordinator.interpret(
                snapshotText, numbering: snapshotNumbering,
                summaryForId: { id in momentForId(id)?.caption })

            await MainActor.run {
                // Stale-response drop (#1): the user edited the text or dismissed the sheet mid-flight.
                guard interpretToken == token else { return }
                isInterpreting = false

                // Music ask the typed-directive contract can't express yet — surface honestly (#5).
                let musicSuffix = outcome.unsupportedMusicNote.map { "\n\($0)" } ?? ""

                switch outcome.kind {
                case .serviceFailure:
                    retryableInstruction = snapshotText     // preserve draft + offer Retry (#2)
                    clarification = (outcome.blocking.first ?? "Couldn't interpret that right now.") + musicSuffix
                    return
                case .clarify:
                    // Thumbnail clarification when numeric refs are unresolved, else text (#2).
                    clarification = clarificationText(outcome) + musicSuffix
                    return
                case .ok:
                    break
                }

                // Merge the visual-picker include chips into the interpreted directives (chips are include-only;
                // the typed text owns opening/ending/ordering via the coordinator). Keeps BOTH inputs, one path.
                var directives = outcome.directives
                for c in snapshotChips where !directives.mustInclude.contains(c.id) {
                    directives.mustInclude.append(c.id)
                }
                let finalDirectives: ResolvedDirectives? = directives.isEmpty ? nil : directives
                let music = MomentReferenceResolver.parseMusicIntent(snapshotText)
                if !musicSuffix.isEmpty { clarification = outcome.unsupportedMusicNote }  // non-blocking note
                onCreate(chosenSeconds, sound, length.wire, approach, finalDirectives,
                         snapshotText, snapshotChips.map(\.id), music)
            }
        }
    }

    /// Clarification copy for an unresolved/ambiguous interpretation. Numeric unresolved refs name the Moment
    /// numbers (the picker lets the user pick visually); a non-numeric (semantic) ambiguity asks to rephrase or
    /// use the picker — never silently dropped (#2/#6).
    private func clarificationText(_ o: InterpretationOutcome) -> String {
        if !o.unresolvedMomentNumbers.isEmpty {
            let list = o.unresolvedMomentNumbers.map { "Moment \($0)" }.joined(separator: ", ")
            return "\(list) couldn't be matched (this Story has \(numbering.count)). Pick it with “Add Moment reference”, or rephrase."
        }
        if !o.unresolved.isEmpty {
            return o.unresolved.joined(separator: " ") + " Try rephrasing, or use “Add Moment reference” to pick it."
        }
        if let b = o.blocking.first { return b }
        return "Please rephrase your instruction so I can apply it."
    }

    // MARK: - row builders

    @ViewBuilder
    private func section<Content: View>(title: String, subtitle: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(StoryTheme.body(17, .semibold)).foregroundStyle(StoryTheme.cream)
            Text(subtitle).font(StoryTheme.body(13)).foregroundStyle(StoryTheme.textMuted)
            VStack(spacing: 10) { content() }.padding(.top, 2)
        }
    }

    @ViewBuilder
    private func soundRow(_ value: SoundPreference, _ title: String, _ detail: String) -> some View {
        let isRec = (initialExplicitSound == nil && inferredSound == value)
        row(selected: sound == value, title: title,
            detail: detail, trailing: isRec ? "Recommended" : nil) { sound = value }
    }

    /// A whole-row Editing-Approach option: icon + title + description + a gold supporting line (speed/effort),
    /// matching the Figma mock. Reuses the same gold-ring + check selected state as the other sections.
    @ViewBuilder
    private func approachRow(_ value: EditingApproach) -> some View {
        let selected = approach == value
        Button { approach = value } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? StoryTheme.gold : StoryTheme.textMuted)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.title).font(StoryTheme.body(16, .medium)).foregroundStyle(StoryTheme.cream)
                    Text(value.detail).font(StoryTheme.body(13)).foregroundStyle(StoryTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(value.supporting).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.gold)
                }
                Spacer(minLength: 8)
                Image(systemName: value.icon).foregroundStyle(selected ? StoryTheme.gold : StoryTheme.textMuted)
                    .font(.system(size: 16))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StoryTheme.surfaceAlt.opacity(selected ? 0.9 : 0.5))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? StoryTheme.gold : StoryTheme.cream.opacity(0.08), lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// A whole-row tappable option with an obvious selected state (gold ring + check).
    @ViewBuilder
    private func row(selected: Bool, title: String, detail: String, trailing: String?, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? StoryTheme.gold : StoryTheme.textMuted)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StoryTheme.body(16, .medium)).foregroundStyle(StoryTheme.cream)
                    Text(detail).font(StoryTheme.body(13)).foregroundStyle(StoryTheme.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(StoryTheme.body(13)).foregroundStyle(selected ? StoryTheme.gold : StoryTheme.textMuted)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StoryTheme.surfaceAlt.opacity(selected ? 0.9 : 0.5))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? StoryTheme.gold : StoryTheme.cream.opacity(0.08), lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
