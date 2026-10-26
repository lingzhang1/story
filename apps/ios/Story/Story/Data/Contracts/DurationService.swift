import Foundation
import CryptoKit
import SwiftData

// Milestone R-d.2 — Story Duration Planning client. Calls the backend /v1/duration-recommendation
// (frozen duration_recommendation/1): deterministic evidence computed server-side from the SAME
// moments[] payload the Edit Planner receives, plus one Opus call for the scope-aware recommendation.
// RECOMMENDS a target; it never sets the Story's duration (the user owns that). On any failure the
// caller falls back to manual duration selection — this service returns nil, never a fabricated number.

struct DurationRecommendation: Decodable, Equatable, Identifiable {
    let id = UUID()
    struct Evidence: Decodable, Equatable {
        init(nMoments: Int, totalUsefulCoverageSeconds: Double, longestContinuousSpanSeconds: Double, feasibleBandSeconds: [Double], zeroUsableMaterial: Bool) {
            self.nMoments = nMoments; self.totalUsefulCoverageSeconds = totalUsefulCoverageSeconds
            self.longestContinuousSpanSeconds = longestContinuousSpanSeconds; self.feasibleBandSeconds = feasibleBandSeconds
            self.zeroUsableMaterial = zeroUsableMaterial
        }
        let nMoments: Int
        let totalUsefulCoverageSeconds: Double
        let longestContinuousSpanSeconds: Double
        let feasibleBandSeconds: [Double]
        let zeroUsableMaterial: Bool
        enum CodingKeys: String, CodingKey {
            case nMoments = "n_moments"
            case totalUsefulCoverageSeconds = "total_useful_coverage_seconds"
            case longestContinuousSpanSeconds = "longest_continuous_span_seconds"
            case feasibleBandSeconds = "feasible_band_seconds"
            case zeroUsableMaterial = "zero_usable_material"
        }
    }
    struct Rec: Decodable, Equatable {
        let recommendedRangeSeconds: [Double]
        let highlightsRangeSeconds: [Double]
        let feasibleCeilingSeconds: Double
        let rationale: String
        let payoffBreathing: Bool?
        enum CodingKeys: String, CodingKey {
            case recommendedRangeSeconds = "recommended_range_seconds"
            case highlightsRangeSeconds = "highlights_range_seconds"
            case feasibleCeilingSeconds = "feasible_ceiling_seconds"
            case rationale, payoffBreathing = "payoff_breathing"
        }
    }
    let evidence: Evidence
    let recommendation: Rec?          // nil when the model was unavailable -> manual selection
    let explicitTargetSeconds: Double?  // echoed when CreativeIntent already carried one
    let note: String?
    enum CodingKeys: String, CodingKey {
        case evidence, recommendation
        case explicitTargetSeconds = "explicit_target_seconds"
        case note
    }

    static func == (a: DurationRecommendation, b: DurationRecommendation) -> Bool {
        a.evidence == b.evidence && a.recommendation == b.recommendation && a.explicitTargetSeconds == b.explicitTargetSeconds
    }

    /// Manual-only fallback when the recommendation model was unavailable: carry just the deterministic
    /// evidence (feasible ceiling) so the sheet still offers an honest Custom range. recommendation = nil.
    init(fallbackEvidenceFor payload: (moments: [JSONValue], creativeIntent: JSONValue)) {
        // Minimal client-side evidence: we cannot recompute AU unions here, so present a permissive range
        // and let the backend validator enforce feasibility at create time.
        self.evidence = Evidence(nMoments: payload.moments.count, totalUsefulCoverageSeconds: 0,
                                 longestContinuousSpanSeconds: 0, feasibleBandSeconds: [5, 120],
                                 zeroUsableMaterial: false)
        self.recommendation = nil
        self.explicitTargetSeconds = nil
        self.note = "recommendation unavailable; choose a duration"
    }

    /// A single recommended point the UI can preselect: midpoint of the recommended range, clamped to ceiling.
    var recommendedPointSeconds: Double? {
        guard let r = recommendation, r.recommendedRangeSeconds.count == 2 else { return nil }
        let mid = (r.recommendedRangeSeconds[0] + r.recommendedRangeSeconds[1]) / 2.0
        return min(mid, r.feasibleCeilingSeconds)
    }
    var highlightsPointSeconds: Double? {
        guard let r = recommendation, r.highlightsRangeSeconds.count == 2 else { return nil }
        return (r.highlightsRangeSeconds[0] + r.highlightsRangeSeconds[1]) / 2.0
    }

    /// EditPlan v5.3 mode-aware Sizing (P1-C §3): seed the duration from the range appropriate to the resolved
    /// editorial TYPE — Highlights from `highlights_range_seconds`, Full Story from `recommended_range_seconds`.
    /// GRACEFUL FALLBACK: if the type-specific point is unavailable (missing/malformed range) fall back to the
    /// other point, then to nil (caller keeps its existing safe sizing behavior). No new sizing model call; this
    /// only SELECTS between ranges Duration Intelligence already returned. nil type => recommended (v5.2 default).
    func pointSeconds(forEditorialType type: EditorialType?) -> Double? {
        switch type {
        case .highlights: return highlightsPointSeconds ?? recommendedPointSeconds
        case .fullStory:  return recommendedPointSeconds ?? highlightsPointSeconds
        case nil:         return recommendedPointSeconds
        }
    }
}

