import XCTest
import SwiftData
@testable import Story

// P1-E — My Music durability + preview tests (offline; §10).
// A fake MusicFavoritesSyncing stands in for /v1/music/favorites (holds server revision + favorites),
// exercising the REAL reconcile/merge/push logic. Cloud-backup state + guards and preview eligibility are
// pure-logic units. No live audio-provider requests.
@MainActor
final class MusicDurabilityTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: MyMusicAssetModel.self, configurations: config)
    }

    // MARK: - Fake favorites backend

    final class FakeFavoritesSync: MusicFavoritesSyncing, @unchecked Sendable {
        var favorites: [MusicFavoriteRef] = []
        var revision = 0
        var putCount = 0
        func get(accessToken: String) async throws -> (favorites: [MusicFavoriteRef], revision: Int) {
            (favorites, revision)
        }
        func put(accessToken: String, baseRevision: Int, favorites: [MusicFavoriteRef]) async throws -> (favorites: [MusicFavoriteRef], revision: Int) {
            putCount += 1
            if baseRevision != revision {
                throw FavoritesSyncConflict(serverFavorites: self.favorites, serverRevision: revision)
            }
            self.favorites = favorites
            revision += 1
            return (favorites, revision)
        }
    }

    private func makeFavorite(trackId: String, title: String = "T") -> MyMusicAssetModel {
        let a = MyMusicAssetModel(displayName: title, relativePath: "", originalFilename: title,
                                  durationSeconds: 30, contentHash: "provider:\(trackId)", providerTrackId: trackId)
        ctx.insert(a); try? ctx.save(); return a
    }
    private func makeImported(id: UUID = UUID(), rel: String = "mymusic/x.m4a") -> MyMusicAssetModel {
        let a = MyMusicAssetModel(id: id, displayName: "Imported", relativePath: rel, originalFilename: "x.m4a",
                                  durationSeconds: 10, contentHash: String(repeating: "a", count: 64))
        ctx.insert(a); try? ctx.save(); return a
    }

    // MARK: - §10 saved catalog track sync

    func test_savingCatalogTrack_pushesReference() async {
        _ = makeFavorite(trackId: "t1")
        let fake = FakeFavoritesSync()
        let sync = MyMusicFavoritesSync(service: fake)
        await sync.pushLocal(context: ctx, activeOwner: "alice", token: { "tok" })
        XCTAssertEqual(fake.favorites.map { $0.trackId }, ["t1"])
    }

    func test_restoreAfterReinstall_adoptsCloudFavorites() async {
        // Fresh local library (empty), populated cloud -> adopt, never clear.
        let fake = FakeFavoritesSync()
        fake.favorites = [MusicFavoriteRef(trackId: "t1", title: "A", durationSeconds: 30, savedAt: 1),
                          MusicFavoriteRef(trackId: "t2", title: "B", durationSeconds: 40, savedAt: 2)]
        fake.revision = 3
        let sync = MyMusicFavoritesSync(service: fake)
        let adopted = await sync.reconcile(context: ctx, activeOwner: "alice", token: { "tok" })
        XCTAssertEqual(adopted, 2)
        let local = (try? ctx.fetch(FetchDescriptor<MyMusicAssetModel>()))?.filter { $0.isProviderFavorite } ?? []
        XCTAssertEqual(Set(local.compactMap { $0.providerTrackId }), ["t1", "t2"])
    }

    func test_emptyCloud_neverClearsLocalLibrary() async {
        _ = makeFavorite(trackId: "t1")
        let fake = FakeFavoritesSync()   // empty remote, revision 0
        let sync = MyMusicFavoritesSync(service: fake)
        _ = await sync.reconcile(context: ctx, activeOwner: "alice", token: { "tok" })
        let local = (try? ctx.fetch(FetchDescriptor<MyMusicAssetModel>()))?.filter { $0.isProviderFavorite } ?? []
        XCTAssertEqual(local.count, 1, "an empty remote must not delete a populated local library")
        // and the local one is pushed up (loss-safe union)
        XCTAssertEqual(fake.favorites.map { $0.trackId }, ["t1"])
    }

    func test_twoDeviceMerge_unionsFavorites() async {
        _ = makeFavorite(trackId: "local1")
        let fake = FakeFavoritesSync()
        fake.favorites = [MusicFavoriteRef(trackId: "cloud1", title: "C", durationSeconds: 20, savedAt: 1)]
        fake.revision = 1
        let sync = MyMusicFavoritesSync(service: fake)
        _ = await sync.reconcile(context: ctx, activeOwner: "alice", token: { "tok" })
        XCTAssertEqual(Set(fake.favorites.map { $0.trackId }), ["local1", "cloud1"], "merge is a union, neither side lost")
    }

    func test_mergedRefs_localMetadataWinsOnTie() {
        let local = makeFavorite(trackId: "t1", title: "Local Name")
        let cloud = [MusicFavoriteRef(trackId: "t1", title: "Cloud Name", durationSeconds: 30, savedAt: 5)]
        let merged = MyMusicFavoritesSync.mergedRefs(local: [local], cloud: cloud)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.title, "Local Name")
    }

    // MARK: - §10 imported-track cloud backup state

    func test_backupState_defaultsLocalOnly() {
        let a = makeImported()
        XCTAssertEqual(a.cloudBackupState, .localOnly)
        XCTAssertFalse(a.isCloudBacked)
    }

    func test_isCloudBacked_requiresVerifiedPlusMediaId() {
        let a = makeImported()
        a.cloudMediaId = "cm1"
        a.cloudBackupState = .restorePending
        XCTAssertFalse(a.isCloudBacked, "restore_pending with bytes not yet verified is not backed")
        a.cloudBackupState = .cloudVerified
        XCTAssertTrue(a.isCloudBacked)
    }

    func test_backup_refusesProviderFavorite() async {
        let fav = makeFavorite(trackId: "t1")
        do {
            try await MyMusicCloudBackup.backUp(fav, owner: "alice", accessToken: "tok")
            XCTFail("a provider favorite must never be uploaded (licensing)")
        } catch MyMusicCloudBackup.BackupError.notImported {
            // expected
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func test_audioContentType_mapping() {
        XCTAssertEqual(MyMusicCloudBackup.audioContentType(forExtension: "mp3"), "audio/mpeg")
        XCTAssertEqual(MyMusicCloudBackup.audioContentType(forExtension: "WAV"), "audio/wav")
        XCTAssertEqual(MyMusicCloudBackup.audioContentType(forExtension: "m4a"), "audio/mp4")
        XCTAssertEqual(MyMusicCloudBackup.audioContentType(forExtension: "xyz"), "audio/mp4")
    }

    // MARK: - §10 preview eligibility + honest state subtitle

    func test_previewEligibility_favoriteAlwaysPreviewable() {
        let fav = makeFavorite(trackId: "t1")
        XCTAssertTrue(MusicPickerView.canPreview(fav), "a saved favorite re-resolves authorized audio on demand")
    }

    func test_subtitle_honestStates() {
        let imported = makeImported()
        imported.cloudBackupState = .cloudVerified
        XCTAssertTrue(MusicPickerView.subtitle(for: imported).contains("Backed up"))
        imported.cloudBackupState = .restorePending
        XCTAssertTrue(MusicPickerView.subtitle(for: imported).contains("Restoring"))
        imported.cloudBackupState = .unavailable
        XCTAssertTrue(MusicPickerView.subtitle(for: imported).contains("Unavailable"))
        imported.cloudBackupState = .localOnly
        XCTAssertTrue(MusicPickerView.subtitle(for: imported).contains("this device only"))
        let fav = makeFavorite(trackId: "t1")
        XCTAssertTrue(MusicPickerView.subtitle(for: fav).hasPrefix("Saved"))
    }
}
