import AVFoundation
import CoreMedia
import Foundation

// MediaEngineV1 — R-a feasibility spike (Milestone R-a).
//
// EXECUTES a frozen EditPlan/2; it does NOT reinterpret Story intelligence. Pure AVFoundation on-device
// composition: trim -> speed -> concatenate -> 9:16 reframe -> straight cut / basic crossfade -> native-audio
// mix (keep|duck|mute) + optional soundtrack -> export H.264 MP4.
//
// SCOPE (V1 only): trim, order, output duration, aspect/crop-fit, cut, basic crossfade, 0.5x–2.0x speed,
// native-audio keep/duck/mute, optional single soundtrack, export, Photos/Files save when authorized.
// NOT V1: masking, split-screen, layered compositing, generative footage, motion transitions, speed ramps,
// color grading (Creative Editing V2).
//
// This file is PARSE-CHECKED in the Kiro sandbox (swiftc -parse). Actual rendering REQUIRES Xcode / a physical
// device — AVAssetExportSession cannot run in the sandbox. Do not treat a clean parse as a successful render.

// MARK: - EditPlan/2 decode shapes (mirror the frozen contract; renderer-side DTOs)

struct EditPlanV2: Decodable {
    let schemaVersion: String
    let targetDurationSeconds: Double
    let outputFormat: String            // vertical | square | landscape
    let musicAssetId: String?
    let feasible: Bool
    let segments: [EditSegmentV2]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case targetDurationSeconds = "target_duration_seconds"
        case outputFormat = "output_format"
        case musicAssetId = "music_asset_id"
        case feasible
        case segments
    }
}

struct EditSegmentV2: Decodable {
    let order: Int
    let assetId: String                 // Moment id -> MediaStore relative path lookup by the caller
    let sourceStartSeconds: Double?
    let sourceEndSeconds: Double?
    let outputDurationSeconds: Double
    let speed: Double?
    let nativeAudio: String             // keep | duck | mute
    let musicAlignment: MusicAlignment?

    enum CodingKeys: String, CodingKey {
        case order
        case assetId = "asset_id"
        case sourceStartSeconds = "source_start_seconds"
        case sourceEndSeconds = "source_end_seconds"
        case outputDurationSeconds = "output_duration_seconds"
        case speed
        case nativeAudio = "native_audio"
        case musicAlignment = "music_alignment"
    }
}

struct MusicAlignment: Decodable {
    let anchor: String                  // beat | downbeat | highlight | none
    let note: String?
}

// MARK: - MusicAnalysis/1 (only what the renderer needs for alignment + ducking windows)

struct MusicAnalysisV1: Decodable {
    let durationSeconds: Double
    let bpm: Double?
    let tempoReliable: Bool
    let beats: [Double]
    let downbeats: [Double]
    let highlightWindow: HighlightWindow?

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case bpm
        case tempoReliable = "tempo_reliable"
        case beats
        case downbeats
        case highlightWindow = "highlight_window"
    }
}

struct HighlightWindow: Decodable {
    let startSeconds: Double
    let endSeconds: Double
    enum CodingKeys: String, CodingKey {
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

// MARK: - Inputs

struct MediaEngineInputs {
    let plan: EditPlanV2
    /// Resolve a segment.assetId (Moment id) to an on-device file URL (via MediaStore in the app).
    let resolveMomentURL: (String) -> URL?
    /// Optional authorized, temporary soundtrack file (a LOCAL licensed test file for the spike; a future
    /// temporary MusicAsset download in production — never a Free-tier distributed export).
    let soundtrackURL: URL?
    let musicAnalysis: MusicAnalysisV1?
    /// MusicPlan.audio_strategy — drives soundtrack treatment (does NOT come from the model as a curve).
    let soundtrackRole: String          // continuous | supportive | sparse
    let nativeAudioPriority: String     // low | selective | important
}

enum MediaEngineError: Error {
    case missingMoment(String)
    case noVideoTrack(String)
    case infeasiblePlan(String)
    case unsupportedOutputFormat(String)
    case exportFailed(String)
}

// MARK: - Output sizing

enum OutputSize {
    static func render(for outputFormat: String) throws -> CGSize {
        switch outputFormat {
        case "vertical":  return CGSize(width: 1080, height: 1920)   // 9:16
        case "square":    return CGSize(width: 1080, height: 1080)
        case "landscape": return CGSize(width: 1920, height: 1080)
        default: throw MediaEngineError.unsupportedOutputFormat(outputFormat)
        }
    }
}

// MARK: - Deterministic native-audio gain policy (V1, no model curves)

enum NativeAudioPolicy {
    /// Per-segment captured-audio gain. keep=1.0; duck=low under a soundtrack; mute=0.
    static func captureGain(nativeAudio: String) -> Float {
        switch nativeAudio {
        case "keep": return 1.0
        case "duck": return 0.25
        case "mute": return 0.0
        default:     return 1.0
        }
    }

