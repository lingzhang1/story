import XCTest
@testable import Story

// Package B Increment 1 — pure, device-independent camera-control logic.
//
// The device-dependent pieces (zoom-preset DERIVATION from real switch-over factors, focus/exposure
// point application, torch) require an AVCaptureDevice and are verified in physical-device acceptance,
// not here. What IS unit-testable is the zoom-label FORMATTING rule used by the preset strip.
final class CameraControlsTests: XCTestCase {

    func testZoomLabel_subOne_showsLeadingDotTenths() {
        XCTAssertEqual(CameraZoomFormat.label(0.5), ".5")
        XCTAssertEqual(CameraZoomFormat.label(0.6), ".6")
    }

    func testZoomLabel_wholeNumbers_showAsInteger() {
        XCTAssertEqual(CameraZoomFormat.label(1.0), "1")
        XCTAssertEqual(CameraZoomFormat.label(2.0), "2")
        XCTAssertEqual(CameraZoomFormat.label(3.0), "3")
    }

    func testZoomLabel_fractional_showsOneDecimal() {
        XCTAssertEqual(CameraZoomFormat.label(1.5), "1.5")
        XCTAssertEqual(CameraZoomFormat.label(2.5), "2.5")
    }

    // Guards the display contract the Increment-1 spec cares about: a device WITHOUT an ultra-wide
    // must NEVER show "0.5"/".5" (no fake optical lens implied). The derivation itself is device-tested,
    // but the formatter must at least render a real preset list correctly in each regime.
    func testZoomLabels_representativePresetLists() {
        // Pro-style (ultra-wide + tele present)
        XCTAssertEqual([0.5, 1.0, 2.0].map(CameraZoomFormat.label), [".5", "1", "2"])
        // SE-style (wide only + digital 2× fallback) — no ".5"
        XCTAssertEqual([1.0, 2.0].map(CameraZoomFormat.label), ["1", "2"])
    }

    // MARK: - Gradual zoom ladder (owner fix: 0.5/1/5 was too big a step)

    func testLadder_fillsIntermediateStepsBetweenOpticalAnchors() {
        // Owner's device reported optical anchors [0.5, 1, 5] — must become a gradual ramp.
        XCTAssertEqual(CameraZoomFormat.ladder(anchors: [0.5, 1, 5], maxUserZoom: 15),
                       [0.5, 1, 2, 3, 4, 5])
    }

    func testLadder_preservesSubOneAnchorAndNeverInterpolatesBelowOne() {
        // 0.5 kept exactly; nothing fabricated between 0.5 and 1.
        let r = CameraZoomFormat.ladder(anchors: [0.5, 1, 3], maxUserZoom: 10)
        XCTAssertEqual(r, [0.5, 1, 2, 3])
        XCTAssertFalse(r.contains(where: { $0 > 0.5 && $0 < 1 }))
    }

    func testLadder_wideOnlyStillOffersGradualDigitalSteps() {
        // A wide-only device (top anchor 1×) still gets a usable digital ramp up to the ceiling.
        XCTAssertEqual(CameraZoomFormat.ladder(anchors: [1], maxUserZoom: 4), [1, 2, 3])
    }

    func testLadder_clampsToDeviceMax() {
        XCTAssertEqual(CameraZoomFormat.ladder(anchors: [1], maxUserZoom: 2.5), [1, 2])
        XCTAssertEqual(CameraZoomFormat.ladder(anchors: [0.5, 1, 5], maxUserZoom: 3),
                       [0.5, 1, 2, 3])
    }

    func testLadder_alwaysIncludesOneAndIsSortedUnique() {
        let r = CameraZoomFormat.ladder(anchors: [2, 2, 5], maxUserZoom: 8)
        XCTAssertTrue(r.contains(1.0))
        XCTAssertEqual(r, r.sorted())
        XCTAssertEqual(r.count, Set(r).count)
    }

    // MARK: - Live magnification label (active chip shows the exact zoom, native pattern)

