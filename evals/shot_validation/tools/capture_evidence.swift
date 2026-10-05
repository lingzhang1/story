// capture_evidence.swift — forward-only CaptureEvidenceV1 selector (C4A.2 EXPERIMENT).
//
// Simulates a LIVE camera-stream evidence layer by walking a source video strictly
// FORWARD in time at a cheap observation rate (~3 fps). At each observed time T the
// selector may use ONLY observations <= T (no future lookahead). It computes two
// cheap signals per observed frame — normalized luma frame-change and a sharpness
// proxy (variance-of-Laplacian) — keeps a BOUNDED rolling candidate buffer, and at
// stream end prunes to ~4–6 ordered evidence points with temporal ROLES.
//
// It is INTENT-INDEPENDENT: no people/object labels, no Story/Beat/Shot/importance/
// emotion, no event descriptions. It does NOT do optical flow, object tracking,
// embeddings, Vision/ML semantic recognition, scene understanding, or event
// classification. Same physical file -> identical evidence regardless of requested
// context (verified downstream).
//
// Two entry paths are intended for production (LIVE camera stream / OFFLINE local
// video) feeding ONE generator; this tool implements the OFFLINE path only and
// drives the generator frame-by-frame, exactly as the live path would.
//
// Usage:
//   swiftc -O capture_evidence.swift -o capture_evidence
//   capture_evidence <input_video> <out_dir> [obs_fps=3] [target_min=4] [target_max=6]
// Prints a CaptureEvidenceV1 JSON manifest (+ selector CPU time) to stdout and
// writes the selected evidence JPEGs into out_dir.

import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Accelerate

func die(_ m: String) -> Never { FileHandle.standardError.write((m+"\n").data(using:.utf8)!); exit(2) }

let GEN_VERSION = "capture_evidence/v1"

let args = CommandLine.arguments
guard args.count >= 3 else { die("usage: capture_evidence <input> <out_dir> [obs_fps] [min] [max]") }
let input = args[1]
let outDir = args[2]
let obsFps = args.count > 3 ? (Double(args[3]) ?? 3.0) : 3.0
let targetMin = args.count > 4 ? (Int(args[4]) ?? 4) : 4
let targetMax = args.count > 5 ? (Int(args[5]) ?? 6) : 6

let asset = AVURLAsset(url: URL(fileURLWithPath: input))
let durSec = CMTimeGetSeconds(asset.duration)
guard durSec.isFinite && durSec > 0 else { die("could not read duration for \(input)") }
guard let track = asset.tracks(withMediaType: .video).first else { die("no video track") }

// Observation grid: one observation every 1/obsFps seconds, forward in time.
let step = 1.0 / obsFps
var obsTimes: [Double] = []
var t = 0.0
while t < durSec { obsTimes.append(t); t += step }
if obsTimes.last.map({ durSec - $0 > 0.02 }) ?? true { obsTimes.append(max(0, durSec - 0.001)) }

// Image generator — small grayscale thumbnails are enough for cheap signals; we
// also keep a modest color JPEG ONLY for the frames we end up selecting.
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
gen.requestedTimeToleranceAfter = CMTime(seconds: 0.12, preferredTimescale: 600)
gen.maximumSize = CGSize(width: 160, height: 160)   // tiny: cheap signal compute

// Separate generator for the final selected frames at validation resolution.
let hiGen = AVAssetImageGenerator(asset: asset)
hiGen.appliesPreferredTrackTransform = true
hiGen.requestedTimeToleranceBefore = .zero
hiGen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
hiGen.maximumSize = CGSize(width: 1024, height: 1024)

func grayBuffer(_ cg: CGImage) -> ([Float], Int, Int) {
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w*h)
    let cs = CGColorSpaceCreateDeviceGray()
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w, space: cs,
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return ([],0,0) }
    ctx.draw(cg, in: CGRect(x:0,y:0,width:w,height:h))
    return (px.map { Float($0) }, w, h)
}

// Mean absolute luma difference, normalized 0..1.
func frameChange(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var acc = 0.0
    for i in 0..<a.count { acc += Double(abs(a[i]-b[i])) }
    return min(1.0, (acc / Double(a.count)) / 255.0)
}

