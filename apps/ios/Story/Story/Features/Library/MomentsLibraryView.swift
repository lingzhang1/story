import SwiftUI
import SwiftData

// LibraryContext — the ONE Moments-library component adapts to WHERE it was opened from
// (Capture UX corrections, Phase 4). Only the primary action + a couple of affordances
// change; the grid, tiles, preview and multi-select are shared.
//
//   • home        : browse + multi-select; primary action = "Create Story (N)".
//   • story(s)    : browse + multi-select; primary action = "Add to Story (N)". Moments
//                   already linked to `s` are badged "In Story" and are NOT re-added
//                   (dup-link prevented). Calls onChanged after linking so the Story refreshes.
//   • recentBrowse: opened from the camera's recent-Moment thumbnail. Browse-only (tap to
//                   preview), NO Select / Create / Add — closing returns to the camera.
enum LibraryContext {
    case home
    case story(StoryModel)
    case recentBrowse

    var allowsSelection: Bool {
        if case .recentBrowse = self { return false }
        return true
    }
    var associatedStory: StoryModel? {
        if case .story(let s) = self { return s }
        return nil
    }
    /// LibraryContext has an associated value (.story), so it is NOT Equatable — use this instead of `== .home`.
    var isHome: Bool { if case .home = self { return true }; return false }
}

