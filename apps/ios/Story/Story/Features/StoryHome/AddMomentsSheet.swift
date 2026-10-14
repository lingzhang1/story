import SwiftUI

// AddMomentsSheet — the shared "Add Moments" source chooser (Capture UX corrections, Phase 3).
// Replaces the ambiguous "+ Add photos or videos" entry inside a Story with two explicit sources:
//
//   1. From Story Moments — reuse the global Moments Library picker in .story context
//      (link existing reusable Moments; no media duplication, dup-link prevented).
//   2. From iPhone Photos — the existing native Photos import (unchanged pipeline).
//
// The sheet only PICKS a source and reports it back; the host owns the actual presentation
// (library cover vs photos picker) so the existing import flow is reused verbatim.
struct AddMomentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onFromStoryMoments: () -> Void
    var onFromPhotos: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(StoryTheme.cream.opacity(0.12))
                .frame(width: 36, height: 4).padding(.top, 10).padding(.bottom, 18)

            Text("Add Moments")
                .font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 4)
            Text("Reuse moments you've already captured, or bring in media from your Photos.")
                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 18)

            sourceRow(icon: "square.grid.2x2", title: "From Story Moments",
                      sub: "Pick from moments you've already captured") {
                dismiss(); onFromStoryMoments()
            }
            Divider().overlay(StoryTheme.cream.opacity(0.07)).padding(.horizontal, 24)
            sourceRow(icon: "photo.on.rectangle.angled", title: "From iPhone Photos",
                      sub: "Import photos or videos from your library") {
                dismiss(); onFromPhotos()
            }

            Button { dismiss() } label: {
                Text("Cancel").font(StoryTheme.body(14))
                    .foregroundStyle(StoryTheme.cream.opacity(0.4))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .padding(.top, 10).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceRow(icon: String, title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20)).foregroundStyle(StoryTheme.gold)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StoryTheme.body(16)).foregroundStyle(StoryTheme.cream)
                    Text(sub).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.45))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(StoryTheme.cream.opacity(0.3))
            }
            .padding(.horizontal, 24).padding(.vertical, 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
