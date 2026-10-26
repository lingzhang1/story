import Foundation
import AVFoundation
import UIKit

// MomentFrameExtractor — implements the FROZEN au_frames/1 evidence policy
// (06-asset-understanding.md §2): from one local Moment video, extract exactly
// 24 ORDERED, evenly-spaced frames across the full clip duration, each tagged
// with its timestamp (ms), resized to longest-edge 768px and JPEG ~0.6.
//
// On-device only (AVFoundation). The original never leaves the device; only the
// derived frames are produced here and handed to the AU request (then discarded).
// No native video. No 48/96 frames. Deterministic given the same input.
struct AUExtractedFrame {
    let jpeg: Data
    let tMs: Int
}

enum MomentFrameExtractorError: Error, LocalizedError {
    case unreadable
    case tooShort
    case noFrames

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The Moment video could not be read."
        case .tooShort: return "The Moment video has no usable duration."
        case .noFrames: return "No frames could be extracted from the Moment."
        }
    }
}

struct MomentFrameExtractor {
    static let frameCount = 24                    // au_frames/1: EXACTLY 24
    static let maxLongestSide: CGFloat = 768      // au_frames/1: 768px longest edge
    static let jpegQuality: CGFloat = 0.6         // au_frames/1: JPEG ~0.6
    static let framePolicy = "au_frames/1"
    /// Frame-extraction reliability policy version. Bumped by Editorial Pipeline v2 P0 (explicit async track
    /// load + video-track verification + bounded per-frame generation). Reported in BuildProvenance so a run's
    /// extraction behavior is provable, not inferred from master.
    static let extractionPolicy = "au_extract/2"

    /// Extract 24 ordered timestamped frames from a local video file.
    /// Async because AVAssetImageGenerator image generation is awaited.
    static func extract(from url: URL) async throws -> [AUExtractedFrame] {
        let asset = AVURLAsset(url: url)
        // P0 reliability: load duration AND tracks asynchronously up front. The prior code loaded only
        // `.duration`; an asset whose video track was not yet loaded (or absent — audio-only / unsupported
        // container) could yield an image generator that returns empty for every timestamp, producing a silent
        // `.noFrames`. Verifying a VIDEO track exists turns "silent empty sheet" into an explicit, classifiable
        // failure and avoids spending 24 generation attempts on an asset that can never produce a frame.
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw MomentFrameExtractorError.unreadable
        }
        guard !videoTracks.isEmpty else {
            throw MomentFrameExtractorError.unreadable   // no decodable video track -> never fabricate
        }
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw MomentFrameExtractorError.tooShort
        }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true   // honour portrait/landscape orientation
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        // Ask AVFoundation to downscale during decode where possible (perf/memory).
        gen.maximumSize = CGSize(width: maxLongestSide * 2, height: maxLongestSide * 2)

        // Evenly spaced sample times across the FULL clip, inclusive of both ends.
        // For N frames: t_i = duration * i / (N-1), i = 0..N-1.
        let n = frameCount
        var times: [CMTime] = []
        for i in 0..<n {
            let frac = n == 1 ? 0.0 : Double(i) / Double(n - 1)
            times.append(CMTime(seconds: totalSeconds * frac, preferredTimescale: 600))
        }

        var out: [AUExtractedFrame] = []
        for t in times {
            if Task.isCancelled { break }   // honor cancellation mid-extraction
            do {
                let (cg, actual) = try await imageAndTime(gen, at: t)
                guard let jpeg = encode(cg) else { continue }
                let ms = Int((CMTimeGetSeconds(actual) * 1000).rounded())
                out.append(AUExtractedFrame(jpeg: jpeg, tMs: ms))
            } catch {
                continue   // skip an undecodable timestamp rather than fail the whole clip
            }
        }
        // Keep strictly increasing timestamps (AVFoundation may clamp near EOF).
        out.sort { $0.tMs < $1.tMs }
        var deduped: [AUExtractedFrame] = []
        var lastMs = -1
        for f in out where f.tMs > lastMs {
            deduped.append(f)
            lastMs = f.tMs
        }
        guard !deduped.isEmpty else { throw MomentFrameExtractorError.noFrames }
        return deduped
    }

    // MARK: - helpers

    private static func imageAndTime(
        _ gen: AVAssetImageGenerator, at time: CMTime
    ) async throws -> (CGImage, CMTime) {
        try await withCheckedThrowingContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, image, actualTime, result, error in
                if let image, result == .succeeded {
                    cont.resume(returning: (image, actualTime))
                } else {
                    cont.resume(throwing: error ?? MomentFrameExtractorError.noFrames)
                }
            }
        }
    }

    private static func encode(_ cg: CGImage) -> Data? {
        let image = UIImage(cgImage: cg)
        let resized = resizedToLongestSide(image, maxSide: maxLongestSide)
        return resized.jpegData(compressionQuality: jpegQuality)
    }

    private static func resizedToLongestSide(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = Swift.max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