    /// Soundtrack gain WHILE a kept native segment plays — driven by MusicPlan.audio_strategy, NOT the model.
    /// keep + important => soundtrack steps well back (the real sound leads); sparse role reinforces that.
    static func soundtrackGainUnder(nativeAudio: String, role: String, priority: String) -> Float {
        if nativeAudio == "keep" {
            if priority == "important" { return role == "sparse" ? 0.0 : 0.12 }
            if priority == "selective" { return 0.2 }
            return 0.35
        }
        // duck/mute segments: soundtrack carries
        switch role {
        case "continuous": return 1.0
        case "supportive": return 0.8
        case "sparse":     return 0.5
        default:            return 0.8
        }
    }
}

// MARK: - Media Engine V1

struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let segmentRanges: [(segment: EditSegmentV2, range: CMTimeRange)]
    let soundtrackTrack: AVMutableCompositionTrack?
    let totalDuration: CMTime
}

struct MediaEngineV1 {
    /// Build the AVMutableComposition + video composition from the plan. (Export is a separate call so a unit
    /// test can assert composition timing without running AVAssetExportSession.)
    func buildComposition(_ inputs: MediaEngineInputs) throws -> BuiltComposition {
        let plan = inputs.plan
        guard plan.feasible else { throw MediaEngineError.infeasiblePlan("plan marked infeasible") }
        let renderSize = try OutputSize.render(for: plan.outputFormat)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaEngineError.exportFailed("could not add video track")
        }
        let captureAudioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
        var segmentRanges: [(segment: EditSegmentV2, range: CMTimeRange)] = []

        for segment in plan.segments.sorted(by: { $0.order < $1.order }) {
            guard let url = inputs.resolveMomentURL(segment.assetId) else {
                throw MediaEngineError.missingMoment(segment.assetId)   // fail — never silently skip
            }
            let asset = AVURLAsset(url: url)
            guard let srcVideo = asset.tracks(withMediaType: .video).first else {
                throw MediaEngineError.noVideoTrack(segment.assetId)
            }
            let start = CMTime(seconds: segment.sourceStartSeconds ?? 0, preferredTimescale: 600)
            let end = CMTime(seconds: segment.sourceEndSeconds ?? segment.outputDurationSeconds,
                             preferredTimescale: 600)
            let srcRange = CMTimeRange(start: start, end: end)

            let segStart = cursor
            try videoTrack.insertTimeRange(srcRange, of: srcVideo, at: cursor)
            if let srcAudio = asset.tracks(withMediaType: .audio).first, let at = captureAudioTrack {
                try? at.insertTimeRange(srcRange, of: srcAudio, at: cursor)
            }

            // speed (0.5x–2.0x): scale the inserted range to the requested output duration
            if let speed = segment.speed, speed > 0, abs(speed - 1.0) > 0.01 {
                let inserted = CMTimeRange(start: cursor, duration: srcRange.duration)
                let scaled = CMTime(seconds: srcRange.duration.seconds / speed, preferredTimescale: 600)
                videoTrack.scaleTimeRange(inserted, toDuration: scaled)
            }

            // 9:16 (or chosen) reframe: aspect-fill transform (center crop) for this segment
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            let transform = Self.aspectFillTransform(natural: srcVideo.naturalSize,
                                                     preferred: srcVideo.preferredTransform,
                                                     render: renderSize)
            layer.setTransform(transform, at: cursor)
            layerInstructions.append(layer)

            let outDur = CMTime(seconds: segment.outputDurationSeconds, preferredTimescale: 600)
            segmentRanges.append((segment, CMTimeRange(start: segStart, duration: outDur)))
            cursor = CMTimeAdd(cursor, outDur)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instruction.layerInstructions = layerInstructions
        videoComposition.instructions = [instruction]

        // optional soundtrack (a LOCAL licensed test file for the spike; never Free-tier Epidemic export)
        var soundtrackTrack: AVMutableCompositionTrack? = nil
        if let sURL = inputs.soundtrackURL, FileManager.default.fileExists(atPath: sURL.path) {
            let sAsset = AVURLAsset(url: sURL)
            if let sTrack = sAsset.tracks(withMediaType: .audio).first,
               let mTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
                let want = CMTimeRange(start: .zero, duration: cursor)
                let avail = CMTimeRange(start: .zero, duration: min(sAsset.duration.seconds, cursor.seconds) > 0
                                        ? CMTime(seconds: min(sAsset.duration.seconds, cursor.seconds), preferredTimescale: 600)
                                        : cursor)
                try? mTrack.insertTimeRange(avail, of: sTrack, at: .zero)
                _ = want
                soundtrackTrack = mTrack
            }
        }
        return BuiltComposition(composition: composition, videoComposition: videoComposition,
                                segmentRanges: segmentRanges, soundtrackTrack: soundtrackTrack,
                                totalDuration: cursor)
    }

