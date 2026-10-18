import XCTest
@testable import Story

// Phase 2 revision-scope classifier. Maps the owner's examples to A (deterministic) / B (targeted) /
// C (full re-edit) by ACTUAL change scope, not mere presence of directives/soft.
final class RevisionScopeClassifierTests: XCTestCase {

    func test_structural_directive_only_is_deterministic() {
        // "Start with Moment 5" -> hard directive, no soft, base plan present -> A.
        let s = RevisionScopeClassifier.classify(hasHardDirectives: true, softDirection: "", hasBasePlan: true)
        XCTAssertEqual(s, .deterministic)
        XCTAssertFalse(s.sendsSheets)
    }

    func test_pacing_tweak_is_targeted_textlight() {
        // "Make the cuts slightly faster" -> targeted, no images.
        let s = RevisionScopeClassifier.classify(hasHardDirectives: false, softDirection: "make the cuts slightly faster", hasBasePlan: true)
        XCTAssertEqual(s, .targeted(needsImages: false))
        XCTAssertFalse(s.sendsSheets)
    }

    func test_visual_replacement_is_targeted_with_images() {
        // "Replace the opening with the most beautiful shot" -> targeted, needs images.
        let s = RevisionScopeClassifier.classify(hasHardDirectives: false, softDirection: "replace the opening with the most beautiful shot", hasBasePlan: true)
        XCTAssertEqual(s, .targeted(needsImages: true))
        XCTAssertTrue(s.sendsSheets)
    }

    func test_rebuild_is_full_reedit() {
        // "Completely rebuild the Story" -> C.
        let s = RevisionScopeClassifier.classify(hasHardDirectives: false, softDirection: "completely rebuild the story", hasBasePlan: true)
        XCTAssertEqual(s, .fullReedit)
        XCTAssertTrue(s.sendsSheets)
    }

    func test_directive_plus_rebuild_is_full_reedit_opening_still_enforced_upstream() {
        // "Start with Moment 5 and completely rebuild the Story" -> C (the hard opening is enforced by the
        // directive validator regardless of the path; the classifier only decides planning scope).
        let s = RevisionScopeClassifier.classify(hasHardDirectives: true, softDirection: "start with Moment 5 and completely rebuild the story", hasBasePlan: true)
        XCTAssertEqual(s, .fullReedit)
    }

    func test_no_base_plan_creative_ask_is_full_reedit() {
        // Without a base plan we cannot preserve unaffected edits -> a creative ask is a full plan.
        let s = RevisionScopeClassifier.classify(hasHardDirectives: false, softDirection: "make it dreamier", hasBasePlan: false)
        XCTAssertEqual(s, .fullReedit)
    }

    func test_soft_only_with_base_plan_is_targeted() {
        let s = RevisionScopeClassifier.classify(hasHardDirectives: false, softDirection: "tighten the middle a bit", hasBasePlan: true)
        XCTAssertEqual(s, .targeted(needsImages: false))
    }
}
