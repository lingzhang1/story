import SwiftUI

// Explicit Moment References — the ONE reusable visual picker + reference-chip UI, shared by pre-creation
// Creative Direction and post-generation Revision (owner: do not duplicate the picker). It only SELECTS
// Moments and emits chips carrying stable UUIDs; it never creates/removes StoryMomentLinks and never
// duplicates media (thumbnails come from the existing MomentThumbnailCache).

/// A reference chip the user inserted into an instruction. Carries the STABLE Moment id (not the display
/// number) so a later reorder cannot change its meaning. `displayNumber` is for rendering only, resolved
/// against the current snapshot at render time.
struct MomentReferenceChipModel: Identifiable, Equatable {
    let id: UUID               // stable Moment UUID
    var displayNumber: Int     // current snapshot number (render-only)
}

/// The shared visual picker. Presents the Story's Moments (via the numbering snapshot) with thumbnail +
/// number + duration + selection state; multi-select; "Add references" inserts chips for the selected ids.
struct MomentReferencePicker: View {
    let numbering: StoryMomentNumbering
    /// Resolve a stable id -> MomentModel for the live thumbnail (the picker shows real frames, no media copy).
    let momentForId: (UUID) -> MomentModel?
    /// Ids already referenced (pre-checked so re-opening is additive, not destructive).
    let alreadyReferenced: Set<UUID>
    /// Called with the final selected stable ids when the user confirms.
    let onConfirm: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(numbering.items, id: \.id) { item in
                        cell(item)
                    }
                }
                .padding(StoryTheme.screenPadding)
            }
            .background(StoryTheme.ink)
            .navigationTitle("Add Moment reference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(StoryTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add\(selected.isEmpty ? "" : " \(selected.count)")") {
                        onConfirm(numbering.items.map(\.id).filter { selected.contains($0) })
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(selected.isEmpty ? StoryTheme.textMuted : StoryTheme.gold)
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear { selected = alreadyReferenced.intersection(Set(numbering.items.map(\.id))) }
        }
    }

    @ViewBuilder
    private func cell(_ item: NumberedMoment) -> some View {
        let isOn = selected.contains(item.id)
        Button {
            if isOn { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            VStack(spacing: 6) {
                thumb(item)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: StoryTheme.field))
                    .overlay(alignment: .topLeading) { numberBadge(item.number) }
                    .overlay(alignment: .topTrailing) { selectionBadge(isOn) }
                    .overlay(alignment: .bottomTrailing) { durationBadge(item.durationSeconds) }
                    .overlay(
                        RoundedRectangle(cornerRadius: StoryTheme.field)
                            .stroke(isOn ? StoryTheme.gold : Color.clear, lineWidth: 2))
                Text("Moment \(item.number)")
                    .font(StoryTheme.body(12, .medium))
                    .foregroundStyle(isOn ? StoryTheme.gold : StoryTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumb(_ item: NumberedMoment) -> some View {
        if let m = momentForId(item.id) {
            MomentThumbView(moment: m)
        } else {
            RoundedRectangle(cornerRadius: StoryTheme.field).fill(StoryTheme.surfaceAlt)
        }
    }

    private func numberBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(StoryTheme.body(12, .bold)).foregroundStyle(StoryTheme.cream)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(StoryTheme.ink.opacity(0.7), in: Capsule())
            .padding(6)
    }

    @ViewBuilder
    private func selectionBadge(_ on: Bool) -> some View {
        if on {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(StoryTheme.gold)
                .background(Circle().fill(StoryTheme.ink).padding(2))
                .padding(6)
        }
    }

    private func durationBadge(_ sec: Double) -> some View {
        Text(sec >= 1 ? "\(Int(sec.rounded()))s" : String(format: "%.1fs", sec))
            .font(StoryTheme.body(10, .medium)).foregroundStyle(StoryTheme.cream.opacity(0.9))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(StoryTheme.ink.opacity(0.7), in: Capsule())
            .padding(6)
    }
}

/// Live first-frame thumbnail for a Moment (reuses the existing cache — no new extraction, no media copy).
private struct MomentThumbView: View {
    let moment: MomentModel
    @State private var img: UIImage?
    var body: some View {
        Color.clear
            .overlay {
                if let img { Image(uiImage: img).resizable().scaledToFill() }
                else { StoryTheme.surfaceAlt }
            }
            .clipped()
            .task { img = await MomentThumbnailCache.shared.thumbnail(for: moment) }
    }
}

/// A horizontal, wrapping row of reference chips shown beneath the instruction field. Each chip shows its
/// current display number and an ✕ to remove it (removal detaches the REFERENCE only — never the Moment).
struct MomentReferenceChipRow: View {
    let chips: [MomentReferenceChipModel]
    let onRemove: (UUID) -> Void

    var body: some View {
        if chips.isEmpty { EmptyView() } else {
            FlowLayout(spacing: 6) {
                ForEach(chips) { chip in
                    HStack(spacing: 4) {
                        Text("Moment \(chip.displayNumber)")
                            .font(StoryTheme.body(12, .medium)).foregroundStyle(StoryTheme.cream)
                        Button { onRemove(chip.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(StoryTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(StoryTheme.surface, in: Capsule())
                    .overlay(Capsule().stroke(StoryTheme.gold.opacity(0.5), lineWidth: 1))
                }
            }
        }
    }
}

/// Minimal wrapping layout for the chip row (SwiftUI Layout; iOS 16+).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x - bounds.minX + s.width > maxW { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