// Sharpness proxy: variance of a cheap 3x3 Laplacian over the grayscale thumb.
func sharpness(_ g: [Float], _ w: Int, _ h: Int) -> Double {
    guard w > 2, h > 2 else { return 0 }
    var vals: [Double] = []; vals.reserveCapacity((w-2)*(h-2))
    for y in 1..<(h-1) {
        for x in 1..<(w-1) {
            let c = Double(g[y*w+x])
            let lap = 4*c - Double(g[y*w+(x-1)]) - Double(g[y*w+(x+1)])
                           - Double(g[(y-1)*w+x]) - Double(g[(y+1)*w+x])
            vals.append(lap)
        }
    }
    let mean = vals.reduce(0,+)/Double(vals.count)
    let varr = vals.reduce(0){ $0 + ($1-mean)*($1-mean) }/Double(vals.count)
    return varr
}

struct Obs { let tMs: Int; let change: Double; let sharp: Double }
var observations: [Obs] = []
var prevGray: [Float]? = nil

// Normalize sharpness across the clip at the END (needs the clip's own scale);
// forward-only still holds because selection ROLES use raw change in a causal
// rolling buffer, and the final sharpness_score is only a reported 0..1 scaling.
let cpuStart = ProcessInfo.processInfo.systemUptime

// --- FORWARD PASS: observe, compute causal change, maintain rolling candidates ---
// Rolling candidate buffer is BOUNDED: we keep the running max-change observation
// seen so far plus its immediate neighbors (before/after) as they arrive. This is
// exactly what a live selector can do with no future knowledge.
struct Cand { var tMs: Int; var change: Double; var sharp: Double }
let BUFFER_CAP = 12
var rolling: [Cand] = []            // bounded, causal
var maxChangeSoFar = 0.0
var bestChangeTMs = -1

for ot in obsTimes {
    let cmt = CMTime(seconds: ot, preferredTimescale: 600)
    guard let cg = try? gen.copyCGImage(at: cmt, actualTime: nil) else { continue }
    let (g,w,h) = grayBuffer(cg)
    if g.isEmpty { continue }
    let ch = prevGray.map { frameChange($0, g) } ?? 0.0
    let sh = sharpness(g,w,h)
    let tMs = Int((ot*1000).rounded())
    observations.append(Obs(tMs: tMs, change: ch, sharp: sh))
    prevGray = g
    // causal rolling buffer: push, keep bounded by dropping the lowest-change
    // interior candidate (never the first/last-seen anchors within the window)
    rolling.append(Cand(tMs: tMs, change: ch, sharp: sh))
    if rolling.count > BUFFER_CAP {
        // drop the smallest-change entry that is not the current newest
        var dropIdx = 0; var dropVal = Double.greatestFiniteMagnitude
        for i in 0..<(rolling.count-1) where rolling[i].change < dropVal { dropVal = rolling[i].change; dropIdx = i }
        rolling.remove(at: dropIdx)
    }
    if ch > maxChangeSoFar { maxChangeSoFar = ch; bestChangeTMs = tMs }
}
let cpuForward = ProcessInfo.processInfo.systemUptime - cpuStart

guard observations.count >= 2 else { die("too few observations (\(observations.count))") }

// --- PRUNE (at stream completion) to ~min..max ordered evidence points --------
// Always: start anchor + end anchor. Then the dominant change region (the global
// max-change observation found causally during the pass) and its before/after
// neighbors. If room remains, add the next strongest, well-separated changes.
let shStats = observations.map { $0.sharp }
let shMax = max(shStats.max() ?? 1, 1e-6)
func normSharp(_ s: Double) -> Double { min(1.0, s/shMax) }

let startObs = observations.first!
let endObs = observations.last!

// Rank interior observations by change (desc), enforce temporal separation.
let interior = observations.dropFirst().dropLast().sorted { $0.change > $1.change }
let minSepMs = max(250, Int((durSec*1000)/Double(targetMax*3)))  // scale separation to clip length

struct Pick { let tMs: Int; var role: String; let change: Double; let sharp: Double }
var picks: [Pick] = [
    Pick(tMs: startObs.tMs, role: "start", change: startObs.change, sharp: startObs.sharp),
    Pick(tMs: endObs.tMs, role: "end", change: endObs.change, sharp: endObs.sharp),
]

