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
}
