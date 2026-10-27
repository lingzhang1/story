import Foundation

// EvidenceFrameMapper — DETERMINISTIC device-side port of packages/evidence_mapper (P1-F §7).
//
// Picks WHICH cached sampled frames a per-Video-Type contact sheet should contain. Same algorithm as the
// Python mapper (kept in lockstep): distinct-first round-robin across candidates (never confidence-collapse),
// representative-first context (region center, then setup/aftermath, peak last — ADVISORY), whole-Moment
// overview floor, uniform full-budget fallback when there are no candidates. Changes frame RELEVANCE, not
// count: returns a subset within the existing per-Moment budget. Candidate peaks/intervals are advisory;
// sampled timestamps are provenance only; the model `evidence` string is never consulted.

enum EvidenceVideoType { case highlights, fullStory }

struct EvidenceCandidate {
    let start: Double      // seconds
    let end: Double
    let peak: Double?
    let confidence: Double?
}

enum EvidenceFrameMapper {
    static let contextPadSeconds = 1.5

    /// Return chosen sampled-frame INDICES (ascending, de-duplicated, <= budget).
    static func selectFrames(videoType: EvidenceVideoType,
                             sampledFrameMs: [Int],
                             visualCandidates: [EvidenceCandidate],
                             narrativeCandidates: [EvidenceCandidate],
                             eventTimesS: [Double],
                             budget: Int) -> [Int] {
        let n = sampledFrameMs.count
        if n == 0 || budget <= 0 { return [] }
        if budget >= n { return Array(0..<n) }

        var cands = (videoType == .highlights) ? visualCandidates : narrativeCandidates
        if videoType == .fullStory {
            for t in eventTimesS { cands.append(EvidenceCandidate(start: t, end: t, peak: nil, confidence: nil)) }
        }

        // overview floor — full budget when no candidates (clean uniform), else ~half to leave room.
        let overviewK = cands.isEmpty ? budget : max(2, min(budget / 2 + 1, budget))
        var chosen: [Int] = overviewIndices(n: n, k: overviewK)

        // distinct-first round-robin over representative-first context lists.
        let ranked = rankCandidates(cands)
        let ctxLists = ranked.map { contextIndices(sampledFrameMs: sampledFrameMs, c: $0) }
        var cursors = [Int](repeating: 0, count: ctxLists.count)
        var progressed = true
        func count() -> Int { Set(chosen).count }
        while count() < budget && progressed {
            progressed = false
            for ci in ctxLists.indices {
                if count() >= budget { break }
                let ctx = ctxLists[ci]
                while cursors[ci] < ctx.count && chosen.contains(ctx[cursors[ci]]) { cursors[ci] += 1 }
                if cursors[ci] < ctx.count {
                    chosen.append(ctx[cursors[ci]]); cursors[ci] += 1; progressed = true
                }
            }
        }

        // top-up to full budget with uniform overview if candidates underfilled it.
        if count() < budget {
            for idx in overviewIndices(n: n, k: budget) {
                if !chosen.contains(idx) { chosen.append(idx) }
                if count() >= budget { break }
            }
        }

        var seen = Set<Int>(); var ordered: [Int] = []
        for idx in chosen where !seen.contains(idx) {
            seen.insert(idx); ordered.append(idx)
            if ordered.count >= budget { break }
        }
        return ordered.sorted()
    }

    // MARK: - helpers (mirror the Python mapper exactly)

    private static func nearestIndex(_ sampledFrameMs: [Int], _ tMs: Int) -> Int {
        var best = 0, bestD = Int.max
        for (i, t) in sampledFrameMs.enumerated() {
            let d = abs(t - tMs)
            if d < bestD { best = i; bestD = d }
        }
        return best
    }

    private static func overviewIndices(n: Int, k: Int) -> [Int] {
        if n <= 0 || k <= 0 { return [] }
        if k >= n { return Array(0..<n) }
        if k == 1 { return [0] }
        var out = Set<Int>()
        for i in 0..<k { out.insert(Int((Double(i) / Double(k - 1) * Double(n - 1)).rounded())) }
        return out.sorted()
    }

    private static func contextIndices(sampledFrameMs: [Int], c: EvidenceCandidate) -> [Int] {
        let padMs = Int(contextPadSeconds * 1000)
        let mid = (c.start + c.end) / 2.0
        var targets = [Int(mid * 1000), Int(c.start * 1000) - padMs, Int(c.end * 1000) + padMs]
        if let peak = c.peak { targets.append(Int(peak * 1000)) }   // advisory — never first/alone
        var out: [Int] = []
        for t in targets {
            let idx = nearestIndex(sampledFrameMs, t)
            if !out.contains(idx) { out.append(idx) }
        }
        return out
    }

    private static func rankCandidates(_ cands: [EvidenceCandidate]) -> [EvidenceCandidate] {
        // earlier start first (stable temporal axis); confidence only a weak tiebreak. NOT confidence-sorted.
        cands.sorted { a, b in
            let sa = (a.start * 1000).rounded() / 1000, sb = (b.start * 1000).rounded() / 1000
            if sa != sb { return sa < sb }
            return (a.confidence ?? 0) > (b.confidence ?? 0)
        }
    }
}

// MARK: - Cache-hit orchestrator

enum AUEvidenceCacheHit {
    /// Attempt a full cache-hit sheet build for one Moment. Returns a contact sheet on success, or nil on ANY
    /// miss/validation failure (caller falls back to restore/extract). Pure of restore + MomentFrameExtractor.
    /// `editorialCandidates` are parsed from the Moment's local MomentUnderstanding (visual/narrative/events).
    static func buildSheet(momentId: UUID,
                           videoType: EvidenceVideoType,
                           visualCandidates: [EvidenceCandidate],
                           narrativeCandidates: [EvidenceCandidate],
                           eventTimesS: [Double],
                           budget: ContactSheetBudget,
                           service: AUEvidenceService = AUEvidenceService()) async -> MomentContactSheet? {
        do {
            let (manifest, download) = try await service.fetchManifest(momentId: momentId)
            let packed = try await service.downloadPacked(download, manifest: manifest)
            let allFrames = try service.unpackFrames(packed, manifest: manifest)
            let picked = EvidenceFrameMapper.selectFrames(
                videoType: videoType, sampledFrameMs: manifest.sampledFrameMs,
                visualCandidates: visualCandidates, narrativeCandidates: narrativeCandidates,
                eventTimesS: eventTimesS, budget: budget.framesPerMoment)
            let selected = picked.compactMap { i in i < allFrames.count ? allFrames[i] : nil }
            guard !selected.isEmpty else { return nil }
            // duration ≈ last sampled timestamp (ms) in seconds; the sheet header uses it for labeling only.
            let durationSeconds = Double(manifest.sampledFrameMs.last ?? 0) / 1000.0
            return try MomentContactSheetBuilder.buildFromFrames(
                momentId: momentId, frames: selected, durationSeconds: durationSeconds, budget: budget)
        } catch {
            return nil   // any miss/integrity/transport failure -> caller uses existing fallback
        }
    }
}
