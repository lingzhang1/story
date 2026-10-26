import SwiftUI

// Milestone R-d.2 — COMPACT recommendation-first duration choice (v2, simplified after device feedback that
// the first layout was bulky). One prominent primary CTA (the recommended length + a short reason), a small
// "Shorter highlights" option, and a quiet, collapsed "Choose exact length" disclosure holding the slider.
// NO universal 15/30/60 defaults — numbers come from the recommendation (or the feasible band when the model
// was unavailable). The user accepts or overrides; the chosen seconds become the Story's authoritative target.
struct DurationChoiceView: View {
    let rec: DurationRecommendation
    let onAccept: (Double) -> Void
    let onCancel: () -> Void

    @State private var showCustom = false
    @State private var customSeconds: Double

    init(rec: DurationRecommendation, editorialType: EditorialType? = nil,
         onAccept: @escaping (Double) -> Void, onCancel: @escaping () -> Void) {
        self.rec = rec; self.onAccept = onAccept; self.onCancel = onCancel
        // P1-C §3: seed from the editorial-type-appropriate range (Highlights -> highlights range, Full Story ->
        // recommended range) when a type is provided; nil => recommended (v5.2 default). Graceful band fallback.
        let seed = rec.pointSeconds(forEditorialType: editorialType)
            ?? ((rec.evidence.feasibleBandSeconds.first ?? 10) + (rec.evidence.feasibleBandSeconds.last ?? 30)) / 2
        _customSeconds = State(initialValue: seed.rounded())
    }

    private var ceiling: Double {
        max(rec.recommendation?.feasibleCeilingSeconds ?? 60, rec.evidence.feasibleBandSeconds.last ?? 60)
    }
    private var floor: Double { max(3, rec.evidence.feasibleBandSeconds.first ?? 5) }
    private var recPoint: Double? { rec.recommendedPointSeconds }
    /// A typed value clamped into the feasible band, so an out-of-range entry (e.g. 500) can't be accepted.
    private var clampedCustom: Double { min(max(customSeconds.rounded(), floor), ceiling) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Story length")
                .font(StoryTheme.eyebrow()).foregroundStyle(StoryTheme.textMuted)

            if let point = recPoint, let r = rec.recommendation {
                // Primary: recommended — one tap to accept.
                Button { onAccept(point) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Create · \(Int(point.rounded()))s").font(StoryTheme.body(18, .semibold))
                            Text(r.rationale).font(StoryTheme.body(13)).opacity(0.75)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                    }
                    .foregroundStyle(StoryTheme.ink)
                    .padding(.horizontal, 18).padding(.vertical, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StoryTheme.cream).clipShape(RoundedRectangle(cornerRadius: 14))
                }
                // Secondary: shorter highlights — a quiet text link, not a heavy box.
                if let hi = rec.highlightsPointSeconds, Int(hi.rounded()) != Int(point.rounded()) {
                    Button("Shorter highlights · \(Int(hi.rounded()))s") { onAccept(hi) }
                        .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.gold)
                }
            } else {
                Text(rec.note ?? "Choose a length for your Story.")
                    .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textSecondary)
            }

            // Quiet custom disclosure — collapsed by default so the screen stays simple. Lets the user TYPE an
            // exact number of seconds (easier than dragging a slider), with a stepper for fine nudges.
            DisclosureGroup(isExpanded: $showCustom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        TextField("seconds", value: $customSeconds, format: .number)
                            .keyboardType(.numberPad)
                            .font(StoryTheme.display(20)).foregroundStyle(StoryTheme.cream)
                            .frame(width: 90)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(StoryTheme.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("seconds").font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textSecondary)
                        Spacer()
                        Stepper("", value: $customSeconds, in: floor...ceiling, step: 1).labelsHidden()
                    }
                    Text("\(Int(floor))–\(Int(ceiling))s fits your footage")
                        .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.textMuted)
                    Button("Create · \(Int(clampedCustom))s") { onAccept(clampedCustom) }
                        .font(StoryTheme.body(15, .medium)).foregroundStyle(StoryTheme.gold)
                }
                .padding(.top, 8)
            } label: {
                Text("Choose exact length").font(StoryTheme.body(15)).foregroundStyle(StoryTheme.textSecondary)
            }
            .tint(StoryTheme.textSecondary)

            Button("Cancel") { onCancel() }
                .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textMuted)
                .frame(maxWidth: .infinity).padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationBackground(StoryTheme.ink)
    }
}
