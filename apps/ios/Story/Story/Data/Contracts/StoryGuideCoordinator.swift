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
    private let v2Service: StoryGuideV2Generating
    private var generating = false

    init(context: ModelContext, service: StoryGuideGenerating = StoryGuideService(),
         v2Service: StoryGuideV2Generating = StoryGuideV2Service()) {
        self.context = context
        self.service = service
        self.v2Service = v2Service
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

    // MARK: - StoryGuide/2 (AI shooting script) — additive, version-aware

    /// The persisted v2 shooting script for a Story, decoded, or nil if the stored Guide is not v2 (or none).
    /// Reads the SAME StoryGuideModel row (version-agnostic storage) and decodes it as v2 only when its
    /// schema_version is story_guide/2 — so a v1 row never mis-decodes as a scene list.
    func guideV2(for storyId: UUID) -> StoryGuideV2DTO? {
        guard let row = guideModel(for: storyId),
              row.schemaVersion == "story_guide/2",
              let data = row.guideJSON.data(using: .utf8),
              let dto = try? StoryContractCoding.decoder().decode(StoryGuideV2DTO.self, from: data)
        else { return nil }
        return dto
    }

    /// Whether this Story already has a persisted v2 shooting script.
    func hasGuideV2(for storyId: UUID) -> Bool {
        guideModel(for: storyId)?.schemaVersion == "story_guide/2"
    }

    /// Generate + persist the v2 shooting script ONCE if absent (same semantics as ensureGuide). Preserves a
    /// COMPATIBLE existing v2 result (no repeated inference) and does NOT overwrite a usable synced Guide.
    /// On failure (incl. the backend route being gated off -> 404 -> unavailable) returns nil and leaves the
    /// Story valid + retryable — NEVER fabricates. The caller falls back to the v1 path when this returns nil
    /// and no v2 row exists.
    @discardableResult
    func ensureGuideV2(for story: StoryModel) async -> StoryGuideV2DTO? {
        if let existing = guideV2(for: story.id) { return existing }
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
            let dto = try await v2Service.generate(request)
            persistV2(dto, for: story.id)
            return dto
        } catch {
            return nil
        }
    }

    private func persistV2(_ dto: StoryGuideV2DTO, for storyId: UUID) {
        let json = (try? StoryContractCoding.encoder().encode(dto))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        if let row = guideModel(for: storyId) {
            row.guideJSON = json
            row.schemaVersion = dto.schemaVersion   // flips the row to story_guide/2
            row.promptVersion = "story_guide/v2"
            row.updatedAt = .now
        } else {
            context.insert(StoryGuideModel(storyId: storyId, guideJSON: json,
                                           schemaVersion: dto.schemaVersion, promptVersion: "story_guide/v2"))
        }
        try? context.save()
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
