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

    /// R6 — the ASYNC resolution gate for editing/rendering: for each Moment that is cloud-only, download +
    /// verify + atomically install its original FIRST (via MediaResolver), THEN delegate to the synchronous
    /// `resolve`. This guarantees a render/edit never silently drops a backed-up Moment just because its local
    /// bytes were evicted/absent (req #8). A Moment that is cloud-only AND cannot be restored (not this
    /// account's, or no cloud copy) is collected in `unavailable` so the caller can refuse honestly rather than
    /// render a partial Story (req #9/#12) — it is NEVER silently skipped here.
    @MainActor
    static func resolveEnsuringLocal(moments: [MomentModel],
                                     context: ModelContext,
                                     activeOwner: String?,
                                     token: @escaping () async -> String?)
        async -> (media: [MomentMedia], unavailable: [(momentId: UUID, error: Error)]) {
        var unavailable: [(UUID, Error)] = []
        for m in moments {
            guard let rel = m.asset?.relativePath else { continue }
            if MediaStore.shared.fileExists(relativePath: rel) { continue }   // already local
            do {
                _ = try await MediaResolver.shared.ensureLocal(
                    moment: m, context: context, activeOwner: activeOwner, token: token)
            } catch {
                unavailable.append((m.id, error))
            }
        }
        return (resolve(moments: moments), unavailable.map { ($0.0, $0.1) })
    }

    /// CLOUD-AWARE PLANNER DURATION (Phase 2). The Edit Planner payload needs a Moment's duration but NOT its
    /// original bytes: duration is content metadata that `AssetModel.durationSeconds` already persists for every
    /// Moment (populated at capture/import and carried in the synced Story doc's moment_refs). So planner
    /// eligibility must NOT require a local file — a cloud-only Moment (bytes evicted/not-yet-restored) whose
    /// AssetModel still has a positive duration is fully plannable. Prefer a FRESH local probe when the original
    /// is on disk (authoritative), else fall back to the persisted/cloud `AssetModel.durationSeconds`. Returns
    /// 0 when neither is known (caller treats 0 as "no usable duration" and drops honestly, never inventing one).
    static func plannerDuration(for moment: MomentModel) -> Double {
        if let rel = moment.asset?.relativePath, MediaStore.shared.fileExists(relativePath: rel) {
            let probed = AVURLAsset(url: MediaStore.shared.absoluteURL(for: rel)).duration.seconds
            if probed.isFinite && probed > 0 { return probed }
        }
        let meta = moment.asset?.durationSeconds ?? 0
        return (meta.isFinite && meta > 0) ? meta : 0
    }

    /// Can this Moment's ORIGINAL bytes be obtained for RENDER — either they are on disk now, OR they are
    /// cloud-backed and restorable on demand via R6? Planner eligibility requires this (in addition to AU +
    /// duration): planning a Moment whose bytes are gone forever (no local file AND not cloud-backed) would
    /// select footage that can never render. A cloud-only-but-backed Moment IS renderable (R6 restores it
    /// before render), so it stays eligible — that is exactly the R7 regression fix.
    static func isRenderableSource(_ moment: MomentModel) -> Bool {
        if let rel = moment.asset?.relativePath, MediaStore.shared.fileExists(relativePath: rel) { return true }
        return (moment.cloudMediaId ?? "").isEmpty == false && moment.cloudStateRaw == "cloud_verified"
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

    /// Directive-eligibility PREFLIGHT (invalid_after_repair root-cause fix). A hard directive may reference a
    /// Moment the planner payload will NOT contain (build() drops a Moment with no local file OR no completed
    /// AU). Submitting such a directive deterministically fails `directive … references Moment not in the
    /// eligible source set` -> invalid_after_repair. This reports, for the Story's PERSISTED directives, which
    /// referenced Moments are NOT eligible and WHY, so the caller can restore a missing file on demand (R6) or
    /// block honestly ("still being analyzed") instead of submitting a doomed request. Pure read; no network.
    struct DirectiveEligibility {
        var ineligibleNeedsRestore: [UUID]   // linked, cloud-backed, no local bytes yet -> restorable
        var ineligibleNeedsAU: [UUID]        // local file present but AU not completed -> wait, cannot force
        var ineligibleUnknown: [UUID]        // referenced id not a linked Moment at all (stale chip)
        var allEligible: Bool { ineligibleNeedsRestore.isEmpty && ineligibleNeedsAU.isEmpty && ineligibleUnknown.isEmpty }
    }

    static func directiveEligibility(for story: StoryModel, context: ModelContext) -> DirectiveEligibility {
        var out = DirectiveEligibility(ineligibleNeedsRestore: [], ineligibleNeedsAU: [], ineligibleUnknown: [])
        guard let dirs = ResolvedDirectives.fromWireJSON(story.creativeDirectivesJSON) else { return out }
        var ids = Set(dirs.mustInclude + dirs.exclude)
        if let o = dirs.opening { ids.insert(o) }
        if let e = dirs.ending { ids.insert(e) }
        for pair in dirs.orderAfter + dirs.orderAdjacent { ids.formUnion(pair) }
        // exclude-directives do NOT require the Moment to be in the payload (excluding an absent Moment is
        // trivially satisfied), so drop pure-exclude ids from the eligibility requirement.
        for ex in dirs.exclude { ids.remove(ex) }
        guard !ids.isEmpty else { return out }

        let momentById = Dictionary(uniqueKeysWithValues: story.moments.map { ($0.id, $0) })
        let allMUs = (try? context.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? []
        let hasAU = Set(allMUs.map { $0.momentId })
        for id in ids {
            guard let m = momentById[id] else { out.ineligibleUnknown.append(id); continue }
            // CLOUD-AWARE eligibility (Phase 1/2): the planner payload needs AU + a known duration, NOT local
            // bytes. So a Moment is ELIGIBLE for a directive reference as soon as its AU is present AND a
            // duration is known (local probe OR AssetModel cloud metadata) — even if its original is evicted.
            // We only report ineligibility when the planner genuinely cannot place it:
            //   • AU present + duration>0                         -> eligible (nothing appended).
            //   • AU MISSING, AU restorable from cloud (backed up) -> needsRestore (hydrate server AU, no bytes).
            //   • AU MISSING, local file present (will be analyzed) -> needsAU (genuine analysis delay).
            //   • no AU and not restorable / no duration            -> unknown (cannot satisfy).
            let auPresent = hasAU.contains(id)
            let dur = MomentResolver.plannerDuration(for: m)
            let renderable = MomentResolver.isRenderableSource(m)
            if auPresent && dur > 0 && renderable { continue }      // eligible — in the payload
            let cloudBacked = (m.cloudMediaId ?? "").isEmpty == false
            let hasFile = (m.asset?.relativePath).map { MediaStore.shared.fileExists(relativePath: $0) } ?? false
            if !auPresent && cloudBacked {
                out.ineligibleNeedsRestore.append(id)   // server AU restorable via UnderstandingSync (metadata, no bytes, no Bedrock)
            } else if !auPresent && hasFile {
                out.ineligibleNeedsAU.append(id)        // local but not analyzed yet -> wait, cannot force
            } else {
                out.ineligibleUnknown.append(id)        // not analyzed & not restorable, no duration, or bytes gone -> honest block
            }
        }
        return out
    }

    /// Issue (R7 regression): the Customize / Revise "Moment N" numbering MUST be built from the SAME usable
    /// set the planner receives — a Moment is usable iff it has a resolvable LOCAL file AND a completed
    /// MomentUnderstanding (identical to `build()`'s filter), ordered by createdAt. After R7-C a Story can hold
    /// cloud-only shells (evicted, no local file) or Moments whose AU has not been restored yet; those are
    /// dropped from the planner payload but were still counted in a numbering built from ALL `story.moments`,
    /// so "Start with Moment 14" could reference a Moment the planner never sees -> unsatisfiable opening ->
    /// invalid_after_repair. Numbering off THIS set keeps "Moment N" 1:1 with what the planner can place.
    static func usableNumberedMoments(for story: StoryModel, context: ModelContext) -> [NumberedMoment] {
        let media = MomentResolver.resolve(moments: story.moments)
        let mediaById = Dictionary(uniqueKeysWithValues: media.map { ($0.momentId, $0) })
        let momentIds = Set(story.moments.map { $0.id })
        let allMUs = (try? context.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? []
        let muByMoment = Dictionary(uniqueKeysWithValues:
            allMUs.filter { momentIds.contains($0.momentId) }.map { ($0.momentId, $0) })
        var out: [NumberedMoment] = []
        for m in story.moments.sorted(by: { $0.createdAt < $1.createdAt }) {
            // CLOUD-AWARE: same eligibility as build() — AU + a known duration (local probe OR cloud metadata),
            // NOT local-file presence. Keeps "Moment N" 1:1 with the planner's eligible set even for a
            // cloud-only Moment, so an opening/ending/adjacency reference to it is satisfiable (R7 regression fix).
            guard muByMoment[m.id] != nil else { continue }          // same AU gate as build()
            let dur = MomentResolver.plannerDuration(for: m)
            guard dur > 0, MomentResolver.isRenderableSource(m) else { continue }
            out.append(NumberedMoment(number: 0, id: m.id,
                                      durationSeconds: dur,
                                      relativePath: mediaById[m.id]?.relativePath ?? m.asset?.relativePath,
                                      localAvailable: mediaById[m.id] != nil))
        }
        return out
    }

    /// Milestone R-d.2 — the SAME moments[] (id/duration_seconds/useful_segments/summary) + CreativeIntent
    /// payload the Edit Planner receives, exposed so the Duration Planner recommends against identical
    /// evidence. Returns nil when there is no usable material (caller shows "keep shooting"). Does NOT invent
    /// a target: creative_intent carries the Story's EXPLICIT target_duration_seconds only when one is set.
    static func momentsPayload(for story: StoryModel, context: ModelContext)
        -> (moments: [JSONValue], creativeIntent: JSONValue)? {
        let momentIds = Set(story.moments.map { $0.id })
        let allMUs = (try? context.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? []
        let muByMoment = Dictionary(uniqueKeysWithValues:
            allMUs.filter { momentIds.contains($0.momentId) }.map { ($0.momentId, $0) })
        var moments: [JSONValue] = []
        for m in story.moments.sorted(by: { $0.createdAt < $1.createdAt }) {
            // CLOUD-AWARE: identical eligibility to build() — AU + a known duration (local probe OR cloud
            // metadata), independent of local bytes — so the Duration Planner recommends against EXACTLY the
            // footage the Edit Planner will see, including cloud-only Moments.
            guard let mu = muByMoment[m.id] else { continue }
            let dur = MomentResolver.plannerDuration(for: m)
            guard dur > 0, MomentResolver.isRenderableSource(m) else { continue }
            let understanding = JSONValue.object(fromJSONString: mu.understandingJSON)
            moments.append(.object([
                "id": .string(m.id.uuidString),
                "duration_seconds": .number(dur),
                "useful_segments": .array(usefulSegmentPairs(from: understanding, duration: dur)),
                "summary": understandingSummary(understanding),
            ].merging(Self.evidenceField(understanding)) { _, new in new }))
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
                      musicAnalysis: JSONValue? = nil,
                      revisionContext: JSONValue? = nil) throws -> Build {
        // Resolvable local media, keyed by Moment id (the ORIGINAL bytes on THIS device right now). Used for
        // the render-time URL resolver + diagnostics — NOT as the planner-eligibility gate (see below).
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

        // CLOUD-AWARE PLANNER ELIGIBILITY (Phase 2, owner P0). A Moment participates in PLANNING iff it has a
        // completed/synced AU AND a known duration — INDEPENDENT of whether its original bytes are on this
        // device. The planner payload needs only {id, duration_seconds, useful_segments, summary, evidence},
        // all of which come from AssetModel.durationSeconds (cloud metadata) + the AU JSON — never the bytes.
        // This closes the R7 regression where a cloud-only Moment (e.g. TMB Moment 2) with server-side AU was
        // silently dropped because its file was not local, making a directive that named it fail
        // directive_ref_ineligible. Original bytes are restored through R6 before RENDERING, not for planning.
        //   • has AU + duration  -> eligible: added to moments[]. If also local, added to includedMedia.
        //   • has file, no AU     -> excluded (genuine analysis delay; readiness surfaces it honestly).
        //   • no file, no AU      -> excluded (nothing to plan from).
        for m in story.moments.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let mu = muByMoment[m.id] else {
                excluded.append(m.id); continue                 // no completed AU -> drop, never invent
            }
            let dur = MomentResolver.plannerDuration(for: m)    // local probe OR cloud metadata; 0 = unknown
            guard dur > 0 else {
                excluded.append(m.id); continue                 // no usable duration anywhere -> drop honestly
            }
            guard MomentResolver.isRenderableSource(m) else {
                excluded.append(m.id); continue                 // bytes neither local nor cloud-restorable -> cannot render -> drop
            }
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
            ].merging(Self.evidenceField(understanding)) { _, new in new }))
            // includedMedia is the LOCAL render set: only Moments whose bytes are on disk NOW. A cloud-only
            // eligible Moment is in moments[] (planner) but NOT here — R6 restores it before render.
            if let localMedia = mediaById[m.id] { included.append(localMedia) }
        }

        // Plannable iff >=1 Moment reached the planner payload (has AU + duration). This is the CLOUD-AWARE
        // set: a fully cloud-only Story (every eligible Moment's bytes evicted) is still plannable — the
        // originals are restored through R6 before render. (Was `included` (local-only), which wrongly made a
        // cloud-only Story unplannable even when every Moment had synced AU — the R7 regression.)
        guard !moments.isEmpty else { throw BuildError.noUsableMoments }

        // R-d.2: the Story target is AUTHORITATIVE and must be chosen upstream (explicit CreativeIntent or an
        // accepted Duration recommendation). NO blind numeric fallback on the normal path — an unset target is a
        // precondition failure the create flow surfaces as manual selection, never a silent 15s.
        guard let target = targetSeconds ?? story.intentTargetDurationSeconds else {
            throw BuildError.missingTarget
        }

        let intent = creativeIntentPayload(story: story, target: target)

        // Wire the Story's PERSISTED StoryGuide + StoryCoverage into the request. Edit Planner v5's prompt is
        // told to "allocate time by narrative significance relative to the Guide and Coverage" — but these were
        // being sent as EMPTY objects, so v5 selected from CreativeIntent + thin per-Moment summaries alone and
        // under-used footage (observed: 36 eligible -> 11 selected at a 105s target). We send the ACTUAL evidence
        // when present; honest empty-object fallback when absent (never fabricated/stale-forced). Same loaders as
        // the music path. No frozen prompt/contract change — the fields already exist and v5 already reads them.
        let guideJSON = Self.loadGuideJSON(for: story.id, context: context)
        let coverageJSON = Self.loadCoverageJSON(for: story.id, context: context)

        let req = EditPlanRequestDTO(
            storyId: story.id,
            creativeIntentId: story.id,                 // CreativeIntent is 1:1 with the Story (flattened on StoryModel)
            creativeIntent: intent,
            storyGuide: guideJSON,
            storyCoverage: coverageJSON,
            moments: moments,
            outputFormat: outputFormat,
            musicPlan: musicPlan,                       // R-d: present => music-aware planning; nil => no-music parity
            musicAssetId: musicAssetId,
            musicAnalysis: musicAnalysis,
            soundPreference: story.effectiveSoundPreference.rawValue,   // immersive|balanced|music_led → native_audio bias
            editorialMode: story.editorialMode,                        // highlights|full|custom → selection breadth (nil = infer)
            revisionContext: revisionContext)                          // Creative Revision Foundation: Explore/Revise version-aware context (nil = unchanged)

        return Build(request: req, includedMedia: included, excludedMomentIds: excluded)
    }

    /// Load the Story's persisted StoryGuide wire JSON (story_guide/1), or an empty object when absent.
    /// Never fabricates: a missing/empty Guide yields `.object([:])` so the planner falls back honestly.
    static func loadGuideJSON(for storyId: UUID, context: ModelContext) -> JSONValue {
        var desc = FetchDescriptor<StoryGuideModel>(predicate: #Predicate { $0.storyId == storyId })
        desc.fetchLimit = 1
        if let json = (try? context.fetch(desc))?.first?.guideJSON, !json.isEmpty {
            return JSONValue.object(fromJSONString: json)
        }
        return .object([:])
    }

    /// Load the Story's persisted StoryCoverage wire JSON (story_coverage/*), or an empty object when absent.
    static func loadCoverageJSON(for storyId: UUID, context: ModelContext) -> JSONValue {
        var desc = FetchDescriptor<StoryCoverageModel>(predicate: #Predicate { $0.storyId == storyId })
        desc.fetchLimit = 1
        if let json = (try? context.fetch(desc))?.first?.coverageJSON, !json.isEmpty {
            return JSONValue.object(fromJSONString: json)
        }
        return .object([:])
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

    /// Arm B (AU-evidence forwarding): build a DETERMINISTIC, BOUNDED factual description for the planner from
    /// the AU output ALREADY persisted — folding observed.summary + subjects + the key events + temporal note.
    /// Previously only observed.summary was forwarded, so distinct outfits/accessories/settings AU had already
    /// described in subjects/events never reached the Edit Planner (proven 16->22 distinct selection on the real
    /// girl_with_dress set). This changes ONLY how much of the existing AU evidence is forwarded — no new field,
    /// no model call, no prompt/contract change, and the original persisted AU output is untouched. Only real
    /// present fields are used (never fabricated), de-duplicated, and the whole string is length-capped.
    private static func understandingSummary(_ understanding: JSONValue) -> JSONValue {
        guard case let .object(root) = understanding,
              case let .object(observed)? = root["observed"] else { return .string("") }

        var parts: [String] = []
        var seen = Set<String>()                 // avoid repeating the same phrase across summary/subjects/events
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let key = t.lowercased()
            if seen.contains(key) { return }
            seen.insert(key); parts.append(t)
        }

        if case let .string(summary)? = observed["summary"] { add(summary) }

        // subjects: who/what matters (people, key objects — e.g. "red bag"). Cap to a few, comma-joined.
        if case let .array(subjects)? = observed["subjects"] {
            let names = subjects.compactMap { v -> String? in if case let .string(s) = v { return s }; return nil }
                .prefix(6)
            if !names.isEmpty { add("subjects: " + names.joined(separator: ", ")) }
        }

        // events: ordered factual event descriptions (NOT timestamps — the planner has useful_segments for timing).
        if case let .array(events)? = observed["events"] {
            let descs = events.compactMap { v -> String? in
                if case let .object(e) = v, case let .string(d)? = e["description"] { return d }; return nil
            }.prefix(4)
            if !descs.isEmpty { add("events: " + descs.joined(separator: "; ")) }
        }

        // temporal_order_note: the key first/then/last interpretation, when present and non-trivial.
        if case let .string(note)? = observed["temporal_order_note"] { add(note) }

        // Bounded: cap the whole description so a 36-Moment request stays measurable (~per-Moment ceiling).
        var out = parts.joined(separator: " · ")
        let cap = 600
        if out.count > cap { out = String(out.prefix(cap)) + "…" }
        return .string(out)
    }

    // MARK: - A1 richer-evidence forwarding (owner-approved 2026-10-12; multimodal experiment addendum)

    /// Per-Moment bounds for the A1 structured `evidence` object. Chosen so a 100-Moment request stays well
    /// under a reasonable request budget: subjects ≤ MAX_SUBJECTS, events ≤ MAX_EVENTS each trimmed to
    /// MAX_EVENT_CHARS, summary ≤ MAX_SUMMARY_CHARS, temporal note ≤ MAX_NOTE_CHARS, and the whole evidence
    /// object serialized is hard-capped at MAX_EVIDENCE_CHARS as a belt-and-suspenders ceiling. These replace
    /// the single destructive 600-char prose cap with a STRUCTURED, measured budget that keeps event
    /// timestamps explicit instead of dropping them.
    private static let MAX_SUBJECTS = 10
    private static let MAX_EVENTS = 8
    private static let MAX_EVENT_CHARS = 90
    private static let MAX_SUMMARY_CHARS = 320
    private static let MAX_NOTE_CHARS = 200
    private static let MAX_EVIDENCE_CHARS = 1400

    /// Arm A1 (owner-approved): a DETERMINISTIC, BOUNDED, STRUCTURED evidence object forwarded to the planner
    /// ALONGSIDE the legacy `summary`. Unlike `understandingSummary` (which folds everything into one prose
    /// string capped at 600 chars — truncating subjects/accessories/timings on rich clips), this preserves the
    /// AU facts the planner needs as structure: fuller subjects, events WITH their source timestamps, and the
    /// temporal order note. Only real present AU fields are used — never fabricated — de-duplicated, each field
    /// individually bounded, and the whole object hard-capped. No new model call, no frozen AU-prompt change,
    /// no EditPlan/2 change (this is an additive request-grounding field the planner already reads as context).
    /// Returns `.null` when the AU output has no observed block (older/partial records) so the field is omitted.
    static func richEvidence(from understanding: JSONValue) -> JSONValue {
        guard case let .object(root) = understanding,
              case let .object(observed)? = root["observed"] else { return .null }

        func clip(_ s: String, _ n: Int) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > n ? String(t.prefix(n)) + "…" : t
        }

        var obj: [String: JSONValue] = [:]

        if case let .string(summary)? = observed["summary"], !summary.isEmpty {
            obj["summary"] = .string(clip(summary, MAX_SUMMARY_CHARS))
        }

        // subjects: de-duplicated (case-insensitive), bounded. These carry outfits/accessories/locations.
        if case let .array(subjects)? = observed["subjects"] {
            var seen = Set<String>(); var names: [JSONValue] = []
            for v in subjects {
                guard case let .string(s) = v else { continue }
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = t.lowercased()
                if t.isEmpty || seen.contains(key) { continue }
                seen.insert(key); names.append(.string(clip(t, 80)))
                if names.count >= MAX_SUBJECTS { break }
            }
            if !names.isEmpty { obj["subjects"] = .array(names) }
        }

        // events: STRUCTURED {t, t_end?, what} — timestamps kept explicit (the planner can align to action
        // beats), descriptions trimmed. Ordered as AU produced them; bounded count.
        if case let .array(events)? = observed["events"] {
            var evs: [JSONValue] = []
            for v in events {
                guard case let .object(e) = v, case let .string(d)? = e["description"], !d.isEmpty else { continue }
                var ev: [String: JSONValue] = ["what": .string(clip(d, MAX_EVENT_CHARS))]
                if case let .number(t)? = e["start_time"] { ev["t"] = .number((t * 10).rounded() / 10) }
                if case let .number(te)? = e["end_time"] { ev["t_end"] = .number((te * 10).rounded() / 10) }
                evs.append(.object(ev))
                if evs.count >= MAX_EVENTS { break }
            }
            if !evs.isEmpty { obj["events"] = .array(evs) }
        }

        if case let .string(note)? = observed["temporal_order_note"], !note.isEmpty {
            obj["temporal_order_note"] = .string(clip(note, MAX_NOTE_CHARS))
        }

        if obj.isEmpty { return .null }

        // Belt-and-suspenders: if the evidence's total text somehow exceeds the hard ceiling (pathological AU),
        // drop events from the end until it fits — events are the most verbose and the least load-bearing tail.
        func textLen(_ o: [String: JSONValue]) -> Int {
            var n = 0
            for (_, v) in o {
                switch v {
                case .string(let s): n += s.count
                case .array(let a):
                    for e in a {
                        if case let .string(s) = e { n += s.count }
                        else if case let .object(eo) = e {
                            for (_, ev) in eo { if case let .string(s) = ev { n += s.count } }
                        }
                    }
                default: break
                }
            }
            return n
        }
        var o = obj
        while textLen(o) > MAX_EVIDENCE_CHARS, case let .array(evs)? = o["events"], !evs.isEmpty {
            o["events"] = .array(Array(evs.dropLast()))
            if case let .array(x)? = o["events"], x.isEmpty { o.removeValue(forKey: "events") }
        }
        return .object(o)
    }

    /// Wrap `richEvidence` as a dict to merge into a Moment payload: `["evidence": <obj>]` when present, or an
    /// EMPTY dict when the AU record has no observed block — so `.merging` is a no-op and the payload is
    /// byte-identical to the pre-A1 shape (backward compatibility for older/partial AU records and tests).
    static func evidenceField(_ understanding: JSONValue) -> [String: JSONValue] {
        let ev = richEvidence(from: understanding)
        if case .null = ev { return [:] }
        return ["evidence": ev]
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
