import XCTest
@testable import Story

// P0 Creative Direction UX — prompt guidance + capability classification tests (logic-only, no UI host).
final class PromptGuidanceTests: XCTestCase {

    // MARK: - Capability classifier (iOS mirror of the backend vocabulary)

    func test_classifier_supported() {
        for t in ["shorten each clip to 5s", "reorder the clips", "change the soundtrack",
                  "make the pacing faster", "use the most beautiful views first", ""] {
            XCTAssertEqual(CapabilityClassifier.classify(t), .supported, t)
        }
    }

    func test_classifier_all_unsupported() {
        for t in ["make it warmer", "add a glow", "color correct the whole thing",
                  "reframe to square", "increase the brightness", "add captions", "stabilize the shaky clip",
                  "make the sky more blue", "make it bluer"] {
            guard case .allUnsupported = CapabilityClassifier.classify(t) else {
                return XCTFail("expected allUnsupported for \(t)")
            }
        }
    }

    func test_classifier_mixed() {
        guard case .mixed(let nouns) = CapabilityClassifier.classify("shorten the clips and make it warmer") else {
            return XCTFail("expected mixed")
        }
        XCTAssertTrue(nouns.contains("color tone changes"))
        // Regression: the sky-blue phrasing that slipped through the first vocabulary.
        guard case .mixed = CapabilityClassifier.classify("Shorten to 5s for each clip and make sky color more blue") else {
            return XCTFail("expected mixed for sky-blue + shorten")
        }
    }

    func test_phrase_formatting() {
        XCTAssertEqual(CapabilityClassifier.phrase(["filters"]), "filters")
        XCTAssertEqual(CapabilityClassifier.phrase(["a", "b"]), "a or b")
        XCTAssertEqual(CapabilityClassifier.phrase(["a", "b", "c"]), "a, b or c")
    }

    // MARK: - Suggestions: valid Moment references only, different sets per screen

    func test_suggestions_use_real_moment_number() {
        let c = PromptSuggestions.customize(firstMomentNumber: 3)
        XCTAssertTrue(c.contains { $0.text.contains("Moment 3") })
        // No opening example invented when there are no referenceable Moments.
        let none = PromptSuggestions.customize(firstMomentNumber: nil)
        XCTAssertFalse(none.contains { $0.text.lowercased().contains("moment") })
    }

    func test_customize_and_revise_differ() {
        let c = PromptSuggestions.customize(firstMomentNumber: 1).map(\.label)
        let r = PromptSuggestions.revise(firstMomentNumber: 1).map(\.label)
        XCTAssertNotEqual(Set(c), Set(r))
        // Revise emphasizes preservation/shortening/reorder/music.
        XCTAssertTrue(r.contains { $0.lowercased().contains("shorten") })
        XCTAssertTrue(r.contains { $0.lowercased().contains("soundtrack") || $0.lowercased().contains("music") })
    }

    // MARK: - Append behavior (insert editable text, never replace blindly)

    func test_append_join_rule() {
        // The documented join: non-empty + no trailing sentence punctuation -> ". " separator.
        var text = "Start with Moment 2"
        let fragment = "Keep each shot around 5 seconds"
        let sep = (text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?")) ? " " : ". "
        text = text + sep + fragment
        XCTAssertEqual(text, "Start with Moment 2. Keep each shot around 5 seconds")
    }
}
