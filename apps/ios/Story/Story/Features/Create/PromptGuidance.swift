import SwiftUI

// P0 Creative Direction UX — prompt guidance + capability awareness (iOS-only; no backend/contract change).
// Two small REUSABLE pieces shared by Customize (pre-creation Creative Direction) and Revise (post-generation):
//   • PromptSuggestionChips — a compact "Try asking Story…" row of tappable examples that INSERT/APPEND
//     editable text into the instruction field. Never auto-submits. Example Moment references use a REAL
//     Moment number from the live numbering snapshot (never a hardcoded nonexistent N).
//   • CapabilityInfoButton + CapabilitySheet — a small (i) affordance opening a concise "What can Story edit?"
//     sheet with the supported list and a short unsupported list (so the main screen is not overwhelmed).
// Styling reuses StoryTheme + the shared FlowLayout (one wrapping-chip layout, no duplication).

/// One tappable example. `text` is what gets appended to the instruction field (editable, not submitted).
struct PromptSuggestion: Identifiable, Equatable {
    let id = UUID()
    let label: String   // short chip label
    let text: String    // full instruction fragment appended to the field
}

/// A compact "Try asking Story…" section. Tapping a chip APPENDS its text to the bound instruction (with a
/// separating space/period), places the caret implicitly at the end, and never submits. Designed to sit
/// directly beneath the instruction field.
struct PromptSuggestionChips: View {
    let title: String
    let suggestions: [PromptSuggestion]
    @Binding var text: String
    /// Called after an append so the host can invalidate any in-flight interpretation (stale-drop safeguard),
    /// exactly as a manual edit would.
    var onInsert: () -> Void = {}

