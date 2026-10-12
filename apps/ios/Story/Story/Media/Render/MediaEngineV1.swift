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

struct EditPlanV2: Codable {
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

struct EditSegmentV2: Codable {
    let order: Int
    let assetId: String                 // Moment id -> MediaStore relative path lookup by the caller
    let sourceStartSeconds: Double?
    let sourceEndSeconds: Double?
    let outputDurationSeconds: Double
    let speed: Double?
    let nativeAudio: String             // keep | duck | mute
    let musicAlignment: MusicAlignment?
    let transition: Transition?         // frozen TransitionInstruction: cut | fade | dissolve (+ duration)

    enum CodingKeys: String, CodingKey {
        case order
        case assetId = "asset_id"
        case sourceStartSeconds = "source_start_seconds"
        case sourceEndSeconds = "source_end_seconds"
        case outputDurationSeconds = "output_duration_seconds"
        case speed
        case nativeAudio = "native_audio"
        case musicAlignment = "music_alignment"
        case transition
    }

    init(order: Int, assetId: String, sourceStartSeconds: Double?, sourceEndSeconds: Double?,
         outputDurationSeconds: Double, speed: Double?, nativeAudio: String,
         musicAlignment: MusicAlignment?, transition: Transition? = nil) {
        self.order = order; self.assetId = assetId
        self.sourceStartSeconds = sourceStartSeconds; self.sourceEndSeconds = sourceEndSeconds
        self.outputDurationSeconds = outputDurationSeconds; self.speed = speed
        self.nativeAudio = nativeAudio; self.musicAlignment = musicAlignment; self.transition = transition
    }
}

/// Mirrors the frozen TransitionInstruction (ai_contracts.TransitionType = cut | fade | dissolve). The renderer
/// treats a CROSSFADE as `dissolve` (both clips visible, cross-dissolving opacity) — the standard meaning;
/// `fade` is a single-clip fade and `cut` is a straight cut. We do NOT change the frozen contract.
struct Transition: Codable {
    let type: String                    // cut | fade | dissolve
    let durationSeconds: Double?
    enum CodingKeys: String, CodingKey {
        case type
        case durationSeconds = "duration_seconds"
    }
    /// The crossfade overlap this transition implies on its INCOMING segment (0 for cut/fade/absent).
    var crossfadeSeconds: Double { type == "dissolve" ? (durationSeconds ?? 0.3) : 0.0 }
}

struct MusicAlignment: Codable {
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
    /// Set by render() AFTER awaiting the soundtrack asset's tracks load, so buildComposition's synchronous
    /// tracks() read returns the real audio track (a freshly-downloaded temp MP3 is otherwise empty on iOS 16+).
    var preloadedSoundtrackAsset: AVURLAsset? = nil
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
    /// Fire-and-forget diagnostic beacon: GET /health?music=<note>. Lands in the App Runner ACCESS log so the
    /// no-music investigation can read the device-side music state server-side (no console/dev-mode needed).
    /// Best-effort, non-blocking — never affects the render.
    static func beacon(_ note: String) {
        var comps = URLComponents(url: StoryBackend.baseURL.appendingPathComponent("health"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "music", value: String(note.prefix(180)))]
        guard let url = comps?.url else { return }
        URLSession.shared.dataTask(with: url).resume()
    }

    /// Build the AVMutableComposition + video composition from the plan. (Export is a separate call so a unit
    /// test can assert composition timing without running AVAssetExportSession.)
    func buildComposition(_ inputs: MediaEngineInputs) throws -> BuiltComposition {
        let plan = inputs.plan
        guard plan.feasible else { throw MediaEngineError.infeasiblePlan("plan marked infeasible") }
        let renderSize = try OutputSize.render(for: plan.outputFormat)

        let composition = AVMutableComposition()
        // TWO video tracks (ping-pong) so adjacent segments can OVERLAP for a crossfade. A straight cut simply
        // places the next segment at the previous one's end (zero overlap) — the two-track arrangement is a
        // superset of the old single-track cut behavior.
        guard let vTrackA = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let vTrackB = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaEngineError.exportFailed("could not add video tracks")
        }
        let vTracks = [vTrackA, vTrackB]
        // Matching TWO capture-audio tracks so overlapping segment audio can cross-ramp without a spike.
        let aTrackA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let aTrackB = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let aTracks = [aTrackA, aTrackB]

