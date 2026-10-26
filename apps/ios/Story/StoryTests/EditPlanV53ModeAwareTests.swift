import XCTest
@testable import Story

// EditPlan v5.3 mode-aware — P1-C §6 offline tests for the PURE resolution + sizing logic.
// The full async Original/Revise/Explore coordinator matrix (submit→resume→persist) is exercised on-device
// via StoryCreationCoordinatorTests + ⌘U (SwiftData @Model macro can't run in the parse sandbox); these cover
// the deterministic units: editorial-type resolution rules and mode-aware duration selection.
final class EditPlanV53ModeAwareTests: XCTestCase {

    // MARK: - Editorial-type resolution (§2/§5)

    func testOriginalDefaultsToHighlightsWhenUnselected() {
        // No explicit Story selection -> Highlights DEFAULT (never inferred, custom != Full Story).
        XCTAssertEqual(ResolvedEditorial.fromLegacy(nil).typeForNewAttempt, .highlights)
        XCTAssertEqual(ResolvedEditorial.fromLegacy("").typeForNewAttempt, .highlights)
    }

    func testOriginalExplicitTypes() {
        XCTAssertEqual(ResolvedEditorial.fromLegacy("highlights").typeForNewAttempt, .highlights)
        XCTAssertEqual(ResolvedEditorial.fromLegacy("full").typeForNewAttempt, .fullStory)
    }

    func testCustomDurationIsNotFullStory() {
        // Legacy custom = unspecified type + explicit duration; its .type is nil (NOT Full Story);
        // a new attempt seeded from it falls back to the Highlights default, never Full Story.
        let r = ResolvedEditorial.fromLegacy("custom")
        XCTAssertNil(r.type)
        XCTAssertTrue(r.isUserExactDuration)
        XCTAssertEqual(r.typeForNewAttempt, .highlights)
    }

    func testEditorialTypeWireValues() {
        XCTAssertEqual(EditorialType.highlights.rawValue, "highlights")
        XCTAssertEqual(EditorialType.fullStory.rawValue, "full_story")
        XCTAssertEqual(EditorialType.defaultType, .highlights)
    }

    // MARK: - Mode-aware sizing selection (§3)

    private func rec(recommended: [Double]?, highlights: [Double]?) -> DurationRecommendation {
        // Decode a minimal recommendation JSON so we exercise the real accessors.
        var recObj = "null"
        if let r = recommended, let h = highlights {
            recObj = """
            {"recommended_range_seconds":[\(r[0]),\(r[1])],"highlights_range_seconds":[\(h[0]),\(h[1])],
             "feasible_ceiling_seconds":120,"rationale":"x"}
            """
        }
        let json = """
        {"evidence":{"n_moments":3,"total_useful_coverage_seconds":60,"longest_continuous_span_seconds":20,
         "feasible_band_seconds":[5,120],"zero_usable_material":false},"recommendation":\(recObj)}
        """
        return try! JSONDecoder().decode(DurationRecommendation.self, from: Data(json.utf8))
    }

    func testHighlightsSeedsFromHighlightsRange() {
        let r = rec(recommended: [40, 60], highlights: [12, 20])
        XCTAssertEqual(r.pointSeconds(forEditorialType: .highlights), 16)   // (12+20)/2
    }

    func testFullStorySeedsFromRecommendedRange() {
        let r = rec(recommended: [40, 60], highlights: [12, 20])
        XCTAssertEqual(r.pointSeconds(forEditorialType: .fullStory), 50)    // (40+60)/2
    }

    func testNilTypeSeedsFromRecommended() {
        let r = rec(recommended: [40, 60], highlights: [12, 20])
        XCTAssertEqual(r.pointSeconds(forEditorialType: nil), 50)           // v5.2 default
    }

    func testGracefulFallbackWhenRangesMissing() {
        // No recommendation at all -> nil (caller keeps its safe band fallback).
        let none = rec(recommended: nil, highlights: nil)
        XCTAssertNil(none.pointSeconds(forEditorialType: .highlights))
        XCTAssertNil(none.pointSeconds(forEditorialType: .fullStory))
    }
}
