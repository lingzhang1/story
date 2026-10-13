import Foundation
import AVFoundation

// MultimodalVisualBudget — MVP ADAPTIVE VISUAL-EVIDENCE PREFLIGHT.
//
// Goal: PRESERVE multimodal visual reasoning whenever possible instead of silently dropping to text-only
// because the image payload would exceed provider limits. Before the planning request is sent, this computes
// a deterministic visual budget and builds contact sheets that fit the request-size ceiling — WITHOUT a model
// call, WITHOUT fabricating evidence, and WITHOUT ever dropping a source Moment from planning (A1 text is kept
// for every eligible Moment; only VISUAL coverage is reduced).
//
// Adaptation ladder (deterministic, cheapest-degradation first), applied until the payload fits:
//   1. Resize oversized sheets      (smaller cell side)
//   2. Compress JPEGs               (lower quality floor)
//   3. Remove redundant frames      (fewer frames per Moment)
//   4. Reduce frames per Moment      (toward the minimum)
//   5. Reduce whole-Moment visual coverage  (sheets only for the highest-value Moments; the rest go text-only)
//
// Frame allocation uses evidence ALREADY available (AU useful_segments count, events, clip duration) to spend
// the frame budget where footage is richest — no extra model pass. Moment IDs and timestamps are stable.

struct VisualBudgetLimits {
    /// Server backstop is 20 MB total / 1 MB per sheet (apps/api _MM_EDIT_MAX_*). The device aims BELOW that so
    /// the server never has to reject — leaving headroom for the JSON body + transport framing.
    var maxTotalImageBytes: Int = 16 * 1024 * 1024     // 16 MB device target (< 20 MB server ceiling)
    var maxSheetBytes: Int = 900 * 1024                // 900 KB/sheet device target (< 1 MB server ceiling)
    var maxSheets: Int = 120
    /// Degradation floors — never go below these before falling back to text-only for a Moment.
    var minCellSide: CGFloat = 200
    var minJpegQuality: CGFloat = 0.45
    var minFramesPerMoment: Int = 3
}

struct VisualBudgetInput {
    let momentId: UUID
    let url: URL
    let durationSeconds: Double
    let usefulSegmentCount: Int     // from AU observed.useful_segments (richness signal)
    let eventCount: Int             // from AU observed.events (richness signal)
}

/// What the preflight decided and produced, plus diagnostics (never includes image bytes/content).
struct VisualBudgetResult {
    let sheets: [MomentContactSheet]       // sheets that fit; order matches `sheetOrder`
    let sheetOrder: [UUID]                 // Moment ids, one per sheet, in sheets[] order
    let momentsWithImages: Int
    let momentsTextOnly: Int               // Moments planned with A1 text only (visual coverage reduced)
    let totalImageBytes: Int
    let selectedTier: String               // human-readable tier label for diagnostics
    let appliedSteps: [String]             // which ladder steps were applied
}

enum MultimodalVisualBudget {

