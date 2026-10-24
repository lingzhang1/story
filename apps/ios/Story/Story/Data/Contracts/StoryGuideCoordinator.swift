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
    private let refineService: StoryGuideRefining
    private var generating = false

    init(context: ModelContext, service: StoryGuideGenerating = StoryGuideService(),
         v2Service: StoryGuideV2Generating = StoryGuideV2Service(),
         refineService: StoryGuideRefining = StoryGuideRefineService()) {
        self.context = context
        self.service = service
        self.v2Service = v2Service
        self.refineService = refineService
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

    // MARK: - StoryGuide/2 REFINEMENT ("Update Guide", Guide v2.1)

    /// The result of a refinement, for the UI to surface a short summary ("2 added, 1 archived").
    struct RefinementOutcome {
        let guide: StoryGuideV2DTO
        let changes: [SceneChangeDTO]
        let archivedSceneIds: [String]
    }

    enum RefineError: Error { case unavailable, noGuide, duplicate }

    /// Pinned scene ids for a Story (user-protected; refinement may never archive/rewrite them).
    func pinnedSceneIds(for storyId: UUID) -> [String] {
        let desc = FetchDescriptor<StoryScenePinModel>(predicate: #Predicate { $0.storyId == storyId })
        return ((try? context.fetch(desc)) ?? []).map { $0.sceneId }
    }

    func isPinned(storyId: UUID, sceneId: String) -> Bool {
        let key = "\(storyId.uuidString)#\(sceneId)"
        var desc = FetchDescriptor<StoryScenePinModel>(predicate: #Predicate { $0.key == key })
        desc.fetchLimit = 1
        return ((try? context.fetch(desc)) ?? []).first != nil
    }

    /// Toggle a scene pin. Pins are durable user decisions; marks the Story dirty for R7 sync.
    @discardableResult
    func togglePin(storyId: UUID, sceneId: String) -> Bool {
        let key = "\(storyId.uuidString)#\(sceneId)"
        var desc = FetchDescriptor<StoryScenePinModel>(predicate: #Predicate { $0.key == key })
        desc.fetchLimit = 1
        if let existing = ((try? context.fetch(desc)) ?? []).first {
            context.delete(existing)
            try? context.save()
            return false
        } else {
            context.insert(StoryScenePinModel(storyId: storyId, sceneId: sceneId))
            try? context.save()
            return true
        }
    }

    /// Captured scene ids: scenes with real Coverage evidence (a strong/looking_good state, OR any represented
    /// possibility / evidence moment). DERIVED — a captured scene is one the footage already serves, so a
    /// refinement must never archive it. Reads the Story's persisted Coverage/2 snapshot; empty when none.
    func capturedSceneIds(for storyId: UUID) -> [String] {
        guard let cov = coverageV2(for: storyId) else { return [] }
        var ids: [String] = []
        for d in cov.dimensionCoverage {
            let hasEvidence = !d.evidenceMomentIds.isEmpty || !d.representedPossibilityIds.isEmpty
            let represented = (d.state == .strong || d.state == .lookingGood)
            if hasEvidence || represented { ids.append(d.storyGuideDimensionId) }
        }
        return ids
    }

    private func coverageV2(for storyId: UUID) -> StoryCoverageV2DTO? {
        var desc = FetchDescriptor<StoryCoverageModel>(predicate: #Predicate { $0.storyId == storyId })
        desc.fetchLimit = 1
        guard let row = (try? context.fetch(desc))?.first,
              let data = row.coverageJSON.data(using: .utf8),
              let dto = try? StoryContractCoding.decoder().decode(StoryCoverageV2DTO.self, from: data)
        else { return nil }
        return dto
    }

    /// The last refinement input fingerprint (dedupe guard) persisted on the guide row's promptVersion suffix is
    /// avoided; instead we cache it in a lightweight in-memory + guide-hash check. A repeated identical update on
    /// an unchanged guide is a no-op (req 6: no duplicate inference for unchanged inputs).
    private var lastRefineFingerprint: [UUID: String] = [:]

    private static func refineFingerprint(guideJSON: String, instruction: String, eventContext: String,
                                          captured: [String], pinned: [String]) -> String {
        let parts = [guideJSON, instruction, eventContext,
                     captured.sorted().joined(separator: ","), pinned.sorted().joined(separator: ",")]
        return sha256(parts.joined(separator: "\u{1}"))
    }

    /// Refine (Update Guide) the v2 shooting script with a user instruction and/or the persistent event context.
    /// ASYNC + non-destructive: the CURRENT guide stays in place until a valid refined guide replaces it, so a
    /// failure (unavailable / 404 / 503) LEAVES the existing Guide untouched and throws `.unavailable` for a
    /// recoverable error. Dedupes identical inputs (`.duplicate`) so repeated taps don't re-infer. Captured +
    /// pinned scenes are passed as protected ids; the server enforces preservation, and persistV2 marks the row
    /// dirty for R7 sync (history: archived ids come back in the outcome).
    @discardableResult
    func refineGuideV2(for story: StoryModel, instruction: String?) async throws -> RefinementOutcome {
        guard let current = guideV2(for: story.id) else { throw RefineError.noGuide }
        if generating { throw RefineError.unavailable }

        let instr = (instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let eventCtx = (story.eventContext ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let captured = capturedSceneIds(for: story.id)
        let pinned = pinnedSceneIds(for: story.id)
        let currentJSON = guideModel(for: story.id)?.guideJSON ?? "{}"
        let fp = Self.refineFingerprint(guideJSON: currentJSON, instruction: instr, eventContext: eventCtx,
                                        captured: captured, pinned: pinned)
        // Dedupe: identical (guide + instruction + context + protected-ids) => no inference.
        if lastRefineFingerprint[story.id] == fp && instr.isEmpty {
            throw RefineError.duplicate
        }

        generating = true
        defer { generating = false }

        let intentDTO = CreativeIntentContractDTO(from: story)
        let intentValue: JSONValue = {
            guard let d = try? StoryContractCoding.encoder().encode(intentDTO) else { return .object([:]) }
            return JSONValue.object(fromJSONString: String(data: d, encoding: .utf8) ?? "{}")
        }()
        var scope: [String: JSONValue] = [:]
        if let dur = story.intentTargetDurationSeconds { scope["target_duration_seconds"] = .number(dur) }

        // Compact current scenes for the request (id + the four prose fields the model reasons over).
        let sceneValues: [JSONValue] = current.scenes.map { s in
            .object(["id": .string(s.id), "title": .string(s.title),
                     "what_to_capture": .string(s.whatToCapture),
                     "how_to_shoot": .string(s.howToShoot),
                     "why_it_matters": .string(s.whyItMatters)])
        }

        let request = StoryGuideRefineRequestDTO(
            storyId: story.id, creativeIntent: intentValue, scope: .object(scope),
            currentFramingSummary: current.framingSummary, currentScenes: sceneValues,
            capturedSceneIds: captured, pinnedSceneIds: pinned,
            userInstruction: instr.isEmpty ? nil : instr,
            eventContext: eventCtx.isEmpty ? nil : eventCtx,
            sourceCreativeIntentVersion: nil)

        do {
            let result = try await refineService.refine(request)
            // Only now replace the persisted guide (the current one survived until a valid result arrived).
            persistV2(result.guide, for: story.id)
            lastRefineFingerprint[story.id] = fp
            return RefinementOutcome(guide: result.guide, changes: result.changes,
                                     archivedSceneIds: result.archivedSceneIds)
        } catch {
            // Current Guide is untouched; surface a recoverable error.
            throw RefineError.unavailable
        }
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
