import Foundation
import SwiftData
import CryptoKit

// MusicDirectionCoordinator — owns the MusicDirection LIFECYCLE (Milestone M-c).
//
//   CreativeIntent (+ Guide framing) -> MusicDirectionService.infer -> persist StoryMusicDirectionModel.
//
// Rules (M-c):
//   • Inferred ONCE when absent — covers new Stories AND legacy Stories created before MusicDirection
//     existed (identical path). Not regenerated as Moments arrive; does NOT read StoryCoverage.
//   • A user edit (`save(userEdit:)`) sets userAuthored=true and is NEVER overwritten by inference on
//     relaunch, migration, or Coverage recompute. `ensure` returns a user-authored direction untouched.
//   • Changing MusicDirection regenerates NOTHING (CreativeIntent/Guide/Coverage/MomentUnderstanding
//     are all independent). It only updates `fingerprint`, which a FUTURE MusicPlan cache compares to
//     decide its own staleness.
@MainActor
final class MusicDirectionCoordinator {
    private let context: ModelContext
    private let service: MusicDirectionInferring
    private var inferring = false

    init(context: ModelContext, service: MusicDirectionInferring = MusicDirectionService()) {
        self.context = context
        self.service = service
    }

    /// The persisted MusicDirection for a Story, decoded, or nil if none yet.
    func direction(for storyId: UUID) -> MusicDirectionContractDTO? {
        guard let row = model(for: storyId),
              let data = row.directionJSON.data(using: .utf8),
              let dto = try? StoryContractCoding.decoder().decode(MusicDirectionContractDTO.self, from: data)
        else { return nil }
        return dto
    }

    func isUserAuthored(for storyId: UUID) -> Bool { model(for: storyId)?.userAuthored ?? false }

    /// Fingerprint of the active direction (future MusicPlan staleness). Empty when none.
    func fingerprint(for storyId: UUID) -> String { model(for: storyId)?.fingerprint ?? "" }

    /// Infer + persist ONCE if absent. Covers new + legacy Stories. A user-authored direction is
    /// returned untouched (never re-inferred). Returns the direction in effect, or nil if inference
    /// failed (the Story stays valid; the row simply stays absent and can be retried).
    @discardableResult
    func ensure(for story: StoryModel, guideFramingSummary: String?) async -> MusicDirectionContractDTO? {
        if let existing = direction(for: story.id) { return existing } // includes any user-authored one
        if inferring { return nil }
        inferring = true
        defer { inferring = false }

        let intentDTO = CreativeIntentContractDTO(from: story)
        let intentValue: JSONValue = {
            guard let d = try? StoryContractCoding.encoder().encode(intentDTO) else { return .object([:]) }
            return JSONValue.object(fromJSONString: String(data: d, encoding: .utf8) ?? "{}")
        }()
        let request = MusicDirectionRequestDTO(creativeIntent: intentValue, guideFramingSummary: guideFramingSummary)
        do {
            let dto = try await service.infer(request)
            persist(dto, for: story.id, userAuthored: false)
            return dto
        } catch {
            return nil // inference unavailable: Story valid, direction retryable, NO fabrication
        }
    }

    /// Persist a USER-authored direction. Overrides inference permanently (userAuthored=true) and is
    /// never regenerated. Regenerates nothing else; only bumps the fingerprint.
    func save(userEdit dto: MusicDirectionContractDTO, for storyId: UUID) {
        persist(dto, for: storyId, userAuthored: true)
    }

    /// Remove the persisted direction so the next ensure() re-infers a fresh default
    /// ("Let Story choose"). Clears a user override deliberately — only called from that action.
    func clear(for storyId: UUID) {
        if let row = model(for: storyId) { context.delete(row); try? context.save() }
    }

    private func persist(_ dto: MusicDirectionContractDTO, for storyId: UUID, userAuthored: Bool) {
        let json = (try? StoryContractCoding.encoder().encode(dto))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let fp = Self.sha256(json)
        if let row = model(for: storyId) {
            // Never downgrade a user-authored row via inference.
            if row.userAuthored && !userAuthored { return }
            row.directionJSON = json
            row.userAuthored = userAuthored
            row.fingerprint = fp
            row.updatedAt = .now
        } else {
            context.insert(StoryMusicDirectionModel(
                storyId: storyId, directionJSON: json, userAuthored: userAuthored, fingerprint: fp))
        }
        try? context.save()
    }

    private func model(for storyId: UUID) -> StoryMusicDirectionModel? {
        var desc = FetchDescriptor<StoryMusicDirectionModel>(predicate: #Predicate { $0.storyId == storyId })
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
