import SwiftUI

// StoryComponents — the small set of reusable UI patterns the frozen Figma UX
// repeats. Only patterns actually reused are extracted (no generic framework).
// C3.5 Figma UX convergence.

// MARK: - Buttons

/// Primary CTA — cream pill on ink (Figma primary).
struct StoryPrimaryButton: View {
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(StoryTheme.body(15, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(StoryTheme.cream)
                .foregroundStyle(StoryTheme.ink)
                .clipShape(Capsule())
        }
        .accessibilityAddTraits(.isButton)
    }
}

/// Secondary — gold text, no fill.
struct StorySecondaryButton: View {
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(StoryTheme.body(15, .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(StoryTheme.gold)
        }
    }
}

/// Intentional DISABLED-future-capability action. Looks deliberate (muted
/// outline pill), is non-interactive, and carries an accessibility hint saying
/// it's not available yet. NOT a "Coming soon" text sprinkle.
struct StoryUnavailableButton: View {
    let title: String
    var note: String? = nil          // optional short reason shown under it
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(StoryTheme.body(15, .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .foregroundStyle(StoryTheme.textMuted)
                .overlay(Capsule().stroke(StoryTheme.cream.opacity(0.12), lineWidth: 1))
            if let note {
                Text(note).font(StoryTheme.body(11)).foregroundStyle(StoryTheme.textMuted)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityHint("Not available yet")
        .accessibilityAddTraits(.isButton)
        .accessibilityRemoveTraits(.isButton)
    }
}

// MARK: - Image-forward cards (frozen Figma)

/// Neutral bundled placeholder photos (procedural dusk gradients — no
/// copyrighted content). Used where the frozen Figma shows a photographic card
/// but the native app has no real media yet. Deterministic by key so a given
/// surface always shows the same tone. See Assets.xcassets/ph_*.
enum StoryPlaceholderPhoto {
    static let all = ["ph_alpine", "ph_trail", "ph_lake", "ph_city"]
    static func name(_ i: Int) -> String { all[((i % all.count) + all.count) % all.count] }
}

/// A large image-backed make-path card (Figma ScreenHome lgCard: aspectRatio
/// 16/9, radius 20, bottom-up ink gradient, eyebrow+title+sub overlaid).
struct StoryImageCard: View {
    let image: String            // asset name
    let eyebrow: String
    let title: String
    let sub: String
    var enabled: Bool = true
    var titleSize: CGFloat = 21
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(image).resizable().scaledToFill()
                .opacity(enabled ? 0.75 : 0.4)
            LinearGradient(
                stops: [.init(color: StoryTheme.ink.opacity(0.94), location: 0),
                        .init(color: StoryTheme.ink.opacity(0.25), location: 0.6),
                        .init(color: .clear, location: 1)],
                startPoint: .bottom, endPoint: .top)
            VStack(alignment: .leading, spacing: 2) {
                StoryEyebrow(text: eyebrow)
                Text(title).font(StoryTheme.display(titleSize))
                    .foregroundStyle(enabled ? StoryTheme.cream : StoryTheme.cream.opacity(0.55))
                if !sub.isEmpty {
                    Text(sub).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.5))
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 15)
            Image(systemName: "arrow.right")
                .font(.system(size: 13)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
        }
        .aspectRatio(16.0/9.0, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .opacity(enabled ? 1 : 0.85)
    }
}

/// A compact image mosaic row used on cards (Figma: 3 tiles side by side with
/// a card body below). Degrades to placeholder tones when no media.
struct StoryMosaicStrip: View {
    var height: CGFloat = 110
    var startIndex: Int = 0
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Image(StoryPlaceholderPhoto.name(startIndex + i))
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: height)
                    .clipped().opacity(0.88)
            }
        }
        .frame(height: height)
        .clipped()
    }
}

// MARK: - Text treatments

struct StoryEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(StoryTheme.eyebrow())
            .tracking(2)
            .foregroundStyle(StoryTheme.textMuted)
    }
}

struct StorySectionHeader: View {
    let text: String
    var body: some View {
        Text(text).font(StoryTheme.body(15, .medium)).foregroundStyle(StoryTheme.gold)
    }
}

/// Story lifecycle status (active / completed).
struct StoryStatusPill: View {
    let status: StoryStatus
    var body: some View {
        Text(status == .completed ? "Completed" : "Active")
            .font(StoryTheme.body(11, .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(status == .completed ? StoryTheme.textMuted : StoryTheme.gold)
            .overlay(Capsule().stroke(
                (status == .completed ? StoryTheme.textMuted : StoryTheme.gold).opacity(0.4), lineWidth: 1))
    }
}

// MARK: - Containers

/// A tappable Story entry/card surface.
struct StoryCard<Content: View>: View {
    var enabled: Bool = true
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(StoryTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: StoryTheme.card))
            .opacity(enabled ? 1 : 0.55)
    }
}

/// Guidance card (concept / shot instruction) used in the recommendation.
struct GuidanceCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(StoryTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: StoryTheme.card))
    }
}

// MARK: - Field

struct StoryTextField: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 44
    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).foregroundStyle(StoryTheme.textMuted)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            }
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(StoryTheme.cream)
        }
        .frame(minHeight: minHeight)
        .background(StoryTheme.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: StoryTheme.field))
    }
}

// MARK: - States

/// Empty state — a quiet line in Story's voice.
struct StoryEmptyState: View {
    let text: String
    var body: some View {
        Text(text).font(StoryTheme.body(15))
            .foregroundStyle(StoryTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Intentional "unavailable future capability" block — preserves the Figma
/// section's hierarchy but reads as deliberately inactive (not a stub).
struct StoryUnavailableSection<Header: View>: View {
    @ViewBuilder var header: () -> Header
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header()
            Text(message).font(StoryTheme.body(13))
                .foregroundStyle(StoryTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(StoryTheme.surfaceAlt.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: StoryTheme.card))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Not available yet")
    }
}

/// Director/scene "thinking" state — staged copy, no fake percentage.
struct StoryThinkingState: View {
    let line: String
    var body: some View {
        VStack(spacing: 20) {
            ProgressView().tint(StoryTheme.gold).scaleEffect(1.3)
            Text(line).font(StoryTheme.display(20))
                .foregroundStyle(StoryTheme.cream)
                .multilineTextAlignment(.center)
                .transition(.opacity)
        }
        .padding(32)
    }
}