// MomentsLibraryView — the GLOBAL Moments library. Shows EVERY Moment across all Stories,
// newest first, grouped in a square grid. Behavior adapts to LibraryContext (above). Reuses
// MomentManageTile + MomentPreviewView — no new tile/preview UI.
struct MomentsLibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthStore.self) private var auth

    var libraryContext: LibraryContext = .home
    /// Called after Moments are linked to a Story (.story context) so the caller can refresh.
    var onChanged: (() -> Void)? = nil

    @State private var moments: [MomentModel] = []
    @State private var previewMoment: MomentModel?
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var pendingDelete = false
    @State private var confirmBackup = false   // R4-A: first-use cloud-backup disclosure
    @State private var showBackupSettings = false   // R4-A.1: Auto Backup settings sheet
    @State private var showImporter = false         // import photos/videos into the global library
    @State private var showStorage = false          // R5: storage management sheet
    @State private var importBanner: String? = nil  // honest import progress line
    @State private var uploadJobState: [UUID: MediaUploadJobModel.State] = [:]   // R4-A.1: momentId -> upload state (badges)
    @State private var setupSelection: MomentSelection?   // Phase 3: selected → Start-a-Story setup
    /// Ids already linked to the active Story (.story context) — badged + excluded from re-add.
    @State private var alreadyInStory = Set<UUID>()

    private var useCases: StoryUseCases {
        StoryUseCases(repository: StoryRepository(context: context, owner: auth.activeOwner))
    }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if moments.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: cols, spacing: 2) {
                        ForEach(moments) { m in
                            tile(m)
                        }
                    }
                    .padding(.top, 8)
                    Text(hintText)
                        .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
                        .padding(.top, 14)
                }
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
        }
        .storyBackground()
        // Pin the header (title + Auto Backup + Select) so the actions stay reachable while scrolling the grid.
        .safeAreaInset(edge: .top) {
            header
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .background(.ultraThinMaterial)
        }
        .swipeBackToDismiss(dismiss)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { if selecting && !selected.isEmpty { selectionBar } }
        .fullScreenCover(item: $previewMoment) { m in MomentPreviewView(moment: m) }
        .navigationDestination(item: $setupSelection) { sel in
            // Phase 3: Create Story routes through the EXISTING Start-a-Story setup (name,
            // description, creative intent), seeding the selected Moments — not a generic
            // "New Story". One pipeline; cancelling leaves no orphan Story.
            CreativeDirectionView(seedMoments: sel.moments)
        }
        .confirmationDialog("Delete \(selected.count) moment\(selected.count == 1 ? "" : "s") from your library?",
                            isPresented: $pendingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes the original media and analysis, and removes these moments from any Story that used them. Already-created videos are unaffected.")
        }
        .confirmationDialog("Back up \(selected.count) moment\(selected.count == 1 ? "" : "s") to your account?",
                            isPresented: $confirmBackup, titleVisibility: .visible) {
            Button("Back Up") { backUpSelection() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The original video is uploaded privately to your YoTale account so it's safe if you lose this phone. It stays on this device too — nothing is deleted. Only you can access it; it won't appear for another account on this phone.")
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showBackupSettings) {
            AutoBackupSettingsView(onBackUpExisting: { backUpAllExistingLocalOnly() })
                .environment(auth)
        }
        .sheet(isPresented: $showStorage) {
            StorageSettingsView(moments: { moments })
                .environment(auth)
        }
        // Import existing photos/videos into the global library (reuses the frozen StoryPhotosPicker plumbing).
        .photosPickerSheet(
            isPresented: $showImporter,
            onProgress: { p in importBanner = p.finished ? nil : StoryImportCopy.line(for: p) },
            onPicked: { media in importPicked(media) })
        .overlay(alignment: .top) {
            if let importBanner {
                Text(importBanner)
                    .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.ink)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(StoryTheme.gold, in: Capsule())
                    .padding(.top, 70)
            }
        }
    }

    /// Create standalone global Moments from imported media, enqueue AU, and — if Auto Backup is ON — auto-
    /// enroll each for cloud upload (so a freshly-imported LARGE video exercises the multipart/resume path).
    /// Non-blocking; originals are copied into MediaStore by the picker, never deleted.
    private func importPicked(_ media: [ImportedMedia]) {
        let auQueue = AssetUnderstandingQueue(context: context)
        let uploadQueue = makeQueue()
        var created: [MomentModel] = []
        for item in media {
            guard let m = try? useCases.shootStandaloneMoment(
                relativePath: item.path, durationSeconds: item.duration) else { continue }
            // Carry recovered capture metadata (never fabricated).
            if let asset = m.asset {
                asset.capturedAt = item.capturedAt
                asset.latitude = item.latitude
                asset.longitude = item.longitude
            }
            created.append(m)
            auQueue.enqueue(momentId: m.id, relativeMediaPath: item.path,
                            sourceCaptureId: nil, captureContext: nil)
        }
        try? context.save()
        // Auto-enroll each imported Moment for backup when Auto Backup is on (no-op otherwise).
        for m in created { uploadQueue.autoEnrollIfEnabled(moment: m) }
        Task { await auQueue.drain(); await uploadQueue.drain(); reload() }
    }

    /// R4-A.1: build an upload queue bound to the live AuthStore (owner-scoped token; Wi-Fi/cellular gate from
    /// the account's preference — the default networkAllows wiring).
    private func makeQueue() -> MediaUploadQueue {
        MediaUploadQueue(
            context: context,
            activeOwner: { [weak auth] in auth?.storyUserId },
            tokenForOwner: { [weak auth] owner in
                guard let auth, auth.storyUserId == owner else { return nil }
                return await auth.validAccessToken()
            })
    }

    /// R4-A: enroll the selected local-only Moments for cloud backup under the active account, then kick the
    /// queue. Non-blocking; originals are preserved. Already-owned/other-account Moments are skipped by enroll.
    private func backUpSelection() {
        let picked = moments.filter { selected.contains($0.id) }
        let queue = makeQueue()
        for m in picked { queue.enroll(moment: m) }
        selected.removeAll(); selecting = false
        Task { await queue.drain(); reload() }
    }

    /// R4-A.1 Part 3: back up ALL existing local-only Moments visible to the active account (the explicit
    /// "back up existing too" choice). enroll() skips any Moment already owned by another account, so this
    /// never claims content it shouldn't. Non-blocking; originals preserved.
    private func backUpAllExistingLocalOnly() {
        let queue = makeQueue()
        let localOnly = moments.filter { $0.isLocalOnly }
        for m in localOnly { queue.enroll(moment: m) }
        Task { await queue.drain(); reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { dismiss() } label: {
                Text(backGlyph).font(StoryTheme.body(18)).foregroundStyle(StoryTheme.cream.opacity(0.4))
                    .frame(width: 40, height: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(backLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText).font(StoryTheme.display(22)).foregroundStyle(StoryTheme.cream)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(subtitleText)
                    .font(StoryTheme.body(12)).foregroundStyle(StoryTheme.cream.opacity(0.3))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Consolidated actions: a single overflow menu keeps the header uncluttered (owner: header was too
            // crowded with separate cloud / import / storage icons). Home + signed-in gates unchanged.
            if libraryContext.isHome {
                Menu {
                    if auth.isSignedIn {
                        Button { showBackupSettings = true } label: { Label("Auto Backup", systemImage: "icloud") }
                    }
                    Button { showImporter = true } label: { Label("Import Photos or Videos", systemImage: "square.and.arrow.down") }
                    if auth.isSignedIn {
                        Button { showStorage = true } label: { Label("Manage Storage", systemImage: "internaldrive") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 19))
                        .foregroundStyle(StoryTheme.cream.opacity(0.7))
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }.accessibilityLabel("Library options")
            }
            if !moments.isEmpty && libraryContext.allowsSelection {
                Button(selecting ? "Done" : "Select") {
                    withAnimation { selecting.toggle(); if !selecting { selected.removeAll() } }
                }
                .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.gold)
            }
        }
    }

    // Camera thumbnail (.recentBrowse) uses an explicit "camera" affordance so it reads as
    // "back to the camera", not "up a level".
    private var backGlyph: String {
        if case .recentBrowse = libraryContext { return "✕" }
        return "←"
    }
    private var backLabel: String {
        if case .recentBrowse = libraryContext { return "Back to camera" }
        return "Back"
    }

    private var titleText: String {
        switch libraryContext {
        case .home, .story: return "Moments"
        case .recentBrowse: return "Recent Moments"
        }
    }

    private var subtitleText: String {
        switch libraryContext {
        case .home:         return "\(moments.count) in your library"
        case .story(let s): return "Add to \(s.title.displayTitle)"
        case .recentBrowse: return "\(moments.count) in your library"
        }
    }

    private var hintText: String {
        if case .recentBrowse = libraryContext {
            return "Tap a moment to preview · close to return to the camera."
        }
        if selecting {
            switch libraryContext {
            case .story: return "Tap moments to select · add them to this Story."
            default:     return "Tap moments to select · create a Story from them, or delete them."
            }
        }
        switch libraryContext {
        case .story: return "Tap a moment to preview · tap Select to add moments to this Story."
        default:     return "Tap a moment to preview · tap Select to pick moments for a new Story."
        }
    }

    // MARK: - Tiles

    @ViewBuilder
    private func tile(_ m: MomentModel) -> some View {
        let inStory = alreadyInStory.contains(m.id)
        if selecting {
            MomentManageTile(moment: m, onTap: { if !inStory { toggle(m) } }, onRemove: nil)
                .overlay(alignment: .topTrailing) {
                    if inStory {
                        // Already in this Story — badged, not selectable (dup-link prevented).
                        Text("In Story")
                            .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                            .foregroundStyle(StoryTheme.ink)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(StoryTheme.gold.opacity(0.85), in: Capsule())
                            .padding(5)
                    } else {
                        Image(systemName: selected.contains(m.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(m.id) ? StoryTheme.gold : StoryTheme.cream.opacity(0.6))
                            .padding(6)
                    }
                }
                .opacity(inStory ? 0.5 : 1)
        } else {
            MomentManageTile(moment: m, onTap: { previewMoment = m }, onRemove: nil)
                .overlay(alignment: .topTrailing) {
                    if inStory {
                        Text("In Story")
                            .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                            .foregroundStyle(StoryTheme.ink)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(StoryTheme.gold.opacity(0.85), in: Capsule())
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomLeading) { backupBadge(for: m) }
        }
    }

    /// R4-A.1 Part 4 — an UNOBTRUSIVE per-tile backup-state chip (icon only, no intrusive banner). Derived
    /// from the Moment's cloud state + any live upload job for the active account.
    @ViewBuilder
    private func backupBadge(for m: MomentModel) -> some View {
        if let (icon, tint) = backupBadgeStyle(for: m) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(4)
                .background(StoryTheme.ink.opacity(0.55), in: Circle())
                .padding(5)
        }
    }

    /// (sfSymbol, tint) for the Moment's backup state, or nil for a plain local-only Moment (no clutter).
    private func backupBadgeStyle(for m: MomentModel) -> (String, Color)? {
        // R5: local-availability is an independent dimension — surface it first so a cloud-only Moment reads
        // clearly as "backed up, tap to download" rather than just "verified".
        switch m.asset?.localAvailability {
        case .restoring: return ("arrow.down.circle", StoryTheme.gold)                  // Downloading original
        case .evicted:   return ("icloud.and.arrow.down", StoryTheme.gold)              // Cloud-only (tap to restore)
        default: break                                                                  // available -> fall through
        }
        if m.cloudStateRaw == "cloud_verified" { return ("checkmark.icloud.fill", StoryTheme.gold) }
        switch uploadJobState[m.id] {
        case .running:  return ("arrow.up.circle", StoryTheme.cream.opacity(0.9))   // Uploading
        case .pending:  return ("clock", StoryTheme.cream.opacity(0.7))             // Waiting (Wi-Fi/queued)
        case .failed:   return ("exclamationmark.icloud", .red.opacity(0.9))        // Backup failed
        case .cancelled, .verified, .none:
            // Not enrolled / no live job -> NOT backed up yet. Show an explicit dim cloud-slash so every
            // tile states its backup status at a glance (owner: need to see uploaded-or-not for every video).
            // (`.verified` job with a non-verified cloud state is treated as not-yet-confirmed.)
            return ("icloud.slash", StoryTheme.cream.opacity(0.45))                 // Not backed up (local only)
        }
    }

    // MARK: - Selection bar (context-specific primary action)

    private var selectionBar: some View {
        Group {
            switch libraryContext {
            case .home:      homeSelectionBar
            case .story:
                Button { addSelectionToStory() } label: {
                    Text("Add to Story (\(selected.count))").frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Capsule().fill(StoryTheme.cream)).foregroundStyle(StoryTheme.ink)
                }.buttonStyle(.plain)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.ultraThinMaterial)
            case .recentBrowse:
                EmptyView()
            }
        }
    }

    // R4-A.1 — clear action hierarchy (owner mockup): a header count, Create Story as the full-width PRIMARY
    // on its own row, then a secondary row with Back Up (left) and a low-prominence destructive Delete (right).
    // Lives in a safe-area inset (no grid overlap); wraps cleanly on small screens.
    private var homeSelectionBar: some View {
        VStack(spacing: 12) {
            Text("\(selected.count) Moment\(selected.count == 1 ? "" : "s") selected")
                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { createStoryFromSelection() } label: {
                Label("Create Story (\(selected.count))", systemImage: "film")
                    .font(StoryTheme.display(16))
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Capsule().fill(StoryTheme.cream)).foregroundStyle(StoryTheme.ink)
            }.buttonStyle(.plain)

            HStack {
                // Secondary: Back Up (signed-in only).
                if auth.isSignedIn {
                    Button { confirmBackup = true } label: {
                        Label("Back Up (\(selected.count))", systemImage: "icloud.and.arrow.up")
                            .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.gold)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Back up \(selected.count) moments")
                }
                Spacer()
                // Destructive, low prominence (text + icon, no fill).
                Button(role: .destructive) { pendingDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                        .font(StoryTheme.body(15)).foregroundStyle(StoryTheme.cream.opacity(0.6))
                }.buttonStyle(.plain)
                    .accessibilityLabel("Delete \(selected.count) moments")
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No moments yet").font(StoryTheme.display(18)).foregroundStyle(StoryTheme.cream.opacity(0.7))
            Text("Capture a moment to start your library.")
                .font(StoryTheme.body(13)).foregroundStyle(StoryTheme.cream.opacity(0.35))
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    // MARK: - Actions

    private func reload() {
        // R1 account isolation: local-only Moments are shared with every account; owned Moments only with their
        // owner. allMoments() returns the raw library; filter through the centralized visibility rule.
        moments = ((try? useCases.allMoments()) ?? []).visible(to: auth.storyUserId)
        if let s = libraryContext.associatedStory {
            alreadyInStory = Set(s.momentLinks.compactMap { $0.moment?.id })
        } else {
            alreadyInStory = []
        }
        // R4-A.1: load this account's upload-job states for the per-tile badges.
        if let owner = auth.storyUserId {
            let jobs = (try? context.fetch(FetchDescriptor<MediaUploadJobModel>(
                predicate: #Predicate { $0.ownerAccountId == owner }))) ?? []
            uploadJobState = Dictionary(jobs.map { ($0.momentId, $0.state) }, uniquingKeysWith: { a, _ in a })
        } else {
            uploadJobState = [:]
        }
    }

    private func toggle(_ m: MomentModel) {
        if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
    }

    private func createStoryFromSelection() {
        let picked = moments.filter { selected.contains($0.id) }
        guard !picked.isEmpty else { return }
        // Phase 3: hand the selection to the existing Start-a-Story setup instead of minting a
        // generic "New Story". The wizard creates the Story once (on confirm) and links these.
        setupSelection = MomentSelection(moments: picked)
    }

    private func addSelectionToStory() {
        guard let story = libraryContext.associatedStory else { return }
        // Preserve selection order (newest-first grid order of the picked tiles).
        let picked = moments.filter { selected.contains($0.id) && !alreadyInStory.contains($0.id) }
        guard !picked.isEmpty else { return }
        try? useCases.addExistingMoments(picked, to: story)
        onChanged?()
        dismiss()
    }

    private func deleteSelected() {
        for m in moments where selected.contains(m.id) {
            try? useCases.deleteMomentFromLibrary(m)
        }
        selected.removeAll()
        selecting = false
        reload()
    }
}

// Identifiable + Hashable wrapper so a Moment multi-selection can drive navigationDestination(item:)
// into the Start-a-Story setup (Phase 3). navigationDestination(item:) requires Hashable; we hash by
// the stable UUID id (the moments array itself is reference types and need not participate).
struct MomentSelection: Identifiable, Hashable {
    let id = UUID()
    let moments: [MomentModel]

    static func == (lhs: MomentSelection, rhs: MomentSelection) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