    /// Build the largest visual payload that fits the limits, degrading deterministically. Returns the sheets
    /// to attach + the id order; Moments without a sheet are still planned (text-only A1) by the caller.
    static func build(_ inputs: [VisualBudgetInput],
                      limits: VisualBudgetLimits = VisualBudgetLimits()) async -> VisualBudgetResult {
        var applied: [String] = []

        // Rank Moments by visual richness so, if we must reduce COVERAGE (step 5), the richest keep images.
        let ranked = inputs.sorted { lhs, rhs in
            let l = richness(lhs), r = richness(rhs)
            if l != r { return l > r }
            return lhs.momentId.uuidString < rhs.momentId.uuidString   // stable tiebreak
        }

        // Tier knobs we will walk through (steps 1-4). Each tuple = (cell, quality, frameScale, label).
        // frameScale multiplies the Tier-1 duration-scaled frame count (then clamped to minFramesPerMoment).
        let tiers: [(cell: CGFloat, q: CGFloat, fscale: Double, label: String)] = [
            (320, 0.70, 1.00, "tier1"),
            (300, 0.65, 1.00, "tier1-resized"),
            (280, 0.58, 0.80, "tier1-compressed"),
            (240, 0.52, 0.60, "tier1-fewer-frames"),
            (limits.minCellSide, limits.minJpegQuality, 0.0, "tier1-min"),   // fscale 0 => minFramesPerMoment
        ]

        // Try each tier at FULL coverage; if even the smallest tier overflows, reduce coverage (step 5).
        for (ti, tier) in tiers.enumerated() {
            let sheets = await buildSheets(ranked, tier: tier, limits: limits)
            let total = sheets.reduce(0) { $0 + $1.jpeg.count }
            if ti >= 1 && !applied.contains("resize") { applied.append("resize") }
            if ti >= 2 && !applied.contains("compress") { applied.append("compress") }
            if ti >= 3 && !applied.contains("reduce-frames") { applied.append("reduce-frames") }
            if total <= limits.maxTotalImageBytes && sheets.count <= limits.maxSheets {
                return VisualBudgetResult(
                    sheets: sheets, sheetOrder: sheets.map { $0.momentId },
                    momentsWithImages: sheets.count, momentsTextOnly: inputs.count - sheets.count,
                    totalImageBytes: total, selectedTier: tier.label, appliedSteps: applied)
            }
        }

        // Step 5: smallest tier still overflows -> reduce COVERAGE. Keep the richest Moments' sheets until the
        // byte budget is hit; the rest plan text-only. A1 text still covers every Moment (caller's job).
        applied.append("reduce-coverage")
        let smallest = tiers.last!
        let allSheets = await buildSheets(ranked, tier: smallest, limits: limits)
        var kept: [MomentContactSheet] = []
        var running = 0
        for s in allSheets {   // allSheets is in richness order (ranked)
            if running + s.jpeg.count > limits.maxTotalImageBytes || kept.count >= limits.maxSheets { break }
            kept.append(s); running += s.jpeg.count
        }
        return VisualBudgetResult(
            sheets: kept, sheetOrder: kept.map { $0.momentId },
            momentsWithImages: kept.count, momentsTextOnly: inputs.count - kept.count,
            totalImageBytes: running, selectedTier: smallest.label + "+partial-coverage",
            appliedSteps: applied)
    }

    /// Build one sheet per input at the given tier, skipping any sheet that still exceeds the per-sheet cap
    /// after this tier's compression (that Moment degrades to text-only rather than busting the per-sheet
    /// limit). Never throws — a Moment whose frames can't be extracted is simply text-only.
    private static func buildSheets(_ inputs: [VisualBudgetInput],
                                    tier: (cell: CGFloat, q: CGFloat, fscale: Double, label: String),
                                    limits: VisualBudgetLimits) async -> [MomentContactSheet] {
        var out: [MomentContactSheet] = []
        for inp in inputs {
            let base = ContactSheetBudget.tier1(forDuration: inp.durationSeconds).framesPerMoment
            let frames = tier.fscale <= 0
                ? limits.minFramesPerMoment
                : max(limits.minFramesPerMoment, Int((Double(base) * tier.fscale).rounded()))
            var budget = ContactSheetBudget(framesPerMoment: frames)
            budget.cellLongestSide = tier.cell
            budget.jpegQuality = tier.q
            do {
                let sheet = try await MomentContactSheetBuilder.build(
                    momentId: inp.momentId, url: inp.url,
                    durationSeconds: inp.durationSeconds, budget: budget)
                if sheet.jpeg.count <= limits.maxSheetBytes {
                    out.append(sheet)
                }   // else: too big even at this tier -> text-only for this Moment
            } catch {
                continue   // frame extraction failed -> text-only for this Moment (never fabricate)
            }
        }
        return out
    }

    /// Visual richness heuristic from evidence ALREADY on hand (no model call): more useful segments / events
    /// / longer footage => more worth spending frames on. Pure, deterministic.
    private static func richness(_ i: VisualBudgetInput) -> Double {
        Double(i.usefulSegmentCount) * 2.0 + Double(i.eventCount) * 1.0 + min(i.durationSeconds / 30.0, 3.0)
    }
}
