import SwiftUI
import SwiftData

// Start a Story — frozen Figma wizard (ScreenStoryIntent → Direction → Context →
// Blueprint). Produces a PERSISTENT Story (distinct from Create Now). Real C1
// resolves the intent at the Context step ("Here's what I understood"); the
// Blueprint arc is a disabled-future surface (no StoryBlueprint capability).
// C3.5.
struct CreativeDirectionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    enum Step { case describe, feel, context, blueprint }
    @State private var step: Step = .describe
    @State private var title = ""
    @State private var description = ""
    @State private var feeling: String?            // chosen preset tag (optional)
    @State private var isResolving = false
    @State private var errorMessage: String?
    @State private var resolvedStory: StoryModel?       // reflected at Context step
    @State private var navigate = false                 // Start Story -> Story Home

    private let presets: [(title: String, desc: String)] = [
        ("Cinematic journey", "Cinematic · Scenic · Journey"),
        ("Energetic adventure", "Energetic · Kinetic · Adventure"),
        ("Personal & emotional", "Personal · Intimate · Emotional"),
        ("Minimal / scenic", "Minimal · Scenic · Quiet"),
    ]

    private var useCases: StoryUseCases {
        StoryUseCases(repository: StoryRepository(context: context))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                backRow
                switch step {
                case .describe:  describeStep
                case .feel:      feelStep
                case .context:   contextStep
                case .blueprint: blueprintStep
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, StoryTheme.screenPadding).padding(.top, 8)
        }
        .storyBackground()
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $navigate) {
            if let s = resolvedStory { StoryHomeView(story: s) }
        }
        .alert("Couldn't create your Story", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Try Again") { Task { await resolve() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var backRow: some View {
        Button(action: back) {
            Text("← Back").font(StoryTheme.body(14)).foregroundStyle(StoryTheme.textMuted)
        }
    }

    // Step 1 — describe
    private var describeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tell me about\nthis experience.")
                .font(StoryTheme.displayItalic(28)).foregroundStyle(StoryTheme.cream)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("What it is, how long, what you want it to feel like.")
                .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.32))
            StoryTextField(placeholder: "We're hiking the Tour du Mont Blanc for 8 days…",
                           text: $description, minHeight: 220)
            StoryTextField(placeholder: "Give it a title", text: $title, minHeight: 44)
            Spacer(minLength: 8)
            StoryPrimaryButton(title: "Continue") { step = .feel }
                .disabled(cannotContinueDescribe).opacity(cannotContinueDescribe ? 0.4 : 1)
        }
    }
    private var cannotContinueDescribe: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty
        || description.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Step 2 — feel (optional preset; any input is enough)
    private var feelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How should this\nStory feel?")
                .font(StoryTheme.displayItalic(27)).foregroundStyle(StoryTheme.cream)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick a feeling, add a reference, or describe it. Any one is enough.")
                .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.32))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(presets, id: \.title) { p in
                    let selected = feeling == p.title
                    let dimmed = feeling != nil && !selected
                    Button { feeling = selected ? nil : p.title } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer(minLength: 0)
                            Text(p.title).font(StoryTheme.display(17))
                                .foregroundStyle(StoryTheme.cream)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(p.desc).font(StoryTheme.body(11))
                                .foregroundStyle(StoryTheme.cream.opacity(0.4))
                                .padding(.top, 5)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .bottomLeading)
                        .padding(.horizontal, 15).padding(.vertical, 16)
                        .background(selected ? StoryTheme.gold.opacity(0.08) : StoryTheme.cream.opacity(0.03))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(selected ? StoryTheme.gold : StoryTheme.cream.opacity(0.1),
                                    lineWidth: selected ? 2 : 1.5))
                        .overlay(alignment: .topTrailing) {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(StoryTheme.ink)
                                    .frame(width: 18, height: 18)
                                    .background(StoryTheme.gold).clipShape(Circle())
                                    .padding(10)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .opacity(dimmed ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Reference media — disabled future (dashed, like Figma + Add a reference).
            Text("+ Add a reference")
                .font(StoryTheme.body(14)).foregroundStyle(StoryTheme.cream.opacity(0.45))
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(StoryTheme.cream.opacity(0.18)))
                .accessibilityHint("Not available yet")
            Text("or describe it").font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
            StoryTextField(placeholder: "Mostly landscapes and the scale of the mountains. Include us naturally. Slow, cinematic feeling.",
                           text: $description, minHeight: 96)
            StoryPrimaryButton(title: "Continue") { Task { await resolve() } }
        }
    }

    // Step 3 — context (reflect the REAL resolved intent)
    private var contextStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isResolving {
                StoryThinkingState(line: "Reading what you wrote…")
                    .frame(maxWidth: .infinity).padding(.top, 60)
            } else if let s = resolvedStory {
                Text("Here's what I understood.")
                    .font(StoryTheme.display(28)).foregroundStyle(StoryTheme.cream)
                Text(s.title).font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
                Text(s.intentSummary).font(StoryTheme.body(16))
                    .foregroundStyle(StoryTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                // Music direction — disabled future.
                StoryUnavailableSection(header: { StoryEyebrow(text: "Music") },
                    message: "Story will choose music that fits. Not available yet.")
                StoryPrimaryButton(title: "Looks good") { step = .blueprint }
                StorySecondaryButton(title: "Edit") { step = .describe; resolvedStory = nil }
            }
        }
    }

    // Step 4 — blueprint (frozen arc surface, DISABLED — no StoryBlueprint capability)
    private var blueprintStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Here's what I'll look for.")
                .font(StoryTheme.display(28)).foregroundStyle(StoryTheme.cream)
            StoryUnavailableSection(header: { StoryEyebrow(text: "Story Guide") },
                message: "As your Story grows, I'll suggest what would make it stronger. This guidance is coming in a later update.")
            Text("You're all set.").font(StoryTheme.display(20)).foregroundStyle(StoryTheme.cream)
            Text("Capture naturally as you go.")
                .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.textSecondary)
            StoryPrimaryButton(title: "Start Story") { navigate = true }
        }
    }

    private func back() {
        switch step {
        case .describe:  dismiss()
        case .feel:      step = .describe
        case .context:   step = .feel
        case .blueprint: step = .context
        }
    }

    private func resolve() async {
        isResolving = true; errorMessage = nil; step = .context
        defer { isResolving = false }
        do {
            // Prepend the chosen feeling to the direction so C1 sees it.
            let dir = feeling.map { "\($0). \(description)" } ?? description
            resolvedStory = try await useCases.startStoryWithRealIntent(title: title, direction: dir)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Something went wrong. Please try again."
            step = .feel
        }
    }
}