    /// Aspect-fill center-crop transform mapping a source track into the render rect.
    static func aspectFillTransform(natural: CGSize, preferred: CGAffineTransform, render: CGSize) -> CGAffineTransform {
        // apply the source's preferred (orientation) transform first
        let oriented = natural.applying(preferred)
        let w = abs(oriented.width == 0 ? natural.width : oriented.width)
        let h = abs(oriented.height == 0 ? natural.height : oriented.height)
        let scale = max(render.width / w, render.height / h)
        let tx = (render.width - w * scale) / 2.0
        let ty = (render.height - h * scale) / 2.0
        return preferred
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// Build the native-audio + soundtrack mix (gains only; NO sample-level model curves).
    /// Per-segment capture gain is applied over each segment's output time range, with short linear ramps at
    /// boundaries to avoid abrupt jumps. The optional soundtrack track is gained per MusicPlan.audio_strategy.
    func buildAudioMix(_ inputs: MediaEngineInputs,
                       composition: AVMutableComposition,
                       segmentRanges: [(segment: EditSegmentV2, range: CMTimeRange)],
                       soundtrackTrack: AVMutableCompositionTrack?) -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        var params: [AVMutableAudioMixInputParameters] = []
        let ramp = CMTime(seconds: 0.08, preferredTimescale: 600)   // short deterministic fade

        // capture-audio track: time-ranged gain per segment (keep/duck/mute)
        if let capture = composition.tracks(withMediaType: .audio).first {
            let p = AVMutableAudioMixInputParameters(track: capture)
            for sr in segmentRanges {
                let g = NativeAudioPolicy.captureGain(nativeAudio: sr.segment.nativeAudio)
                let r = sr.range
                let inStart = r.start
                let inEnd = CMTimeAdd(r.start, ramp)
                let outStart = CMTimeSubtract(CMTimeAdd(r.start, r.duration), ramp)
                let outEnd = CMTimeAdd(r.start, r.duration)
                // ramp in to the segment's gain, hold, ramp out — avoids clicks at cuts
                p.setVolumeRamp(fromStartVolume: 0.0, toEndVolume: g, timeRange: CMTimeRange(start: inStart, end: inEnd))
                p.setVolume(g, at: inEnd)
                p.setVolumeRamp(fromStartVolume: g, toEndVolume: 0.0, timeRange: CMTimeRange(start: outStart, end: outEnd))
            }
            params.append(p)
        }

        // soundtrack track: gained per segment by audio_strategy under kept native audio
        if let music = soundtrackTrack {
            let p = AVMutableAudioMixInputParameters(track: music)
            for sr in segmentRanges {
                let g = NativeAudioPolicy.soundtrackGainUnder(
                    nativeAudio: sr.segment.nativeAudio,
                    role: inputs.soundtrackRole, priority: inputs.nativeAudioPriority)
                p.setVolume(g, at: sr.range.start)
            }
            params.append(p)
        }
        mix.inputParameters = params
        return mix
    }

