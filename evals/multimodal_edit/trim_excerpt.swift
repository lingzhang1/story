// trim_excerpt.swift — cut [start,end] from a source video to an .mp4 WITH audio, for human A1/B review.
// Sandbox has no ffmpeg; AVAssetExportSession does the trim natively (video+audio passthrough-ish via a
// high-quality preset). Usage: trim_excerpt <input> <out.mp4> <start_s> <end_s>
import Foundation
import AVFoundation

func die(_ m: String) -> Never { FileHandle.standardError.write((m+"\n").data(using:.utf8)!); exit(2) }
let a = CommandLine.arguments
guard a.count == 5, let s = Double(a[3]), let e = Double(a[4]), e > s else { die("usage: trim_excerpt <in> <out.mp4> <start_s> <end_s>") }
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let out = URL(fileURLWithPath: a[2])
try? FileManager.default.removeItem(at: out)
let sem = DispatchSemaphore(value: 0)
guard let exp = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { die("no export session") }
exp.outputURL = out
exp.outputFileType = .mp4
let dur = CMTimeGetSeconds(asset.duration)
let lo = max(0, min(s, dur)); let hi = max(lo + 0.05, min(e, dur))
exp.timeRange = CMTimeRange(start: CMTime(seconds: lo, preferredTimescale: 600),
                            duration: CMTime(seconds: hi - lo, preferredTimescale: 600))
exp.exportAsynchronously { sem.signal() }
sem.wait()
if exp.status == .completed {
    print("OK \(out.lastPathComponent) [\(String(format: "%.1f", lo))-\(String(format: "%.1f", hi))s]")
} else {
    die("export failed: \(exp.error?.localizedDescription ?? "unknown") status=\(exp.status.rawValue)")
}
