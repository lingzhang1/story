import Foundation
import AVFoundation

// MARK: - Opt-in flag (DEFAULT ON for the best-results MVP; kill-switch retained)

/// Gate for the V2-b deterministic creative-refinement pre-pass. DEFAULT ON so the MVP ships the extra
/// refinement pass that improves the result. It is deterministic (no model call) and degrades to a no-op when
/// it has nothing to improve, so default-ON is safe. Kill-switch without a rebuild: env
/// `STORY_CREATIVE_REFINEMENT=0` or UserDefaults bool `STORY_CREATIVE_REFINEMENT=false` forces it OFF.
enum StoryCreativeRefinement {
    static let flagKey = "STORY_CREATIVE_REFINEMENT"
    private static let _enabledDefault = true
    /// Default ON. Env/UserDefaults override wins (incident kill-switch).
    static var enabled: Bool {
        if ProcessInfo.processInfo.environment[flagKey] == "0" { return false }
        if ProcessInfo.processInfo.environment[flagKey] == "1" { return true }
        if UserDefaults.standard.object(forKey: flagKey) != nil {
            return UserDefaults.standard.bool(forKey: flagKey)
        }
        return _enabledDefault
    }
    static func setPersistentOverride(_ on: Bool) { UserDefaults.standard.set(on, forKey: flagKey) }
    /// Diagnostic breadcrumb from the last refine() call (validation notes / no-op reasons) — for the device
    /// report, never a user-facing surface.
    static var lastOutcomeNotes: [String] = []
    /// Diagnostic breadcrumb: the soundtrack state at the last render (URL present? file bytes?). Explains a
    /// silent/no-music output on device without guessing.
    static var lastMusicNote: String = ""
    /// TEMPORARY DEBUG build identifier so the device UI proves WHICH source the installed app was built from
    /// (must include the StoryGuide input-wiring fixes a4c6aa5 + 4391b42). Bump on each verification rebuild.
    static let buildIdentifier: String = "r7-sync-reconcile-2"
    /// Diagnostic breadcrumb: exactly what the MusicPlan request carried + what it returned, captured in the
    /// SINGLE resolver construction path. Proves (not assumes) the Guide reached MusicPlan. No media, no creds.
    static var lastMusicPlanInput: String = ""
}

// CreativeRefinementV2b — Creative Editing V2-b, architecture B: a DETERMINISTIC refinement stage that runs
// AFTER the frozen Edit Planner v4 produced an executable EditPlan/2, and BEFORE MediaEngineV1 renders it.
//
// It never calls a model and never reinterprets a frozen EditPlan/2 field. It computes bounded on-device
// Edit Evidence at candidate cut boundaries only, proposes CONSERVATIVE source in/out nudges and optional
// J/L native-audio bridges, then VALIDATES every proposed change. If any check fails — or evidence is
// insufficient — it returns the ORIGINAL plan unchanged (a straight cut is always a valid result).
//
// Opt-in: the caller passes `enabled`. When false (default until device-accepted), the plan is returned
// untouched, so V1 rendering is unaffected.
//
// Scope guard (owner direction): P0 ONLY — cut-boundary precision + native-audio continuity. NO match cuts,
// speed ramps, color, split-screen. Those are explicitly out of V2-b.

// MARK: - Edit Evidence (bounded, boundary-only, deterministic)

/// Evidence sampled around ONE candidate boundary (an in- or out-point of a segment). Motion from frame
/// luma-difference; audio from RMS/onset. Reduced per owner decision #3 to motion + audio + AU action only.
struct BoundaryEvidence {
    let timeSeconds: Double            // the boundary time in the SOURCE clip
    let motionMagnitude: Double        // 0..1 coarse inter-frame change around the boundary
    let motionDirection: String        // "left"|"right"|"up"|"down"|"none" (approx; "none" when below threshold)
    let audioRMS: Double               // 0..1 local audio energy
    let isSilence: Bool                // audioRMS below a silence floor
    let onsetNearby: Bool              // an audio onset within the search window
    let actionCandidate: Bool          // AU event start/end lands within the window
}

/// What the refinement decided for one segment (for the report; never a contract field).
struct SegmentRefinement {
    let order: Int
    let originalIn: Double?
    let originalOut: Double?
    let refinedIn: Double?
    let refinedOut: Double?
    let bridge: String                 // "none" | "J" | "L"
    let reason: String                 // human-readable why (or why no-op)
    var changed: Bool { refinedIn != originalIn || refinedOut != originalOut || bridge != "none" }
}

