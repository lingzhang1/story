import SwiftUI

// Post-generation Natural-Language Revision — the Revise entry. Reuses the SAME MomentReferencePicker and
// MomentReferenceResolver as pre-creation Creative Direction (owner: one shared picker + resolution; do not
// duplicate). The user types a change and/or adds Moment references; on Apply we resolve them into hard
// directives + a soft-direction string and hand them to the coordinator's Revise path, which carries the
// EXACT base plan so unaffected edits are preserved.
//
// SOURCE-MOMENT vs GENERATED-SEGMENT (owner Phase F): this sheet references SOURCE Moments only
// ("include/exclude/start-with Moment N"). A segment-occurrence reference ("remove the third shot") is a
// DIFFERENT concept and is intentionally NOT a Moment reference — it is left as free-text soft direction and
// not parsed as a Moment number, so the two can never be conflated.
struct ReviseStorySheet: View {
    let story: StoryModel
    let base: GeneratedOutputModel
    /// Apply the revision: resolved hard directives + the raw instruction (soft direction).
    let onApply: (ResolvedDirectives, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""
    @State private var chips: [MomentReferenceChipModel] = []
    @State private var showPicker = false
    @State private var clarification: String?
    // Interpretation lifecycle (owner safeguards #1/#2) — mirror of CustomizeYourStoryView.
    @State private var isInterpreting = false
    @State private var interpretToken = UUID()
    @State private var retryable = false

    private var numbering: StoryMomentNumbering { StoryMomentNumbering(story: story.moments) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("What would you like to change?")
                        .font(StoryTheme.displayItalic(24)).foregroundStyle(StoryTheme.cream)
                    Text("Describe the change, or reference specific Moments. The rest of the edit is kept.")
                        .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.textSecondary)

                    StoryTextField(placeholder: "Start with Moment 8, drop Moment 4, make it more cinematic…",
                                   text: $instruction, minHeight: 140)
                        .onChange(of: instruction) { _, _ in
                            interpretToken = UUID()
                            if retryable { retryable = false; clarification = nil }
                        }

                    if !story.moments.isEmpty {
                        Button { showPicker = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 13, weight: .semibold))
                                Text("Add Moment reference").font(StoryTheme.body(13, .medium))
                            }
                            .foregroundStyle(StoryTheme.gold)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .overlay(Capsule().stroke(StoryTheme.gold.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    MomentReferenceChipRow(chips: chips) { id in chips.removeAll { $0.id == id } }
                    if let clarification {
                        Text(clarification).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.danger)
                    }
                    if retryable {
                        Button { apply() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                                Text("Retry").font(StoryTheme.body(13, .medium))
                            }
                            .foregroundStyle(StoryTheme.gold)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .overlay(Capsule().stroke(StoryTheme.gold.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 8)
                }
                .padding(StoryTheme.screenPadding)
            }
            .background(StoryTheme.ink)
            .navigationTitle("Revise").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { interpretToken = UUID(); dismiss() }.foregroundStyle(StoryTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isInterpreting ? "Understanding…" : "Apply") { apply() }
                        .fontWeight(.semibold)
                        .foregroundStyle((canApply && !isInterpreting) ? StoryTheme.gold : StoryTheme.textMuted)
                        .disabled(!canApply || isInterpreting)
                }
            }
            .sheet(isPresented: $showPicker) {
                MomentReferencePicker(
                    numbering: numbering,
                    momentForId: { id in story.moments.first { $0.id == id } },
                    alreadyReferenced: Set(chips.map(\.id)),
                    onConfirm: { ids in
                        let n = numbering
                        chips = n.items.filter { ids.contains($0.id) }
                            .map { MomentReferenceChipModel(id: $0.id, displayNumber: $0.number) }
                    })
            }
        }
    }

    private var canApply: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chips.isEmpty
    }

    private func apply() {
        guard !isInterpreting else { return }                         // duplicate-tap (#1)
        let snapshotText = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotChips = chips
        let n = numbering
        let token = UUID()
        interpretToken = token
        clarification = nil; retryable = false; isInterpreting = true

        Task {
            let outcome = await InterpretationCoordinator.interpret(
                snapshotText, numbering: n,
                summaryForId: { id in story.moments.first { $0.id == id }?.caption })
            await MainActor.run {
                guard interpretToken == token else { return }          // stale-drop (#1)
                isInterpreting = false
                let musicSuffix = outcome.unsupportedMusicNote.map { "\n\($0)" } ?? ""
                switch outcome.kind {
                case .serviceFailure:
                    retryable = true
                    clarification = (outcome.blocking.first ?? "Couldn't interpret that right now.") + musicSuffix
                    return
                case .clarify:
                    clarification = clarificationText(outcome, numbering: n) + musicSuffix
                    return
                case .ok:
                    break
                }
                // Merge include chips; the Revise path carries the EXACT base plan via onApply (unchanged
                // semantics — revision operates on the selected version).
                var directives = outcome.directives
                for c in snapshotChips where !directives.mustInclude.contains(c.id) {
                    directives.mustInclude.append(c.id)
                }
                if !musicSuffix.isEmpty { clarification = outcome.unsupportedMusicNote }  // non-blocking note
                onApply(directives, snapshotText)
                dismiss()
            }
        }
    }

    private func clarificationText(_ o: InterpretationOutcome, numbering: StoryMomentNumbering) -> String {
        if !o.unresolvedMomentNumbers.isEmpty {
            let list = o.unresolvedMomentNumbers.map { "Moment \($0)" }.joined(separator: ", ")
            return "\(list) couldn't be matched (this Story has \(numbering.count)). Pick it with “Add Moment reference”, or rephrase."
        }
        if !o.unresolved.isEmpty {
            return o.unresolved.joined(separator: " ") + " Try rephrasing, or use “Add Moment reference”."
        }
        if let b = o.blocking.first { return b }
        return "Please rephrase your instruction so I can apply it."
    }
}