func farEnough(_ tMs: Int) -> Bool { picks.allSatisfy { abs($0.tMs - tMs) >= minSepMs } }

// The dominant change observation (change role) + flanking before/after.
if bestChangeTMs >= 0, let changeObs = observations.first(where: { $0.tMs == bestChangeTMs }), farEnough(changeObs.tMs) {
    picks.append(Pick(tMs: changeObs.tMs, role: "change", change: changeObs.change, sharp: changeObs.sharp))
    // before = last observation before change with meaningful separation
    if let b = observations.last(where: { $0.tMs < changeObs.tMs && changeObs.tMs - $0.tMs >= minSepMs }), farEnough(b.tMs) {
        picks.append(Pick(tMs: b.tMs, role: "before_change", change: b.change, sharp: b.sharp))
    }
    if let a = observations.first(where: { $0.tMs > changeObs.tMs && $0.tMs - changeObs.tMs >= minSepMs }), farEnough(a.tMs) {
        picks.append(Pick(tMs: a.tMs, role: "after_change", change: a.change, sharp: a.sharp))
    }
}
// Fill toward targetMax with the next strongest well-separated changes.
for o in interior {
    if picks.count >= targetMax { break }
    if farEnough(o.tMs) { picks.append(Pick(tMs: o.tMs, role: "change", change: o.change, sharp: o.sharp)) }
}
// Ensure at least targetMin: if too few (very static clip), add evenly-spaced fills.
if picks.count < targetMin {
    let need = targetMin - picks.count
    for k in 1...need {
        let frac = Double(k)/Double(need+1)
        let tMs = startObs.tMs + Int(Double(endObs.tMs - startObs.tMs)*frac)
        if farEnough(tMs) {
            let near = observations.min(by: { abs($0.tMs-tMs) < abs($1.tMs-tMs) })!
            picks.append(Pick(tMs: near.tMs, role: "change", change: near.change, sharp: near.sharp))
        }
    }
}
// Order by time; de-dup by tMs.
var seen = Set<Int>()
let ordered = picks.sorted { $0.tMs < $1.tMs }.filter { seen.insert($0.tMs).inserted }

// --- Emit selected JPEGs at validation resolution ----------------------------
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let stem = (input as NSString).lastPathComponent.replacingOccurrences(of:" ",with:"_")
    .components(separatedBy: ".").dropLast().joined(separator: "_")
func writeJPEG(_ cg: CGImage, _ path: String) -> Bool {
    guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    return CGImageDestinationFinalize(d)
}

struct EvidencePoint: Codable { let timestamp_ms: Int; let role: String; let change_score: Double; let sharpness_score: Double; let frame_ref: String }
var ev: [EvidencePoint] = []
for (i,p) in ordered.enumerated() {
    let cmt = CMTime(seconds: Double(p.tMs)/1000.0, preferredTimescale: 600)
    var ref = ""
    if let cg = try? hiGen.copyCGImage(at: cmt, actualTime: nil) {
        let path = "\(outDir)/\(stem)_ev\(i)_\(p.role)_t\(p.tMs).jpg"
        if writeJPEG(cg, path) { ref = path }
    }
    ev.append(EvidencePoint(timestamp_ms: p.tMs, role: p.role,
        change_score: (p.change*1000).rounded()/1000,
        sharpness_score: (normSharp(p.sharp)*1000).rounded()/1000, frame_ref: ref))
}
let cpuTotal = ProcessInfo.processInfo.systemUptime - cpuStart

struct CaptureEvidenceV1: Codable {
    let generator_version: String
    let duration_ms: Int
    let observation_rate_fps: Double
    let observed_frames: Int
    let evidence_count: Int
    let evidence_points: [EvidencePoint]
    let selector_cpu_ms_forward: Double
    let selector_cpu_ms_total: Double
}
let man = CaptureEvidenceV1(
    generator_version: GEN_VERSION,
    duration_ms: Int((durSec*1000).rounded()),
    observation_rate_fps: obsFps,
    observed_frames: observations.count,
    evidence_count: ev.count,
    evidence_points: ev,
    selector_cpu_ms_forward: (cpuForward*1000*100).rounded()/100,
    selector_cpu_ms_total: (cpuTotal*1000*100).rounded()/100)
print(String(data: try JSONEncoder().encode(man), encoding: .utf8)!)
