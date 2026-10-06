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
    /// strengths and strong/looking_good dimensions. No ids, no scores.
    static func strengthLines(_ cov: StoryCoverageDTO) -> [String] {
        if !cov.strengths.isEmpty { return Array(cov.strengths.prefix(3)) }
        // Fallback: name strong dimensions in plain words (label only, never id).
        return cov.dimensions
            .filter { $0.coverage == .strong || $0.coverage == .lookingGood }
            .prefix(3)
            .map { $0.label }
    }

    /// Gentle "what could make it stronger" lines — ONLY genuinely weak dimensions,
    /// phrased as optional opportunities, never as homework or required shots.
    /// Suppressed entirely for `sufficient` (ENOUGH state owns that case).
    static func opportunityLines(_ cov: StoryCoverageDTO) -> [String] {
        guard cov.sufficiency.status != .sufficient else { return [] }
        return cov.dimensions
            .filter { $0.coverage == .couldUseMore }
            .prefix(2)
            .map { $0.purpose?.isEmpty == false ? $0.purpose! : $0.label }
    }

    /// The ENOUGH line for a sufficient Story (Figma-consistent). Non-prescriptive.
    static func enoughLine(_ cov: StoryCoverageDTO) -> String {
        "Your Story already tells its story. You can keep capturing, or create it now."
    }

    /// A single honest uncertainty line when some Moments are still being understood.
    /// Pending = UNKNOWN, never surfaced as a gap. nil when nothing is pending.
    static func pendingLine(_ cov: StoryCoverageDTO) -> String? {
        guard cov.pendingCount > 0 else { return nil }
        let n = cov.pendingCount
        return "Still looking at \(n) more moment\(n == 1 ? "" : "s") — your guide will fill in as they're ready."
    }
}

// MARK: - Story Guide section

struct StoryGuideSection: View {
    let coverage: StoryCoverageDTO?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StoryEyebrow(text: "Story Guide")

            if let cov = coverage {
                content(cov)
            } else if isLoading {
                // No coverage yet, computing: neutral Figma-consistent loading.
                Text("Reading your Story…")
                    .font(StoryTheme.body(13).italic())
                    .foregroundStyle(StoryTheme.cream.opacity(0.32))
            } else {
                // No coverage and not computing (e.g. no understood Moments yet): neutral.
                Text("Your guide appears as your Story's moments come together.")
                    .font(StoryTheme.body(13).italic())
                    .foregroundStyle(StoryTheme.cream.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private func content(_ cov: StoryCoverageDTO) -> some View {
        let strengths = StoryCoveragePresentation.strengthLines(cov)
        let opportunities = StoryCoveragePresentation.opportunityLines(cov)
        let pending = StoryCoveragePresentation.pendingLine(cov)

        VStack(alignment: .leading, spacing: 10) {
            if cov.sufficiency.status == .sufficient {
                Text(StoryCoveragePresentation.enoughLine(cov))
                    .font(StoryTheme.display(16))
                    .foregroundStyle(StoryTheme.cream.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !strengths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What your Story has")
                        .font(StoryTheme.body(11)).tracking(0.4)
                        .foregroundStyle(StoryTheme.cream.opacity(0.3))
                    ForEach(strengths, id: \.self) { s in
                        guideLine(s, tone: StoryTheme.cream.opacity(0.72))
                    }
                }
            }

            if !opportunities.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Could make it stronger")
                        .font(StoryTheme.body(11)).tracking(0.4)
                        .foregroundStyle(StoryTheme.cream.opacity(0.3))
                    ForEach(opportunities, id: \.self) { o in
                        guideLine(o, tone: StoryTheme.cream.opacity(0.56))
                    }
                }
            }

            if let pending {
                Text(pending)
                    .font(StoryTheme.body(12).italic())
                    .foregroundStyle(StoryTheme.cream.opacity(0.34))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func guideLine(_ text: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("·").font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.25))
            Text(text).font(StoryTheme.body(13)).foregroundStyle(tone)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Story Idea section
//
// Renders NOTHING when storyIdea is nil (the whole section is omitted by the
// parent via `if coverage?.storyIdea != nil`). This view assumes a non-nil idea.

struct StoryIdeaSection: View {
    let idea: CoverageStoryIdeaDTO
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