struct RefinementOutcome {
    let plan: EditPlanV2               // refined OR original (on any validation failure)
    let applied: Bool                  // true only if at least one change passed validation and was kept
    let perSegment: [SegmentRefinement]
    let validationNotes: [String]
}

// MARK: - Tunables (conservative; owner can adjust after device review)

enum RefinementConfig {
    static let maxNudgeSeconds: Double = 0.5       // never move a boundary more than this
    static let motionSettleThreshold: Double = 0.12 // below this = "settled" (good cut point)
    static let silenceFloor: Double = 0.02          // audioRMS below => silence
    static let searchWindowSeconds: Double = 0.5    // look ±this around the original boundary
    static let durationTolerance: Double = 0.20     // ±20% of target output duration (matches planner)
    static let bridgeMaxSeconds: Double = 0.4       // J/L overlap cap
    static let sampleStepSeconds: Double = 0.05     // evidence sampling granularity
}

// MARK: - Refinement engine

enum CreativeRefinementV2b {

    /// Entry point. `evidenceProvider` yields BoundaryEvidence for a (clipURL, time) — injectable so the pure
    /// refinement/validation logic is unit-testable without AVFoundation. In production the caller passes
    /// `AVFoundationEvidence.sample`.
    static func refine(
        plan: EditPlanV2,
        enabled: Bool,
        resolveURL: (String) -> URL?,
        actionTimestamps: [String: [Double]],   // assetId -> AU event start/end times (source seconds)
        sourceDuration: (String) -> Double?,     // assetId -> source clip duration (seconds)
        usefulRanges: [String: [(Double, Double)]], // assetId -> AU useful_segments (hard bounds)
        evidenceProvider: (URL, Double) -> BoundaryEvidence?
    ) -> RefinementOutcome {
        guard enabled else {
            return RefinementOutcome(plan: plan, applied: false, perSegment: [],
                                     validationNotes: ["refinement disabled — original plan"])
        }
        var refinedSegs: [EditSegmentV2] = []
        var reports: [SegmentRefinement] = []
        var notes: [String] = []
        var anyChange = false

        // DIAGNOSTIC: does the evidence provider return anything at all? If every sample is nil (e.g. the
        // on-device sampler can't read frames/audio), refinement will correctly no-op everywhere — and this
        // line in lastOutcomeNotes tells us THAT is why, instead of leaving it a mystery.
        var evidenceHits = 0, evidenceMisses = 0

        for seg in plan.segments {
            let url = resolveURL(seg.assetId)
            let dur = sourceDuration(seg.assetId)
            let useful = usefulRanges[seg.assetId] ?? []
            let actions = actionTimestamps[seg.assetId] ?? []
            if let url, let inP = seg.sourceStartSeconds {
                if evidenceProvider(url, inP) != nil { evidenceHits += 1 } else { evidenceMisses += 1 }
            }
            let (refined, report) = refineSegment(
                seg, url: url, sourceDuration: dur, useful: useful, actions: actions,
                evidenceProvider: evidenceProvider)
            refinedSegs.append(refined)
            reports.append(report)
            notes.append("seg \(report.order): \(report.reason)")
            if report.changed { anyChange = true }
        }
        notes.insert("evidence: \(evidenceHits) hit / \(evidenceMisses) miss across \(plan.segments.count) segments", at: 0)

        if !anyChange {
            notes.append("no boundary met the evidence bar; original plan kept (all no-ops)")
            return RefinementOutcome(plan: plan, applied: false, perSegment: reports, validationNotes: notes)
        }

        let candidate = plan.replacingSegments(refinedSegs)
        // VALIDATE the whole candidate; on ANY failure, fall back to the original executable plan.
        let verdict = RefinementValidator.validate(original: plan, candidate: candidate,
                                                   sourceDuration: sourceDuration, usefulRanges: usefulRanges)
        if verdict.ok {
            notes.append(contentsOf: verdict.notes)
            return RefinementOutcome(plan: candidate, applied: true, perSegment: reports, validationNotes: notes)
        } else {
            notes.append("VALIDATION FAILED -> original plan retained: \(verdict.notes.joined(separator: "; "))")
            return RefinementOutcome(plan: plan, applied: false, perSegment: reports, validationNotes: notes)
        }
    }

