import SwiftUI
import SwiftData
import AVKit

// Moments — frozen Figma full-screen moment grid (ScreenMoments). Shows every
// Moment in the Story as square tiles; TAP a tile to PREVIEW it (video -> player,
// image -> full image), or tap the ✕ to remove-from-Story (local/mechanical,
// StoryUseCases.removeMoment — no generation, no AI). The Story's status is never
// changed here. R-c.1: also hosts the SHARED "+ Add photos or videos" import flow
// (same picker + progress banner as Story Home).
struct MomentsManageView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var story: StoryModel

    @State private var pendingRemove: MomentModel?
    @State private var previewMoment: MomentModel?
    @State private var pickerItems = false
    @State private var importProgress: ImportProgress?

    private var useCases: StoryUseCases {
        StoryUseCases(repository: StoryRepository(context: context))
    }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var moments: [MomentModel] {
        story.moments.sorted(by: { $0.createdAt < $1.createdAt })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Button { dismiss() } label: {
                        Text("←").font(StoryTheme.body(18)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                            .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Back")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Moments").font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
                        Text("\(moments.count) in \(story.title.displayTitle)")
                            .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
                    }
                    Spacer()
                }
                .padding(.top, 8)

                if moments.isEmpty {
                    StoryEmptyState(text: "No moments yet. Shoot one, or add photos or videos below.")
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: cols, spacing: 2) {
                        ForEach(moments) { m in
                            MomentManageTile(moment: m,
                                             onTap: { previewMoment = m },
                                             onRemove: { pendingRemove = m })
                        }
                    }
                    .padding(.top, 18)
                    Text("Tap a moment to preview · tap ✕ to remove it from this Story.")
                        .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
                        .padding(.top, 14)
                }

                // R-c.1: the SAME import flow as Story Home (shared picker + progress banner).
                Button { pickerItems = true } label: {
                    Text("+ Add photos or videos")
                        .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.cream.opacity(0.75))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .overlay(Capsule().stroke(StoryTheme.cream.opacity(0.14), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .padding(.top, 20)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
        }
        .storyBackground()
        .swipeBackToDismiss(dismiss)
        .overlay(alignment: .top) { importBanner }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $previewMoment) { m in
            MomentPreviewView(moment: m)
        }
        .photosPickerSheet(isPresented: $pickerItems, onProgress: { p in
            importProgress = p.finished && p.done == 0 && p.failed == 0 ? nil : p
            if p.finished {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if importProgress?.finished == true { importProgress = nil }
                }
            }
        }) { picked in
            // Shared import: persist Moments, then enqueue AU for the imported videos (contextless) + drain.
            let created = (try? useCases.addExistingMedia(to: story, relativePaths: picked)) ?? []
            if !created.isEmpty {
                let auQueue = AssetUnderstandingQueue(context: context)
                auQueue.enqueueImportedVideos(created)
                Task { await auQueue.drain() }
            }
        }
        .confirmationDialog("Remove this moment?",
                            isPresented: Binding(get: { pendingRemove != nil },
                                                 set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from Story", role: .destructive) {
                if let m = pendingRemove { try? useCases.removeMoment(m, from: story) }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("The moment is removed from this Story. This does not delete the original from your library.")
        }
    }

    // R-c.1 shared import banner (same copy/behavior as Story Home).
    @ViewBuilder
    private var importBanner: some View {
        if let p = importProgress {
            Text(StoryImportCopy.line(for: p))
                .font(StoryTheme.body(13))
                .foregroundStyle(StoryTheme.cream.opacity(0.9))
                .padding(.vertical, 10).padding(.horizontal, 18)
                .background(StoryTheme.surfaceAlt, in: Capsule())
                .overlay(Capsule().stroke(StoryTheme.cream.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: importProgress)
        }
    }
}

private struct MomentManageTile: View {
    let moment: MomentModel
    var onTap: () -> Void
    var onRemove: () -> Void
    @State private var thumb: UIImage?
    private var isVideo: Bool { (moment.asset?.durationSeconds ?? 0) > 0 }
    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let thumb { Image(uiImage: thumb).resizable().scaledToFill() }
                else { StoryTheme.surfaceAlt }
            }
            .clipped()
            .overlay(alignment: .center) {
                // A play glyph marks a video tile (vs a still) and signals the tile is tappable to preview.
                if isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(StoryTheme.cream.opacity(0.85))
                        .shadow(color: .black.opacity(0.4), radius: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(StoryTheme.cream)
                        .frame(width: 26, height: 26)
                        .background(StoryTheme.ink.opacity(0.55), in: Circle())
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove this moment")
            }
            .task { thumb = await MomentThumbnailCache.shared.thumbnail(for: moment) }
    }
}

// MomentPreviewView — full-screen preview of a single Moment's source media. Video -> AVPlayer (tap to
// play/pause, autoplays once); still image (duration 0) -> full image. Read-only; never mutates the Moment.
private struct MomentPreviewView: View {
    let moment: MomentModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var image: UIImage?

    private var isVideo: Bool { (moment.asset?.durationSeconds ?? 0) > 0 }
    private var mediaURL: URL? {
        guard let rel = moment.asset?.relativePath, MediaStore.shared.fileExists(relativePath: rel) else { return nil }
        return MediaStore.shared.absoluteURL(for: rel)
    }

    var body: some View {
        ZStack {
            StoryTheme.ink.ignoresSafeArea()
            content
        }
        // Close chrome lives in a top overlay OUTSIDE the player's ignoresSafeArea layer, so the native
        // VideoPlayer controls can't swallow the tap (the previous ✕ sat UNDER the player and never fired).
        .overlay(alignment: .topLeading) {
            Button { close() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StoryTheme.cream)
                    .frame(width: 40, height: 40)
                    .background(StoryTheme.ink.opacity(0.55), in: Circle())
                    .overlay(Circle().stroke(StoryTheme.cream.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .padding(.leading, 12).padding(.top, 8)
            .accessibilityLabel("Back")
        }
        // Swipe-right-to-go-back, like a standard iOS detail screen (shared modifier). Coexists with the
        // player's own scrubber; acts only on a decisive rightward swipe.
        .swipeBackToDismiss(dismiss)
        .onDisappear { player?.pause() }
    }

    private func close() {
        player?.pause()
        dismiss()
    }

    @ViewBuilder
    private var content: some View {
        if let url = mediaURL {
            if isVideo {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        let p = AVPlayer(url: url)
                        player = p
                        p.play()
                    }
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit().ignoresSafeArea()
            } else {
                Color.clear.task {
                    image = UIImage(contentsOfFile: url.path)
                }
            }
        } else {
            VStack(spacing: 10) {
                Text("This media isn't available.")
                    .font(StoryTheme.display(18)).foregroundStyle(StoryTheme.cream)
                Text("The original file wasn't found on this device.")
                    .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.4))
            }
        }
    }
}
