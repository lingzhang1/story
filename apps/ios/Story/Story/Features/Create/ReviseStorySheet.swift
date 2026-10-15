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
                    Spacer(minLength: 8)
                }
                .padding(StoryTheme.screenPadding)
            }
            .background(StoryTheme.ink)
            .navigationTitle("Revise").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(StoryTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .fontWeight(.semibold)
                        .foregroundStyle(canApply ? StoryTheme.gold : StoryTheme.textMuted)
                        .disabled(!canApply)
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
        let n = numbering
        let typed = MomentReferenceResolver.parseTyped(instruction)
        let chipRefs = chips.map { (slot: DirectiveSlot.include, id: $0.id) }
        let ordering = MomentReferenceResolver.parseOrdering(instruction)
        let implicit = MomentReferenceResolver.parseImplicitFollow(instruction)
        let result = MomentReferenceResolver.resolve(typed: typed, chips: chipRefs, ordering: ordering, implicitFollow: implicit, in: n)
        if result.needsClarification {
            clarification = clarificationMessage(result.unresolved, numbering: n)
            return   // never submit a revision with unresolved references
        }
        onApply(result.directives, instruction)
        dismiss()
    }

    private func clarificationMessage(_ unresolved: [UnresolvedReference],
                                      numbering: StoryMomentNumbering) -> String {
        let parts = unresolved.map { u -> String in
            switch u.reason {
            case .numberOutOfRange(let num): return "Moment \(num) doesn't exist (this Story has \(numbering.count))"
            case .momentUnavailable: return "a referenced Moment is no longer in this Story"
            }
        }
        return "Please fix: " + parts.joined(separator: "; ") + "."
    }
}
