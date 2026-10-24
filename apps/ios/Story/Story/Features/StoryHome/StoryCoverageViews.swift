import SwiftUI
import SwiftData

// StoryCoverageViews — the REAL Story Guide + Story Idea surfaces (Milestone E),
// wired to StoryCoverageDTO. Preserves the frozen Figma visual design of the
// StoryHome Guide/Idea sections; replaces the neutral "not available" placeholders.
//
// HARD UX RULES (frozen):
//   Story Guide: ordinary language from strengths + meaningful weak dimensions +
//     sufficiency. NEVER raw dimension ids, numeric scores, percentages, progress
//     bars, "3/7", required-shot counts, or filmmaking jargon. Advisory only — the
//     user may always Create My Story. For `sufficient`, a gentle ENOUGH line; never
//     imply the user must stop OR must continue.
//   Story Idea: show ONE card ONLY when story_idea != null; visually optional /
//     inspirational. When null, render NOTHING (no "No ideas" placeholder) — do-nothing
//     intelligence creates no interruption.
//   Pending AU is UNKNOWN, not absent: when pendingCount > 0 the Guide stays honest
//     about uncertainty and NEVER reports pending material as a missing requirement.
//   TMB demo chapter labels are NEVER used — all copy derives from this Story's data.

// MARK: - Presentation mapping (pure, testable)

enum StoryCoveragePresentation {

    /// Ordinary-language "what your Story already contains" lines, derived from
    /// strengths (Coverage/2 carries the positive evidence directly). No ids, no scores.
    /// NOTE (Batch 1): minimal V2 adaptation — the full Figma Guide UX (dimensions +
    /// purposes + possibilities, driven by the persisted StoryGuide) lands in Batch 3.
    static func strengthLines(_ cov: StoryCoverageV2DTO) -> [String] {
        Array(cov.strengths.prefix(3))
    }

    /// Gentle "what could make it stronger" lines — ONLY genuinely weak dimensions,
    /// phrased as optional opportunities, never as homework or required shots.
    /// Suppressed entirely for `sufficient` (ENOUGH state owns that case).
    static func opportunityLines(_ cov: StoryCoverageV2DTO) -> [String] {
        guard cov.sufficiency.status != .sufficient else { return [] }
        // Batch 1: dimension labels/purposes live in the StoryGuide now; Batch 3 renders
        // them from the Guide. Until then, surface the sufficiency reason if present.
        if let r = cov.sufficiency.reason, !r.isEmpty { return [r] }
        return []
    }

    /// The ENOUGH line for a sufficient Story (Figma-consistent). Non-prescriptive.
    static func enoughLine(_ cov: StoryCoverageV2DTO) -> String {
        "Your Story already tells its story. You can keep capturing, or create it now."
    }

    /// A single honest uncertainty line when some Moments are still being understood.
    /// Pending = UNKNOWN, never surfaced as a gap. nil when nothing is pending.
    static func pendingLine(_ cov: StoryCoverageV2DTO) -> String? {
        guard cov.pendingCount > 0 else { return nil }
        let n = cov.pendingCount
        return "Still looking at \(n) more moment\(n == 1 ? "" : "s") — your guide will fill in as they're ready."
    }
}

// MARK: - Story Guide section

// Persistent Story Guide (E2-c): renders the StoryGuide creative map (always, when a Guide exists,
// independent of Coverage) + an optional StoryCoverage/2 overlay (qualitative dimension state +
// represented-possibility [x]/Shoot/Reshoot affordances). Advisory, NEVER a checklist: no
// percentages, no X/Y, no progress bars, no required-shot counts. A dimension can be `strong` with
// ZERO checked possibilities and must still read coherently. Only `represented_possibility_ids` drives
// a literal [x]/Reshoot; coverage state alone NEVER fakes a possibility check.
struct StoryGuideSection: View {
    let guide: StoryGuideDTO?
    let coverage: StoryCoverageV2DTO?
    let isLoading: Bool
    /// Guide possibility -> Shoot (Director entry point B). Wired in Batch 4.
    var onShoot: (_ dimension: StoryGuideDimensionDTO, _ possibility: CapturePossibilityDTO) -> Void = { _, _ in }
    /// Retry Guide generation when it failed/was interrupted (empty state).
    var onRetry: () -> Void = {}