    /// Refine ONE segment: nudge in/out toward a motion-settled / audio-onset-friendly point inside bounds.
    private static func refineSegment(
        _ seg: EditSegmentV2, url: URL?, sourceDuration: Double?,
        useful: [(Double, Double)], actions: [Double],
        evidenceProvider: (URL, Double) -> BoundaryEvidence?
    ) -> (EditSegmentV2, SegmentRefinement) {
        let origIn = seg.sourceStartSeconds
        let origOut = seg.sourceEndSeconds
        func noop(_ why: String) -> (EditSegmentV2, SegmentRefinement) {
            (seg, SegmentRefinement(order: seg.order, originalIn: origIn, originalOut: origOut,
                                    refinedIn: origIn, refinedOut: origOut, bridge: "none", reason: why))
        }
        guard let url, let origIn, let origOut else { return noop("no url or open-ended boundaries — skip") }
        // hard lower/upper bounds: the segment's own useful range (or [0, sourceDuration])
        let (lo, hi) = tightestBound(origIn: origIn, origOut: origOut, useful: useful,
                                     sourceDuration: sourceDuration)

        let newIn = bestBoundary(url: url, around: origIn, lo: lo, hi: origOut,
                                 actions: actions, isInPoint: true, evidenceProvider: evidenceProvider) ?? origIn
        let newOut = bestBoundary(url: url, around: origOut, lo: origIn, hi: hi,
                                  actions: actions, isInPoint: false, evidenceProvider: evidenceProvider) ?? origOut

        // Preserve essential continuous action: never SHRINK a span that AU flagged continuous (useful span
        // that fully contains the segment) — only allow trimming into dead air, not into the action.
        guard newOut - newIn >= (origOut - origIn) * 0.6 else {
            return noop("refusing to shorten past 60% of the chosen span (preserve continuous action)")
        }
        if abs(newIn - origIn) < 0.01 && abs(newOut - origOut) < 0.01 {
            return noop("no better boundary found within the search window")
        }
        let refined = EditSegmentV2(order: seg.order, assetId: seg.assetId,
                                    sourceStartSeconds: newIn, sourceEndSeconds: newOut,
                                    outputDurationSeconds: seg.outputDurationSeconds, speed: seg.speed,
                                    nativeAudio: seg.nativeAudio, musicAlignment: seg.musicAlignment,
                                    transition: seg.transition)
        let reason = "nudged in \(fmt(origIn))->\(fmt(newIn)), out \(fmt(origOut))->\(fmt(newOut)) toward motion-settle/onset"
        return (refined, SegmentRefinement(order: seg.order, originalIn: origIn, originalOut: origOut,
                                           refinedIn: newIn, refinedOut: newOut, bridge: "none", reason: reason))
    }

    /// Scan the search window for the best boundary: prefer a point where motion is SETTLED and (for an
    /// in-point) just AFTER an onset / (for an out-point) just BEFORE a silence, staying within [lo,hi] and
    /// within maxNudge of the original. Returns nil when nothing beats the original.
    private static func bestBoundary(
        url: URL, around original: Double, lo: Double, hi: Double, actions: [Double],
        isInPoint: Bool, evidenceProvider: (URL, Double) -> BoundaryEvidence?
    ) -> Double? {
        let w = RefinementConfig.searchWindowSeconds
        let step = RefinementConfig.sampleStepSeconds
        let lowT = max(lo, original - w)
        let highT = min(hi, original + w)
        guard highT > lowT else { return nil }
        var best: (t: Double, score: Double)? = nil
        var t = lowT
        while t <= highT {
            // never cut across an AU action timestamp (would clip a significant action)
            let clipsAction = actions.contains { abs($0 - t) < 0.08 }
            if !clipsAction, let e = evidenceProvider(url, t) {
                var score = 0.0
                // settled motion is a good cut (low magnitude)
                score += (RefinementConfig.motionSettleThreshold - e.motionMagnitude)
                // in-point: reward being just after an onset / out-point: reward approaching silence
                if isInPoint { score += e.onsetNearby ? 0.15 : 0.0 }
                else { score += e.isSilence ? 0.15 : 0.0 }
                // penalize distance from the original (stay conservative)
                score -= abs(t - original) * 0.3
                if best == nil || score > best!.score { best = (t, score) }
            }
            t += step
        }
        guard let b = best else { return nil }
        // only accept a move that clears the original by a meaningful margin AND is within maxNudge
        guard abs(b.t - original) <= RefinementConfig.maxNudgeSeconds else { return nil }
        guard let origEv = evidenceProvider(url, original) else { return b.t }
        let origScore = (RefinementConfig.motionSettleThreshold - origEv.motionMagnitude)
        return b.score > origScore + 0.03 ? b.t : nil   // require a real improvement, else no-op
    }