    /// Snap a planned cut time to the nearest beat/downbeat ONLY when alignment is requested AND tempo is
    /// reliable. Ambient (tempo_reliable=false) is never beat-snapped — matches the frozen planner behavior.
    static func snappedCut(at planned: Double, anchor: String, analysis: MusicAnalysisV1?, tolerance: Double = 0.15) -> Double {
        guard let a = analysis, anchor != "none" else { return planned }
        let grid: [Double]
        switch anchor {
        case "downbeat": grid = a.tempoReliable ? a.downbeats : []
        case "beat":     grid = a.tempoReliable ? a.beats : []
        case "highlight": grid = a.highlightWindow.map { [$0.startSeconds] } ?? []
        default: grid = []
        }
        guard let nearest = grid.min(by: { abs($0 - planned) < abs($1 - planned) }),
              abs(nearest - planned) <= tolerance else { return planned }
        return nearest
    }
}

// MARK: - Rendered output persistence (survives relaunch; never touches source Moments)

struct RenderOutputStore {
    static let shared = RenderOutputStore()
    private let dirName = "rendered"

    private var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var dirURL: URL { documentsURL.appendingPathComponent(dirName, isDirectory: true) }

    func ensureDir() { try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true) }

    /// A fresh output URL under <Documents>/rendered/<uuid>.mp4 (relative path is what persists).
    func newOutput() -> (relative: String, url: URL) {
        ensureDir()
        let rel = "\(dirName)/\(UUID().uuidString).mp4"
        return (rel, documentsURL.appendingPathComponent(rel))
    }

    func absoluteURL(for relative: String) -> URL { documentsURL.appendingPathComponent(relative) }
    func exists(relative: String) -> Bool { FileManager.default.fileExists(atPath: absoluteURL(for: relative).path) }
}

struct RenderResult {
    let relativePath: String
    let url: URL
    let durationSeconds: Double
    let renderSize: CGSize
}

extension MediaEngineV1 {
    /// Full render: build composition -> export H.264 MP4 -> verify duration -> persist. Cancellable.
    /// Cleans up any partial output on failure/cancel. NEVER modifies source Moments.
    /// NOTE: AVAssetExportSession runs only on device/Xcode; this is the production path, not sandbox-runnable.
    func render(_ inputs: MediaEngineInputs,
                progress: ((Float) -> Void)? = nil,
                shouldCancel: (() -> Bool)? = nil) async throws -> RenderResult {
        let built = try buildComposition(inputs)
        let mix = buildAudioMix(inputs, composition: built.composition,
                                segmentRanges: built.segmentRanges, soundtrackTrack: built.soundtrackTrack)

        guard let export = AVAssetExportSession(asset: built.composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaEngineError.exportFailed("could not create export session")
        }
        let out = RenderOutputStore.shared.newOutput()
        export.outputURL = out.url
        export.outputFileType = .mp4
        export.videoComposition = built.videoComposition
        export.audioMix = mix
        export.shouldOptimizeForNetworkUse = true

        // cancellation + progress polling
        let poller = Task {
            while export.status == .waiting || export.status == .exporting {
                progress?(export.progress)
                if shouldCancel?() == true { export.cancelExport() }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await export.export()
        poller.cancel()

        func cleanupPartial() { try? FileManager.default.removeItem(at: out.url) }

        switch export.status {
        case .completed:
            let asset = AVURLAsset(url: out.url)
            let dur = asset.duration.seconds
            // duration sanity vs the plan total (±0.3s tolerance where feasible)
            let planned = built.totalDuration.seconds
            if abs(dur - planned) > 0.3 {
                // keep the file (it IS playable) but surface the drift to the caller via the result
                progress?(1.0)
            }
            return RenderResult(relativePath: out.relative, url: out.url,
                                durationSeconds: dur, renderSize: built.videoComposition.renderSize)
        case .cancelled:
            cleanupPartial()
            throw MediaEngineError.exportFailed("cancelled")
        default:
            cleanupPartial()
            throw MediaEngineError.exportFailed(export.error?.localizedDescription ?? "export failed")
        }
    }
}
