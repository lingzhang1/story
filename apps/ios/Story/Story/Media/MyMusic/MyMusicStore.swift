import Foundation
import CryptoKit
import AVFoundation
import SwiftData

// MyMusicStore — managed LOCAL storage for user-imported audio (Milestone M-e, Phase 2).
//
// LOCAL-FIRST: imported bytes are copied under <Documents>/mymusic/<uuid>.<ext> and
// NEVER uploaded to the backend. The SwiftData row (MyMusicAssetModel) stores only a
// RELATIVE path + sha256 content hash + locally-derived analysis — never the bytes,
// never an absolute path (the container path changes across installs).
//
// Dedup: a re-import of identical bytes (same sha256) reuses the existing row instead
// of writing a second copy. Removal deletes both the managed file and the row.
//
// Distinct from PROVIDER tracks: provider favorites are resolved transiently and are
// NEVER permanently copied here (licensing). Only user-owned imports live in this store.
enum MyMusicStoreError: Error, LocalizedError {
    case unreadable                 // could not read the picked file (permissions / DRM / gone)
    case unsupportedOrCorrupt       // not decodable as audio, or zero-duration
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "That file couldn't be read. If it's from a streaming service it may be protected."
        case .unsupportedOrCorrupt: return "That file isn't a supported, playable audio file."
        case .copyFailed(let w): return "Couldn't save that track (\(w))."
        }
    }
}

struct MyMusicStore {
    static let shared = MyMusicStore()
    private let dirName = "mymusic"

    private var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var dirURL: URL { documentsURL.appendingPathComponent(dirName, isDirectory: true) }

    func ensureDir() { try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true) }

    /// Resolve a stored relative path to its absolute on-device URL.
    func absoluteURL(for relative: String) -> URL { documentsURL.appendingPathComponent(relative) }

    /// True when the managed file for this asset still exists (missing-file recovery check).
    func exists(_ asset: MyMusicAssetModel) -> Bool {
        FileManager.default.fileExists(atPath: absoluteURL(for: asset.relativePath).path)
    }

    /// Import a user-picked audio file into managed storage, deduping by content hash.
    /// `pickedURL` is a (possibly security-scoped) URL from the Files picker. Returns the
    /// persisted asset (existing one on a dedup hit, else a freshly inserted + analyzed row).
    /// Does NOT upload anything; bytes stay on device.
    @MainActor
    func importAudio(from pickedURL: URL, into context: ModelContext) throws -> MyMusicAssetModel {
        ensureDir()
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        guard let bytes = try? Data(contentsOf: pickedURL, options: .mappedIfSafe) else {
            throw MyMusicStoreError.unreadable
        }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        // Dedup: same bytes already imported -> reuse (and refresh lastUsedAt).
        let existing = try? context.fetch(
            FetchDescriptor<MyMusicAssetModel>(predicate: #Predicate { $0.contentHash == hash })
        )
        if let hit = existing?.first {
            hit.lastUsedAt = .now
            try? context.save()
            return hit
        }

        // Validate it is real, playable audio with a positive duration BEFORE committing a copy.
        let probe = AVURLAsset(url: pickedURL)
        let durationSeconds = CMTimeGetSeconds(probe.duration)
        guard durationSeconds.isFinite, durationSeconds > 0.1 else {
            throw MyMusicStoreError.unsupportedOrCorrupt
        }

        let id = UUID()
        let ext = pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension.lowercased()
        let rel = "\(dirName)/\(id.uuidString).\(ext)"
        let dest = documentsURL.appendingPathComponent(rel)
        do { try bytes.write(to: dest, options: .atomic) }
        catch { throw MyMusicStoreError.copyFailed(String(describing: error)) }

        // LOCAL analysis — honest: duration + coarse energy always; bpm only if validated, else nil.
        let analysis = LocalMusicAnalysis.analyze(url: dest, durationSeconds: durationSeconds)

        let name = pickedURL.deletingPathExtension().lastPathComponent
        let asset = MyMusicAssetModel(
            id: id,
            displayName: name.isEmpty ? "Imported track" : name,
            relativePath: rel,
            originalFilename: pickedURL.lastPathComponent,
            durationSeconds: durationSeconds,
            contentHash: hash,
            energyCurveJSON: analysis.energyCurveJSON,
            bpm: analysis.bpm,
            lastUsedAt: .now)
        context.insert(asset)
        try? context.save()
        return asset
    }

    /// Save a PROVIDER track as a licensing-safe favorite in the Your-music library: a REFERENCE by track id,
    /// NOT a byte copy. Deduped by "provider:<trackId>". Re-resolved live from the provider each time it is used.
    @MainActor
    @discardableResult
    func saveProviderFavorite(trackId: String, title: String, durationSeconds: Double,
                              into context: ModelContext) -> MyMusicAssetModel {
        let hash = "provider:\(trackId)"
        if let hit = (try? context.fetch(
            FetchDescriptor<MyMusicAssetModel>(predicate: #Predicate { $0.contentHash == hash })))?.first {
            hit.lastUsedAt = .now
            try? context.save()
            return hit
        }
        let asset = MyMusicAssetModel(
            displayName: title,
            relativePath: "",                 // NO bytes — licensing: a favorite is a reference, not a copy
            originalFilename: title,
            durationSeconds: durationSeconds,
            contentHash: hash,
            providerTrackId: trackId,
            lastUsedAt: .now)
        context.insert(asset)
        try? context.save()
        return asset
    }

    /// Remove an asset: delete the managed file then the row. A Story version still
    /// referencing it degrades to no-music on re-open (handled by the re-render path), never crashes.
    @MainActor
    func remove(_ asset: MyMusicAssetModel, from context: ModelContext) {
        try? FileManager.default.removeItem(at: absoluteURL(for: asset.relativePath))
        context.delete(asset)
        try? context.save()
    }

    /// Build a local MusicAnalysisV1 for an imported asset — duration only; beats/bpm honestly empty
    /// (local analysis never fabricates them). Shared by the create flow and Change Music.
    static func localAnalysis(for asset: MyMusicAssetModel) -> MusicAnalysisV1? {
        let dict: [String: Any] = [
            "duration_seconds": asset.durationSeconds,
            "tempo_reliable": false,
            "beats": [Double](),
            "downbeats": [Double]()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let an = try? JSONDecoder().decode(MusicAnalysisV1.self, from: data) else { return nil }
        return an
    }
}
