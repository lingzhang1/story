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
    @State private var showSignIn = false   // Home-header direct sign-in sheet (no gated action required)

    // R1 account isolation: the @Query is unscoped (SwiftData predicates can't close over runtime auth state),
    // so we filter in memory through the CENTRALIZED AccountScope rules. SwiftUI re-renders this view when
    // `auth.storyUserId` changes, so switching accounts (or signing out) refreshes both the counts and lists
    // with no stale visibility.
    private var visibleStories: [StoryModel] { stories.visible(to: auth.storyUserId) }
    private var visibleMoments: [MomentModel] { moments.visible(to: auth.storyUserId) }

    // Active Stories first (most recent first), then completed below.
    private var sortedStories: [StoryModel] {
        visibleStories.sorted { a, b in
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
                            secondaryCard(icon: "photo.on.rectangle", count: visibleMoments.count,
                                          title: "Moments", sub: "Your captured memories")
                        }
                        .buttonStyle(.plain)

                        Button { showStories = true } label: {
                            secondaryCard(icon: "film", count: visibleStories.count,
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
            // Account affordance in the Home header — the ONLY entry point to sign in WITHOUT first triggering a
            // gated AI action (Start a Story / music search / capture AI). Beta testers can sign in here to see
            // their account's Stories and to (re-)test the OTP flow.
            //   • Signed in  -> a menu showing a short id + Sign Out (AuthStore exposes only storyUserId, never
            //                   the email, by design).
            //   • Signed out -> a "Sign In" button that presents the shared SignInView as a sheet. No Story is
            //                   created and no AI is triggered; local content stays visible either way.
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
            } else {
                Button { showSignIn = true } label: {
                    Label("Sign In", systemImage: "person.crop.circle")
                        .font(StoryTheme.body(14))
                        .foregroundStyle(StoryTheme.gold)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 32).padding(.bottom, 22)
        .confirmationDialog("Sign out of Story?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { auth.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Moments and Stories stay on this device. You'll sign in again to use Story's AI.")
        }
        .sheet(isPresented: $showSignIn) {
            // Direct sign-in from Home: no pending action to resume — dismiss on success or cancel. On success,
            // AuthStore resolves the canonical story_user_id (R1.1) and the Home lists re-scope to the account.
            SignInView(auth: auth,
                       onSignedIn: { showSignIn = false },
                       onCancel: { showSignIn = false })
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
