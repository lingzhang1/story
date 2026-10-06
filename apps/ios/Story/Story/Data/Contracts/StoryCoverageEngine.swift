import Foundation
import SwiftData
import CryptoKit

// StoryCoverageEngine — the on-device orchestrator + cache lifecycle for Story
// Coverage (Milestone E, FROZEN).
//
// RESPONSIBILITY: given a Story, assemble the COMPACT text-only request (resolved
// CreativeIntent + scope + all COMPLETE MomentUnderstanding records + pending
// count), call the backend StoryCoverageEngine (Opus 4.6, original prompt) via
// StoryCoverageService, and cache the resulting snapshot in StoryCoverageModel.
//
// FROZEN behaviors:
//   - FULL RECOMPUTATION. No event sourcing, no incremental mutation, no Story
//     graph. A new snapshot REPLACES the old one wholesale (upsert by storyId).
//   - STALENESS from provenance: coverage is stale when the completed-MU set
//     (ids + updatedAt) OR the CreativeIntent changes. We never key anything on
//     a dimension id (snapshot-local handle only).
//   - KEEP LAST VALID: a failed recompute (503 / transport / decode) leaves the
//     cached row untouched and returns the previous coverage. Never fabricates.
//   - PENDING = UNKNOWN, not absent: pending Moments are counted (pendingCount),
//     excluded from the understood set, and the UX stays honest about uncertainty.
//   - COMPACT INPUT ONLY: never sends raw video/frames/Director history/
//     SceneUnderstanding/CaptureSessions — only the MomentUnderstanding JSON.
@MainActor
final class StoryCoverageEngine {
    private let context: ModelContext
    private let service: StoryCoverageComputing
    private let promptVersion = "story_coverage/v1"
    private let schemaVersion = "story_coverage/1"

    private var recomputing = false

    init(
        context: ModelContext,
        service: StoryCoverageComputing = StoryCoverageService()
    ) {
        self.context = context
        self.service = service
    }

    // MARK: - Read cached coverage (decoded)

    /// The latest cached snapshot for a Story, decoded, or nil if none exists.
    func cachedCoverage(for storyId: UUID) -> StoryCoverageDTO? {
        guard let row = cachedModel(for: storyId),
              let data = row.coverageJSON.data(using: .utf8),
              let dto = try? StoryContractCoding.decoder().decode(StoryCoverageDTO.self, from: data)
        else { return nil }
        return dto
    }

    /// Whether the cached snapshot (if any) is still current for the Story's
    /// present inputs. true when NO cache exists OR provenance no longer matches.
    func isStale(for story: StoryModel) -> Bool {
        guard let row = cachedModel(for: story.id) else { return true }
        let inputs = currentInputs(for: story)
        return row.sourceUnderstandingIdsFingerprint != inputs.sourceFingerprint
            || row.creativeIntentFingerprint != inputs.intentFingerprint
    }

    // MARK: - Opportunistic recompute

    /// Recompute coverage for a Story IF stale (or forced). Non-blocking semantics:
    /// callers fire-and-forget (`Task { await ... }`). On success caches the new
    /// snapshot; on failure keeps the previous valid cache. Returns the coverage in
    /// effect after the call (new on success, previous on failure, nil if neither).
    @discardableResult
    func recomputeIfNeeded(for story: StoryModel, force: Bool = false) async -> StoryCoverageDTO? {
        if recomputing { return cachedCoverage(for: story.id) }
        if !force && !isStale(for: story) { return cachedCoverage(for: story.id) }

        recomputing = true
        defer { recomputing = false }

        let inputs = currentInputs(for: story)

        // Build the compact request. CreativeIntent + scope + completed MU JSON only.
        let intentDTO = CreativeIntentContractDTO(from: story)
        let intentValue: JSONValue = {
            guard let d = try? StoryContractCoding.encoder().encode(intentDTO) else { return .object([:]) }
            return JSONValue.object(fromJSONString: String(data: d, encoding: .utf8) ?? "{}")
        }()
        var scope: [String: JSONValue] = [:]
        if let dur = story.intentTargetDurationSeconds { scope["target_duration_seconds"] = .number(dur) }

        let request = StoryCoverageRequestDTO(
            storyId: story.id,
            creativeIntent: intentValue,
            scope: .object(scope),
            momentUnderstandings: inputs.completedMUValues,
            pendingCount: inputs.pendingCount
        )

        do {
            let dto = try await service.compute(request)
            cache(dto, for: story.id, inputs: inputs)
            return dto
        } catch {
            // KEEP LAST VALID — never fabricate, never clear the cache on failure.
            return cachedCoverage(for: story.id)
        }
    }

