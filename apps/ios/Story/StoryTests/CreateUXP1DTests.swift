import XCTest
@testable import Story

// P1-D §14 — offline tests for the PURE Create-UX decision logic: Video Type seeding (Highlights default,
// historical custom != Full Story), the independent Recommended/Custom duration seed, and the default-ON
// EditorialTypeFlag with override precedence. The full on-device matrix (type switch updates the estimate,
// chip insertion, More Options expand/collapse, Revise inherit, Explore switch, async submit/resume) runs
// via StoryCreationCoordinatorTests + ⌘U; these cover the deterministic units without a SwiftUI host.
final class CreateUXP1DTests: XCTestCase {

    typealias V = CustomizeYourStoryView

    // MARK: - Video Type seeding (§4 / §12) — option B: ALWAYS opens Highlights

    func testUnselectedOriginalSeedsHighlights() {
        XCTAssertEqual(V.seedVideoType(editorialMode: nil), .highlights)
        XCTAssertEqual(V.seedVideoType(editorialMode: ""), .highlights)
    }

    func testSeedAlwaysHighlightsRegardlessOfPersistedMode() {
        // Owner decision (option B): the sheet always opens on Highlights — a prior Full Story generation does
        // NOT pre-select Full Story on re-open; the user opts into Full Story per attempt.
        XCTAssertEqual(V.seedVideoType(editorialMode: "full"), .highlights)
        XCTAssertEqual(V.seedVideoType(editorialMode: "highlights"), .highlights)
        XCTAssertEqual(V.seedVideoType(editorialMode: "custom"), .highlights)   // custom is a duration fact
        XCTAssertEqual(V.seedVideoType(editorialMode: "visual_first"), .highlights) // old approach is NOT a type
    }

    // MARK: - Duration is INDEPENDENT of type (§8)

    func testHistoricalCustomSeedsCustomDuration() {
        XCTAssertEqual(V.seedDurationChoice(editorialMode: "custom", explicitTarget: 45), .custom)
    }

    func testExplicitTargetSeedsCustomDuration() {
        // A prior explicit target (non-nil) opens the duration control as Custom...
        XCTAssertEqual(V.seedDurationChoice(editorialMode: "highlights", explicitTarget: 30), .custom)
    }

    func testNoExplicitTargetSeedsRecommended() {
        // ...while no explicit target (a fresh/recommended selection) opens as Recommended.
        XCTAssertEqual(V.seedDurationChoice(editorialMode: "highlights", explicitTarget: nil), .recommended)
        XCTAssertEqual(V.seedDurationChoice(editorialMode: "full", explicitTarget: nil), .recommended)
        XCTAssertEqual(V.seedDurationChoice(editorialMode: nil, explicitTarget: nil), .recommended)
    }

    func testVideoTypeWireValuesMatchContract() {
        XCTAssertEqual(V.VideoType.highlights.wire, "highlights")
        XCTAssertEqual(V.VideoType.full.wire, "full")
    }

    // MARK: - EditorialTypeFlag default-ON + override precedence (§11)

    func testFlagDefaultsOnWithNoOverride() {
        // No env override possible in-test; clear any UserDefaults override -> baseline must be ON.
        EditorialTypeFlag.setOverride(nil)
        XCTAssertTrue(EditorialTypeFlag.enabled, "P1-D: Editing v2 is the product default")
    }

    func testUserDefaultsOverrideForcesOff() {
        EditorialTypeFlag.setOverride(false)
        XCTAssertFalse(EditorialTypeFlag.enabled, "an explicit override must win over the default")
        EditorialTypeFlag.setOverride(nil)   // restore baseline; a cleared override must not persist
        XCTAssertTrue(EditorialTypeFlag.enabled)
    }

    func testOverrideCanBeClearedToAvoidStaleContamination() {
        EditorialTypeFlag.setOverride(true)
        EditorialTypeFlag.setOverride(nil)   // §11: a stale dev toggle must be clearable, not sticky
        XCTAssertNil(UserDefaults.standard.object(forKey: EditorialTypeFlag.key))
        XCTAssertTrue(EditorialTypeFlag.enabled)
    }
}
