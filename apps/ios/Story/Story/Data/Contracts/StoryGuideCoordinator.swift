import Foundation
import SwiftData
import CryptoKit

// StoryGuideCoordinator — owns the StoryGuide LIFECYCLE (E2-c, separate domain from Coverage).
//
// Responsibility (do NOT fold into StoryCoverageEngine):
//   CreativeIntent -> StoryGuideService.generate -> persist StoryGuideModel (canonical ids inside).
// Generated ONCE per Story (one active version, MVP). Coverage READS the persisted Guide; it never
// generates it. Guide generation failure leaves the Story valid and the Guide retryable — NEVER a
// fabricated generic Guide.
//
// Existing-Story migration: a Story with CreativeIntent but no Guide gets a Guide generated ONCE from
// its CreativeIntent (NOT from old Coverage/1 dimensions), persisted; Coverage/2 then recomputes from
// existing completed MomentUnderstanding. No Story recreation required.
@MainActor
final class StoryGuideCoordinator {
    private let context: ModelContext
    private let service: StoryGuideGenerating
    private var generating = false

    init(context: ModelContext, service: StoryGuideGenerating = StoryGuideService()) {
        self.context = context
        self.service = service
    }

    /// The persisted Guide for a Story, decoded, or nil if none exists yet.
    func guide(for storyId: UUID) -> StoryGuideDTO? {
        guard let row = guideModel(for: storyId),
              let data = row.guideJSON.data(using: .utf8),
              let dto = try? StoryContractCoding.decoder().decode(StoryGuideDTO.self, from: data)
        else { return nil }
        return dto
    }

    /// Whether this Story already has a persisted Guide.
    func hasGuide(for storyId: UUID) -> Bool { guideModel(for: storyId) != nil }

    /// Fingerprint of the active Guide (for Coverage staleness). Empty when no Guide.
    func guideFingerprint(for storyId: UUID) -> String {
        guard let row = guideModel(for: storyId) else { return "" }
        return Self.sha256("\(row.schemaVersion)#\(row.guideJSON.count)#\(Int(row.updatedAt.timeIntervalSince1970))")
    }

    /// Generate + persist the Guide ONCE if absent. Covers BOTH new-Story creation and existing-Story
    /// migration (identical path: CreativeIntent -> Guide). Fire-and-forget; returns the Guide in
    /// effect (existing or newly generated), or nil if generation failed (Story stays valid).
    @discardableResult
    func ensureGuide(for story: StoryModel) async -> StoryGuideDTO? {
        if let existing = guide(for: story.id) { return existing }
        // Issue 4: do NOT generate a Guide while the Story is hydrating from the cloud — a verified cloud Guide
        // may be about to be restored (restore first, regenerate only if genuinely missing). The barrier is
        // seeded from the durable hydrationPending rows, so a view that opens before the pull completes (or
        // after a relaunch) still holds here instead of racing in a fresh local guide. Returns nil (neutral,
        // retryable) — the Story stays valid and the view re-queries once hydration ends.
        if CloudHydrationGate.shared.isHydratingAfterSeed(storyId: story.id, context: context) { return nil }
        if generating { return nil }
        generating = true
        defer { generating = false }

        let intentDTO = CreativeIntentContractDTO(from: story)
        let intentValue: JSONValue = {
            guard let d = try? StoryContractCoding.encoder().encode(intentDTO) else { return .object([:]) }
            return JSONValue.object(fromJSONString: String(data: d, encoding: .utf8) ?? "{}")
        }()
        var scope: [String: JSONValue] = [:]
        if let dur = story.intentTargetDurationSeconds { scope["target_duration_seconds"] = .number(dur) }

        let request = StoryGuideRequestDTO(
            storyId: story.id, creativeIntent: intentValue, scope: .object(scope),
            sourceCreativeIntentVersion: nil)
        do {
            let dto = try await service.generate(request)
            persist(dto, for: story.id)
            return dto
        } catch {
            // Guide unavailable: Story remains valid, Guide retryable, NO fabrication.
            return nil
        }
    }

    private func persist(_ dto: StoryGuideDTO, for storyId: UUID) {
        let json = (try? StoryContractCoding.encoder().encode(dto))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        if let row = guideModel(for: storyId) {
            row.guideJSON = json
            row.schemaVersion = dto.schemaVersion
            row.updatedAt = .now
        } else {
            context.insert(StoryGuideModel(storyId: storyId, guideJSON: json, schemaVersion: dto.schemaVersion))
        }
        try? context.save()
    }

    private func guideModel(for storyId: UUID) -> StoryGuideModel? {
        var desc = FetchDescriptor<StoryGuideModel>(predicate: #Predicate { $0.storyId == storyId })
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
