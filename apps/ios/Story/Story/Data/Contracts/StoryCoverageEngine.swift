import Foundation
import SwiftData
import CryptoKit

// StoryCoverageEngine — on-device orchestrator + cache lifecycle for StoryCoverage/2 (E2-c).
//
// RESPONSIBILITY: given a Story AND its already-persisted StoryGuide, assemble the Coverage/2 request
// (CreativeIntent + scope + the Guide + all COMPLETE MomentUnderstanding records + pending count),
// call POST /v1/story-coverage/v2 (internal Mapper + Judge), and cache the StoryCoverageV2DTO snapshot.
//
// IMPORTANT (frozen architecture): this engine READS the Guide; it does NOT generate it. Guide
// lifecycle lives in StoryGuideCoordinator. Coverage is Guide-relative.
//
// FROZEN behaviors:
//   - Zero completed MomentUnderstanding -> NO Mapper/Judge call (the Guide alone supplies content).
//   - Pending-only (0 completed) -> NO call; pending is UNKNOWN, not a gap.
//   - FULL RECOMPUTATION; snapshot upsert by storyId.
//   - STALENESS from provenance: stale when the completed-MU set, the CreativeIntent, OR the Guide
//     fingerprint changes.
//   - KEEP LAST VALID: a failed recompute (503/transport/decode) leaves the cache untouched.
@MainActor
final class StoryCoverageEngine {
    private let context: ModelContext
    private let service: StoryCoverageV2Computing
    private let schemaVersion = "story_coverage/2"

    init(context: ModelContext, service: StoryCoverageV2Computing = StoryCoverageV2Service()) {
        self.context = context
        self.service = service
    }

    // MARK: - Read cached coverage (decoded)

    func cachedCoverage(for storyId: UUID) -> StoryCoverageV2DTO? {
        guard let row = cachedModel(for: storyId),
              let data = row.coverageJSON.data(using: .utf8),
              let dto = try? StoryContractCoding.decoder().decode(StoryCoverageV2DTO.self, from: data)
        else { return nil }
        return dto
    }

    /// Stale when NO cache exists OR provenance (completed-MU set / intent / Guide) no longer matches.
    func isStale(for story: StoryModel, guideFingerprint: String) -> Bool {
        guard let row = cachedModel(for: story.id) else { return true }
        let inputs = currentInputs(for: story)
        // SELF-HEAL: a cached snapshot with ZERO dimension coverage while completed understandings exist is a
        // broken/empty mapping (e.g. a prior Mapper truncation that validated as empty dimension_coverage).
        // Its provenance fingerprints still match the unchanged inputs, so without this it would be served
        // forever and every Guide item would stay "Shoot". Force a recompute so it repopulates.
        if !inputs.completedMUValues.isEmpty,
           let dto = cachedCoverage(for: story.id), dto.dimensionCoverage.isEmpty {
            return true
        }
        return row.sourceUnderstandingIdsFingerprint != inputs.sourceFingerprint
            || row.creativeIntentFingerprint != inputs.intentFingerprint
            || row.storyGuideFingerprint != guideFingerprint
    }

    // MARK: - Opportunistic recompute (Guide is REQUIRED — passed in by the coordinator/view-model)

    /// Recompute Coverage/2 IF stale (or forced). Requires the persisted Guide (DTO + fingerprint).
    /// Returns the coverage in effect after the call. NO model call when zero completed MU exists.
    ///
    /// P0: routed through the PROCESS-WIDE CoverageRecomputeGate so view recreation / a burst of AU completions
    /// coalesce to AT MOST ONE active compute per Story (+ at most one pending replacement at the latest
    /// fingerprint). A same-fingerprint request reuses the in-flight/cached work instead of enqueuing a new
    /// Bedrock job — this is the storm fix.
    @discardableResult
    func recomputeIfNeeded(for story: StoryModel,
                           guide: StoryGuideDTO,
                           guideFingerprint: String,
                           force: Bool = false) async -> StoryCoverageV2DTO? {
        let inputs = currentInputs(for: story)
        // Zero completed AU (incl. pending-only): the Guide supplies the product content; do NOT call
        // Mapper/Judge merely to invent Coverage. Keep any prior cache; otherwise nil.
        if inputs.completedMUValues.isEmpty { return cachedCoverage(for: story.id) }
        if !force && !isStale(for: story, guideFingerprint: guideFingerprint) {
            return cachedCoverage(for: story.id)
        }
        // The fingerprint that identifies THIS requested computation (inputs + guide). Same fingerprint => same
        // work; the gate coalesces duplicates and suppresses obsolete results.
        let fp = Self.sha256("\(inputs.sourceFingerprint)#\(inputs.intentFingerprint)#\(guideFingerprint)")
        let storyId = story.id
        return await CoverageRecomputeGate.shared.run(storyId: storyId, fingerprint: fp) { [weak self] in
            guard let self else { return nil }
            return await self.performCompute(for: story, guide: guide, guideFingerprint: guideFingerprint,
                                             expectedFingerprint: fp)
        }
    }

    /// DEBOUNCED entry for AU-triggered recomputes: a burst of completions schedules a single trailing compute
    /// (~800ms) instead of one per completion. Safe to call on every AU completion / view refresh.
    func scheduleRecompute(for story: StoryModel, guide: StoryGuideDTO, guideFingerprint: String) {
        CoverageRecomputeGate.shared.debounce(storyId: story.id) { [weak self] in
            _ = await self?.recomputeIfNeeded(for: story, guide: guide, guideFingerprint: guideFingerprint)
        }
    }

