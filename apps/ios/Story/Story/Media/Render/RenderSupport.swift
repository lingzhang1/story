import AVFoundation
import Foundation
import SwiftData

// RenderSupport — bridges persisted Moments to the Media Engine and builds a deterministic, known-valid
// EditPlan/2 fixture for the DEBUG render harness. NO network, NO Epidemic, NO creative decisions.

struct MomentMedia {
    let momentId: UUID
    let relativePath: String
    let durationSeconds: Double
}

enum MomentResolver {
    /// Resolve a Story's Moments to their on-device media (id, relative path, duration). Skips Moments whose
    /// file is missing — the CALLER decides whether that is fatal (the renderer hard-fails on an unresolved id).
    static func resolve(moments: [MomentModel]) -> [MomentMedia] {
        var out: [MomentMedia] = []
        for m in moments.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let rel = m.asset?.relativePath, MediaStore.shared.fileExists(relativePath: rel) else { continue }
            let url = MediaStore.shared.absoluteURL(for: rel)
            let dur = AVURLAsset(url: url).duration.seconds
            out.append(MomentMedia(momentId: m.id, relativePath: rel,
                                   durationSeconds: dur.isFinite && dur > 0 ? dur : 0))
        }
        return out
    }

    /// A Media-Engine URL resolver closure keyed by the Moment id STRING (matches EditSegmentV2.assetId).
    /// UUIDs are case-insensitive: the Edit Planner round-trips the id through the model, which may normalize
    /// its hex case (Swift's `uuidString` is UPPERCASE; the planner returns it lowercased), so we lowercase
    /// BOTH the key and the lookup — otherwise a valid plan resolves to "no local file".
    static func urlResolver(for media: [MomentMedia]) -> (String) -> URL? {
        let map = Dictionary(uniqueKeysWithValues:
            media.map { ($0.momentId.uuidString.lowercased(), $0.relativePath) })
        return { id in map[id.lowercased()].map { MediaStore.shared.absoluteURL(for: $0) } }
    }
}

enum DebugEditPlanFixture {
    /// A deterministic, KNOWN-VALID EditPlan/2 over the given resolved Moments: straight cuts, each Moment
    /// trimmed to a short head window, native_audio=keep on the first (so Case B is exercisable), duck on the
    /// rest, output = vertical, no music_alignment (no analysis). Scales output to a target.
    static func montage(media: [MomentMedia], targetSeconds: Double = 12.0, outputFormat: String = "vertical") -> EditPlanV2 {
        let n = max(1, media.count)
        let per = max(1.0, targetSeconds / Double(n))
        var segs: [EditSegmentV2] = []
        for (i, m) in media.enumerated() {
            let span = min(per, max(1.0, m.durationSeconds))
            segs.append(EditSegmentV2(
                order: i, assetId: m.momentId.uuidString,
                sourceStartSeconds: 0.0, sourceEndSeconds: span,
                outputDurationSeconds: round(span * 100) / 100,
                speed: 1.0, nativeAudio: i == 0 ? "keep" : "duck", musicAlignment: nil))
        }
        let total = segs.reduce(0.0) { $0 + $1.outputDurationSeconds }
        return EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: total,
                          outputFormat: outputFormat, musicAssetId: nil, feasible: true, segments: segs)
    }

    /// Decode a real EditPlan/2 JSON (e.g. from the deployed /v1/edit-plan) into the renderer DTO.
    static func decode(_ json: Data) throws -> EditPlanV2 {
        try JSONDecoder().decode(EditPlanV2.self, from: json)
    }

    /// CASE D (crossfade) — a deterministic plan where segments 1..n carry a 0.3s `dissolve` so the renderer
    /// overlaps them with an opacity ramp (a REAL crossfade, not a fade-to-black). Needs >=2 Moments.
    static func crossfade(media: [MomentMedia], outputFormat: String = "vertical") -> EditPlanV2 {
        var segs: [EditSegmentV2] = []
        for (i, m) in media.prefix(3).enumerated() {
            let span = min(3.0, max(1.5, m.durationSeconds))   // >= 1.5s so a 0.3s dissolve fits comfortably
            segs.append(EditSegmentV2(
                order: i, assetId: m.momentId.uuidString,
                sourceStartSeconds: 0.0, sourceEndSeconds: span,
                outputDurationSeconds: round(span * 100) / 100,
                speed: 1.0, nativeAudio: "keep", musicAlignment: nil,
                transition: i == 0 ? nil : Transition(type: "dissolve", durationSeconds: 0.3)))
        }
        // output duration = sum of segments minus the overlaps (one 0.3s overlap per dissolve)
        let dissolves = max(0, segs.count - 1)
        let total = segs.reduce(0.0) { $0 + $1.outputDurationSeconds } - 0.3 * Double(dissolves)
        return EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: round(total * 100) / 100,
                          outputFormat: outputFormat, musicAssetId: nil, feasible: true, segments: segs)
    }

    /// CASE D (speed) — a deterministic plan exercising 0.5x and 2.0x playback. Needs >=2 Moments; the first
    /// segment plays at 0.5x (slow), the second at 2.0x (fast). Straight cuts. output_duration = span / speed.
    static func speedCases(media: [MomentMedia], outputFormat: String = "vertical") -> EditPlanV2 {
        let speeds: [Double] = [0.5, 2.0, 1.0]
        var segs: [EditSegmentV2] = []
        for (i, m) in media.prefix(3).enumerated() {
            let span = min(2.0, max(1.0, m.durationSeconds))     // 2s source window
            let speed = speeds[i % speeds.count]
            segs.append(EditSegmentV2(
                order: i, assetId: m.momentId.uuidString,
                sourceStartSeconds: 0.0, sourceEndSeconds: span,
                outputDurationSeconds: round((span / speed) * 100) / 100,   // 0.5x -> longer, 2x -> shorter
                speed: speed, nativeAudio: "keep", musicAlignment: nil))
        }
        let total = segs.reduce(0.0) { $0 + $1.outputDurationSeconds }
        return EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: total,
                          outputFormat: outputFormat, musicAssetId: nil, feasible: true, segments: segs)
    }

    /// CASE F (missing Moment) — a plan whose FIRST segment references a Moment id that does not resolve to any
    /// local file. The renderer MUST throw MediaEngineError.missingMoment and produce NO output (never a partial
    /// MP4, never a silent skip). The remaining segments are valid so the failure is unambiguously the bad id.
    static func missingMoment(media: [MomentMedia], outputFormat: String = "vertical") -> EditPlanV2 {
        var segs: [EditSegmentV2] = [
            EditSegmentV2(order: 0, assetId: "00000000-0000-0000-0000-000000000000",   // deliberately unresolvable
                          sourceStartSeconds: 0.0, sourceEndSeconds: 2.0,
                          outputDurationSeconds: 2.0, speed: 1.0, nativeAudio: "keep", musicAlignment: nil)
        ]
        for (i, m) in media.prefix(2).enumerated() {
            segs.append(EditSegmentV2(order: i + 1, assetId: m.momentId.uuidString,
                sourceStartSeconds: 0.0, sourceEndSeconds: 2.0,
                outputDurationSeconds: 2.0, speed: 1.0, nativeAudio: "keep", musicAlignment: nil))
        }
        let total = segs.reduce(0.0) { $0 + $1.outputDurationSeconds }
        return EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: total,
                          outputFormat: outputFormat, musicAssetId: nil, feasible: true, segments: segs)
    }
}

