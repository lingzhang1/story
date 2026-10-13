import XCTest
@testable import Story

// EditingApproach — pure-logic tests for the MVP Customize UX editing-approach preference. Covers the
// migration-safe decode (existing Stories with nil/unknown raw), the routing flag (visual_first => multimodal),
// the safe default, and the non-technical copy invariant (no model/endpoint/token jargon leaks to the user).
final class EditingApproachTests: XCTestCase {

    func testWireValues() {
        XCTAssertEqual(EditingApproach.storytelling.rawValue, "storytelling")
        XCTAssertEqual(EditingApproach.visualFirst.rawValue, "visual_first")
    }

    func testDefaultIsStorytelling() {
        XCTAssertEqual(EditingApproach.default, .storytelling)
    }

    func testMigrationSafeDecode() {
        // Existing Stories: nil raw (never chose) OR an unknown/garbage value -> safe default, never a crash.
        XCTAssertEqual(EditingApproach.fromRaw(nil), .storytelling)
        XCTAssertEqual(EditingApproach.fromRaw(""), .storytelling)
        XCTAssertEqual(EditingApproach.fromRaw("legacy_mode"), .storytelling)
        // Valid values round-trip.
        XCTAssertEqual(EditingApproach.fromRaw("storytelling"), .storytelling)
        XCTAssertEqual(EditingApproach.fromRaw("visual_first"), .visualFirst)
    }

    func testRoutingFlag() {
        // Only Visual-first requires the multimodal (contact-sheet) path.
        XCTAssertFalse(EditingApproach.storytelling.requiresMultimodal)
        XCTAssertTrue(EditingApproach.visualFirst.requiresMultimodal)
    }

    func testCopyIsNonTechnical() {
        // Phase-1 rule: no model names / endpoints / tokens / implementation jargon in user-facing copy.
        let banned = ["opus", "sonnet", "bedrock", "token", "/v1", "edit-plan", "mm", "endpoint",
                      "model", "api", "gateway", "json", "multimodal"]
        for a in EditingApproach.allCases {
            let blob = (a.title + " " + a.detail + " " + a.supporting).lowercased()
            for term in banned {
                XCTAssertFalse(blob.contains(term), "approach \(a.rawValue) copy leaks jargon '\(term)': \(blob)")
            }
        }
    }

    func testCopyMatchesSpec() {
        XCTAssertEqual(EditingApproach.storytelling.title, "Storytelling")
        XCTAssertEqual(EditingApproach.visualFirst.title, "Visual-first")
        XCTAssertEqual(EditingApproach.storytelling.supporting, "Faster · Uses video descriptions")
        XCTAssertEqual(EditingApproach.visualFirst.supporting, "More visual analysis · May take longer")
    }
}
