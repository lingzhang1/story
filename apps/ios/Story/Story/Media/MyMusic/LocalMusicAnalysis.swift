import Foundation
import AVFoundation

// LocalMusicAnalysis — on-device audio analysis for imported My Music (Milestone M-e, Phase 2).
//
// HONEST by construction:
//   - duration: authoritative, from the decoded file.
//   - energy curve: a COARSE normalized (0..1) amplitude envelope, computed by RMS-windowing
//     the decoded PCM samples. This is real measured loudness, not an invented shape.
//   - bpm / beats / downbeats / highlights: we do NOT ship a validated local beat tracker, so
//     these are LEFT EMPTY (bpm nil, beats []). We NEVER fabricate them. The mix path already
//     degrades gracefully to energy-only when beats are absent (same as provider tracks without
//     reliable tempo), so an imported track still ducks/aligns on the energy envelope.
//
// All work is local; nothing is uploaded.
struct LocalMusicAnalysis {
    let energyCurveJSON: String     // JSON array of Doubles in 0..1 ("[]" when analysis failed)
    let bpm: Double?                // nil unless a validated local estimate exists (currently always nil)

    /// Analyze the decoded audio at `url`. Best-effort: on any decode failure returns an empty
    /// curve (the caller stores "[]" / nil — honest absence, never a crash).
    static func analyze(url: URL, durationSeconds: Double, buckets: Int = 32) -> LocalMusicAnalysis {
        guard let curve = energyCurve(url: url, buckets: buckets), !curve.isEmpty,
              let data = try? JSONEncoder().encode(curve),
              let json = String(data: data, encoding: .utf8) else {
            return LocalMusicAnalysis(energyCurveJSON: "[]", bpm: nil)
        }
        return LocalMusicAnalysis(energyCurveJSON: json, bpm: nil)
    }

    /// Coarse RMS energy envelope, `buckets` points, normalized so the loudest bucket is 1.0.
    /// Reads mono-mixed samples in bounded chunks (never loads the whole file into memory at once).
    private static func energyCurve(url: URL, buckets: Int) -> [Double]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = file.length
        guard total > 0, buckets > 0 else { return nil }

        let framesPerBucket = max(1, Int(total) / buckets)
        let channels = Int(format.channelCount)
        var sums = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)

        // Read in bounded blocks; attribute each block's RMS energy to its bucket.
        let blockSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else { return nil }

        var framePos = 0
        while true {
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: blockSize) }
            catch { return nil }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let chans = buffer.floatChannelData else { break }

            for i in 0..<n {
                // mono-mix the channels
                var s: Float = 0
                for c in 0..<channels { s += chans[c][i] }
                let v = Double(s / Float(max(1, channels)))
                let bucket = min(buckets - 1, (framePos + i) / framesPerBucket)
                sums[bucket] += v * v
                counts[bucket] += 1
            }
            framePos += n
            if framePos >= Int(total) { break }
        }

        var curve = (0..<buckets).map { j -> Double in
            counts[j] > 0 ? (sums[j] / Double(counts[j])).squareRoot() : 0
        }
        let peak = curve.max() ?? 0
        guard peak > 0 else { return nil }
        curve = curve.map { $0 / peak }   // normalize 0..1
        return curve
    }
}