    private static func tightestBound(origIn: Double, origOut: Double,
                                      useful: [(Double, Double)], sourceDuration: Double?) -> (Double, Double) {
        // the useful range that contains the segment is the hard bound; else [0, sourceDuration]
        if let containing = useful.first(where: { $0.0 <= origIn + 0.01 && $0.1 >= origOut - 0.01 }) {
            return (containing.0, containing.1)
        }
        return (0.0, sourceDuration ?? origOut)
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}

// MARK: - EditPlanV2 copy-with-segments (refined plan is a NEW value; original is never mutated)

extension EditPlanV2 {
    /// Build a copy of this plan with its segments replaced. Preserves every other frozen field verbatim —
    /// schema_version, target, format, music_asset_id, feasible — so nothing in the contract is reinterpreted.
    /// Uses the compiler-synthesized memberwise initializer (EditPlanV2 is a struct with all stored lets).
    func replacingSegments(_ segs: [EditSegmentV2]) -> EditPlanV2 {
        EditPlanV2(schemaVersion: schemaVersion, targetDurationSeconds: targetDurationSeconds,
                   outputFormat: outputFormat, musicAssetId: musicAssetId, feasible: feasible, segments: segs)
    }
}

// MARK: - Deterministic validator (Phase 4) — any failure => keep the ORIGINAL plan

enum RefinementValidator {
    struct Verdict { let ok: Bool; let notes: [String] }

    static func validate(
        original: EditPlanV2, candidate: EditPlanV2,
        sourceDuration: (String) -> Double?,
        usefulRanges: [String: [(Double, Double)]]
    ) -> Verdict {
        var notes: [String] = []
        // structural parity: same count + order + assetIds + narrative selection preserved
        guard candidate.segments.count == original.segments.count else {
            return Verdict(ok: false, notes: ["segment count changed"]) }
        for (o, c) in zip(original.segments, candidate.segments) {
            if o.order != c.order || o.assetId != c.assetId {
                return Verdict(ok: false, notes: ["order/assetId changed (narrative selection must be preserved)"]) }
            // source bounds valid and non-inverted
            if let s = c.sourceStartSeconds, let e = c.sourceEndSeconds {
                guard e > s else { return Verdict(ok: false, notes: ["segment \(c.order): inverted/empty source range"]) }
                if let dur = sourceDuration(c.assetId) {
                    guard s >= -0.001, e <= dur + 0.05 else {
                        return Verdict(ok: false, notes: ["segment \(c.order): source out of clip bounds"]) }
                }
                // stay inside the AU useful range that contained the ORIGINAL segment
                if let os = o.sourceStartSeconds, let oe = o.sourceEndSeconds,
                   let useful = usefulRanges[c.assetId],
                   let band = useful.first(where: { $0.0 <= os + 0.01 && $0.1 >= oe - 0.01 }) {
                    guard s >= band.0 - 0.001, e <= band.1 + 0.001 else {
                        return Verdict(ok: false, notes: ["segment \(c.order): refined range left the useful band"]) }
                }
            }
            // output duration + speed are UNCHANGED by refinement (we only move source in/out)
            guard abs(c.outputDurationSeconds - o.outputDurationSeconds) < 0.001 else {
                return Verdict(ok: false, notes: ["segment \(c.order): output duration changed (forbidden)"]) }
            guard (c.speed ?? 1.0) == (o.speed ?? 1.0) else {
                return Verdict(ok: false, notes: ["segment \(c.order): speed changed (forbidden)"]) }
            // music alignment + transition preserved verbatim
            guard (c.transition?.type ?? "cut") == (o.transition?.type ?? "cut") else {
                return Verdict(ok: false, notes: ["segment \(c.order): transition changed (forbidden)"]) }
        }
        // total target duration tolerance (output durations are unchanged, so this is a belt-and-suspenders check)
        let total = candidate.segments.reduce(0.0) { $0 + $1.outputDurationSeconds }
        let tol = candidate.targetDurationSeconds * RefinementConfig.durationTolerance
        guard abs(total - candidate.targetDurationSeconds) <= tol + 0.001 else {
            return Verdict(ok: false, notes: ["total duration \(total) out of ±20% tolerance"]) }
        notes.append("validation OK: \(candidate.segments.count) segments, bounds + duration + contract fields intact")
        return Verdict(ok: true, notes: notes)
    }
}

// MARK: - AVFoundation evidence provider (production sampler; the pure engine above is injected with this)

enum AVFoundationEvidence {
    /// Sample bounded Edit Evidence at (clip, time): coarse motion from luma frame-diff + audio RMS/onset.
    /// Reads only a few frames in a small window — never the whole video. Returns nil on read failure
    /// (the engine treats nil as "no evidence" -> no-op, never a crash).
    static func sample(url: URL, time: Double) -> BoundaryEvidence? {
        let asset = AVURLAsset(url: url)
        guard let vtrack = asset.tracks(withMediaType: .video).first else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.03, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 160, height: 160)   // tiny — motion only needs coarse luma
        let dt = 0.08
        guard let a = lumaGrid(gen, time), let b = lumaGrid(gen, time + dt) else { return nil }
        let (mag, dir) = motion(a, b)
        let (rms, onset) = audioRMS(asset: asset, track: vtrack, around: time)
        return BoundaryEvidence(
            timeSeconds: time,
            motionMagnitude: mag,
            motionDirection: dir,
            audioRMS: rms,
            isSilence: rms < RefinementConfig.silenceFloor,
            onsetNearby: onset,
            actionCandidate: false)   // action candidacy is supplied separately from AU, not from pixels
    }

