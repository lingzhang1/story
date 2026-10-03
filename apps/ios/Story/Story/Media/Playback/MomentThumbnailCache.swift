import UIKit
import AVFoundation

// Extracts and caches a representative first-frame thumbnail for a Moment's
// video asset, so the Story Home / Preview mosaics can show real captured
// content as square tiles (Figma photographic grid) instead of embedding live
// VideoPlayers. Falls back to nil when no playable asset exists — the tile then
// shows a neutral placeholder tone. Presentation-only; no domain/contract change.
actor MomentThumbnailCache {
    static let shared = MomentThumbnailCache()

    private var cache: [String: UIImage] = [:]

    func thumbnail(for moment: MomentModel) async -> UIImage? {
        guard let asset = moment.asset,
              MediaStore.shared.fileExists(relativePath: asset.relativePath) else { return nil }
        let key = asset.relativePath
        if let cached = cache[key] { return cached }

        let url = MediaStore.shared.absoluteURL(for: asset.relativePath)
        let avAsset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: avAsset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 400)

        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cg = try? await imageCG(gen, at: time) else { return nil }
        let img = UIImage(cgImage: cg)
        cache[key] = img
        return img
    }

    private func imageCG(_ gen: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cg, _, _, err in
                if let cg { cont.resume(returning: cg) }
                else { cont.resume(throwing: err ?? NSError(domain: "thumb", code: -1)) }
            }
        }
    }
}
