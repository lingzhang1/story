// stitch_plan.swift — concatenate an arm's selected EditPlan segments into ONE preview .mp4 (video+audio,
// in plan order, exact source ranges). This is a FAITHFUL PREVIEW of what the arm would cut — it is NOT the
// production MediaEngineV1 render (no soundtrack, no transitions, no crop/speed). native_audio keep/duck/mute
// is approximated: keep/duck -> source audio included; mute -> audio dropped for that segment.
//
// Usage: stitch_plan <out.mp4> <srcDir> <segmentsJSON>
//   segmentsJSON = '[{"asset_id":"IMG_x","source_start_seconds":0,"source_end_seconds":4,"native_audio":"keep"},...]'
import Foundation
import AVFoundation

func die(_ m: String) -> Never { FileHandle.standardError.write((m+"\n").data(using:.utf8)!); exit(2) }
let a = CommandLine.arguments
guard a.count >= 4 else { die("usage: stitch_plan <out.mp4> <srcDir> <segmentsJSON> [preset]") }
let outURL = URL(fileURLWithPath: a[1])
let srcDir = a[2]
guard let segData = a[3].data(using: .utf8),
      let segs = try? JSONSerialization.jsonObject(with: segData) as? [[String: Any]] else { die("bad segments JSON") }

func resolve(_ aid: String) -> URL? {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(atPath: srcDir) else { return nil }
    for f in items {
        let stem = (f as NSString).deletingPathExtension
        if stem == aid { return URL(fileURLWithPath: srcDir + "/" + f) }
    }
    return nil
}

let comp = AVMutableComposition()
guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
else { die("could not add tracks") }

var cursor = CMTime.zero
var placed = 0
for seg in segs {
    guard let aid = seg["asset_id"] as? String, let url = resolve(aid) else { continue }
    let s = (seg["source_start_seconds"] as? Double) ?? 0
    let e = (seg["source_end_seconds"] as? Double) ?? 0
    guard e > s else { continue }
    let asset = AVURLAsset(url: url)
    let dur = CMTimeGetSeconds(asset.duration)
    let lo = max(0, min(s, dur)); let hi = max(lo + 0.05, min(e, dur))
    let range = CMTimeRange(start: CMTime(seconds: lo, preferredTimescale: 600),
                            duration: CMTime(seconds: hi - lo, preferredTimescale: 600))
    guard let srcV = asset.tracks(withMediaType: .video).first else { continue }
    do {
        try vTrack.insertTimeRange(range, of: srcV, at: cursor)
        if (seg["native_audio"] as? String) != "mute", let srcA = asset.tracks(withMediaType: .audio).first {
            try? aTrack.insertTimeRange(range, of: srcA, at: cursor)
        }
        // keep orientation of the first clip's transform so portrait clips aren't sideways
        if placed == 0 { vTrack.preferredTransform = srcV.preferredTransform }
        cursor = CMTimeAdd(cursor, range.duration)
        placed += 1
    } catch { FileHandle.standardError.write("warn: seg \(aid) insert failed: \(error)\n".data(using:.utf8)!) }
}
guard placed > 0 else { die("no segments placed") }

try? FileManager.default.removeItem(at: outURL)
let presetName = a.count > 4 ? a[4] : AVAssetExportPresetMediumQuality
guard let exp = AVAssetExportSession(asset: comp, presetName: presetName) else { die("no export session") }
exp.outputURL = outURL
exp.outputFileType = .mp4
let sem = DispatchSemaphore(value: 0)
exp.exportAsynchronously { sem.signal() }
sem.wait()
if exp.status == .completed {
    print("OK \(outURL.lastPathComponent) placed=\(placed) dur=\(String(format: "%.1f", CMTimeGetSeconds(cursor)))s")
} else {
    die("export failed: status=\(exp.status.rawValue) \(exp.error?.localizedDescription ?? "")")
}