    var body: some View {
        if suggestions.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(StoryTheme.body(12, .medium)).foregroundStyle(StoryTheme.textSecondary)
                FlowLayout(spacing: 8) {
                    ForEach(suggestions) { s in
                        Button { append(s.text) } label: {
                            HStack(spacing: 5) {
                                Text(s.label).font(StoryTheme.body(13, .medium)).foregroundStyle(StoryTheme.cream)
                                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(StoryTheme.textSecondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(StoryTheme.surface, in: Capsule())
                            .overlay(Capsule().stroke(StoryTheme.cream.opacity(0.14), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Insert example: \(s.label)")
                    }
                }
            }
        }
    }

    private func append(_ fragment: String) {
        let cur = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cur.isEmpty {
            text = fragment
        } else {
            // Join with a period+space unless the current text already ends in sentence punctuation.
            let sep = (cur.hasSuffix(".") || cur.hasSuffix("!") || cur.hasSuffix("?")) ? " " : ". "
            text = cur + sep + fragment
        }
        onInsert()
    }
}

/// The small (i) affordance + its sheet. Compact: a one-line supported summary opens the full list on tap.
struct CapabilityInfoButton: View {
    @State private var showSheet = false
    var body: some View {
        Button { showSheet = true } label: {
            HStack(spacing: 5) {
                Text("Editing capabilities").font(StoryTheme.body(12, .medium))
                Image(systemName: "info.circle").font(.system(size: 13, weight: .regular))
            }
            .foregroundStyle(StoryTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What can Story edit?")
        .sheet(isPresented: $showSheet) { CapabilitySheet() }
    }
}

/// "What can Story edit?" — the supported list (what to ask for) and a short unsupported list (what it can't
/// do yet), so a user forms realistic instructions before submitting. Kept concise on purpose.
struct CapabilitySheet: View {
    @Environment(\.dismiss) private var dismiss

    private let supported: [(String, String)] = [
        ("scissors", "Trim, reorder and select clips"),
        ("timer", "Change how long each shot plays"),
        ("gauge.with.dots.needle.67percent", "Adjust playback speed (within limits)"),
        ("square.on.square.dashed", "Apply supported transitions (cut, crossfade, fade)"),
        ("music.note", "Change the soundtrack"),
        ("speaker.wave.2", "Keep, duck or mute the original audio"),
        ("waveform.path", "Align cuts with the music's beats"),
    ]
    private let unsupported: [String] = [
        "Color grading and filters",
        "Brightness / exposure adjustments",
        "Stabilization",
        "Text overlays and subtitles",
        "Advanced zoom / reframing",
        "Background replacement",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Story can").font(StoryTheme.body(15, .semibold)).foregroundStyle(StoryTheme.cream)
                        ForEach(supported, id: \.1) { icon, label in
                            HStack(spacing: 10) {
                                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(StoryTheme.gold)
                                    .frame(width: 22)
                                Text(label).font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.92))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Not yet supported").font(StoryTheme.body(15, .semibold))
                            .foregroundStyle(StoryTheme.textSecondary)
                        ForEach(unsupported, id: \.self) { label in
                            HStack(spacing: 10) {
                                Image(systemName: "minus").font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(StoryTheme.textMuted).frame(width: 22)
                                Text(label).font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textSecondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(StoryTheme.screenPadding)
            }
            .background(StoryTheme.ink)
            .navigationTitle("What can Story edit?").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).foregroundStyle(StoryTheme.gold)
                }
            }
        }
    }
}

// MARK: - Example sets (Customize vs Revise). Opening examples use a REAL Moment number from the snapshot.

enum PromptSuggestions {
    /// Customize (pre-creation Creative Direction): opening / include-exclude / visual selection / pacing /
    /// music + native audio. `firstMomentNumber` is the lowest real Moment number (nil => omit the opening
    /// example rather than invent a number).
    static func customize(firstMomentNumber: Int?) -> [PromptSuggestion] {
        var out: [PromptSuggestion] = []
        if let n = firstMomentNumber {
            out.append(.init(label: "Start with Moment \(n)", text: "Start with Moment \(n)"))
        }
        out.append(contentsOf: [
            .init(label: "Keep each shot around 5 seconds", text: "Keep each shot around 5 seconds"),
            .init(label: "Use the most beautiful views first", text: "Use the most beautiful views first"),
            .init(label: "Make cuts follow the music", text: "Make the cuts follow the music"),
            .init(label: "Keep the original audio", text: "Keep the original audio"),
        ])
        return out
    }

    /// Revise (post-generation): preserve footage / shorten shots / reorder / replace opening / pacing /
    /// change music. `firstMomentNumber` feeds the "replace opening" example with a real number.
    static func revise(firstMomentNumber: Int?) -> [PromptSuggestion] {
        var out: [PromptSuggestion] = [
            .init(label: "Shorten each shot to ~5 seconds", text: "Shorten each shot to around 5 seconds"),
            .init(label: "Make the pacing faster", text: "Make the pacing faster"),
        ]
        if let n = firstMomentNumber {
            out.append(.init(label: "Open with Moment \(n)", text: "Start with Moment \(n)"))
        }
        out.append(contentsOf: [
            .init(label: "Reorder the Moments", text: "Reorder the Moments so the best one comes first"),
            .init(label: "Change the soundtrack", text: "Change the soundtrack to something calmer"),
        ])
        return out
    }
}

// MARK: - Pre-submit capability classification (Phase 4)
//
// A SMALL iOS mirror of the backend `_classify_unsupported_ops` vocabulary, used ONLY for instant pre-submit
// feedback (no network round-trip per keystroke). It is NOT a second NLP parser and NOT the authority — the
// backend guard remains the final word; this just lets the UI warn/confirm before an expensive job. Keep the
// two vocabularies in sync when either changes. Verdicts mirror the backend: .supported / .mixed / .allUnsupported.

enum CapabilityVerdict: Equatable {
    case supported
    case mixed(unsupported: [String])        // some supported edit + some unsupported effect
    case allUnsupported(unsupported: [String])
}

enum CapabilityClassifier {
    /// (regex, human noun) — mirrors the backend UNSUPPORTED map.
    private static let unsupported: [(String, String)] = [
        (#"color[- ]?correct|colou?r grad"#, "color correction"),
        (#"\bfilter\b|\bfilters\b|\blut\b"#, "filters"),
        (#"\bbright(er|ness)?\b|\bcontrast\b|\bsaturat|\bexposure\b|\bvibran|\btint\b|\bhue\b"#, "brightness/color adjustments"),
        (#"\bwarm(er|th)?\b|\bcool(er)?\b|\bteal\b|film look|color (tone|tint)|more (blue|green|red|orange|yellow|purple|pink|golden|vivid|colou?rful)|(blue|green|red|orange|yellow|purple|golden)r\b|make .*(sky|colou?rs?|grass|water|sunset) "#, "color tone changes"),
        (#"\bglow\b|\bvignette\b|\bbloom\b|light leak"#, "glow/vignette effects"),
        (#"\bblur\b|\bsharpen\b|\bgrain\b"#, "blur/sharpen effects"),
        (#"\bzoom\b|\bcrop\b|\breframe\b|\bpan\b|ken burns|re-?frame|punch in"#, "zoom/reframe"),
        (#"\bstabili[sz]e|\bstabili[sz]ation|anti-?shake"#, "stabilization"),
        (#"\btext\b|\bcaption|\bsubtitle|\bsticker|\boverlay|title card"#, "text/overlays"),
        (#"green ?screen|chroma ?key|remove background|replace background"#, "background replacement"),
    ]
    /// Genuine edit verbs/targets (mirrors the backend SUPPORTED set) — presence => MIXED, not all-unsupported.
    private static let supportedPattern =
        #"shorten|length|trim|\bcut\b|duration|pace|pacing|faster|slow(er)?|\bspeed\b|reorder|rearrange|\bswap\b|opening|ending|move (moment|clip|shot|it)|\binclude\b|\bexclude\b|\bremove\b|add moment|crossfade|\bfade\b|dissolve|transition|\bmusic\b|soundtrack|\btrack\b|\bsong\b|\bmute\b|\bduck\b"#

    static func classify(_ instruction: String) -> CapabilityVerdict {
        let text = instruction.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .supported }
        var nouns: [String] = []
        for (pat, noun) in unsupported where matches(pat, text) && !nouns.contains(noun) { nouns.append(noun) }
        if nouns.isEmpty { return .supported }
        return matches(supportedPattern, text) ? .mixed(unsupported: nouns)
                                               : .allUnsupported(unsupported: nouns)
    }

    /// Human phrase for a noun list: "a or b" / "a, b or c".
    static func phrase(_ nouns: [String]) -> String {
        guard let first = nouns.first else { return "" }
        if nouns.count == 1 { return first }
        return nouns.dropLast().joined(separator: ", ") + " or " + nouns[nouns.count - 1]
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