// MARK: - Real EditPlan request builder (R-b Case G)

/// Builds the POST /v1/edit-plan request from a Story's ALREADY-PERSISTED data: the resolved CreativeIntent
/// (fields on StoryModel) + each Moment's COMPLETED MomentUnderstanding (useful_segments). This is the
/// load-bearing IDENTITY MAPPING for Case G:
///
///   MomentModel.id  ==  request moments[].id  ==  EditSegment.asset_id (echoed back)  ->  MediaStore file
///
/// A Moment WITHOUT a completed MomentUnderstanding, or without a resolvable local file, is EXCLUDED from the
/// request (reported via `excludedMomentIds`) — it is never sent with invented content. NO-MUSIC MODE only:
/// music_plan / music_asset_id / music_analysis are omitted (no production MusicPlan engine exists), so the
/// planner emits no music anchors. Deterministic; no network here (the caller sends the request).
enum EditPlanRequestBuilder {

    struct Build {
        let request: EditPlanRequestDTO
        let includedMedia: [MomentMedia]       // the resolvable Moments actually sent (drives URL resolution)
        let excludedMomentIds: [UUID]          // Moments dropped: no completed AU, or no local file

        /// The resolved Story target that was baked into the request's CreativeIntent. Reading it back from the
        /// request (not recomputing) guarantees the preflight sees EXACTLY the target the planner will.
        var resolvedTargetSeconds: Double? {
            if case let .object(ci) = request.creativeIntent,
               case let .number(t)? = ci["target_duration_seconds"] { return t }
            return nil
        }

        /// The per-Moment usable material, parsed from the SAME request.moments the planner receives — so the
        /// duration-feasibility preflight and the planner can never disagree about what footage exists.
        var materials: [DurationFeasibility.MomentMaterial] {
            request.moments.compactMap { mv in
                guard case let .object(m) = mv else { return nil }
                let dur: Double = { if case let .number(d)? = m["duration_seconds"] { return d }; return 0 }()
                var spans: [(start: Double, end: Double)] = []
                if case let .array(segs)? = m["useful_segments"] {
                    for s in segs {
                        guard case let .array(pair) = s, pair.count == 2,
                              case let .number(a) = pair[0], case let .number(b) = pair[1] else { continue }
                        spans.append((start: a, end: b))
                    }
                }
                return DurationFeasibility.MomentMaterial(durationSeconds: dur, usefulSegments: spans)
            }
        }

