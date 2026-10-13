import Foundation
import AVFoundation
import UIKit

// MomentContactSheetBuilder — MVP MULTIMODAL (Tier-1 contact sheets).
//
// From ONE local Moment video, build a SINGLE tiled "contact-sheet" JPEG: a small grid of timestamped frames
// with the Moment id and each frame's source timestamp burned in. One sheet per Moment keeps the planner's
// Converse request within provider input limits (per-frame image blocks overflowed at 36+ Moments in the
// experiment — "Input is too long"); the tiled sheet is the faithful Tier-1 representation the Short-Form /
// A0-A1-B experiments validated.
//
// Derived evidence ONLY: the original video never leaves the device, and the sheet is handed to the
// multimodal planning request and then discarded (no frame store, no persistence). Deterministic given the
// same input + budget. All work is local AVFoundation + UIKit.

struct MomentContactSheet {
    let momentId: UUID
    let jpeg: Data
    let frameCount: Int
}

enum ContactSheetError: Error, LocalizedError {
    case noFrames
    case encodeFailed
    var errorDescription: String? {
        switch self {
        case .noFrames: return "No frames could be extracted for the contact sheet."
        case .encodeFailed: return "The contact sheet could not be encoded."
        }
    }
}

/// Deterministic per-sheet budget. The adaptive preflight (MultimodalVisualBudget) chooses these knobs; the
/// builder just honors them. Defaults match the experiment's Tier-1 policy (duration-scaled 4..9 frames,
/// 3 columns, ~320px cells, JPEG 0.7).
struct ContactSheetBudget {
    var framesPerMoment: Int          // target frames to sample for this Moment (clamped 1...24)
    var columns: Int = 3
    var cellLongestSide: CGFloat = 320
    var jpegQuality: CGFloat = 0.7

    /// Experiment Tier-1 default: max(4, min(9, round(duration/8))).
    static func tier1(forDuration dur: Double) -> ContactSheetBudget {
        let n = max(4, min(9, Int((dur / 8.0).rounded())))
        return ContactSheetBudget(framesPerMoment: n)
    }
}

struct MomentContactSheetBuilder {

    /// Build one tiled contact-sheet JPEG for a Moment video. Reuses MomentFrameExtractor's ordered,
    /// timestamped frames, then evenly subsamples to `budget.framesPerMoment` and tiles them.
    static func build(momentId: UUID, url: URL, durationSeconds: Double,
                      budget: ContactSheetBudget) async throws -> MomentContactSheet {
        // Reuse the frozen 24-frame extractor, then pick an evenly-spaced subset (never MORE than extracted).
        let all = try await MomentFrameExtractor.extract(from: url)
        guard !all.isEmpty else { throw ContactSheetError.noFrames }
        let want = max(1, min(budget.framesPerMoment, all.count))
        let picked = evenlySubsample(all, count: want)
        guard let jpeg = tile(frames: picked, momentId: momentId, durationSeconds: durationSeconds,
                              budget: budget) else { throw ContactSheetError.encodeFailed }
        return MomentContactSheet(momentId: momentId, jpeg: jpeg, frameCount: picked.count)
    }

    /// Pick `count` evenly-spaced frames from an ordered list (keeps first and last).
    static func evenlySubsample(_ frames: [AUExtractedFrame], count: Int) -> [AUExtractedFrame] {
        let n = frames.count
        if count >= n { return frames }
        if count <= 1 { return [frames[0]] }
        var out: [AUExtractedFrame] = []
        for i in 0..<count {
            let idx = Int((Double(i) / Double(count - 1) * Double(n - 1)).rounded())
            out.append(frames[min(idx, n - 1)])
        }
        // de-dup indices that collapsed to the same timestamp
        var seen = Set<Int>(); var deduped: [AUExtractedFrame] = []
        for f in out where !seen.contains(f.tMs) {
            seen.insert(f.tMs); deduped.append(f)
        }
        return deduped.isEmpty ? [frames[0]] : deduped
    }

    /// Tile frames into one labeled JPEG. Header = "Moment <id>  dur=Xs (N frames)"; each cell labeled with
    /// its source timestamp. Dark background so burned-in text is legible regardless of footage.
    private static func tile(frames: [AUExtractedFrame], momentId: UUID, durationSeconds: Double,
                             budget: ContactSheetBudget) -> Data? {
        let imgs: [(UIImage, Int)] = frames.compactMap { f in
            UIImage(data: f.jpeg).map { ($0, f.tMs) }
        }
        guard !imgs.isEmpty else { return nil }

        let cols = max(1, budget.columns)
        let cell = budget.cellLongestSide
        // Scale each frame so its longest side == cell.
        let scaled: [(UIImage, Int)] = imgs.map { (im, tms) in
            let s = im.size
            let longest = Swift.max(s.width, s.height)
            let factor = longest > 0 ? cell / longest : 1
            let newSize = CGSize(width: s.width * factor, height: s.height * factor)
            let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
            let r = UIGraphicsImageRenderer(size: newSize, format: fmt)
            let out = r.image { _ in im.draw(in: CGRect(origin: .zero, size: newSize)) }
            return (out, tms)
        }
        let maxCellH = scaled.map { $0.0.size.height }.max() ?? cell
        let rows = (scaled.count + cols - 1) / cols
        let headH: CGFloat = 26
        let labelH: CGFloat = 18
        let sheetW = CGFloat(cols) * cell
        let sheetH = headH + CGFloat(rows) * (maxCellH + labelH)

        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: sheetW, height: sheetH), format: fmt)
        let data = renderer.jpegData(withCompressionQuality: budget.jpegQuality) { ctx in
            UIColor(white: 0.07, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
            let head = "Moment \(momentId.uuidString.lowercased())  dur=\(String(format: "%.1f", durationSeconds))s  (\(scaled.count) frames)"
            draw(text: head, at: CGPoint(x: 6, y: 5),
                 font: .boldSystemFont(ofSize: 14), color: UIColor(white: 0.92, alpha: 1))
            for (i, item) in scaled.enumerated() {
                let (im, tms) = item
                let rr = i / cols, cc = i % cols
                let x = CGFloat(cc) * cell
                let y = headH + CGFloat(rr) * (maxCellH + labelH)
                im.draw(in: CGRect(x: x, y: y, width: im.size.width, height: im.size.height))
                draw(text: "t=\(String(format: "%.1f", Double(tms) / 1000.0))s",
                     at: CGPoint(x: x + 4, y: y + im.size.height + 1),
                     font: .systemFont(ofSize: 12), color: UIColor(red: 0.47, green: 0.86, blue: 1, alpha: 1))
            }
        }
        return data
    }

    private static func draw(text: String, at p: CGPoint, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: p, withAttributes: attrs)
    }
}
