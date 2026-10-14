import Foundation

// RevisionContextBuilder — Creative Revision Foundation (Create Another Version / Explore).
//
// Pure, model-free. Derives the bounded, version-aware `revision_context` JSON that the planner injects into
// its USER message (frozen v5.2 system body + EditPlan/2 output UNCHANGED), and the deterministic diversity
// diagnostics that decide whether an Explore alternative is MEANINGFULLY different from its parent.
//
// Source of truth = the parent chain's PERSISTED `editPlanJSON` (the exact executable plan the renderer
// consumed). For Explore we send COMPACT SUMMARIES (not full plans): per prior version — selected moment ids
// in order, opening + ending moment, and the shot-duration distribution. Bounded to a small number of recent
// versions so the request stays small.
enum RevisionContextBuilder {

    static let maxSummaries = 4

    /// A compact, bounded summary of one GeneratedOutput's edit, derived from its persisted editPlanJSON.
    /// Returns nil when the output has no decodable plan (legacy/mock outputs) — such a version simply does
    /// not contribute a summary (never fabricated).
    static func summary(of output: GeneratedOutputModel) -> JSONValue? {
        guard let json = output.editPlanJSON, let data = json.data(using: .utf8),
              let plan = try? StoryContractCoding.decoder().decode(EditPlanV2.self, from: data) else {
            return nil
        }
        let ordered = plan.segments.sorted { $0.order < $1.order }
        let seq: [JSONValue] = ordered.map { .object([
            "asset_id": .string($0.assetId),
            "output_duration_seconds": .number($0.outputDurationSeconds),
        ]) }
        let durations = ordered.map { $0.outputDurationSeconds }
        var obj: [String: JSONValue] = [
            "version_id": .string((output.versionId ?? output.id).uuidString),
            "segments": .array(seq),
            "shot_count": .number(Double(ordered.count)),
        ]
        if let first = ordered.first { obj["opening_moment_id"] = .string(first.assetId) }
        if let last = ordered.last { obj["ending_moment_id"] = .string(last.assetId) }
        if !durations.isEmpty {
            obj["shot_duration_min"] = .number(durations.min() ?? 0)
            obj["shot_duration_max"] = .number(durations.max() ?? 0)
            obj["shot_duration_median"] = .number(median(durations))
        }
        return .object(obj)
    }

    /// Build the EXPLORE `revision_context` for a deliberate alternative version.
    ///   - parent: the version the user SELECTED to work from (lineage anchor).
    ///   - recents: other recent versions of THIS Story to also summarize (bounded). The parent's own lineage,
    ///     not an unrelated sibling, is the anchor; `recents` is advisory "what else has been tried" context.
    /// Returns nil when the parent has no decodable plan (we still re-plan, just without prior-edit evidence).
    static func explore(parent: GeneratedOutputModel, recents: [GeneratedOutputModel]) -> JSONValue? {
        guard let parentSummary = summary(of: parent) else { return nil }
        var summaries: [JSONValue] = [parentSummary]
        let parentVid = (parent.versionId ?? parent.id)
        for o in recents where (o.versionId ?? o.id) != parentVid {
            if summaries.count >= maxSummaries { break }
            if let s = summary(of: o) { summaries.append(s) }
        }
        return .object([
            "mode": .string("explore"),
            "base_version_id": .string(parentVid.uuidString),
            "prior_edit_summaries": .array(summaries),
        ])
    }

    // MARK: - Diversity diagnostics (deterministic; mirrors the backend diversity_diagnostics)

    struct Diversity: Equatable {
        let momentSetJaccard: Double
        let openingChanged: Bool
        let endingChanged: Bool
        let orderChanged: Bool
        let shotCountDelta: Int
        /// Coarse "basically the same edit" flag — the result the owner forbids saving as a creative alternative.
        let nearIdentical: Bool
    }

    /// Compare a NEW plan against the PARENT output's edit. Used to decide whether an Explore alternative is
    /// meaningfully different (NOT to auto-accept — human judgment decides worth; this flags near-identical).
    static func diversity(parent: GeneratedOutputModel, newPlan: EditPlanV2) -> Diversity {
        let pseq = momentSequence(of: parent)
        let nseq = newPlan.segments.sorted { $0.order < $1.order }.map { $0.assetId }
        let pset = Set(pseq), nset = Set(nseq)
        let union = pset.union(nset)
        let jaccard = union.isEmpty ? 1.0 : Double(pset.intersection(nset).count) / Double(union.count)
        let openingChanged = pseq.first != nseq.first
        let endingChanged = pseq.last != nseq.last
        let shared = pset.intersection(nset)
        let pShared = pseq.filter { shared.contains($0) }
        let nShared = nseq.filter { shared.contains($0) }
        let orderChanged = pShared != nShared
        let nearIdentical = jaccard >= 0.999 && !openingChanged && !endingChanged && !orderChanged
        return Diversity(momentSetJaccard: (jaccard * 10000).rounded() / 10000,
                         openingChanged: openingChanged, endingChanged: endingChanged,
                         orderChanged: orderChanged, shotCountDelta: nseq.count - pseq.count,
                         nearIdentical: nearIdentical)
    }

    // MARK: - Helpers

    private static func momentSequence(of output: GeneratedOutputModel) -> [String] {
        guard let json = output.editPlanJSON, let data = json.data(using: .utf8),
              let plan = try? StoryContractCoding.decoder().decode(EditPlanV2.self, from: data) else {
            // Fall back to the recorded source moment ids (unordered best-effort) when no plan is stored.
            return (output.sourceMomentIds.isEmpty ? output.momentIds : output.sourceMomentIds).map { $0.uuidString }
        }
        return plan.segments.sorted { $0.order < $1.order }.map { $0.assetId }
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2
    }
}
