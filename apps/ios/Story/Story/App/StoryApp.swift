import SwiftUI
import SwiftData

// App entry. Owns the SwiftData ModelContainer and injects it into the
// view hierarchy. On first launch, ensures the media directory and an
// opaque LocalIdentity exist (spec 03 §9 — no account required).

@main
struct StoryApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: StoryModel.self, MomentModel.self,
                     AssetModel.self, GeneratedOutputModel.self,
                     LocalIdentityModel.self
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        MediaStore.shared.ensureMediaDirectory()
        Self.ensureLocalIdentity(container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(container)
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
