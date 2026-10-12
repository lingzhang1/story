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
    /// Returns the chosen duration (seconds) + the user's sound choice (always explicit once they press Create).
    let onCreate: (Double, SoundPreference, String) -> Void
    let onCancel: () -> Void

    enum LengthChoice: Hashable { case highlights, full, custom
        var wire: String { switch self { case .highlights: return "highlights"; case .full: return "full"; case .custom: return "custom" } }
    }

    @State private var length: LengthChoice
    @State private var sound: SoundPreference
    @State private var customSeconds: Double

    init(rec: DurationRecommendation, inferredSound: SoundPreference?, initialExplicitSound: SoundPreference?,
         onCreate: @escaping (Double, SoundPreference, String) -> Void, onCancel: @escaping () -> Void) {
        self.rec = rec; self.inferredSound = inferredSound; self.initialExplicitSound = initialExplicitSound
        self.onCreate = onCreate; self.onCancel = onCancel
        // Default length: Full Story when a recommended point exists, else Custom.
        _length = State(initialValue: rec.recommendedPointSeconds != nil ? .full : .custom)
        // Default sound: the user's explicit choice if any, else the inferred recommendation, else balanced.
        _sound = State(initialValue: initialExplicitSound ?? inferredSound ?? .balanced)
        let seed = rec.recommendedPointSeconds
            ?? ((rec.evidence.feasibleBandSeconds.first ?? 10) + (rec.evidence.feasibleBandSeconds.last ?? 30)) / 2
        _customSeconds = State(initialValue: seed.rounded())
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

                Button { onCreate(chosenSeconds, sound, length.wire) } label: {
                    Text("Create my Story").font(StoryTheme.body(17, .semibold)).foregroundStyle(StoryTheme.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(StoryTheme.cream).clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button("Cancel") { onCancel() }
                    .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textMuted)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationBackground(StoryTheme.ink)
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
