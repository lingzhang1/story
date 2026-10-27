import Foundation
import SwiftData

// MyMusicFavoritesSync — P1-E (pre-beta): account-owned sync of SAVED CATALOG-TRACK references (My Music
// favorites), so they survive app uninstall/reinstall. References ONLY — never audio bytes (licensing); the
// provider remains the authorized audio source.
//
// Backed by the new /v1/music/favorites endpoint (GET + optimistic-concurrency PUT). Reconcile is UNION-first
// and loss-safe:
//   • A fresh client with an empty local library NEVER wipes a populated cloud library — pull adopts cloud
//     references first, then push the merged set.
//   • Two devices changing favorites merge by track_id (union); an unsave is represented by the device that
//     made it pushing the smaller set, but a stale empty-local never deletes — explicit removal propagates
//     only from a device that actually had the library and removed an entry (see reconcile notes).
//   • A 409 (another device won) re-pulls the server set and re-merges (never a silent overwrite).
//   • A 401 / transport error leaves local state intact and retries later (recoverable).

struct MusicFavoriteRef: Equatable {
    let trackId: String
    let title: String
    let durationSeconds: Double
    let savedAt: Int
}

protocol MusicFavoritesSyncing {
    func get(accessToken: String) async throws -> (favorites: [MusicFavoriteRef], revision: Int)
    func put(accessToken: String, baseRevision: Int, favorites: [MusicFavoriteRef]) async throws -> (favorites: [MusicFavoriteRef], revision: Int)
}

struct MusicFavoritesService: MusicFavoritesSyncing {
    var baseURL: URL = StoryBackend.baseURL
    var session: URLSession = .shared

    func get(accessToken: String) async throws -> (favorites: [MusicFavoriteRef], revision: Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/music/favorites"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 401 { throw StorySyncError.unauthorized }
        guard http.statusCode == 200 else { throw StorySyncError.badStatus(http.statusCode) }
        return Self.decode(data)
    }

    func put(accessToken: String, baseRevision: Int, favorites: [MusicFavoriteRef]) async throws -> (favorites: [MusicFavoriteRef], revision: Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/music/favorites"))
        req.httpMethod = "PUT"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "base_revision": baseRevision,
            "favorites": favorites.map { ["track_id": $0.trackId, "title": $0.title,
                                          "duration_seconds": $0.durationSeconds, "saved_at": $0.savedAt] }])
        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 401 { throw StorySyncError.unauthorized }
        if http.statusCode == 409 {
            // Another device won — surface the server's current set so the caller re-merges.
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"] as? [String: Any] ?? [:]
            let cur = detail["current"] as? [String: Any] ?? [:]
            let curData = (try? JSONSerialization.data(withJSONObject: cur)) ?? Data()
            let parsed = Self.decode(curData)
            throw FavoritesSyncConflict(serverFavorites: parsed.favorites, serverRevision: parsed.revision)
        }
        guard (200...299).contains(http.statusCode) else { throw StorySyncError.badStatus(http.statusCode) }
        return Self.decode(data)
    }

    private static func decode(_ data: Data) -> (favorites: [MusicFavoriteRef], revision: Int) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], 0) }
        let rev = (obj["revision"] as? Int) ?? (obj["revision"] as? NSNumber)?.intValue ?? 0
        let arr = (obj["favorites"] as? [[String: Any]]) ?? []
        let favs = arr.compactMap { r -> MusicFavoriteRef? in
            guard let tid = r["track_id"] as? String, !tid.isEmpty else { return nil }
            let dur = (r["duration_seconds"] as? Double) ?? (r["duration_seconds"] as? NSNumber)?.doubleValue ?? 0
            let saved = (r["saved_at"] as? Int) ?? (r["saved_at"] as? NSNumber)?.intValue ?? 0
            return MusicFavoriteRef(trackId: tid, title: (r["title"] as? String) ?? "",
                                    durationSeconds: dur, savedAt: saved)
        }
        return (favs, rev)
    }
}

struct FavoritesSyncConflict: Error { let serverFavorites: [MusicFavoriteRef]; let serverRevision: Int }

@MainActor
final class MyMusicFavoritesSync {
    static let shared = MyMusicFavoritesSync()
    private let service: MusicFavoritesSyncing
    private var lastRevision = 0
    init(service: MusicFavoritesSyncing = MusicFavoritesService()) { self.service = service }

