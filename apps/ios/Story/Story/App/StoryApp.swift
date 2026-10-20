import SwiftUI
import SwiftData

// App entry. Owns the SwiftData ModelContainer and injects it into the
// view hierarchy. On first launch, ensures the media directory and an
// opaque LocalIdentity exist (spec 03 §9 — no account required).

@main
struct StoryApp: App {
    let container: ModelContainer
    // P0 Beta Auth Increment 4: the shared session layer. Restored on launch; adopts anonymous local content
    // on first sign-in. Views read it from the environment; the networking seam gets its token via AuthStore.
    @State private var auth = AuthStore()

    init() {
        let schema = Schema([
            StoryModel.self, MomentModel.self, StoryMomentLink.self,
            AssetModel.self, GeneratedOutputModel.self,
            LocalIdentityModel.self,
            MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
            StoryCoverageModel.self, StoryGuideModel.self,
            StoryMusicDirectionModel.self,
            MyMusicAssetModel.self,
            PendingOperationModel.self,
            MusicPlanCacheModel.self,
            DurationRecCacheModel.self
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
        // P0 Phase 2 + R1: edit-plan operation recovery is now ACCOUNT-SCOPED and runs AFTER sign-in (in the
        // auth.state onChange) and on foreground — not here at container init, where no account is resolved yet
        // (a nil-account recovery is a no-op by design, and must never resume another account's render).
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(auth)
                .task {
                    // Gate paid Asset Understanding on an authenticated session (Phase 4): the AU queue drains
                    // only when this returns true. In dev optional-auth a restored/real session reports true;
                    // signed out, AU jobs stay PENDING and resume on sign-in (no model call meanwhile).
                    AssetUnderstandingQueue.sharedIsAuthed = { [weak auth] in auth?.isSignedIn ?? false }
                    // Restore a prior session (silent refresh if the access token expired) and install the
                    // first-sign-in ADOPTION hook: stamp the resolved account onto the device's LocalIdentity
                    // so existing anonymous Stories/Moments are adopted with ZERO data movement. Never deletes
                    // SwiftData; never reassigns content already owned by a DIFFERENT account.
                    // R1 — on first sign-in, run the DEV-ONLY designated-account backfill (owner Decision 3):
                    // stamp pre-R1 nil-owner Stories (and their outputs) to the designated account IFF that
                    // account is the one signing in. Idempotent, non-destructive, never overwrites an explicit
                    // owner, DEBUG-only, and never touches local-only Moments (they stay shared). New Stories are
                    // already stamped at creation; this only migrates legacy pre-ownership Stories.
                    auth.onFirstSignInAdopt = { canonicalId, legacySub in
                        let ctx = container.mainContext
                        // Keep the device LocalIdentity stamp for provenance (first canonical account seen).
                        if let ident = (try? ctx.fetch(FetchDescriptor<LocalIdentityModel>()))?.first,
                           ident.accountId == nil {
                            ident.accountId = canonicalId
                            ident.linkedAt = .now
                            try? ctx.save()
                        }
                        // R1.1 — FIRST re-key this account's R1 Stories from the legacy Cognito sub to the
                        // canonical id (so sub-stamped Stories stay visible under the canonical identity). Only
                        // this account's own sub-owned rows are touched.
                        let rekeyed = DevOwnershipBackfill.rekeySubToCanonical(
                            legacySub: legacySub, canonicalId: canonicalId, context: ctx)
                        if rekeyed > 0 {
                            MediaEngineV1.beacon("R1.1 re-key: sub->canonical for \(rekeyed) Stories")
                        }
                        // THEN the dev-only designated-account backfill for any pre-R1 nil-owner Stories,
                        // recognising the designated account by its sub but stamping the canonical id.
                        let stamped = DevOwnershipBackfill.runIfDesignatedAccount(
                            signedInSub: legacySub, canonicalId: canonicalId, context: ctx)
                        if stamped > 0 {
                            MediaEngineV1.beacon("R1 dev backfill: stamped \(stamped) pre-R1 Stories to designated account (canonical id)")
                        }
                    }
                    await auth.restore()
                }
                .onChange(of: auth.state) { _, newState in
                    // On sign-in, resume any deferred background AU (Phase 4): jobs enqueued while signed out
                    // are still PENDING; the existing idempotent upsert + orphan recovery process each exactly
                    // once under the now-authenticated account — never a duplicate understanding row.
                    if newState == .signedIn {
                        let q = AssetUnderstandingQueue(context: container.mainContext)
                        Task { await q.drain() }
                        // R1: edit-plan recovery is account-scoped and runs on sign-in — resumes ONLY the
                        // now-authenticated account's unfinished operations (never another account's).
                        PendingOperationRecovery(context: container.mainContext,
                                                 activeAccountId: auth.storyUserId).recoverAll()
                    }
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            // Opportunistic AU drain when the app becomes active (network may now be up,
            // or pending jobs may have been enqueued last session).
            if phase == .active {
                let q = AssetUnderstandingQueue(context: container.mainContext)
                Task { await q.drain() }
                // P0 Phase 2 + R1: on every foreground, resume any unfinished edit-plan operation whose poll was
                // suspended while backgrounded (or whose job completed while we were away). ACCOUNT-SCOPED
                // (only the signed-in account's Stories), idempotent + single-flight.
                PendingOperationRecovery(context: container.mainContext,
                                         activeAccountId: auth.storyUserId).recoverAll()
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
