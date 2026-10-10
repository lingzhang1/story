import Foundation

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
    func recommend(creativeIntent: JSONValue, moments: [JSONValue],
                   storyGuide: JSONValue = .object([:]), storyCoverage: JSONValue = .object([:]),
                   requestedScope: String? = nil) async -> DurationRecommendation? {
        let body = DurationRecommendationRequestDTO(
            creativeIntent: creativeIntent, moments: moments,
            storyGuide: storyGuide, storyCoverage: storyCoverage, requestedScope: requestedScope)
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/duration-recommendation"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? JSONEncoder().encode(body) else { return nil }
        req.httpBody = data
        guard let (respData, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(DurationRecommendation.self, from: respData)
    }
}