        let sorted = plan.segments.sorted(by: { $0.order < $1.order })
        var cursor = CMTime.zero
        // Per-segment placement on the timeline (track index + output range) — drives instructions + audio mix.
        var placed: [(segment: EditSegmentV2, track: Int, range: CMTimeRange)] = []

        for (i, segment) in sorted.enumerated() {
            guard let url = inputs.resolveMomentURL(segment.assetId) else {
                throw MediaEngineError.missingMoment(segment.assetId)   // fail — never silently skip
            }
            let asset = AVURLAsset(url: url)
            guard let srcVideo = asset.tracks(withMediaType: .video).first else {
                throw MediaEngineError.noVideoTrack(segment.assetId)
            }
            // A segment crossfades with the PREVIOUS one when THIS segment requests a dissolve. Clamp the
            // overlap to < both neighbours' durations so it can never invert the timeline.
            var xf = segment.transition?.crossfadeSeconds ?? 0.0
            if i == 0 { xf = 0.0 }                                       // nothing to blend into before seg 0
            if xf > 0 {
                let prevOut = placed.last?.range.duration.seconds ?? 0
                xf = max(0.0, min(xf, min(segment.outputDurationSeconds, prevOut) - 0.05))
            }

            let track = vTracks[i % 2]
            let aTrack = aTracks[i % 2]
            let start = CMTime(seconds: segment.sourceStartSeconds ?? 0, preferredTimescale: 600)
            let end = CMTime(seconds: segment.sourceEndSeconds ?? segment.outputDurationSeconds,
                             preferredTimescale: 600)
            let srcRange = CMTimeRange(start: start, end: end)

            // Overlap: pull this segment's start back by xf so it begins while the previous is still visible.
            let segStart = i == 0 ? cursor
                : CMTimeSubtract(cursor, CMTime(seconds: xf, preferredTimescale: 600))

            try track.insertTimeRange(srcRange, of: srcVideo, at: segStart)
            if let srcAudio = asset.tracks(withMediaType: .audio).first, let at = aTrack {
                try? at.insertTimeRange(srcRange, of: srcAudio, at: segStart)
            }
            // speed (0.5x–2.0x): scale the inserted range to the requested output duration
            if let speed = segment.speed, speed > 0, abs(speed - 1.0) > 0.01 {
                let inserted = CMTimeRange(start: segStart, duration: srcRange.duration)
                let scaled = CMTime(seconds: srcRange.duration.seconds / speed, preferredTimescale: 600)
                track.scaleTimeRange(inserted, toDuration: scaled)
            }

            let outDur = CMTime(seconds: segment.outputDurationSeconds, preferredTimescale: 600)
            placed.append((segment, i % 2, CMTimeRange(start: segStart, duration: outDur)))
            cursor = CMTimeAdd(segStart, outDur)   // next segment appends after THIS one's end
        }

        // Build per-time-range video-composition instructions. Collect boundary times, then for each slice
        // decide which track(s) are visible and ramp opacity across any overlap.
        let total = cursor
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        // transform per track for the CURRENTLY-active segment on it (set at each segment start)
        func transform(for segment: EditSegmentV2) throws -> CGAffineTransform {
            guard let url = inputs.resolveMomentURL(segment.assetId),
                  let v = AVURLAsset(url: url).tracks(withMediaType: .video).first else {
                throw MediaEngineError.missingMoment(segment.assetId)
            }
            return Self.aspectFitTransform(natural: v.naturalSize, preferred: v.preferredTransform, render: renderSize)
        }