    private func stateFor(_ dimId: String) -> NarrativeCoverageDTO? {
        coverage?.dimensionCoverage.first(where: { $0.storyGuideDimensionId == dimId })?.state
    }
    private func representedIds(_ dimId: String) -> Set<String> {
        Set(coverage?.dimensionCoverage.first(where: { $0.storyGuideDimensionId == dimId })?.representedPossibilityIds ?? [])
    }
    private func stateLabel(_ s: NarrativeCoverageDTO?) -> String? {
        switch s {
        case .strong: return "You've got this covered"
        case .lookingGood: return "Looking strong"
        case .couldUseMore: return "Could use more"
        default: return nil   // unknown -> no tag (neutral)
        }
    }
    private var pendingLine: String? {
        guard let c = coverage, c.pendingCount > 0 else { return nil }
        let n = c.pendingCount
        return "Still looking at \(n) more moment\(n == 1 ? "" : "s") — your guide will fill in as they're ready."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StoryEyebrow(text: "Story Guide")

            if let g = guide {
                Text("A guide, not a checklist — capture what feels right.")
                    .font(StoryTheme.body(12).italic())
                    .foregroundStyle(StoryTheme.cream.opacity(0.4))
                if !g.framingSummary.isEmpty {
                    Text(g.framingSummary)
                        .font(StoryTheme.body(13).italic())
                        .foregroundStyle(StoryTheme.cream.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(g.dimensions) { dim in
                    dimensionBlock(dim)
                }
                if let pendingLine {
                    Text(pendingLine)
                        .font(StoryTheme.body(12).italic())
                        .foregroundStyle(StoryTheme.cream.opacity(0.34))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            } else if isLoading {
                Text("Thinking about your Story…")
                    .font(StoryTheme.body(13).italic())
                    .foregroundStyle(StoryTheme.cream.opacity(0.32))
            } else {
                Text("Your guide appears as your Story comes together.")
                    .font(StoryTheme.body(13).italic())
                    .foregroundStyle(StoryTheme.cream.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onRetry) {
                    Text("Build my guide")
                        .font(StoryTheme.body(13, .medium)).foregroundStyle(StoryTheme.gold)
                }
                .buttonStyle(.plain).padding(.top, 2)
            }
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private func dimensionBlock(_ dim: StoryGuideDimensionDTO) -> some View {
        let represented = representedIds(dim.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(dim.label).font(StoryTheme.display(17))
                    .foregroundStyle(StoryTheme.cream.opacity(0.9))
                Spacer()
                if let tag = stateLabel(stateFor(dim.id)) {
                    Text("· \(tag)").font(StoryTheme.body(12))
                        .foregroundStyle(stateFor(dim.id) == .couldUseMore
                                         ? StoryTheme.gold.opacity(0.85) : StoryTheme.cream.opacity(0.4))
                }
            }
            Text(dim.purpose).font(StoryTheme.body(13))
                .foregroundStyle(StoryTheme.cream.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(dim.capturePossibilities) { poss in
                possibilityRow(dim: dim, poss: poss, isRepresented: represented.contains(poss.id))
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func possibilityRow(dim: StoryGuideDimensionDTO, poss: CapturePossibilityDTO, isRepresented: Bool) -> some View {
        HStack(spacing: 10) {
            // [x] only when a real Moment realizes this example; else a dashed-open circle (invitation).
            Image(systemName: isRepresented ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 15))
                .foregroundStyle(isRepresented ? StoryTheme.cream.opacity(0.85) : StoryTheme.gold.opacity(0.7))
            Text(poss.label).font(StoryTheme.body(14))
                .foregroundStyle(StoryTheme.cream.opacity(isRepresented ? 0.6 : 0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { onShoot(dim, poss) } label: {
                Text(isRepresented ? "Reshoot →" : "Shoot →")
                    .font(StoryTheme.body(13, .medium))
                    .foregroundStyle(isRepresented ? StoryTheme.cream.opacity(0.4) : StoryTheme.gold)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Story Guide v2 (AI shooting script) — cinematic scene cards

// Renders the story_guide/2 shooting script as cinematic scene cards in YoTale's dark/serif/champagne
// language. Each card: a prominent LAZY reference image (text-only when absent/off/failed), scene title,
// concise what-to-capture, compact how-to-shoot, an EXPANDABLE why-it-matters, coverage status (reusing the
// Coverage/2 state keyed by the scene's stable id — exactly like a v1 dimension), a Shoot action, and the
// Unsplash attribution/source link when an image is shown. Shows a SMALL number of scenes first ("Show full
// shooting script" reveals the rest). Advisory, never a checklist. Images NEVER block the card.
struct StoryGuideV2Section: View {
    let guide: StoryGuideV2DTO?
    let coverage: StoryCoverageV2DTO?
    let isLoading: Bool
    /// Short event label for the "Your trip"-style context pill (from the Story title/kind). Optional.
    var eventLabel: String? = nil
    /// Scene possibility (or the scene itself) -> Shoot (Director entry point B). Reuses the v1 dimension/poss
    /// handoff shape via a bridge the parent provides.
    var onShoot: (_ scene: StoryGuideSceneDTO, _ possibility: SceneCapturePossibilityDTO?) -> Void = { _, _ in }
    var onRetry: () -> Void = {}
    /// Fetch ONE reference image for a scene (backend proxy). Returns nil => text-only card. Injected so the
    /// view stays testable and the network stays out of the view.
    var fetchImage: (_ scene: StoryGuideSceneDTO) async -> SceneImageDTO? = { _ in nil }
    /// Fire Unsplash download-tracking when a scene image is actually shown-to-use (owner-documented rule).
    var trackImageUse: (_ image: SceneImageDTO) async -> Void = { _ in }
    // Guide v2.1 — "Update Guide" refinement + pin affordances (all optional; parent wires to the coordinator).
    /// Submit a natural-language Guide update. Returns a short result summary (e.g. "2 added · 1 archived") on
    /// success, or throws for a recoverable error. ASYNC + non-blocking — the current script stays until it returns.
    var onUpdateGuide: (_ instruction: String) async -> String? = { _ in nil }
    /// Whether a scene is user-pinned (protected from refinement). Default false.
    var isPinned: (_ sceneId: String) -> Bool = { _ in false }
    /// Toggle a scene pin. Returns the new pinned state.
    var onTogglePin: (_ sceneId: String) -> Void = { _ in }
    /// Current persistent event context (editable); nil/empty => not set.
    var eventContext: String = ""
    /// Save edited persistent event context.
    var onSaveEventContext: (_ text: String) -> Void = { _ in }

    @State private var showUpdateSheet = false
    @State private var updateText = ""
    @State private var isRefining = false
    @State private var refineSummary: String?
    @State private var refineError: String?

    /// Which scene is featured (hero). Defaults to the first NOT-yet-covered scene, else the first.
    @State private var featuredId: String?
    @State private var showAllOthers = false
    /// Whole section is CLOSED UP by default — the shooting script is a reference, not the home screen's
    /// centerpiece. Tap the header chevron to open the scene cards. Collapsed state keeps the title + scene
    /// count + Update Guide visible as a discoverable spine.
    @State private var sectionExpanded = false

    private func stateFor(_ sceneId: String) -> NarrativeCoverageDTO? {
        coverage?.dimensionCoverage.first(where: { $0.storyGuideDimensionId == sceneId })?.state
    }
    private func isCovered(_ sceneId: String) -> Bool { stateFor(sceneId) == .strong }
    /// Right-aligned status label on a card, reference-matched ("Covered" / "Not captured" / gentle mid).
    private func statusLabel(_ sceneId: String) -> String {
        switch stateFor(sceneId) {
        case .strong:      return "Covered"
        case .lookingGood: return "Looking strong"
        case .couldUseMore: return "Could use more"
        default:           return "Not captured"
        }
    }
    private var pendingLine: String? {
        guard let c = coverage, c.pendingCount > 0 else { return nil }
        let n = c.pendingCount
        return "Still looking at \(n) more moment\(n == 1 ? "" : "s") — your guide will fill in as they're ready."
    }

    /// Resolve the hero scene + the index-derived "SCENE NN" number for each scene.
    private func sceneNumber(_ g: StoryGuideV2DTO, _ scene: StoryGuideSceneDTO) -> Int {
        (g.scenes.firstIndex(where: { $0.id == scene.id }) ?? 0) + 1
    }
    private func resolvedFeatured(_ g: StoryGuideV2DTO) -> StoryGuideSceneDTO? {
        if let fid = featuredId, let s = g.scenes.first(where: { $0.id == fid }) { return s }
        return g.scenes.first(where: { !isCovered($0.id) }) ?? g.scenes.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let g = guide, !g.scenes.isEmpty {
                header(g)
                if sectionExpanded, let hero = resolvedFeatured(g) {
                    FeaturedSceneCard(
                        scene: hero,
                        number: sceneNumber(g, hero),
                        category: StoryGuideV2Section.category(for: sceneNumber(g, hero)),
                        status: statusLabel(hero.id),
                        covered: isCovered(hero.id),
                        pinned: isPinned(hero.id),
                        onTogglePin: { onTogglePin(hero.id) },
                        onShoot: { onShoot(hero, hero.capturePossibilities.first) },
                        fetchImage: { await fetchImage(hero) },
                        trackImageUse: trackImageUse)

                    let others = g.scenes.filter { $0.id != hero.id }
                    if !others.isEmpty { otherScenes(others) }
                }
                if sectionExpanded, let pendingLine {
                    Text(pendingLine).font(StoryTheme.body(12).italic())
                        .foregroundStyle(StoryTheme.cream.opacity(0.34))
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
            } else if isLoading {
                StoryEyebrow(text: "Your Shooting Script")
                Text("Writing your shooting script…")
                    .font(StoryTheme.body(13).italic()).foregroundStyle(StoryTheme.cream.opacity(0.32))
            } else {
                StoryEyebrow(text: "Your Shooting Script")
                Text("Add a little about your event and your shooting script will appear.")
                    .font(StoryTheme.body(13).italic()).foregroundStyle(StoryTheme.cream.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onRetry) {
                    Text("Build my guide").font(StoryTheme.body(13, .medium)).foregroundStyle(StoryTheme.gold)
                }.buttonStyle(.plain).padding(.top, 2)
            }
        }
        .padding(.top, 20)
    }

    // MARK: header (eyebrow + title + framing + pills)
    @ViewBuilder
    private func header(_ g: StoryGuideV2DTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation { sectionExpanded.toggle() } } label: {
                HStack(spacing: 8) {
                    StoryEyebrow(text: "Your Shooting Script")
                    Spacer(minLength: 8)
                    Image(systemName: sectionExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StoryTheme.cream.opacity(0.45))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("shooting-script-disclosure")
            if sectionExpanded, !g.framingSummary.isEmpty {
                Text(g.framingSummary)
                    .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                pill("\(g.scenes.count) scene\(g.scenes.count == 1 ? "" : "s")", gold: true)
                if let ev = eventLabel, !ev.isEmpty { pill(ev, gold: false) }
                Spacer(minLength: 8)
            }
            // Update Guide — a PROMINENT, clearly-tappable action on its own row (not a faint inline link
            // crowded beside the info pills). This is a primary, important feature; give it a visible,
            // bordered gold affordance that reads as a button.
            Button { updateText = ""; refineError = nil; showUpdateSheet = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold))
                    Text("Update Guide").font(StoryTheme.body(14, .semibold))
                    Spacer(minLength: 0)
                    Text("Tell your director what changed")
                        .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.gold.opacity(0.6))
                        .lineLimit(1)
                }
                .foregroundStyle(StoryTheme.gold)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StoryTheme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(StoryTheme.gold.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isRefining)
            .accessibilityIdentifier("update-guide-button")
            .padding(.top, 2)
            if isRefining {
                Text("Updating your shooting script…")
                    .font(StoryTheme.body(12).italic()).foregroundStyle(StoryTheme.cream.opacity(0.4))
            } else if let s = refineSummary {
                Text(s).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.gold.opacity(0.85))
            } else if let e = refineError {
                Text(e).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.5))
            }
        }
        .sheet(isPresented: $showUpdateSheet) { updateGuideSheet }
    }

    // MARK: Update Guide sheet (one-time instruction + editable persistent event context)
    @ViewBuilder
    private var updateGuideSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Tell your director what changed, and the shooting script will update — your filmed and pinned scenes stay.")
                        .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        StoryEyebrow(text: "What's new")
                        TextEditor(text: $updateText)
                            .frame(minHeight: 90).scrollContentBackground(.hidden)
                            .padding(10).background(StoryTheme.cream.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(StoryTheme.cream).font(StoryTheme.body(15))
                        Text("e.g. \"Tomorrow we're visiting Arashiyama\" · \"We filmed lots of temples — suggest something different\" · \"Focus more on us, less on landscapes\"")
                            .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.cream.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        StoryEyebrow(text: "Ongoing event context (optional)")
                        Text("Persistent details about your event you don't want to retype — itinerary, venue, who's there.")
                            .font(StoryTheme.body(11)).foregroundStyle(StoryTheme.cream.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                        TextEditor(text: Binding(get: { eventContext }, set: { onSaveEventContext($0) }))
                            .frame(minHeight: 70).scrollContentBackground(.hidden)
                            .padding(10).background(StoryTheme.cream.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(StoryTheme.cream).font(StoryTheme.body(14))
                    }
                    Spacer(minLength: 8)
                }.padding(18)
            }
            .background(StoryTheme.ink.ignoresSafeArea())
            .navigationTitle("Update Guide")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showUpdateSheet = false }.foregroundStyle(StoryTheme.cream.opacity(0.7))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") { submitUpdate() }
                        .foregroundStyle(StoryTheme.gold)
                        .disabled(updateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func submitUpdate() {
        let instruction = updateText.trimmingCharacters(in: .whitespacesAndNewlines)
        showUpdateSheet = false
        refineSummary = nil; refineError = nil
        isRefining = true
        Task {
            let summary = await onUpdateGuide(instruction)
            await MainActor.run {
                isRefining = false
                if let summary { refineSummary = summary }
                else { refineError = "Couldn't update just now — your current guide is unchanged. Try again." }
            }
        }
    }

    private func pill(_ text: String, gold: Bool) -> some View {
        Text(text)
            .font(StoryTheme.body(12, .medium))
            .foregroundStyle(gold ? StoryTheme.gold : StoryTheme.cream.opacity(0.7))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(StoryTheme.cream.opacity(0.06))
            .clipShape(Capsule())
    }

    // MARK: Other scenes (compact list + View all)
    @ViewBuilder
    private func otherScenes(_ others: [StoryGuideSceneDTO]) -> some View {
        let visible = showAllOthers ? others : Array(others.prefix(3))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Other scenes").font(StoryTheme.body(14, .medium)).foregroundStyle(StoryTheme.cream.opacity(0.75))
                Spacer()
                if others.count > 3 {
                    Button { withAnimation { showAllOthers.toggle() } } label: {
                        Text(showAllOthers ? "Show fewer" : "View all")
                            .font(StoryTheme.body(13, .medium)).foregroundStyle(StoryTheme.gold)
                    }.buttonStyle(.plain)
                }
            }
            ForEach(visible) { scene in
                OtherSceneRow(
                    scene: scene,
                    covered: isCovered(scene.id),
                    onTap: { withAnimation { featuredId = scene.id } },
                    onShoot: { onShoot(scene, scene.capturePossibilities.first) })
            }
        }
        .padding(.top, 6)
    }

    /// A small, deterministic category vocabulary derived from scene position (NOT a backend field — the
    /// contract stays unchanged). Gives the reference's "SCENE NN · CATEGORY" badge a tasteful label.
    static func category(for number: Int) -> String {
        let vocab = ["OPENING", "ATMOSPHERE", "CONNECTION", "TEXTURE", "CLIMAX", "RELEASE", "DETAIL", "REFLECTION"]
        return vocab[(max(1, number) - 1) % vocab.count]
    }
}

// The featured (hero) scene — the reference's big card. Large lazy reference image (text-only when
// absent/off/failed, NEVER blocks the card), SCENE NN · CATEGORY + status row, serif title, what-to-capture,
// a boxed "How to shoot" panel, an expandable "Why this matters", and a cream "Shoot" pill. Attribution +
// source chip shown only when an image is present (Unsplash requirement).
private struct FeaturedSceneCard: View {
    let scene: StoryGuideSceneDTO
    let number: Int
    let category: String
    let status: String
    let covered: Bool
    var pinned: Bool = false
    var onTogglePin: () -> Void = {}
    let onShoot: () -> Void
    let fetchImage: () async -> SceneImageDTO?
    let trackImageUse: (SceneImageDTO) async -> Void

    @State private var image: SceneImageDTO?
    @State private var whyExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Prominent reference image (lazy, hotlinked) — only occupies space once an image exists.
            if let img = image, let url = URL(string: img.imageURL) {
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.25))) { phase in
                        switch phase {
                        case .success(let i): i.resizable().scaledToFill()
                        default: placeholderBand
                        }
                    }
                    .frame(height: 210).frame(maxWidth: .infinity).clipped()
                    // source chip bottom-left (reference: "kyotanuki.com")
                    if let host = sourceHost(img) {
                        Text(host).font(StoryTheme.body(11))
                            .foregroundStyle(StoryTheme.cream.opacity(0.9))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(StoryTheme.ink.opacity(0.55)).clipShape(Capsule())
                            .padding(10)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                // SCENE NN · CATEGORY  …  status
                HStack(alignment: .firstTextBaseline) {
                    Text("SCENE \(String(format: "%02d", number)) · \(category)")
                        .font(StoryTheme.eyebrow()).tracking(1.2)
                        .foregroundStyle(StoryTheme.gold)
                    Spacer()
                    Button(action: onTogglePin) {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .font(.system(size: 12))
                            .foregroundStyle(pinned ? StoryTheme.gold : StoryTheme.cream.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pinned ? "Unpin scene" : "Pin scene")
                    .accessibilityIdentifier("pin-scene-button")
                    Text(status).font(StoryTheme.body(12))
                        .foregroundStyle(covered ? StoryTheme.cream.opacity(0.5) : StoryTheme.cream.opacity(0.4))
                }
                Text(scene.title).font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
                    .fixedSize(horizontal: false, vertical: true)
                Text(scene.whatToCapture).font(StoryTheme.body(15))
                    .foregroundStyle(StoryTheme.cream.opacity(0.8)).fixedSize(horizontal: false, vertical: true)

                // Boxed "How to shoot" panel.
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: "video").font(.system(size: 12)).foregroundStyle(StoryTheme.cream.opacity(0.85))
                        Text("How to shoot").font(StoryTheme.body(13, .medium)).foregroundStyle(StoryTheme.cream.opacity(0.9))
                    }
                    Text(scene.howToShoot).font(StoryTheme.body(13))
                        .foregroundStyle(StoryTheme.cream.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StoryTheme.cream.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Why this matters (expander) + Shoot pill.
                HStack(alignment: .center) {
                    Button { withAnimation { whyExpanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text("Why this matters").font(StoryTheme.body(13, .medium)).foregroundStyle(StoryTheme.gold)
                            Image(systemName: whyExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9)).foregroundStyle(StoryTheme.gold.opacity(0.8))
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                    Button(action: onShoot) {
                        HStack(spacing: 5) {
                            Text("Shoot").font(StoryTheme.body(14, .medium))
                            Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(StoryTheme.ink)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(StoryTheme.cream).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
                if whyExpanded {
                    Text(scene.whyItMatters).font(StoryTheme.body(13))
                        .foregroundStyle(StoryTheme.cream.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                }
                // Attribution (required) — only when an image is shown.
                if let img = image, let u = URL(string: img.sourceURL) {
                    Link(destination: u) {
                        Text(img.attributionText).font(StoryTheme.body(10))
                            .foregroundStyle(StoryTheme.cream.opacity(0.35)).lineLimit(1)
                    }
                }
            }
            .padding(16)
        }
        .background(StoryTheme.cream.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(StoryTheme.cream.opacity(0.08), lineWidth: 1))
        .task(id: scene.id) {
            // Featured scene can change (user taps an "Other scene") -> reload image for the new hero.
            image = nil
            if let img = await fetchImage() {
                image = img
                await trackImageUse(img)
            }
        }
    }

    private func sourceHost(_ img: SceneImageDTO) -> String? {
        // Prefer the photographer's profile host; fall back to the source URL host.
        if let h = URL(string: img.photographerURL)?.host, !h.isEmpty { return h.replacingOccurrences(of: "www.", with: "") }
        if let h = URL(string: img.sourceURL)?.host, !h.isEmpty { return h.replacingOccurrences(of: "www.", with: "") }
        return nil
    }

    private var placeholderBand: some View {
        LinearGradient(colors: [StoryTheme.cream.opacity(0.06), StoryTheme.cream.opacity(0.02)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// A compact "Other scenes" row (reference: glyph + title + subtitle + status + chevron). Tapping promotes
// the scene to the featured hero; the trailing control offers a quick Shoot.
private struct OtherSceneRow: View {
    let scene: StoryGuideSceneDTO
    let covered: Bool
    let onTap: () -> Void
    let onShoot: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: covered ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 18))
                    .foregroundStyle(covered ? StoryTheme.gold : StoryTheme.gold.opacity(0.6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.title).font(StoryTheme.display(17)).foregroundStyle(StoryTheme.cream.opacity(0.92))
                        .lineLimit(1)
                    Text(scene.whatToCapture).font(StoryTheme.body(12))
                        .foregroundStyle(StoryTheme.cream.opacity(0.45)).lineLimit(1)
                }
                Spacer()
                Text(covered ? "Covered" : "")
                    .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.45))
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(StoryTheme.cream.opacity(0.3))
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(StoryTheme.cream.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StoryTheme.cream.opacity(0.06), lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

// MARK: - Story Idea section
//
// Renders NOTHING when storyIdea is nil (the whole section is omitted by the
// parent via `if coverage?.storyIdea != nil`). This view assumes a non-nil idea.

// Contextual recommendation card. Visually RELATED to the Guide's cinematic scene card — same dark/serif/gold
// language, prominent (optional) reference image, bordered surface — but deliberately NOT identical to a
// persistent Guide scene: it is MORE COMPACT (smaller image + title, lighter chrome), carries an "AI
// suggestion" badge (a contextual recommendation, not a planned scene), and omits the Guide's SCENE NN /
// pin / coverage-status / expandable "Why this matters" machinery. It answers three questions fast — what to
// capture (title), why it helps (a short line), and, WHEN the contract actually carries one, how to capture
// it — then continues into the existing Director flow via "Show me".
//
// Decision-5 contract honesty: the DTO has only {title, description, rationale?}. When `rationale` is present
// it is the WHY and `description` is the concept/how; we render a labelled "How to capture it" panel from
// `description` ONLY then. When `rationale` is ABSENT there is a single text field, so it renders as one
// unlabelled concept/why line and NO "How to capture it" label is fabricated.
struct StoryIdeaSection: View {
    let idea: CoverageStoryIdeaV2DTO
    /// Tapping routes into the existing Show Me / Director flow (high-level -> executable).
    var onShowMe: () -> Void
    /// OPTIONAL dismiss (Phase B decision 5): hide THIS specific idea. Scoped + non-persistent (the caller
    /// holds an in-memory fingerprint) — a materially different future idea is NOT suppressed. Defaults to a
    /// no-op; when nil-equivalent (no caller) the dismiss control is still shown but does nothing, so callers
    /// should wire it. Rendered as a small ✕ in the header.
    var onDismiss: (() -> Void)? = nil
    /// OPTIONAL Guide image reuse (Phase B / decision 5): resolve an ALREADY-available Guide scene image for
    /// this idea's `targetStoryGuideDimensionId`. Returns nil when the idea targets no current scene, the
    /// scene has no image, or image reuse is not wired — in which case the card is text-only (never a new
    /// inference or image provider, never a decorative fetch). Defaults to nil so the card is safe before the
    /// caller wires it.
    var resolveGuideImage: (_ dimensionId: String) async -> SceneImageDTO? = { _ in nil }
    /// OPTIONAL one-line "why it complements the Story" tag shown in the footer (e.g. "Complements your
    /// landscape footage"). Deterministic caller-supplied context; nil => omitted. Never fabricated here.
    var complementNote: String? = nil

    @State private var image: SceneImageDTO?

    /// True when the contract carries BOTH a why (`rationale`) and a separate concept/how (`description`),
    /// so the card can honestly show a distinct "How to capture it" panel. When false there is only one
    /// text field and we never label it a capture instruction (decision 5).
    private var hasDistinctHowTo: Bool {
        guard let r = idea.rationale, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !idea.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// The WHY line. Prefer rationale; fall back to description when rationale is absent (then there is no
    /// separate how-to panel).
    private var whyLine: String { idea.rationale ?? idea.description }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Eyebrow row — same gold ✦ language as the Guide, distinct copy + an "AI suggestion" badge so it
            // reads as a contextual recommendation, never a permanent Guide scene.
            HStack(alignment: .center, spacing: 6) {
                Text("✦").font(.system(size: 10)).foregroundStyle(StoryTheme.gold.opacity(0.9))
                StoryEyebrow(text: "A moment worth capturing")
                Spacer(minLength: 8)
                Text("AI suggestion")
                    .font(StoryTheme.body(11, .medium))
                    .foregroundStyle(StoryTheme.cream.opacity(0.55))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(StoryTheme.cream.opacity(0.07), in: Capsule())
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StoryTheme.cream.opacity(0.45))
                            .padding(6)
                            .background(StoryTheme.cream.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss suggestion")
                    .accessibilityIdentifier("dismiss-story-idea-button")
                }
            }
            .padding(.bottom, 12)

            // Optional visual reference — a reference image for THIS idea (see the resolver). Omitted
            // entirely when none resolves; never a placeholder. More compact than the Guide hero (160 vs 210).
            // No decorative source-host chip — only the REQUIRED Unsplash "Photo by X" credit (below).
            if let img = image, let url = URL(string: img.imageURL) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.25))) { phase in
                    if case let .success(i) = phase {
                        i.resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [StoryTheme.cream.opacity(0.06), StoryTheme.cream.opacity(0.02)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .frame(height: 160).frame(maxWidth: .infinity).clipped()
                .clipShape(RoundedRectangle(cornerRadius: StoryTheme.field))
                .padding(.bottom, 6)
                // Required Unsplash attribution ("Photo by <name> on Unsplash") — small + subtle, linking to
                // the photographer/source. Mandatory whenever an Unsplash image is displayed.
                if !img.attributionText.isEmpty, let u = URL(string: img.sourceURL) {
                    Link(destination: u) {
                        Text(img.attributionText).font(StoryTheme.body(10))
                            .foregroundStyle(StoryTheme.cream.opacity(0.35)).lineLimit(1)
                    }
                    .padding(.bottom, 10)
                }
            }

            // What to capture — the idea title (serif, slightly smaller than the Guide hero's 22 => compact).
            Text(idea.title)
                .font(StoryTheme.display(19))
                .foregroundStyle(StoryTheme.cream)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            // Why it helps — short, NOT labelled as a precise capture instruction (decision 5).
            Text(whyLine)
                .font(StoryTheme.body(14))
                .foregroundStyle(StoryTheme.cream.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            // How to capture it — ONLY when the contract carries a distinct concept/how (rationale present).
            // Labelled honestly; never fabricated. Rendered as a compact boxed panel with a video glyph,
            // matching the mockup and the Guide's "How to shoot" visual language.
            if hasDistinctHowTo {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: "video").font(.system(size: 12)).foregroundStyle(StoryTheme.cream.opacity(0.85))
                        Text("How to capture it").font(StoryTheme.body(13, .medium)).foregroundStyle(StoryTheme.cream.opacity(0.9))
                    }
                    Text(idea.description).font(StoryTheme.body(13))
                        .foregroundStyle(StoryTheme.cream.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StoryTheme.cream.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 12)
            }

            // Footer — optional complement note on the left, "Show me" (unchanged Director entry) on the right.
            HStack(alignment: .center) {
                if let note = complementNote, !note.isEmpty {
                    Text(note)
                        .font(StoryTheme.body(12))
                        .foregroundStyle(StoryTheme.cream.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: onShowMe) {
                    HStack(spacing: 4) {
                        Text("Show me").font(StoryTheme.body(14, .semibold))
                        Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(StoryTheme.ink)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(StoryTheme.cream, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Optional idea — opens capture guidance")
            }
            .padding(.top, 14)
        }
        .padding(16)
        .background(StoryTheme.surfaceAlt.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StoryTheme.cream.opacity(0.08), lineWidth: 1))
        .padding(.top, 20)
        .task(id: idea.targetStoryGuideDimensionId) {
            // Resolve a reference image for THIS idea (resolver prefers the target scene's curated query,
            // then a short generic phrase from the idea title). Always ask — pass the target id when present,
            // else "". nil => text-only card. No image bytes re-hosted; required attribution shown with it.
            image = await resolveGuideImage(idea.targetStoryGuideDimensionId ?? "")
        }
    }
}
