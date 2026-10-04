// sample_frames.swift — ordered, timestamped frame sampler for Shot Validation (C4A).
//
// ffmpeg/ffprobe and pyav are NOT installed in the Kiro sandbox, so frame
// extraction is done with AVFoundation's AVAssetImageGenerator (same approach as
// the C3B scene-frame tool). Extracts N EVENLY-SPACED frames across the clip (or a
// window), writes them as JPEGs named <stem>_f{idx}_t{ms}.jpg so the TEMPORAL
// ORDER and timestamp of each frame is preserved in the filename, and prints a
// JSON manifest to stdout.
//
// Usage:
//   swiftc -O sample_frames.swift -o sample_frames
//   sample_frames <input_video> <out_dir> <n_frames> [start_s] [end_s]
//
// Honors the approved C4 transport (design §7): fixed N ordered frames, evenly
// spaced, timestamped, order preserved. Handles HEVC + H.264 + portrait/landscape
// because AVFoundation decodes natively. Downscales the long edge to <=1024 px and
// JPEG-compresses to keep payload small (<~2MB/frame, matching the C2 budget).

import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func die(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(2) }

let args = CommandLine.arguments
guard args.count >= 4 else { die("usage: sample_frames <input> <out_dir> <n_frames> [start_s] [end_s]") }
let input = args[1]
let outDir = args[2]
guard let n = Int(args[3]), n > 0 else { die("n_frames must be a positive int") }

let asset = AVURLAsset(url: URL(fileURLWithPath: input))
let durSec = CMTimeGetSeconds(asset.duration)
guard durSec.isFinite && durSec > 0 else { die("could not read duration for \(input)") }

let startS = args.count > 4 ? (Double(args[4]) ?? 0) : 0
let endS = args.count > 5 ? (Double(args[5]) ?? durSec) : durSec
let lo = max(0, min(startS, durSec))
let hi = max(lo + 0.001, min(endS, durSec))

// Evenly spaced timestamps across [lo, hi]. For n==1 -> midpoint. For n>1 ->
// endpoints included, interior evenly spaced (preserves first/last evidence).
var times: [Double] = []
if n == 1 { times = [(lo + hi) / 2] }
else { for i in 0..<n { times.append(lo + (hi - lo) * Double(i) / Double(n - 1)) } }

let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true          // correct portrait/landscape orientation
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
gen.maximumSize = CGSize(width: 1024, height: 1024) // downscale long edge <= 1024

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let stem = (input as NSString).lastPathComponent
    .replacingOccurrences(of: " ", with: "_")
    .components(separatedBy: ".").dropLast().joined(separator: "_")

func writeJPEG(_ cg: CGImage, to path: String) -> Bool {
    guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    return CGImageDestinationFinalize(dst)
}

struct FrameRec: Codable { let index: Int; let t_ms: Int; let path: String; let w: Int; let h: Int }
var recs: [FrameRec] = []

for (i, t) in times.enumerated() {
    let cmt = CMTime(seconds: t, preferredTimescale: 600)
    do {
        let cg = try gen.copyCGImage(at: cmt, actualTime: nil)
        let tms = Int((t * 1000).rounded())
        let path = "\(outDir)/\(stem)_f\(i)_t\(tms).jpg"
        if writeJPEG(cg, to: path) {
            recs.append(FrameRec(index: i, t_ms: tms, path: path, w: cg.width, h: cg.height))
        }
    } catch {
        FileHandle.standardError.write("warn: frame at \(t)s failed: \(error)\n".data(using: .utf8)!)
    }
}

struct Manifest: Codable { let input: String; let duration_s: Double; let n_requested: Int; let n_extracted: Int; let frames: [FrameRec] }
let man = Manifest(input: input, duration_s: durSec, n_requested: n, n_extracted: recs.count, frames: recs)
let data = try JSONEncoder().encode(man)
print(String(data: data, encoding: .utf8)!)