        // AVVideoComposition.instructions MUST tile [0, total] CONTIGUOUSLY with NO gaps and NO overlapping
        // time ranges — otherwise AVAssetExportSession fails with "Operation Stopped" and never produces a
        // file. The previous per-segment loop double-covered the crossfade window (segment i's overlap range
        // and segment i+1's solo range both started at the same boundary), which is exactly that failure.
        //
        // Build instructions by a BOUNDARY SWEEP instead: collect every segment's start and end as boundary
        // times, sort+dedupe them, and emit exactly ONE instruction per [t_k, t_{k+1}) slice. For each slice,
        // whichever placed segments are live over it are drawn (one = solo, two = crossfade overlap). This
        // guarantees contiguous, non-overlapping coverage by construction.
        func liveSegments(in slice: CMTimeRange) -> [(segment: EditSegmentV2, track: Int, range: CMTimeRange)] {
            placed.filter { p in
                let pEnd = CMTimeAdd(p.range.start, p.range.duration)
                // live if the segment's range strictly contains the slice interior
                return CMTimeCompare(p.range.start, slice.start) <= 0 && CMTimeCompare(pEnd, slice.end) >= 0
            }
        }

        // boundary set: every segment start + end, clamped to [0, total], sorted & deduped
        var boundaries: [CMTime] = [CMTime.zero, total]
        for p in placed {
            boundaries.append(p.range.start)
            boundaries.append(CMTimeAdd(p.range.start, p.range.duration))
        }
        boundaries = boundaries
            .filter { CMTimeCompare($0, .zero) >= 0 && CMTimeCompare($0, total) <= 0 }
            .sorted { CMTimeCompare($0, $1) < 0 }
        // dedupe adjacent equal times
        var distinct: [CMTime] = []
        for b in boundaries where distinct.last.map({ CMTimeCompare($0, b) != 0 }) ?? true { distinct.append(b) }

        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for k in 0..<max(0, distinct.count - 1) {
            let sliceStart = distinct[k]
            let sliceEnd = distinct[k + 1]
            guard CMTimeCompare(sliceEnd, sliceStart) > 0 else { continue }   // skip zero-length slices
            let slice = CMTimeRange(start: sliceStart, end: sliceEnd)
            let live = liveSegments(in: slice)
            guard !live.isEmpty else { continue }   // (should not happen: coverage is total)

            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = slice
            if live.count == 1 {
                // SOLO slice: one track visible, full opacity.
                let p = live[0]
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vTracks[p.track])
                li.setTransform(try transform(for: p.segment), at: slice.start)
                inst.layerInstructions = [li]
            } else {
                // OVERLAP slice (crossfade): two segments live. The one that STARTED EARLIER is outgoing
                // (ramps 1→0 across this slice); the later one is incoming (ramps 0→1), drawn on top.
                let ordered = live.sorted { CMTimeCompare($0.range.start, $1.range.start) < 0 }
                let outP = ordered[0]
                let inP = ordered[1]
                let outLI = AVMutableVideoCompositionLayerInstruction(assetTrack: vTracks[outP.track])
                outLI.setTransform(try transform(for: outP.segment), at: slice.start)
                outLI.setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0, timeRange: slice)
                let inLI = AVMutableVideoCompositionLayerInstruction(assetTrack: vTracks[inP.track])
                inLI.setTransform(try transform(for: inP.segment), at: slice.start)
                inLI.setOpacityRamp(fromStartOpacity: 0.0, toEndOpacity: 1.0, timeRange: slice)
                inst.layerInstructions = [outLI, inLI]   // incoming drawn over outgoing
            }
            instructions.append(inst)
        }
        videoComposition.instructions = instructions

        // optional soundtrack (a LOCAL licensed test file; never Free-tier Epidemic export)
        var soundtrackTrack: AVMutableCompositionTrack? = nil
        // Use the asset PRE-LOADED asynchronously by render() (see renderSoundtrackAsset). A freshly-downloaded
        // temp MP3 is not indexed yet, so a sync tracks() read here returns empty on iOS 16+ (the 'no music'
        // bug); loading it with await in render() BEFORE this sync builder makes tracks() return the real track
        // without a blocking semaphore (which risked the AVFoundation 'Result accumulator timeout' stall).
        if let sAsset = inputs.preloadedSoundtrackAsset {
            if let sTrack = sAsset.tracks(withMediaType: .audio).first,
               let mTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
                let avail = CMTime(seconds: min(sAsset.duration.seconds, total.seconds), preferredTimescale: 600)
                do {
                    try mTrack.insertTimeRange(CMTimeRange(start: .zero, duration: avail), of: sTrack, at: .zero)
                    soundtrackTrack = mTrack
                } catch {
                    StoryCreativeRefinement.lastMusicNote += " | soundtrack insert FAILED: \(error)"
                }
            } else {
                StoryCreativeRefinement.lastMusicNote += " | preloaded soundtrack had NO audio track (file bad?)"
            }
        }
        // segmentRanges keeps the old (segment, timeline-range) shape the audio mix + duration-verify expect.
        let segmentRanges = placed.map { (segment: $0.segment, range: $0.range) }
        return BuiltComposition(composition: composition, videoComposition: videoComposition,
                                segmentRanges: segmentRanges, soundtrackTrack: soundtrackTrack,
                                totalDuration: total)
    }

    /// Aspect-FIT (contain) transform mapping a source track fully inside the render rect — NO cropping.
    /// The whole source frame is scaled to fit within the output and centered; any area the source doesn't
    /// cover shows the composition background (black). This replaced the earlier aspect-FILL center-crop,
    /// which cut off the sides/top of off-aspect footage (e.g. a person edged out of a 9:16 frame).
    static func aspectFitTransform(natural: CGSize, preferred: CGAffineTransform, render: CGSize) -> CGAffineTransform {
        // apply the source's preferred (orientation) transform first
        let oriented = natural.applying(preferred)
        let w = abs(oriented.width == 0 ? natural.width : oriented.width)
        let h = abs(oriented.height == 0 ? natural.height : oriented.height)
        let scale = min(render.width / w, render.height / h)   // FIT: smallest scale that fits inside
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
        let ramp = CMTime(seconds: 0.08, preferredTimescale: 600)   // short deterministic click-guard fade

        // Capture audio lives on up to TWO tracks (ping-pong, index = segment order % 2). A crossfade overlaps
        // segment i's track with segment i+1's; we ramp each segment's gain in/out across its OWN output range,
        // and the ramp-out of the outgoing segment coincides with the ramp-in of the incoming one over the
        // overlap window — so the sum never spikes above the two segments' target gains.
        let captureTracks = composition.tracks(withMediaType: .audio).prefix(soundtrackTrack == nil ? 2 : 2)
        let captureArr = Array(captureTracks)
        for (idx, track) in captureArr.enumerated() where track != soundtrackTrack {
            let p = AVMutableAudioMixInputParameters(track: track)
            // segments placed on THIS track (every other segment)
            for (i, sr) in segmentRanges.enumerated() where i % 2 == idx {
                let g = NativeAudioPolicy.captureGain(nativeAudio: sr.segment.nativeAudio)
                let r = sr.range
                let inEnd = CMTimeAdd(r.start, ramp)
                let outStart = CMTimeSubtract(CMTimeAdd(r.start, r.duration), ramp)
                let outEnd = CMTimeAdd(r.start, r.duration)
                p.setVolumeRamp(fromStartVolume: 0.0, toEndVolume: g, timeRange: CMTimeRange(start: r.start, end: inEnd))
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
        // Pre-load the soundtrack's tracks ASYNCHRONOUSLY (not a blocking semaphore inside the sync builder —
        // that risked the AVFoundation 'Result accumulator timeout' stall). After this await, the synchronous
        // tracks() read in buildComposition returns the real audio track for a freshly-downloaded temp MP3.
        var inputs = inputs
        if let sURL = inputs.soundtrackURL, FileManager.default.fileExists(atPath: sURL.path) {
            let sAsset = AVURLAsset(url: sURL)
            _ = try? await sAsset.loadTracks(withMediaType: .audio)
            _ = try? await sAsset.load(.duration)
            inputs.preloadedSoundtrackAsset = sAsset
            let sz = (try? FileManager.default.attributesOfItem(atPath: sURL.path)[.size] as? Int) ?? nil
            StoryCreativeRefinement.lastMusicNote =
                "soundtrack preloaded: \(sURL.lastPathComponent) bytes=\(sz.map(String.init) ?? "?") dur=\(String(format: "%.1f", sAsset.duration.seconds))s role=\(inputs.soundtrackRole) priority=\(inputs.nativeAudioPriority)"
            MediaEngineV1.beacon("preload bytes=\(sz.map(String.init) ?? "nil") dur=\(String(format: "%.1f", sAsset.duration.seconds)) ntracks=\(sAsset.tracks(withMediaType: .audio).count)")
        } else {
            StoryCreativeRefinement.lastMusicNote = "NO soundtrack URL at render (pendingMusic path produced none)"
            MediaEngineV1.beacon("no-soundtrack-url")
        }
        let built: BuiltComposition
        do {
            built = try buildComposition(inputs)
        } catch {
            MediaEngineV1.beacon("buildComposition THREW: \(String(describing: error).prefix(120))")
            throw error
        }
        MediaEngineV1.beacon("built soundtrackTrack=\(built.soundtrackTrack != nil ? "YES" : "NO") note=\(StoryCreativeRefinement.lastMusicNote.suffix(80))")
        // Append the per-segment native_audio histogram + role/priority: these three numbers decide whether
        // native audio is AUDIBLE in the final mix (keep=1.0, duck=0.25, mute=0.0; soundtrack full under
        // duck/mute when role=continuous). Surfaced on-screen so a silent-native render names its own cause.
        var naCounts: [String: Int] = [:]
        for s in inputs.plan.segments { naCounts[s.nativeAudio, default: 0] += 1 }
        let naHist = naCounts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        StoryCreativeRefinement.lastMusicNote +=
            " | native_audio[\(naHist)] role=\(inputs.soundtrackRole) priority=\(inputs.nativeAudioPriority)"
        MediaEngineV1.beacon("audio-mix native_audio[\(naHist)] role=\(inputs.soundtrackRole) priority=\(inputs.nativeAudioPriority)")
        let mix = buildAudioMix(inputs, composition: built.composition,
                                segmentRanges: built.segmentRanges, soundtrackTrack: built.soundtrackTrack)

        guard let export = AVAssetExportSession(asset: built.composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            MediaEngineV1.beacon("export SESSION NIL (could not create) segs=\(built.segmentRanges.count) music=\(built.soundtrackTrack != nil) size=\(Int(built.videoComposition.renderSize.width))x\(Int(built.videoComposition.renderSize.height))")
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
            MediaEngineV1.beacon("export CANCELLED (shouldCancel fired)")
            throw MediaEngineError.exportFailed("cancelled")
        default:
            cleanupPartial()
            let err = export.error
            MediaEngineV1.beacon("export FAILED status=\(export.status.rawValue) err=\(err.map { String(describing: $0) } ?? "nil") segs=\(built.segmentRanges.count) music=\(built.soundtrackTrack != nil)")
            throw MediaEngineError.exportFailed(err?.localizedDescription ?? "export failed")
        }
    }
}