    /// The actual Bedrock compute + cache, guarded against OBSOLETE overwrite: if the inputs changed while the
    /// request was in flight (the fingerprint no longer matches), the stale result is DISCARDED (never
    /// overwrites current coverage) and nil is returned so the gate runs the pending-latest replacement.
    private func performCompute(for story: StoryModel, guide: StoryGuideDTO, guideFingerprint: String,
                                expectedFingerprint: String) async -> StoryCoverageV2DTO? {
        let intentDTO = CreativeIntentContractDTO(from: story)
        let intentValue: JSONValue = {
            guard let d = try? StoryContractCoding.encoder().encode(intentDTO) else { return .object([:]) }
            return JSONValue.object(fromJSONString: String(data: d, encoding: .utf8) ?? "{}")
        }()
        let guideValue: JSONValue = {
            guard let d = try? StoryContractCoding.encoder().encode(guide) else { return .object([:]) }
            return JSONValue.object(fromJSONString: String(data: d, encoding: .utf8) ?? "{}")
        }()
        var scope: [String: JSONValue] = [:]
        if let dur = story.intentTargetDurationSeconds { scope["target_duration_seconds"] = .number(dur) }
        let inputsAtStart = currentInputs(for: story)
        let request = StoryCoverageV2RequestDTO(
            storyId: story.id, storyGuide: guideValue, storyGuideVersion: guide.schemaVersion,
            creativeIntent: intentValue, scope: .object(scope),
            momentUnderstandings: inputsAtStart.completedMUValues, pendingCount: inputsAtStart.pendingCount)
        do {
            let dto = try await service.compute(request)
            // OBSOLETE-SKIP: inputs moved on during the call -> do NOT overwrite current coverage with a stale
            // result. The gate's pending-latest pass will recompute at the new fingerprint.
            let now = currentInputs(for: story)
            let nowFp = Self.sha256("\(now.sourceFingerprint)#\(now.intentFingerprint)#\(guideFingerprint)")
            guard nowFp == expectedFingerprint else { return nil }
            cache(dto, for: story.id, inputs: now, guideFingerprint: guideFingerprint)
            return dto
        } catch {
            return cachedCoverage(for: story.id)   // KEEP LAST VALID — never fabricate
        }
    }

    // MARK: - Current inputs

    struct CurrentInputs {
        let completedMUValues: [JSONValue]
        let sourceFingerprint: String
        let intentFingerprint: String
        let pendingCount: Int
    }

    func currentInputs(for story: StoryModel) -> CurrentInputs {
        let momentIds = Set(story.moments.map { $0.id })
        let allMUs = (try? context.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? []
        let completed = allMUs
            .filter { momentIds.contains($0.momentId) }
            .sorted { $0.momentId.uuidString < $1.momentId.uuidString }
        let completedIds = Set(completed.map { $0.momentId })
        let pendingCount = momentIds.subtracting(completedIds).count
        let muValues = completed.map { JSONValue.object(fromJSONString: $0.understandingJSON) }
        let sourceSeed = completed
            .map { "\($0.momentId.uuidString):\(Int($0.updatedAt.timeIntervalSince1970))" }
            .joined(separator: "|")
        return CurrentInputs(
            completedMUValues: muValues,
            sourceFingerprint: Self.sha256("\(sourceSeed)#p\(pendingCount)"),
            intentFingerprint: Self.sha256(intentFingerprintSeed(for: story)),
            pendingCount: pendingCount)
    }

    private func intentFingerprintSeed(for story: StoryModel) -> String {
        [
            story.intentRawText, story.intentSummary, story.intentSubject ?? "",
            story.intentDesiredFeeling.sorted().joined(separator: ","),
            story.intentStyleTags.sorted().joined(separator: ","),
            story.intentEmphasis.sorted().joined(separator: ","),
            story.intentConstraints.sorted().joined(separator: ","),
            story.intentPace ?? "",
            story.intentTargetDurationSeconds.map { String($0) } ?? "",
        ].joined(separator: "\u{1f}")
    }

    // MARK: - Cache (upsert, full replace)

    private func cache(_ dto: StoryCoverageV2DTO, for storyId: UUID, inputs: CurrentInputs, guideFingerprint: String) {
        let json = (try? StoryContractCoding.encoder().encode(dto))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        if let row = cachedModel(for: storyId) {
            row.coverageJSON = json
            row.sourceUnderstandingIdsFingerprint = inputs.sourceFingerprint
            row.creativeIntentFingerprint = inputs.intentFingerprint
            row.storyGuideFingerprint = guideFingerprint
            row.pendingCount = inputs.pendingCount
            row.schemaVersion = dto.schemaVersion
            row.promptVersion = "story_coverage/v2"
            row.updatedAt = .now
        } else {
            context.insert(StoryCoverageModel(
                storyId: storyId, coverageJSON: json,
                sourceUnderstandingIdsFingerprint: inputs.sourceFingerprint,
                creativeIntentFingerprint: inputs.intentFingerprint,
                pendingCount: inputs.pendingCount,
                storyGuideFingerprint: guideFingerprint,
                schemaVersion: dto.schemaVersion, modelId: nil, promptVersion: "story_coverage/v2"))
        }
        try? context.save()
    }

    private func cachedModel(for storyId: UUID) -> StoryCoverageModel? {
        var desc = FetchDescriptor<StoryCoverageModel>(predicate: #Predicate { $0.storyId == storyId })
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
