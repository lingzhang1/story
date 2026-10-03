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