struct DurationRecommendationRequestDTO: Encodable {
    let creativeIntent: JSONValue
    let moments: [JSONValue]
    let storyGuide: JSONValue
    let storyCoverage: JSONValue
    let requestedScope: String?
    enum CodingKeys: String, CodingKey {
        case creativeIntent = "creative_intent"
        case moments
        case storyGuide = "story_guide"
        case storyCoverage = "story_coverage"
        case requestedScope = "requested_scope"
    }
}

final class DurationService {
    private let baseURL: URL
    private let session: URLSession
    init(baseURL: URL = StoryBackend.baseURL, session: URLSession = StoryBackend.longSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Recommend a target duration. Returns nil on any transport/model failure (caller falls back to manual
    /// selection). NEVER throws into the create flow — a recommendation is advisory.
    /// LATENCY P0: pass `storyId` + `context` to cache the result per Story keyed by an input fingerprint, so
    /// reopening Customize with unchanged intent/moments skips the ~4-9s duration_recommendation LLM call.
    func recommend(creativeIntent: JSONValue, moments: [JSONValue],
                   storyGuide: JSONValue = .object([:]), storyCoverage: JSONValue = .object([:]),
                   requestedScope: String? = nil,
                   storyId: UUID? = nil, context: ModelContext? = nil) async -> DurationRecommendation? {
        // Cache hit: reuse the stored recommendation (no model call) when the inputs are unchanged.
        let fingerprint = Self.durationFingerprint(creativeIntent: creativeIntent, moments: moments,
                                                   requestedScope: requestedScope)
        if let sid = storyId, let ctx = context,
           let cached = Self.cachedRecommendation(storyId: sid, fingerprint: fingerprint, context: ctx) {
            MediaEngineV1.beacon("duration: cache HIT fp=\(fingerprint.prefix(8))")
            return cached
        }
        let body = DurationRecommendationRequestDTO(
            creativeIntent: creativeIntent, moments: moments,
            storyGuide: storyGuide, storyCoverage: storyCoverage, requestedScope: requestedScope)
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/duration-recommendation"))
        StoryBackend.authorize(&req)  // P0 auth seam: bearer token when signed in
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? JSONEncoder().encode(body) else { return nil }
        req.httpBody = data
        guard let (respData, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        guard let decoded = try? JSONDecoder().decode(DurationRecommendation.self, from: respData) else { return nil }
        if let sid = storyId, let ctx = context {
            Self.storeRecommendation(storyId: sid, fingerprint: fingerprint, rawResponse: respData, context: ctx)
            MediaEngineV1.beacon("duration: cache MISS->stored fp=\(fingerprint.prefix(8))")
        }
        return decoded
    }

    /// Stable fingerprint of the duration-recommendation inputs (creative intent + moments snapshot +
    /// requested scope + prompt version), stripping volatile provenance keys so a reopen with unchanged
    /// semantic content hashes identically (same lesson as the MusicPlan cache).
    static func durationFingerprint(creativeIntent: JSONValue, moments: [JSONValue],
                                    requestedScope: String?,
                                    promptVersion: String = "duration_recommendation/1") -> String {
        let volatileKeys: Set<String> = ["generated_at", "created_at", "updated_at", "timestamp",
                                         "model_id", "prompt_version", "schema_version", "correlation_id"]
        func strip(_ v: JSONValue) -> JSONValue {
            switch v {
            case .object(let d):
                var out: [String: JSONValue] = [:]
                for (k, val) in d where !volatileKeys.contains(k.lowercased()) { out[k] = strip(val) }
                return .object(out)
            case .array(let a): return .array(a.map(strip))
            default: return v
            }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        func canon(_ v: JSONValue) -> String {
            (try? enc.encode(strip(v))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        let joined = [promptVersion, requestedScope ?? "", canon(creativeIntent),
                      canon(.array(moments))].joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func cachedRecommendation(storyId: UUID, fingerprint: String, context: ModelContext) -> DurationRecommendation? {
        let desc = FetchDescriptor<DurationRecCacheModel>(predicate: #Predicate { $0.storyId == storyId })
        guard let row = (try? context.fetch(desc))?.first, row.inputFingerprint == fingerprint,
              let data = row.recommendationJSON.data(using: .utf8),
              let v = try? JSONDecoder().decode(DurationRecommendation.self, from: data) else { return nil }
        return v
    }

    static func storeRecommendation(storyId: UUID, fingerprint: String, rawResponse: Data, context: ModelContext) {
        guard let json = String(data: rawResponse, encoding: .utf8) else { return }
        let desc = FetchDescriptor<DurationRecCacheModel>(predicate: #Predicate { $0.storyId == storyId })
        if let row = (try? context.fetch(desc))?.first {
            row.recommendationJSON = json; row.inputFingerprint = fingerprint; row.updatedAt = .now
        } else {
            context.insert(DurationRecCacheModel(storyId: storyId, recommendationJSON: json, inputFingerprint: fingerprint))
        }
        try? context.save()
    }
}