    // MARK: - Current inputs (completed MU set + pending count + fingerprints)

    struct CurrentInputs {
        let completedMUValues: [JSONValue]
        let sourceFingerprint: String
        let intentFingerprint: String
        let pendingCount: Int
    }

    /// Assemble the Story's CURRENT coverage inputs from local persistence:
    ///   - completed MomentUnderstanding records (one per Moment, upserted by AU);
    ///   - pending_count = Moments of this Story that have NO completed understanding yet;
    ///   - provenance fingerprints for staleness.
    func currentInputs(for story: StoryModel) -> CurrentInputs {
        let momentIds = Set(story.moments.map { $0.id })

        // Completed understandings for THIS Story's Moments.
        let allMUs = (try? context.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? []
        let completed = allMUs
            .filter { momentIds.contains($0.momentId) }
            .sorted { $0.momentId.uuidString < $1.momentId.uuidString }

        let completedIds = Set(completed.map { $0.momentId })
        let pendingCount = momentIds.subtracting(completedIds).count

        // Pass each understanding JSON through verbatim (it already carries
        // moment_id + observed + story_context in the frozen wire shape).
        let muValues = completed.map { JSONValue.object(fromJSONString: $0.understandingJSON) }

        // Source fingerprint: sorted (momentId, updatedAt) pairs of the completed set.
        let sourceSeed = completed
            .map { "\($0.momentId.uuidString):\(Int($0.updatedAt.timeIntervalSince1970))" }
            .joined(separator: "|")
        let intentSeed = intentFingerprintSeed(for: story)

        return CurrentInputs(
            completedMUValues: muValues,
            sourceFingerprint: Self.sha256("\(sourceSeed)#p\(pendingCount)"),
            intentFingerprint: Self.sha256(intentSeed),
            pendingCount: pendingCount
        )
    }

    private func intentFingerprintSeed(for story: StoryModel) -> String {
        // Stable, order-insensitive seed of the resolved CreativeIntent fields.
        [
            story.intentRawText,
            story.intentSummary,
            story.intentSubject ?? "",
            story.intentDesiredFeeling.sorted().joined(separator: ","),
            story.intentStyleTags.sorted().joined(separator: ","),
            story.intentEmphasis.sorted().joined(separator: ","),
            story.intentConstraints.sorted().joined(separator: ","),
            story.intentPace ?? "",
            story.intentTargetDurationSeconds.map { String($0) } ?? "",
        ].joined(separator: "\u{1f}")
    }

    // MARK: - Cache (upsert, full replace)

    private func cache(_ dto: StoryCoverageDTO, for storyId: UUID, inputs: CurrentInputs) {
        let json = (try? StoryContractCoding.encoder().encode(dto))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        if let row = cachedModel(for: storyId) {
            row.coverageJSON = json
            row.sourceUnderstandingIdsFingerprint = inputs.sourceFingerprint
            row.creativeIntentFingerprint = inputs.intentFingerprint
            row.pendingCount = inputs.pendingCount
            row.schemaVersion = dto.schemaVersion
            row.promptVersion = promptVersion
            row.updatedAt = .now
        } else {
            context.insert(StoryCoverageModel(
                storyId: storyId,
                coverageJSON: json,
                sourceUnderstandingIdsFingerprint: inputs.sourceFingerprint,
                creativeIntentFingerprint: inputs.intentFingerprint,
                pendingCount: inputs.pendingCount,
                schemaVersion: dto.schemaVersion,
                modelId: nil,
                promptVersion: promptVersion
            ))
        }
        try? context.save()
    }

    private func cachedModel(for storyId: UUID) -> StoryCoverageModel? {
        var desc = FetchDescriptor<StoryCoverageModel>(
            predicate: #Predicate { $0.storyId == storyId }
        )
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first
    }

    private static func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