    func testLiveLabel_integerSnapsToWholeTimes() {
        XCTAssertEqual(CameraZoomFormat.liveLabel(1.0), "1×")
        XCTAssertEqual(CameraZoomFormat.liveLabel(2.0), "2×")
        XCTAssertEqual(CameraZoomFormat.liveLabel(2.02), "2×")   // within snap tolerance
    }

    func testLiveLabel_betweenPresetsShowsOneDecimal() {
        XCTAssertEqual(CameraZoomFormat.liveLabel(2.7), "2.7×")
        XCTAssertEqual(CameraZoomFormat.liveLabel(1.4), "1.4×")
    }

    func testLiveLabel_subOneShowsLeadingDot() {
        XCTAssertEqual(CameraZoomFormat.liveLabel(0.5), ".5×")
    }

    // MARK: - Increment 2: exposure slider fraction <-> EV mapping (pure)

    func testExposureEV_fractionEndpointsMapToRangeEnds() {
        let r: ClosedRange<Float> = -2...2
        XCTAssertEqual(CameraZoomFormat.exposureEV(fromFraction: 0, range: r), -2, accuracy: 0.0001)
        XCTAssertEqual(CameraZoomFormat.exposureEV(fromFraction: 1, range: r), 2, accuracy: 0.0001)
        XCTAssertEqual(CameraZoomFormat.exposureEV(fromFraction: 0.5, range: r), 0, accuracy: 0.0001)
    }

    func testExposureEV_clampsOutOfRangeFraction() {
        let r: ClosedRange<Float> = -3...3
        XCTAssertEqual(CameraZoomFormat.exposureEV(fromFraction: -0.5, range: r), -3, accuracy: 0.0001)
        XCTAssertEqual(CameraZoomFormat.exposureEV(fromFraction: 1.5, range: r), 3, accuracy: 0.0001)
    }

    func testExposureFraction_isInverseOfEV() {
        let r: ClosedRange<Float> = -2...2
        for ev in stride(from: Float(-2), through: 2, by: 0.5) {
            let p = CameraZoomFormat.exposureFraction(fromEV: ev, range: r)
            let back = CameraZoomFormat.exposureEV(fromFraction: p, range: r)
            XCTAssertEqual(back, ev, accuracy: 0.0001)
        }
    }

    func testExposureFraction_zeroSpanIsSafe() {
        XCTAssertEqual(CameraZoomFormat.exposureFraction(fromEV: 1, range: 0...0), 0)
    }

    // MARK: - Thumb-dial zoom mapping (log-scaled, native pattern)

    func testDialZoom_endpointsMapToRangeEnds() {
        let r = 0.5...15.0
        XCTAssertEqual(CameraZoomFormat.dialZoom(fromFraction: 0, range: r), 0.5, accuracy: 0.0001)
        XCTAssertEqual(CameraZoomFormat.dialZoom(fromFraction: 1, range: r), 15.0, accuracy: 0.0001)
    }

    func testDialZoom_clampsOutOfRangeFraction() {
        let r = 1.0...5.0
        XCTAssertEqual(CameraZoomFormat.dialZoom(fromFraction: -0.3, range: r), 1.0, accuracy: 0.0001)
        XCTAssertEqual(CameraZoomFormat.dialZoom(fromFraction: 1.4, range: r), 5.0, accuracy: 0.0001)
    }

    func testDialFraction_isInverseOfZoom() {
        let r = 0.5...15.0
        for z in [0.5, 1.0, 1.7, 2.0, 5.0, 15.0] {
            let f = CameraZoomFormat.dialFraction(fromZoom: z, range: r)
            let back = CameraZoomFormat.dialZoom(fromFraction: f, range: r)
            XCTAssertEqual(back, z, accuracy: 0.001)
        }
    }

    func testDialZoom_logScaleGivesFinerLowEnd() {
        // Log scale: the midpoint fraction sits at the geometric mean, not the arithmetic mean —
        // so the low end gets more travel (finer control), like the native dial.
        let r = 0.5...8.0
        let mid = CameraZoomFormat.dialZoom(fromFraction: 0.5, range: r)
        XCTAssertEqual(mid, 2.0, accuracy: 0.01)          // sqrt(0.5*8) = 2, not 4.25
    }
}