    /// Reconcile saved catalog favorites: PULL the cloud set, UNION with the local saved favorites (so a fresh
    /// install adopts cloud references and a populated local set is never lost), adopt any cloud refs missing
    /// locally, then PUSH the merged set. Idempotent; loss-safe; a 409 re-pulls + retries once.
    @discardableResult
    func reconcile(context: ModelContext, activeOwner: String?, token: @escaping () async -> String?) async -> Int {
        guard activeOwner != nil, let accessToken = await token() else { return 0 }
        let cloud: (favorites: [MusicFavoriteRef], revision: Int)
        do { cloud = try await service.get(accessToken: accessToken) } catch { return 0 }
        lastRevision = cloud.revision

        // Adopt any cloud favorite missing locally (restore after reinstall). Keyed by providerTrackId.
        let localFavorites = (try? context.fetch(FetchDescriptor<MyMusicAssetModel>()))?
            .filter { $0.isProviderFavorite } ?? []
        var localTrackIds = Set(localFavorites.compactMap { $0.providerTrackId })
        var adopted = 0
        for ref in cloud.favorites where !localTrackIds.contains(ref.trackId) {
            MyMusicStore.shared.saveProviderFavorite(trackId: ref.trackId, title: ref.title,
                                                     durationSeconds: ref.durationSeconds, into: context)
            localTrackIds.insert(ref.trackId)
            adopted += 1
        }

        // Build the merged set (union of local + cloud) to push back, so neither side silently loses an entry.
        let mergedRefs = Self.mergedRefs(local: localFavorites, cloud: cloud.favorites)
        // Only push if the local set differs from what the server already has (avoid a no-op revision bump).
        let cloudSet = Set(cloud.favorites.map { $0.trackId })
        let mergedSet = Set(mergedRefs.map { $0.trackId })
        if mergedSet != cloudSet {
            do {
                let out = try await service.put(accessToken: accessToken, baseRevision: lastRevision, favorites: mergedRefs)
                lastRevision = out.revision
            } catch let c as FavoritesSyncConflict {
                // Re-merge against the server's newer set and push once more.
                let reMerged = Self.mergedRefs(local: localFavorites, cloud: c.serverFavorites)
                _ = try? await service.put(accessToken: accessToken, baseRevision: c.serverRevision, favorites: reMerged)
            } catch { /* transport/401 — retry on a later reconcile; local intact */ }
        }
        return adopted
    }

    /// Push the current local saved-favorite set after a save/unsave, so the change propagates. Best-effort;
    /// a 409 re-pulls + re-merges. Called from the picker's toggle (fire-and-forget).
    func pushLocal(context: ModelContext, activeOwner: String?, token: @escaping () async -> String?) async {
        guard activeOwner != nil, let accessToken = await token() else { return }
        let local = (try? context.fetch(FetchDescriptor<MyMusicAssetModel>()))?.filter { $0.isProviderFavorite } ?? []
        let refs = local.map { MusicFavoriteRef(trackId: $0.providerTrackId ?? "", title: $0.displayName,
                                                durationSeconds: $0.durationSeconds,
                                                savedAt: Int($0.createdAt.timeIntervalSince1970)) }
            .filter { !$0.trackId.isEmpty }
        do {
            let out = try await service.put(accessToken: accessToken, baseRevision: lastRevision, favorites: refs)
            lastRevision = out.revision
        } catch let c as FavoritesSyncConflict {
            // Server changed under us: adopt the union and push once more so no device's save is dropped.
            let merged = Self.mergedRefs(local: local, cloud: c.serverFavorites)
            if let out = try? await service.put(accessToken: accessToken, baseRevision: c.serverRevision, favorites: merged) {
                lastRevision = out.revision
            }
        } catch { /* recoverable; next reconcile retries */ }
    }

    // UNION merge by track_id; local metadata preferred when both carry the same track (local displayName is
    // the user-facing name). `cloud` is the server's reference set to union with the local saved favorites.
    static func mergedRefs(local: [MyMusicAssetModel], cloud: [MusicFavoriteRef]) -> [MusicFavoriteRef] {
        var byId: [String: MusicFavoriteRef] = [:]
        for r in cloud { byId[r.trackId] = r }
        for a in local {
            guard let tid = a.providerTrackId else { continue }
            byId[tid] = MusicFavoriteRef(trackId: tid, title: a.displayName,
                                         durationSeconds: a.durationSeconds,
                                         savedAt: Int(a.createdAt.timeIntervalSince1970))   // local wins on a tie
        }
        return Array(byId.values).sorted { $0.savedAt < $1.savedAt }
    }
}
