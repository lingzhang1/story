import XCTest
@testable import Story

// Creative Editing V2-b — pure refinement + validation logic (NO device, NO AVFoundation).
//
// VERIFIED HERE: boundary nudging toward motion-settle/onset, conservative bounds, and the Phase-4 validator's
// fall-back-to-original behavior — all via an INJECTED evidence provider.
// REQUIRES XCODE/DEVICE: AVFoundationEvidence.sample (real frame/audio sampling) and the rendered A/B video.
final class CreativeRefinementV2bTests: XCTestCase {

    // a segment spanning 2.0–5.0s of a 10s clip, inside useful band 1.0–6.0
    private func plan(in inS: Double = 2.0, out outS: Double = 5.0) -> EditPlanV2 {
        let seg = EditSegmentV2(order: 1, assetId: "aaaa", sourceStartSeconds: inS, sourceEndSeconds: outS,
                                outputDurationSeconds: 3.0, speed: nil, nativeAudio: "keep",
                                musicAlignment: nil, transition: nil)
        return EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: 3.0, outputFormat: "vertical",
                          musicAssetId: nil, feasible: true, segments: [seg])
    }
    private let dur: (String) -> Double? = { _ in 10.0 }
    private let useful: [String: [(Double, Double)]] = ["aaaa": [(1.0, 6.0)]]
    private let resolve: (String) -> URL? = { id in URL(fileURLWithPath: "/dev/null/\(id).mov") }

    func test_disabled_returns_original_untouched() {
        let p = plan()
        let out = CreativeRefinementV2b.refine(plan: p, enabled: false, resolveURL: resolve,
            actionTimestamps: [:], sourceDuration: dur, usefulRanges: useful, evidenceProvider: { _, _ in nil })
        XCTAssertFalse(out.applied)
        XCTAssertEqual(out.plan.segments[0].sourceStartSeconds, 2.0)
    }

    func test_noop_when_evidence_absent() {
        let p = plan()
        let out = CreativeRefinementV2b.refine(plan: p, enabled: true, resolveURL: resolve,
            actionTimestamps: [:], sourceDuration: dur, usefulRanges: useful, evidenceProvider: { _, _ in nil })
        XCTAssertFalse(out.applied)   // no evidence -> no change -> original kept
        XCTAssertEqual(out.plan.segments[0].sourceStartSeconds, 2.0)
    }

    func test_nudges_in_point_toward_settled_motion() {
        // High motion at 2.0 (original in), settled motion at ~2.3; refinement should pull the in-point later.
        let ev: (URL, Double) -> BoundaryEvidence? = { _, t in
            let settled = abs(t - 2.3) < 0.03
            return BoundaryEvidence(timeSeconds: t, motionMagnitude: settled ? 0.02 : 0.4,
                                    motionDirection: "none", audioRMS: 0.1, isSilence: false,
                                    onsetNearby: settled, actionCandidate: false)
        }
        let out = CreativeRefinementV2b.refine(plan: plan(), enabled: true, resolveURL: resolve,
            actionTimestamps: [:], sourceDuration: dur, usefulRanges: useful, evidenceProvider: ev)
        XCTAssertTrue(out.applied, out.validationNotes.joined(separator: "; "))
        let newIn = out.plan.segments[0].sourceStartSeconds ?? -1
        XCTAssertEqual(newIn, 2.3, accuracy: 0.08)       // moved toward the settled point
        XCTAssertEqual(out.plan.segments[0].outputDurationSeconds, 3.0)  // output duration UNCHANGED
    }

    func test_never_moves_beyond_max_nudge() {
        // settled only far away (3.0s = 1.0 past the in-point, > maxNudge 0.5) -> must NOT jump there
        let ev: (URL, Double) -> BoundaryEvidence? = { _, t in
            BoundaryEvidence(timeSeconds: t, motionMagnitude: abs(t - 3.0) < 0.03 ? 0.0 : 0.4,
                             motionDirection: "none", audioRMS: 0.1, isSilence: false,
                             onsetNearby: false, actionCandidate: false)
        }
        let out = CreativeRefinementV2b.refine(plan: plan(), enabled: true, resolveURL: resolve,
            actionTimestamps: [:], sourceDuration: dur, usefulRanges: useful, evidenceProvider: ev)
        let newIn = out.plan.segments[0].sourceStartSeconds ?? -1
        XCTAssertLessThanOrEqual(abs(newIn - 2.0), 0.5 + 0.001)   // within maxNudge of the original
    }

    func test_stays_inside_useful_band() {
        // settled motion at 0.5s — OUTSIDE the useful band (1.0–6.0); must not escape the band
        let ev: (URL, Double) -> BoundaryEvidence? = { _, t in
            BoundaryEvidence(timeSeconds: t, motionMagnitude: t < 1.0 ? 0.0 : 0.4, motionDirection: "none",
                             audioRMS: 0.1, isSilence: false, onsetNearby: false, actionCandidate: false)
        }
        let out = CreativeRefinementV2b.refine(plan: plan(in: 2.0, out: 5.0), enabled: true, resolveURL: resolve,
            actionTimestamps: [:], sourceDuration: dur, usefulRanges: useful, evidenceProvider: ev)
        let newIn = out.plan.segments[0].sourceStartSeconds ?? -1
        XCTAssertGreaterThanOrEqual(newIn, 1.0 - 0.001)   // never left the useful band
    }

    // ---- validator ----
    func test_validator_rejects_order_change() {
        let orig = plan()
        let swapped = EditSegmentV2(order: 2, assetId: "bbbb", sourceStartSeconds: 2.0, sourceEndSeconds: 5.0,
                                    outputDurationSeconds: 3.0, speed: nil, nativeAudio: "keep",
                                    musicAlignment: nil, transition: nil)
        let cand = orig.replacingSegments([swapped])
        let v = RefinementValidator.validate(original: orig, candidate: cand, sourceDuration: dur, usefulRanges: useful)
        XCTAssertFalse(v.ok)
    }

    func test_validator_rejects_duration_change() {
        let orig = plan()
        let longer = EditSegmentV2(order: 1, assetId: "aaaa", sourceStartSeconds: 2.0, sourceEndSeconds: 5.0,
                                   outputDurationSeconds: 9.0, speed: nil, nativeAudio: "keep",
                                   musicAlignment: nil, transition: nil)
        let v = RefinementValidator.validate(original: orig, candidate: orig.replacingSegments([longer]),
                                             sourceDuration: dur, usefulRanges: useful)
        XCTAssertFalse(v.ok)   // output duration must not change
    }

    func test_validator_rejects_inverted_source_range() {
        let orig = plan()
        let bad = EditSegmentV2(order: 1, assetId: "aaaa", sourceStartSeconds: 5.0, sourceEndSeconds: 2.0,
                                outputDurationSeconds: 3.0, speed: nil, nativeAudio: "keep",
                                musicAlignment: nil, transition: nil)
        let v = RefinementValidator.validate(original: orig, candidate: orig.replacingSegments([bad]),
                                             sourceDuration: dur, usefulRanges: useful)
        XCTAssertFalse(v.ok)
    }

    func test_validator_accepts_in_bounds_nudge() {
        let orig = plan()
        let nudged = EditSegmentV2(order: 1, assetId: "aaaa", sourceStartSeconds: 2.3, sourceEndSeconds: 5.3,
                                   outputDurationSeconds: 3.0, speed: nil, nativeAudio: "keep",
                                   musicAlignment: nil, transition: nil)
        let v = RefinementValidator.validate(original: orig, candidate: orig.replacingSegments([nudged]),
                                             sourceDuration: dur, usefulRanges: useful)
        XCTAssertTrue(v.ok, v.notes.joined(separator: "; "))
    }
}