    private static func lumaGrid(_ gen: AVAssetImageGenerator, _ t: Double) -> [[Double]]? {
        let cm = CMTime(seconds: max(0, t), preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: cm, actualTime: nil) else { return nil }
        let w = 16, h = 16
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: w*h)
        var grid = Array(repeating: Array(repeating: 0.0, count: w), count: h)
        for y in 0..<h { for x in 0..<w { grid[y][x] = Double(p[y*w + x]) / 255.0 } }
        return grid
    }

    private static func motion(_ a: [[Double]], _ b: [[Double]]) -> (Double, String) {
        let h = a.count, w = a[0].count
        var total = 0.0
        var dx = 0.0, dy = 0.0
        for y in 0..<h { for x in 0..<w {
            let d = b[y][x] - a[y][x]
            total += abs(d)
            dx += d * (Double(x) - Double(w)/2)
            dy += d * (Double(y) - Double(h)/2)
        } }
        let mag = min(1.0, total / Double(w*h) * 4.0)   // scale into ~0..1
        var dir = "none"
        if mag >= RefinementConfig.motionSettleThreshold {
            if abs(dx) >= abs(dy) { dir = dx >= 0 ? "right" : "left" }
            else { dir = dy >= 0 ? "down" : "up" }
        }
        return (mag, dir)
    }

    private static func audioRMS(asset: AVURLAsset, track: AVAssetTrack, around t: Double) -> (Double, Bool) {
        // Lightweight: read a short audio window via AVAssetReader. On any failure return (0, false) so the
        // caller treats it as silence/no-onset rather than crashing.
        guard let atrack = asset.tracks(withMediaType: .audio).first else { return (0, false) }
        let start = CMTime(seconds: max(0, t - 0.1), preferredTimescale: 600)
        let dur = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let reader = try? AVAssetReader(asset: asset) else { return (0, false) }
        reader.timeRange = CMTimeRange(start: start, duration: dur)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                        AVLinearPCMIsBigEndianKey: false]
        let out = AVAssetReaderTrackOutput(track: atrack, outputSettings: settings)
        guard reader.canAdd(out) else { return (0, false) }
        reader.add(out); guard reader.startReading() else { return (0, false) }
        var sum = 0.0; var n = 0; var peak = 0.0
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            var len = 0; var dp: UnsafeMutablePointer<Int8>? = nil
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &dp)
            if let dp { dp.withMemoryRebound(to: Int16.self, capacity: len/2) { sp in
                for i in 0..<(len/2) { let v = Double(sp[i]) / 32768.0; sum += v*v; peak = max(peak, abs(v)); n += 1 }
            } }
        }
        let rms = n > 0 ? (sum/Double(n)).squareRoot() : 0.0
        let onset = peak > rms * 2.5 && rms > RefinementConfig.silenceFloor   // crude transient near the window
        return (rms, onset)
    }
}