        /// Creative Editing V2-b: per-asset AU useful ranges, keyed by lowercased Moment id (== EditSegment
        /// asset_id). Parsed from the SAME request.moments the planner saw, so the refinement stage's hard
        /// bounds match what the plan was built against. Empty list for a Moment with no parsable segments.
        var auUsefulRanges: [String: [(Double, Double)]] {
            var out: [String: [(Double, Double)]] = [:]
            for mv in request.moments {
                guard case let .object(m) = mv,
                      case let .string(id)? = m["id"] else { continue }
                var spans: [(Double, Double)] = []
                if case let .array(segs)? = m["useful_segments"] {
                    for s in segs {
                        if case let .array(pair) = s, pair.count == 2,
                           case let .number(a) = pair[0], case let .number(b) = pair[1], b > a {
                            spans.append((a, b))
                        }
                    }
                }
                out[id.lowercased()] = spans
            }
            return out
        }

        /// Creative Editing V2-b: per-asset AU action timestamps. The plan request does not carry AU events
        /// (only useful_segments + summary), so this is empty today — the refinement stage then relies on
        /// motion/audio evidence + useful-range bounds, which is intentionally conservative. Threading real
        /// AU event times here is a bounded follow-up if device review shows it would help.
        var auActionTimestamps: [String: [Double]] { [:] }
    }

    enum BuildError: Error, LocalizedError {
        case noUsableMoments
        case missingTarget
        var errorDescription: String? {
            switch self {
            case .noUsableMoments:
                return "No Moments with both a local video file and a completed analysis — nothing to plan."
            case .missingTarget:
                return "No Story duration chosen — pick a duration before creating."
            }
        }
    }

    /// Milestone R-d.2 — the SAME moments[] (id/duration_seconds/useful_segments/summary) + CreativeIntent
    /// payload the Edit Planner receives, exposed so the Duration Planner recommends against identical
    /// evidence. Returns nil when there is no usable material (caller shows "keep shooting"). Does NOT invent
    /// a target: creative_intent carries the Story's EXPLICIT target_duration_seconds only when one is set.
    static func momentsPayload(for story: StoryModel, context: ModelContext)
        -> (moments: [JSONValue], creativeIntent: JSONValue)? {
        let media = MomentResolver.resolve(moments: story.moments)
        let mediaById = Dictionary(uniqueKeysWithValues: media.map { ($0.momentId, $0) })
        let momentIds = Set(story.moments.map { $0.id })
        let allMUs = (try? context.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? []
        let muByMoment = Dictionary(uniqueKeysWithValues:
            allMUs.filter { momentIds.contains($0.momentId) }.map { ($0.momentId, $0) })
        var moments: [JSONValue] = []
        for m in story.moments.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let media = mediaById[m.id], let mu = muByMoment[m.id] else { continue }
            let dur = media.durationSeconds > 0 ? media.durationSeconds : (m.asset?.durationSeconds ?? 0)
            let understanding = JSONValue.object(fromJSONString: mu.understandingJSON)
            moments.append(.object([
                "id": .string(m.id.uuidString),
                "duration_seconds": .number(dur),
                "useful_segments": .array(usefulSegmentPairs(from: understanding, duration: dur)),
                "summary": understandingSummary(understanding),
            ]))
        }
        guard !moments.isEmpty else { return nil }
        // CreativeIntent WITHOUT inventing a target — carry one ONLY if the Story already has it set.
        var intent = creativeIntentPayload(story: story, target: story.intentTargetDurationSeconds ?? 0)
        if story.intentTargetDurationSeconds == nil, case var .object(obj) = intent {
            obj["target_duration_seconds"] = .null          // no explicit target => omit, never default
            intent = .object(obj)
        }
        return (moments, intent)
    }

