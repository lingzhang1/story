import UIKit
import AVFoundation

// R5 — persisted PREVIEW (poster frame) for a Moment, so a cloud-only (evicted) video still shows real content
// in the grid instead of a black tile (owner Phase 3 #6: preserve local previews). A preview is a tiny JPEG
// under <Documents>/previews/<momentId>.jpg — kept even when the original bytes are freed. Generated from the
// ORIGINAL before eviction; reused on restore. Never the source of truth for export (R6 #9) — preview only.
struct MediaPreviewStore {
    static let shared = MediaPreviewStore()
    private let dirName = "previews"

    private var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var dirURL: URL { documentsURL.appendingPathComponent(dirName, isDirectory: true) }

    func previewURL(momentId: UUID) -> URL { dirURL.appendingPathComponent("\(momentId.uuidString).jpg") }
    func hasPreview(momentId: UUID) -> Bool { FileManager.default.fileExists(atPath: previewURL(momentId: momentId).path) }

    func loadPreview(momentId: UUID) -> UIImage? {
        UIImage(contentsOfFile: previewURL(momentId: momentId).path)
    }

    /// Extract a poster frame from the ORIGINAL video at `absoluteURL` and persist it. Returns true on success.
    /// Called BEFORE eviction so the tile keeps a preview after the original is freed. Idempotent (skips if a
    /// preview already exists). Small (<=400px) JPEG.
    @discardableResult
    func ensurePreview(momentId: UUID, originalURL: URL) async -> Bool {
        if hasPreview(momentId: momentId) { return true }
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let avAsset = AVURLAsset(url: originalURL)
        let gen = AVAssetImageGenerator(asset: avAsset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 400)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cg: CGImage = try? await withCheckedThrowingContinuation({ cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cg, _, _, err in
                if let cg { cont.resume(returning: cg) } else { cont.resume(throwing: err ?? NSError(domain: "preview", code: -1)) }
            }
        }) else { return false }
        guard let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.7) else { return false }
        do { try data.write(to: previewURL(momentId: momentId)); return true } catch { return false }
    }
}
