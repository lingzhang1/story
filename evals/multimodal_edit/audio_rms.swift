// audio_rms.swift — per-window RMS of a clip's audio track, to judge whether a dropped range contains sound.
// Usage: audio_rms <input> <window_s>   -> prints "t_s rms" lines
import Foundation
import AVFoundation
let a = CommandLine.arguments
guard a.count >= 2 else { FileHandle.standardError.write("usage: audio_rms <in> [win_s]\n".data(using:.utf8)!); exit(2) }
let win = a.count > 2 ? (Double(a[2]) ?? 1.0) : 1.0
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
guard let track = asset.tracks(withMediaType: .audio).first else { print("NO_AUDIO_TRACK"); exit(0) }
let dur = CMTimeGetSeconds(asset.duration)
var t = 0.0
while t < dur {
    let hi = min(t + win, dur)
    guard let reader = try? AVAssetReader(asset: asset) else { break }
    reader.timeRange = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600),
                                   duration: CMTime(seconds: hi - t, preferredTimescale: 600))
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    guard reader.canAdd(out) else { t += win; continue }
    reader.add(out); reader.startReading()
    var sum = 0.0; var n = 0
    while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
        var len = 0; var dp: UnsafeMutablePointer<Int8>? = nil
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &dp)
        if let dp { dp.withMemoryRebound(to: Int16.self, capacity: len/2) { sp in
            for i in 0..<(len/2) { let v = Double(sp[i])/32768.0; sum += v*v; n += 1 } } }
    }
    let rms = n > 0 ? (sum/Double(n)).squareRoot() : 0.0
    print(String(format: "%.1f %.4f", t, rms))
    t += win
}