    static func build(story: StoryModel,
                      context: ModelContext,
                      targetSeconds: Double? = nil,
                      outputFormat: String = "vertical",
                      musicPlan: JSONValue? = nil,
                      musicAssetId: String? = nil,
                      musicAnalysis: JSONValue? = nil) throws -> Build {
        // Resolvable local media, keyed by Moment id.
        let media = MomentResolver.resolve(moments: story.moments)
        let mediaById = Dictionary(uniqueKeysWithValues: media.map { ($0.momentId, $0) })

        // Completed MomentUnderstanding for THIS Story's Moments.
        let momentIds = Set(story.moments.map { $0.id })
        let allMUs = (try? context.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? []
        let muByMoment = Dictionary(uniqueKeysWithValues:
            allMUs.filter { momentIds.contains($0.momentId) }.map { ($0.momentId, $0) })

        var moments: [JSONValue] = []
        var included: [MomentMedia] = []
        var excluded: [UUID] = []

        for m in story.moments.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let media = mediaById[m.id], let mu = muByMoment[m.id] else {
                excluded.append(m.id); continue                 // no local file OR no completed AU -> drop, never invent
            }
            let dur = media.durationSeconds > 0 ? media.durationSeconds : (m.asset?.durationSeconds ?? 0)
            let understanding = JSONValue.object(fromJSONString: mu.understandingJSON)
            // Transform AU observed.useful_segments [{start_time,end_time,...}] -> [[a,b], ...] number pairs
            // (the shape the backend validator reads: a source range must overlap a useful_segment).
            let useful = usefulSegmentPairs(from: understanding, duration: dur)
            moments.append(.object([
                "id": .string(m.id.uuidString),
                "duration_seconds": .number(dur),
                "useful_segments": .array(useful),
                // Pass the understanding summary through so the planner has narrative grounding (optional).
                "summary": understandingSummary(understanding),
            ]))
            included.append(media)
        }

        guard !included.isEmpty else { throw BuildError.noUsableMoments }

        // R-d.2: the Story target is AUTHORITATIVE and must be chosen upstream (explicit CreativeIntent or an
        // accepted Duration recommendation). NO blind numeric fallback on the normal path — an unset target is a
        // precondition failure the create flow surfaces as manual selection, never a silent 15s.
        guard let target = targetSeconds ?? story.intentTargetDurationSeconds else {
            throw BuildError.missingTarget
        }

        let intent = creativeIntentPayload(story: story, target: target)

        let req = EditPlanRequestDTO(
            storyId: story.id,
            creativeIntentId: story.id,                 // CreativeIntent is 1:1 with the Story (flattened on StoryModel)
            creativeIntent: intent,
            storyGuide: .object([:]),                   // optional; omitted-equivalent
            storyCoverage: .object([:]),                // optional; omitted-equivalent
            moments: moments,
            outputFormat: outputFormat,
            musicPlan: musicPlan,                       // R-d: present => music-aware planning; nil => no-music parity
            musicAssetId: musicAssetId,
            musicAnalysis: musicAnalysis,
            soundPreference: story.effectiveSoundPreference.rawValue)   // immersive|balanced|music_led → native_audio bias

        return Build(request: req, includedMedia: included, excludedMomentIds: excluded)
    }

    /// Extract `[[start,end], ...]` pairs from a MomentUnderstanding's observed.useful_segments. Falls back to
    /// a single whole-clip window when none are present (so a short clip is still plannable).
    private static func usefulSegmentPairs(from understanding: JSONValue, duration: Double) -> [JSONValue] {
        if case let .object(root) = understanding,
           case let .object(observed)? = root["observed"],
           case let .array(segs)? = observed["useful_segments"] {
            var pairs: [JSONValue] = []
            for s in segs {
                guard case let .object(seg) = s,
                      case let .number(a)? = seg["start_time"],
                      case let .number(b)? = seg["end_time"], b > a else { continue }
                pairs.append(.array([.number(a), .number(b)]))
            }
            if !pairs.isEmpty { return pairs }
        }
        return [.array([.number(0.0), .number(max(1.0, duration))])]
    }

    private static func understandingSummary(_ understanding: JSONValue) -> JSONValue {
        if case let .object(root) = understanding,
           case let .object(observed)? = root["observed"],
           case let .string(summary)? = observed["summary"] {
            return .string(summary)
        }
        return .string("")
    }

    /// The resolved CreativeIntent payload the planner needs, assembled from StoryModel's flattened fields.
    /// `target_duration_seconds` is REQUIRED by the backend; everything else is grounding.
    private static func creativeIntentPayload(story: StoryModel, target: Double) -> JSONValue {
        .object([
            "raw_text": .string(story.intentRawText),
            "theme": .string(story.intentTheme),
            "tone": .string(story.intentTone),
            "summary": .string(story.intentSummary),
            "subject": story.intentSubject.map(JSONValue.string) ?? .null,
            "desired_feeling": .array(story.intentDesiredFeeling.map(JSONValue.string)),
            "style_tags": .array(story.intentStyleTags.map(JSONValue.string)),
            "emphasis": .array(story.intentEmphasis.map(JSONValue.string)),
            "creative_constraints": .array(story.intentConstraints.map(JSONValue.string)),
            "pace": story.intentPace.map(JSONValue.string) ?? .null,
            "target_duration_seconds": .number(target),
        ])
    }
}
