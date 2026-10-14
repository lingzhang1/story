import SwiftUI
import SwiftData

// App entry. Owns the SwiftData ModelContainer and injects it into the
// view hierarchy. On first launch, ensures the media directory and an
// opaque LocalIdentity exist (spec 03 §9 — no account required).

@main
struct StoryApp: App {
    let container: ModelContainer

    init() {
        let schema = Schema([
            StoryModel.self, MomentModel.self, StoryMomentLink.self,
            AssetModel.self, GeneratedOutputModel.self,
            LocalIdentityModel.self,
            MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
            StoryCoverageModel.self, StoryGuideModel.self,
            StoryMusicDirectionModel.self,
            MyMusicAssetModel.self
        ])
        let storeURL = URL.applicationSupportDirectory.appending(path: "default.store")
        do {
            // Default store location (unchanged) so existing on-device Stories keep loading.
            container = try ModelContainer(for: schema)
        } catch {
            // NON-DESTRUCTIVE migration failure (owner rule: never delete user data to recover). A schema
            // change can make an OLD on-device store fail migration — but we must NOT delete .store/-shm/-wal,
            // because that silently discards the user's Stories, Moments and rendered videos. Instead we keep
            // the existing store intact (so a FIXED build can retry the migration) and surface the failure
            // loudly. We boot a SEPARATE, clearly-named fallback store so the app is usable (not bricked) while
            // the real store is preserved for recovery; nothing is written back over the user's data.
            MediaEngineV1.beacon("ModelContainer migration FAILED (store PRESERVED, NOT deleted): \(String(describing: error).prefix(200))")
            let preservedPath = storeURL.path
            MediaEngineV1.beacon("Preserved store remains at \(preservedPath) — install a fixed build to retry migration; no user data was removed.")
            do {
                // A distinct recovery store — never the user's default.store — so the original is untouched.
                let fallbackURL = URL.applicationSupportDirectory.appending(path: "recovery-fallback.store")
                let config = ModelConfiguration(url: fallbackURL)
                container = try ModelContainer(for: schema, configurations: config)
            } catch {
                // Even the clean fallback store could not be created — genuinely unrecoverable, but the user's
                // original default.store is STILL on disk and intact for a future fixed build.
                fatalError("Failed to create fallback ModelContainer (original store preserved at \(preservedPath)): \(error)")
            }
        }
        MediaStore.shared.ensureMediaDirectory()
        Self.ensureLocalIdentity(container.mainContext)
        // Milestone D §6-7: recover orphaned RUNNING AU jobs (app killed mid-run) to
        // PENDING, then drain opportunistically. Non-blocking.
        let auQueue = AssetUnderstandingQueue(context: container.mainContext)
        auQueue.recoverOrphans()
        Task { await auQueue.drain() }
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            // Opportunistic AU drain when the app becomes active (network may now be up,
            // or pending jobs may have been enqueued last session).
            if phase == .active {
                let q = AssetUnderstandingQueue(context: container.mainContext)
                Task { await q.drain() }
            }
        }
    }

    @MainActor
    static func ensureLocalIdentity(_ context: ModelContext) {
        let existing = try? context.fetch(FetchDescriptor<LocalIdentityModel>())
        if existing?.isEmpty ?? true {
            context.insert(LocalIdentityModel())
            try? context.save()
        }
    }
}
