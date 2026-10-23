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
    /// Scene possibility (or the scene itself) -> Shoot (Director entry point B). Reuses the v1 dimension/poss
    /// handoff shape via a bridge the parent provides.
    var onShoot: (_ scene: StoryGuideSceneDTO, _ possibility: SceneCapturePossibilityDTO?) -> Void = { _, _ in }
    var onRetry: () -> Void = {}
    /// Fetch ONE reference image for a scene (backend proxy). Returns nil => text-only card. Injected so the
    /// view stays testable and the network stays out of the view.
    var fetchImage: (_ scene: StoryGuideSceneDTO) async -> SceneImageDTO? = { _ in nil }
    /// Fire Unsplash download-tracking when a scene image is actually shown-to-use (owner-documented rule).
    var trackImageUse: (_ image: SceneImageDTO) async -> Void = { _ in }

    private static let initialVisible = 3
    @State private var showAll = false

    private func stateFor(_ sceneId: String) -> NarrativeCoverageDTO? {
        coverage?.dimensionCoverage.first(where: { $0.storyGuideDimensionId == sceneId })?.state
    }
    private func stateLabel(_ s: NarrativeCoverageDTO?) -> String? {
        switch s {
        case .strong: return "You've got this covered"
        case .lookingGood: return "Looking strong"
        case .couldUseMore: return "Could use more"
        default: return nil
        }
    }
    private var pendingLine: String? {
        guard let c = coverage, c.pendingCount > 0 else { return nil }
        let n = c.pendingCount
        return "Still looking at \(n) more moment\(n == 1 ? "" : "s") — your guide will fill in as they're ready."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StoryEyebrow(text: "Shooting Script")

            if let g = guide {
                Text("A guide, not a checklist — capture what feels right.")
                    .font(StoryTheme.body(12).italic()).foregroundStyle(StoryTheme.cream.opacity(0.4))
                if !g.framingSummary.isEmpty {
                    Text(g.framingSummary)
                        .font(StoryTheme.body(13).italic())
                        .foregroundStyle(StoryTheme.cream.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                let scenes = showAll ? g.scenes : Array(g.scenes.prefix(Self.initialVisible))
                ForEach(scenes) { scene in
                    SceneCard(scene: scene,
                              stateTag: stateLabel(stateFor(scene.id)),
                              couldUseMore: stateFor(scene.id) == .couldUseMore,
                              onShoot: { onShoot(scene, scene.capturePossibilities.first) },
                              fetchImage: { await fetchImage(scene) },
                              trackImageUse: trackImageUse)
                }
                if g.scenes.count > Self.initialVisible {
                    Button { withAnimation { showAll.toggle() } } label: {
                        Text(showAll ? "Show fewer scenes" : "Show full shooting script (\(g.scenes.count))")
                            .font(StoryTheme.body(13, .medium)).foregroundStyle(StoryTheme.gold)
                    }.buttonStyle(.plain).padding(.top, 2)
                }
                if let pendingLine {
                    Text(pendingLine).font(StoryTheme.body(12).italic())
                        .foregroundStyle(StoryTheme.cream.opacity(0.34))
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
            } else if isLoading {
                Text("Writing your shooting script…")
                    .font(StoryTheme.body(13).italic()).foregroundStyle(StoryTheme.cream.opacity(0.32))
            } else {
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
}

// One cinematic scene card. The reference image loads LAZILY and NEVER blocks the card: until it resolves
// (or if it fails / is disabled) the card shows a tasteful text-only header. Attribution + source link are
// shown only when an image is present (Unsplash requirement). why-it-matters is collapsed by default.
private struct SceneCard: View {
    let scene: StoryGuideSceneDTO
    let stateTag: String?
    let couldUseMore: Bool
    let onShoot: () -> Void
    let fetchImage: () async -> SceneImageDTO?
    let trackImageUse: (SceneImageDTO) async -> Void

    @State private var image: SceneImageDTO?
    @State private var triedImage = false
    @State private var whyExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Prominent reference image (lazy, hotlinked) OR a text-only header band.
            ZStack(alignment: .bottomLeading) {
                if let img = image, let url = URL(string: img.imageURL) {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.25))) { phase in
                        switch phase {
                        case .success(let i): i.resizable().scaledToFill()
                        default: placeholderBand
                        }
                    }
                    .frame(height: 150).frame(maxWidth: .infinity).clipped()
                    // ink gradient so the title overlay stays legible (same language as the home hero cards)
                    .overlay(LinearGradient(colors: [.clear, StoryTheme.ink.opacity(0.75)],
                                            startPoint: .top, endPoint: .bottom))
                } else {
                    placeholderBand.frame(height: image == nil && !triedImage ? 0 : 54)
                }
                Text(scene.title)
                    .font(StoryTheme.display(18)).foregroundStyle(StoryTheme.cream)
                    .padding(.horizontal, 14).padding(.bottom, 10)
                    .shadow(radius: image != nil ? 6 : 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                if image == nil {   // title shown in-body when there is no image band to carry it
                    Text(scene.title).font(StoryTheme.display(18)).foregroundStyle(StoryTheme.cream)
                }
                if let tag = stateTag {
                    Text("· \(tag)").font(StoryTheme.body(12))
                        .foregroundStyle(couldUseMore ? StoryTheme.gold.opacity(0.85) : StoryTheme.cream.opacity(0.4))
                }
                Text(scene.whatToCapture).font(StoryTheme.body(14))
                    .foregroundStyle(StoryTheme.cream.opacity(0.82)).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "camera").font(.system(size: 11)).foregroundStyle(StoryTheme.gold.opacity(0.8))
                        .padding(.top, 2)
                    Text(scene.howToShoot).font(StoryTheme.body(13))
                        .foregroundStyle(StoryTheme.cream.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                }
                // Expandable why-it-matters.
                Button { withAnimation { whyExpanded.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text(whyExpanded ? "Why this matters" : "Why this matters")
                            .font(StoryTheme.body(12, .medium)).foregroundStyle(StoryTheme.cream.opacity(0.5))
                        Image(systemName: whyExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                    }
                }.buttonStyle(.plain)
                if whyExpanded {
                    Text(scene.whyItMatters).font(StoryTheme.body(13))
                        .foregroundStyle(StoryTheme.cream.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(action: onShoot) {
                        Text("Shoot →").font(StoryTheme.body(13, .medium)).foregroundStyle(StoryTheme.gold)
                    }.buttonStyle(.plain)
                    Spacer()
                    // Unsplash attribution (required) — only when an image is shown.
                    if let img = image, let u = URL(string: img.sourceURL) {
                        Link(destination: u) {
                            Text(img.attributionText).font(StoryTheme.body(10))
                                .foregroundStyle(StoryTheme.cream.opacity(0.35)).lineLimit(1)
                        }
                    }
                }.padding(.top, 2)
            }
            .padding(14)
        }
        .background(StoryTheme.cream.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StoryTheme.cream.opacity(0.07), lineWidth: 1))
        .task(id: scene.id) {
            // Lazy, non-blocking image load. A nil result (disabled/no-match/failure) leaves the text-only card.
            guard !triedImage else { return }
            triedImage = true
            if let img = await fetchImage() {
                image = img
                await trackImageUse(img)   // the scene reference is now shown-to-use -> fire download tracking
            }
        }
    }

    private var placeholderBand: some View {
        LinearGradient(colors: [StoryTheme.cream.opacity(0.06), StoryTheme.cream.opacity(0.02)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Story Idea section
//
// Renders NOTHING when storyIdea is nil (the whole section is omitted by the
// parent via `if coverage?.storyIdea != nil`). This view assumes a non-nil idea.

struct StoryIdeaSection: View {
    let idea: CoverageStoryIdeaV2DTO
    /// Tapping routes into the existing Show Me / Director flow (high-level -> executable).
    var onShowMe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("✦").font(.system(size: 9)).foregroundStyle(StoryTheme.gold.opacity(0.8))
                StoryEyebrow(text: "Story Idea")
            }
            Text(idea.title)
                .font(StoryTheme.display(18))
                .foregroundStyle(StoryTheme.cream.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Text(idea.description)
                .font(StoryTheme.body(13))
                .foregroundStyle(StoryTheme.cream.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            // Optional / inspirational, never a requirement — a quiet gold affordance.
            Button(action: onShowMe) {
                Text("Show me")
                    .font(StoryTheme.body(13, .medium))
                    .foregroundStyle(StoryTheme.gold)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityHint("Optional idea — opens capture guidance")
        }
        .padding(.top, 20)
    }
}
