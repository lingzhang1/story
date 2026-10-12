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
            StoryModel.self, MomentModel.self,
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
            // A schema change can make an OLD on-device store fail lightweight migration. Rather than
            // fatalError (which bricks the app on every launch until reinstall), log loudly and recover by
            // recreating the default store. A hard migration failure already makes the old store unreadable,
            // so recreation is the only way forward; if it ALSO fails, that is genuinely unrecoverable.
            MediaEngineV1.beacon("ModelContainer migration FAILED: \(String(describing: error).prefix(200)) — recreating store")
            for ext in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + ext))
            }
            do {
                container = try ModelContainer(for: schema)
            } catch {
                fatalError("Failed to create ModelContainer even after store reset: \(error)")
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
