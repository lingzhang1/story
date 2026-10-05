import XCTest
@testable import Story

// C4-Lite — CaptureIntegrityChecker tests (Milestone C4-Lite, C4L-B).
//
// Covers the PURE derivation (the testable core), duration-floor boundaries, the
// frozen-ValidationResult adapter, and the no-semantic-claim invariant. No AI / no
// network / no AWS — all local and deterministic.

final class CaptureIntegrityCheckerTests: XCTestCase {

    private let checker = CaptureIntegrityChecker()          // default floor 0.8s

    // MARK: pure derivation truth table

    func testReadableAndLongEnough_isSave() {
        XCTAssertEqual(checker.verdict(isReadableVideo: true, durationSeconds: 4.0), .save)
    }

    func testUnreadable_failsUnreadable_evenIfDurationLooksFine() {
        // unreadable MUST win over duration (ordering)
        XCTAssertEqual(checker.verdict(isReadableVideo: false, durationSeconds: 10.0),
                       .fail(.unreadableFile))
    }

    func testTooShort_failsTooShort() {
        XCTAssertEqual(checker.verdict(isReadableVideo: true, durationSeconds: 0.47),
                       .fail(.tooShort))
    }

    // MARK: duration-floor boundaries (floor = 0.8s)

    func testDurationBoundaries() {
        XCTAssertEqual(checker.verdict(isReadableVideo: true, durationSeconds: 0.79),
                       .fail(.tooShort), "just under floor -> too short")
        XCTAssertEqual(checker.verdict(isReadableVideo: true, durationSeconds: 0.80),
                       .save, "exactly floor -> save (>= floor)")
        XCTAssertEqual(checker.verdict(isReadableVideo: true, durationSeconds: 1.37),
                       .save, "next real corpus clip (1.37s) is never rejected")
    }

    func testLenientBias_shortButAboveFloorStillSaves() {
        // A clip shorter than any Director target but above the catastrophic floor is a
        // usable Moment — C4-Lite must NOT reject it for being under target.
        XCTAssertEqual(checker.verdict(isReadableVideo: true, durationSeconds: 1.0), .save)
    }

    func testCustomFloorConfig() {
        let strict = CaptureIntegrityChecker(
            config: CaptureIntegrityConfig(minDurationSeconds: 2.0))
        XCTAssertEqual(strict.verdict(isReadableVideo: true, durationSeconds: 1.5),
                       .fail(.tooShort))
    }

    // MARK: frozen ValidationResult adapter

    func testAdapter_save_mapsToUsableAccept() {
        let vr = CaptureIntegrityVerdict.save.asValidationResult()
        XCTAssertTrue(vr.usable)
        XCTAssertEqual(vr.recommendation, .accept)
        XCTAssertTrue(vr.issues.isEmpty)
    }

    func testAdapter_tooShort_mapsToRetakeWithFrozenCode() {
        let vr = CaptureIntegrityVerdict.fail(.tooShort).asValidationResult()
        XCTAssertFalse(vr.usable)
        XCTAssertEqual(vr.recommendation, .retake)
        XCTAssertEqual(vr.issues, [.tooShort])
    }

    func testAdapter_unreadable_mapsToRetakeWithNoBorrowedSemanticCode() {
        // The frozen enum has no "unreadable" code; the adapter must NOT borrow a
        // semantic code (e.g. subject_missing). Empty issues + retake is the honest map.
        let vr = CaptureIntegrityVerdict.fail(.unreadableFile).asValidationResult()
        XCTAssertFalse(vr.usable)
        XCTAssertEqual(vr.recommendation, .retake)
        XCTAssertTrue(vr.issues.isEmpty)
    }

    // MARK: no-semantic-claim invariant

    func testUserReasons_arePhysicalOnly_neverSemantic() {
        let banned = ["shot", "beat", "purpose", "story", "fulfil", "got it", "moment missing"]
        for issue in CaptureIntegrityIssue.allCases {
            let r = issue.userReason.lowercased()
            for word in banned {
                XCTAssertFalse(r.contains(word),
                    "C4-Lite reason '\(issue.rawValue)' must not contain semantic word '\(word)'")
            }
        }
    }

    func testVerdictConvenienceAccessors() {
        XCTAssertTrue(CaptureIntegrityVerdict.save.isSave)
        XCTAssertNil(CaptureIntegrityVerdict.save.issue)
        XCTAssertFalse(CaptureIntegrityVerdict.fail(.tooShort).isSave)
        XCTAssertEqual(CaptureIntegrityVerdict.fail(.tooShort).issue, .tooShort)
    }
}
