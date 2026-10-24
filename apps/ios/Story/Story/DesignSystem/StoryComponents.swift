import SwiftUI

// Presentation-only tidy of a user/C1-authored Story title for DISPLAY. The
// stored title (a real C1 artifact) is NEVER mutated — this only fixes an
// odd leading-lowercase ("tMB hiking" → "TMB hiking") in the UI, per the
// product-over-code rule, without touching the contract value.
extension String {
    var displayTitle: String {
        guard let first = first else { return self }
        if first.isLowercase, count > 1, self[index(startIndex, offsetBy: 1)].isUppercase {
            return first.uppercased() + dropFirst()
        }
        return self
    }
}

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
    var icon: String? = nil      // optional SF Symbol badge, top-left (Figma V0.2.2 primary cards)
    var body: some View {
        Color.clear
            .aspectRatio(16.0/9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                // Aspect-FILL, full brightness. The source art is intentionally bright/vibrant; we do NOT
                // dim the whole image (only a disabled card is knocked back). Center crop keeps the frame
                // full-bleed across iPhone widths.
                Image(image).resizable().scaledToFill()
                    .opacity(enabled ? 1.0 : 0.4)
            )
            .overlay(
                // LOCALIZED bottom-to-top scrim — opaque only across the bottom ~45% (behind the text), fully
                // clear by ~58% so the upper 60%+ of the photo stays bright. Not a full-image darkening.
                LinearGradient(
                    stops: [.init(color: StoryTheme.ink.opacity(0.88), location: 0),
                            .init(color: StoryTheme.ink.opacity(0.55), location: 0.30),
                            .init(color: StoryTheme.ink.opacity(0.12), location: 0.48),
                            .init(color: .clear, location: 0.58)],
                    startPoint: .bottom, endPoint: .top)
            )
            .overlay(alignment: .topLeading) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(StoryTheme.cream)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(14)
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    if !eyebrow.isEmpty { StoryEyebrow(text: eyebrow) }
                    Text(title).font(StoryTheme.display(titleSize))
                        .foregroundStyle(enabled ? StoryTheme.cream : StoryTheme.cream.opacity(0.55))
                        .shadow(color: .black.opacity(0.55), radius: 8, y: 1)
                    if !sub.isEmpty {
                        Text(sub).font(StoryTheme.body(12))
                            .foregroundStyle(StoryTheme.cream.opacity(0.75))
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 16)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(StoryTheme.cream.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.28), in: Circle())
                    .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
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
                Color.clear
                    .frame(maxWidth: .infinity).frame(height: height)
                    .overlay(
                        Image(StoryPlaceholderPhoto.name(startIndex + i))
                            .resizable().scaledToFill().opacity(0.88)
                    )
                    .clipped()
            }
        }
        .frame(height: height)
        .clipped()
        .allowsHitTesting(false)
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
