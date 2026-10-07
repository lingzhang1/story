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
