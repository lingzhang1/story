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

/// Pure, deterministic plan for filling a timeline of `totalSeconds` with a soundtrack of `trackSeconds`
/// by LOOPING it, using a short `seamSeconds` crossfade where one loop meets the next. No AVFoundation here
/// so it is unit-testable: it answers "how many loop iterations, each how long, starting where, and where are
/// the seams" — exactly what buildComposition then lays onto two alternating audio tracks. The video length is
/// authoritative; music is never capped to the track and the timeline is never shortened to the music.
struct SoundtrackLoopPlan {
    struct Iteration { let trackIndex: Int; let start: Double; let length: Double }
    let iterations: [Iteration]
    let seams: [Double]           // timeline times where loop N's tail meets loop N+1's head
    var loopCount: Int { iterations.count }

    /// Returns nil when the asset is unusable (non-finite/too-short track, or no timeline to fill) — the caller
    /// then renders native-audio-only rather than looping a blip forever.
    static func compute(trackSeconds: Double, totalSeconds: Double, seamSeconds: Double = 0.4) -> SoundtrackLoopPlan? {
        guard trackSeconds.isFinite, trackSeconds >= 0.5, totalSeconds > 0 else { return nil }
        var iters: [Iteration] = []
        var seams: [Double] = []
        var cursor = 0.0
        var idx = 0
        while cursor < totalSeconds - 1e-6 {
            let remaining = totalSeconds - cursor
            let thisLen = min(trackSeconds, remaining)
            if thisLen < 0.05 { break }
            iters.append(Iteration(trackIndex: idx % 2, start: cursor, length: thisLen))
            let loopEnd = cursor + thisLen
            if loopEnd < totalSeconds - 1e-6 && thisLen > seamSeconds {
                seams.append(loopEnd)
                cursor = loopEnd - seamSeconds        // next loop head overlaps this tail -> seam crossfade
            } else {
                cursor = loopEnd
            }
            idx += 1
            if iters.count > 10_000 { break }         // runaway guard
        }
        return iters.isEmpty ? nil : SoundtrackLoopPlan(iterations: iters, seams: seams)
    }
}

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
    let soundtrackTrackB: AVMutableCompositionTrack?   // alternate loop track for seam crossfades (nil if no loop/music)
    let loopSeams: [CMTime]                            // timeline times where loop N's tail meets loop N+1's head
    let loopCount: Int                                 // number of soundtrack iterations laid down (0 = none)
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
            // CLAMP the plan's source range to the clip's REAL video-track range. A new-version/revise plan can
            // estimate a sourceEnd past the clip's actual duration; inserting such a range inserts LESS media
            // than requested (or nothing), leaving the composition track short while `placed` still claims the
            // full output slice -> AVAssetExportSession fails with -11841 "The video could not be composed"
            // ("Operation Stopped"). Intersecting with the track's own timeRange guarantees the insert covers
            // exactly what we place. If the intersection is empty (source range entirely past the clip), fall
            // back to the clip's own tail of the requested length; if the clip has no usable video at all, fail
            // honestly rather than build an uncoverable composition.
            let trackRange = srcVideo.timeRange                                   // real available media range
            let requested = CMTimeRange(start: start, end: end)
            var srcRange = requested.intersection(trackRange)
            if srcRange.duration.seconds <= 0.03 {                                // empty / sub-frame overlap
                let want = max(0.1, (segment.sourceEndSeconds ?? segment.outputDurationSeconds)
                               - (segment.sourceStartSeconds ?? 0))
                let dur = CMTime(seconds: min(want, max(0.1, trackRange.duration.seconds)), preferredTimescale: 600)
                let fallbackStart = CMTimeMaximum(.zero, CMTimeSubtract(CMTimeRangeGetEnd(trackRange), dur))
                srcRange = CMTimeRange(start: fallbackStart, duration: dur)
                    .intersection(trackRange)
            }
            guard srcRange.duration.seconds > 0.03 else {
                throw MediaEngineError.exportFailed(
                    "segment source range empty for \(segment.assetId) (clip has no usable video)")
            }

            // Overlap: pull this segment's start back by xf so it begins while the previous is still visible.
            let segStart = i == 0 ? cursor
                : CMTimeSubtract(cursor, CMTime(seconds: xf, preferredTimescale: 600))

            try track.insertTimeRange(srcRange, of: srcVideo, at: segStart)
            var audioInsertedDur: CMTime? = nil
            if let srcAudio = asset.tracks(withMediaType: .audio).first, let at = aTrack {
                // Audio clamped to the SAME range intersected with the audio track (audio may be shorter).
                let aRange = srcRange.intersection(srcAudio.timeRange)
                if aRange.duration.seconds > 0.0 {
                    try? at.insertTimeRange(aRange, of: srcAudio, at: segStart)
                    audioInsertedDur = aRange.duration
                }
            }
            // Map the ACTUALLY-INSERTED (clamped) range onto the planned output duration so the on-track
            // content length equals exactly what `placed` claims — coverage is then exact by construction even
            // when the source range was clamped shorter than requested, OR a speed was applied. (A clamp +
            // no-speed path previously left the track shorter than its slice -> -11841.) outputDurationSeconds
            // already reflects the planner's speed intent, so mapping inserted->outDur subsumes the speed scale.
            let outDur = CMTime(seconds: max(0.1, segment.outputDurationSeconds), preferredTimescale: 600)
            if CMTimeCompare(srcRange.duration, outDur) != 0 {
                track.scaleTimeRange(CMTimeRange(start: segStart, duration: srcRange.duration), toDuration: outDur)
            }
            // Scale audio on ITS OWN inserted range (audio may be shorter than video) so it stays in sync.
            if let aDur = audioInsertedDur, let at = aTrack, CMTimeCompare(aDur, outDur) != 0 {
                at.scaleTimeRange(CMTimeRange(start: segStart, duration: aDur), toDuration: outDur)
            }

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
            // Live if the segment's placed range contains the slice, with a small epsilon so sub-frame
            // boundary rounding (600-timescale starts vs summed durations across many segments) does not
            // falsely drop a segment and leave an uncovered slice (which makes AVAssetExportSession stop).
            let eps = CMTime(value: 1, timescale: 600)   // ~1.7ms tolerance
            return placed.filter { p in
                let pEnd = CMTimeAdd(p.range.start, p.range.duration)
                return CMTimeCompare(p.range.start, CMTimeAdd(slice.start, eps)) <= 0
                    && CMTimeCompare(pEnd, CMTimeSubtract(slice.end, eps)) >= 0
            }
        }

        /// The placed segment that overlaps `slice` the MOST — the guaranteed non-empty fallback so a slice is
        /// never left uncovered (any gap => AVAssetExportSession "Operation Stopped" and no output file).
        func bestCovering(_ slice: CMTimeRange) -> (segment: EditSegmentV2, track: Int, range: CMTimeRange)? {
            placed.map { p -> (p: (segment: EditSegmentV2, track: Int, range: CMTimeRange), ov: Double) in
                let pEnd = CMTimeAdd(p.range.start, p.range.duration)
                let lo = CMTimeMaximum(p.range.start, slice.start)
                let hi = CMTimeMinimum(pEnd, slice.end)
                return (p, max(0, hi.seconds - lo.seconds))
            }.max { $0.ov < $1.ov }?.p
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
            // A slice MUST emit an instruction — an uncovered slice makes AVAssetExportSession stop with no
            // output. If no segment strictly contains this (thin, boundary-rounding) slice, fall back to the
            // single segment that overlaps it most, drawn solo. Coverage is thus total by construction.
            if live.isEmpty {
                guard let fb = bestCovering(slice) else { continue }   // truly nothing (should never happen)
                let inst = AVMutableVideoCompositionInstruction()
                inst.timeRange = slice
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vTracks[fb.track])
                li.setTransform(try transform(for: fb.segment), at: slice.start)
                inst.layerInstructions = [li]
                instructions.append(inst)
                continue
            }

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
        //
        // LOOPING FILL: a soundtrack shorter than the video must REPEAT to cover the whole timeline, not stop
        // at its natural length (which left the tail of a 200s+ Story silent — the "half the video has no
        // music" bug). We lay the track down repeatedly onto TWO alternating soundtrack tracks (same ping-pong
        // arrangement the video uses) so each loop's tail can CROSSFADE into the next loop's head — the mix
        // ramps the seam, avoiding a click/abrupt restart. A short tail is clamped; the whole fill is bounded
        // to `total`. The user's Story duration is preserved; music is NEVER capped to the track length and
        // the video is never shortened to the music.
        var soundtrackTrack: AVMutableCompositionTrack? = nil        // primary (kept for back-compat API)
        var soundtrackTrackB: AVMutableCompositionTrack? = nil       // alternate loop track for seam crossfade
        var loopSeams: [CMTime] = []                                 // timeline times where loop N meets N+1
        var loopCount = 0
        let seamCrossfade = CMTime(seconds: 0.4, preferredTimescale: 600)  // short seam blend
        if let sAsset = inputs.preloadedSoundtrackAsset {
            let trackDur = sAsset.duration.seconds
            // SAFETY + loop plan: a very short, empty, zero/NaN or trackless asset must not loop forever or
            // divide by zero — SoundtrackLoopPlan.compute returns nil, and we fall back to no soundtrack
            // (native audio still carries the Story).
            if let sTrack = sAsset.tracks(withMediaType: .audio).first,
               let plan = SoundtrackLoopPlan.compute(trackSeconds: trackDur, totalSeconds: total.seconds,
                                                     seamSeconds: seamCrossfade.seconds) {
                guard let mTrackA = composition.addMutableTrack(withMediaType: .audio,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid),
                      let mTrackB = composition.addMutableTrack(withMediaType: .audio,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    StoryCreativeRefinement.lastMusicNote += " | could not add soundtrack tracks"
                    let segmentRanges = placed.map { (segment: $0.segment, range: $0.range) }
                    return BuiltComposition(composition: composition, videoComposition: videoComposition,
                                            segmentRanges: segmentRanges, soundtrackTrack: nil,
                                            soundtrackTrackB: nil, loopSeams: [], loopCount: 0,
                                            totalDuration: total)
                }
                let loopTracks = [mTrackA, mTrackB]
                var inserted = false
                for it in plan.iterations {
                    let dst = loopTracks[it.trackIndex]
                    let len = CMTime(seconds: it.length, preferredTimescale: 600)
                    let at = CMTime(seconds: it.start, preferredTimescale: 600)
                    do {
                        try dst.insertTimeRange(CMTimeRange(start: .zero, duration: len), of: sTrack, at: at)
                        inserted = true
                        loopCount += 1
                    } catch {
                        StoryCreativeRefinement.lastMusicNote += " | soundtrack loop insert FAILED: \(error)"
                        break
                    }
                }
                loopSeams = plan.seams.map { CMTime(seconds: $0, preferredTimescale: 600) }
                if inserted {
                    soundtrackTrack = mTrackA
                    soundtrackTrackB = mTrackB
                    StoryCreativeRefinement.lastMusicNote += " | soundtrack looped x\(loopCount) seams=\(loopSeams.count) trackDur=\(String(format: "%.1f", trackDur))s total=\(String(format: "%.1f", total.seconds))s"
                } else {
                    composition.removeTrack(mTrackA); composition.removeTrack(mTrackB)
                    loopSeams = []
                }
            } else {
                StoryCreativeRefinement.lastMusicNote += " | soundtrack unusable (no track / dur=\(String(format: "%.2f", trackDur))s) — native audio only"
            }
        }
        // segmentRanges keeps the old (segment, timeline-range) shape the audio mix + duration-verify expect.
        let segmentRanges = placed.map { (segment: $0.segment, range: $0.range) }
        return BuiltComposition(composition: composition, videoComposition: videoComposition,
                                segmentRanges: segmentRanges, soundtrackTrack: soundtrackTrack,
                                soundtrackTrackB: soundtrackTrackB, loopSeams: loopSeams,
                                loopCount: loopCount, totalDuration: total)
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
                       soundtrackTrack: AVMutableCompositionTrack?,
                       soundtrackTrackB: AVMutableCompositionTrack? = nil,
                       loopSeams: [CMTime] = [],
                       totalDuration: CMTime = .zero) -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        var params: [AVMutableAudioMixInputParameters] = []
        let ramp = CMTime(seconds: 0.08, preferredTimescale: 600)   // short deterministic click-guard fade

        let soundtrackTracks: [AVMutableCompositionTrack] = [soundtrackTrack, soundtrackTrackB].compactMap { $0 }
        // Capture audio lives on up to TWO tracks (ping-pong, index = segment order % 2). A crossfade overlaps
        // segment i's track with segment i+1's; we ramp each segment's gain in/out across its OWN output range,
        // and the ramp-out of the outgoing segment coincides with the ramp-in of the incoming one over the
        // overlap window — so the sum never spikes above the two segments' target gains.
        // Capture tracks are the audio tracks that are NOT soundtrack loop tracks.
        let captureArr = composition.tracks(withMediaType: .audio).filter { t in !soundtrackTracks.contains(t) }
        for (idx, track) in captureArr.enumerated() {
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

        // SOUNDTRACK loop tracks: each gained per segment by audio_strategy under kept native audio, PLUS
        // seam crossfades at loop joins and a final fade-out at the video end. Loop N lives on track (N%2);
        // at each seam the outgoing loop ramps 1->0 and the incoming loop ramps 0->1 over the seam window,
        // so there is no click/abrupt restart and NO accidental silence between loops.
        let seamXf = CMTime(seconds: 0.4, preferredTimescale: 600)
        let finalFade = CMTime(seconds: 1.0, preferredTimescale: 600)
        // base gain curve for the soundtrack across the timeline, sampled at each segment start
        func baseGain(at t: CMTime) -> Float {
            // find the segment live at t; default to the first segment's strategy
            let sr = segmentRanges.last(where: { CMTimeCompare($0.range.start, t) <= 0 }) ?? segmentRanges.first
            guard let s = sr?.segment else { return 0.8 }
            return NativeAudioPolicy.soundtrackGainUnder(nativeAudio: s.nativeAudio,
                                                         role: inputs.soundtrackRole, priority: inputs.nativeAudioPriority)
        }
        for (trackIdx, music) in soundtrackTracks.enumerated() {
            let p = AVMutableAudioMixInputParameters(track: music)
            // per-segment strategy gain
            for sr in segmentRanges {
                p.setVolume(baseGain(at: sr.range.start), at: sr.range.start)
            }
            // seam crossfades: a seam at time `s` joins the loop ENDING at s (track (loopIdx)%2) with the loop
            // STARTING at s - seamXf (track (loopIdx+1)%2). We ramp this track at every seam where it is the
            // outgoing or incoming side.
            for (loopIdx, seam) in loopSeams.enumerated() {
                let outgoingTrack = loopIdx % 2
                let incomingTrack = (loopIdx + 1) % 2
                let g = baseGain(at: seam)
                if trackIdx == outgoingTrack {
                    // ramp down into the seam
                    p.setVolumeRamp(fromStartVolume: g, toEndVolume: 0.0,
                                    timeRange: CMTimeRange(start: CMTimeSubtract(seam, seamXf), end: seam))
                }
                if trackIdx == incomingTrack {
                    // ramp up from the seam start (which began seamXf before `seam`)
                    let inStart = CMTimeSubtract(seam, seamXf)
                    p.setVolumeRamp(fromStartVolume: 0.0, toEndVolume: g,
                                    timeRange: CMTimeRange(start: inStart, end: seam))
                }
            }
            // final fade-out at the very end (whichever track carries the last loop), avoiding a hard stop.
            if CMTimeCompare(totalDuration, finalFade) > 0 {
                let fadeStart = CMTimeSubtract(totalDuration, finalFade)
                p.setVolumeRamp(fromStartVolume: baseGain(at: fadeStart), toEndVolume: 0.0,
                                timeRange: CMTimeRange(start: fadeStart, end: totalDuration))
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
        MediaEngineV1.beacon("built soundtrackTrack=\(built.soundtrackTrack != nil ? "YES" : "NO") loops=\(built.loopCount) seams=\(built.loopSeams.count) total=\(String(format: "%.1f", built.totalDuration.seconds))s note=\(StoryCreativeRefinement.lastMusicNote.suffix(80))")
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
                                segmentRanges: built.segmentRanges, soundtrackTrack: built.soundtrackTrack,
                                soundtrackTrackB: built.soundtrackTrackB, loopSeams: built.loopSeams,
                                totalDuration: built.totalDuration)

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
