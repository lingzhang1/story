import SwiftUI
import SwiftData

// Home — Figma MVP V0.2.2 (Capture Anywhere). Hierarchy:
//   Primary:   Capture a Moment (opens the shared camera immediately) · Start a Story
//   Secondary: Moments (global library) · Stories (projects/films list)
// Dark cinematic styling preserved. The obsolete disabled "Create now" and
// "Use existing photos/videos" entries are removed (owner decision V0.2.2).
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(AuthStore.self) private var auth
    @Query private var stories: [StoryModel]
    @Query private var moments: [MomentModel]

    @State private var showCapture = false
    @State private var showStories = false
    @State private var confirmSignOut = false

    // Active Stories first (most recent first), then completed below.
    private var sortedStories: [StoryModel] {
        stories.sorted { a, b in
            if a.status != b.status { return a.status == .active }
            return a.createdAt > b.createdAt
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    // ── Primary 1: Capture a Moment — opens the shared camera immediately,
                    //    no Story / CreativeIntent / AI call required to open it.
                    Button { showCapture = true } label: {
                        StoryImageCard(image: "ph_lake", eyebrow: "Right now",
                                       title: "Capture a Moment",
                                       sub: "Capture something worth remembering. Get an AI shot idea whenever you want.",
                                       icon: "camera.fill")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 14)

                    // ── Primary 2: Start a Story — existing C1 flow, unchanged.
                    NavigationLink { CreativeDirectionView() } label: {
                        StoryImageCard(image: "ph_alpine", eyebrow: "Over time",
                                       title: "Start a Story",
                                       sub: "Collect moments, tell your story, and create a film.",
                                       icon: "film.fill")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 14)

                    // ── Secondary destinations: Moments · Stories
                    HStack(spacing: 12) {
                        NavigationLink { MomentsLibraryView() } label: {
                            secondaryCard(icon: "photo.on.rectangle", count: moments.count,
                                          title: "Moments", sub: "Your captured memories")
                        }
                        .buttonStyle(.plain)

                        Button { showStories = true } label: {
                            secondaryCard(icon: "film", count: stories.count,
                                          title: "Stories", sub: "Your projects and films")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .storyBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showStories) { StoriesListView() }
        }
        .tint(StoryTheme.gold)
        .fullScreenCover(isPresented: $showCapture) {
            // Standalone capture — NO Story association, library-only. The scene-only
            // AI intent carries no prior Story (no stale-context leak).
            ContinuousCaptureView(captureContext: .standalone(direction: nil))
        }
    }

    private var header: some View {
        HStack {
            StoryEyebrow(text: "Story")
            Spacer()
            // Account affordance — only when signed in. Lets the user (and beta testers) sign out,
            // which is required to RE-TEST the OTP flow and to verify "logout keeps local content".
            // AuthStore exposes only storyUserId (never the email), so we show a short id, by design.
            if auth.isSignedIn {
                Menu {
                    if let uid = auth.storyUserId {
                        Text("Signed in · \(String(uid.prefix(8)))")
                    } else {
                        Text("Signed in")
                    }
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(StoryTheme.cream.opacity(0.7))
                }
            }
        }
        .padding(.top, 32).padding(.bottom, 22)
        .confirmationDialog("Sign out of Story?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { auth.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Moments and Stories stay on this device. You'll sign in again to use Story's AI.")
        }
    }

    // Compact secondary destination card (icon + count row, title, sub).
    private func secondaryCard(icon: String, count: Int, title: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 18)).foregroundStyle(StoryTheme.cream.opacity(0.7))
                Spacer()
                Text("\(count)")
                    .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.cream.opacity(0.5))
            }
            .padding(.bottom, 18)
            Text(title).font(StoryTheme.display(18)).foregroundStyle(StoryTheme.cream)
            Text(sub).font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background(StoryTheme.cream.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StoryTheme.cream.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
    }
}
