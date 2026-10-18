import XCTest
import CoreLocation
@testable import Story

// Camera Metadata P0 (Part A) — pure, device-independent logic. The device paths (CLLocationManager
// delegate, AVCaptureMovieFileOutput embedding, PhotosSaver, live import) are physical-device acceptance.
final class CameraMetadataTests: XCTestCase {

    // MARK: - Fix validation (freshness AND horizontal accuracy)

    private func loc(acc: Double, age: TimeInterval, at capture: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 37.3, longitude: -122.0),
                   altitude: 0, horizontalAccuracy: acc, verticalAccuracy: -1,
                   timestamp: capture.addingTimeInterval(age))
    }

    func testValidate_acceptsFreshAccurateFix() {
        let t = Date()
        let fix = CaptureLocationService.validate(location: loc(acc: 12, age: -5, at: t),
                                                  captureTime: t, freshnessWindow: 60, maxAccuracyMeters: 100)
        XCTAssertNotNil(fix)
        XCTAssertEqual(fix?.horizontalAccuracyMeters, 12)
    }

    func testValidate_rejectsStaleFix() {
        let t = Date()
        XCTAssertNil(CaptureLocationService.validate(location: loc(acc: 12, age: -120, at: t),
                                                     captureTime: t, freshnessWindow: 60, maxAccuracyMeters: 100))
    }

    func testValidate_rejectsInaccurateFix() {
        let t = Date()
        XCTAssertNil(CaptureLocationService.validate(location: loc(acc: 250, age: -5, at: t),
                                                     captureTime: t, freshnessWindow: 60, maxAccuracyMeters: 100))
    }

    func testValidate_rejectsNegativeAccuracy() {
        let t = Date()
        // horizontalAccuracy < 0 means "invalid" per CoreLocation — must be rejected, not stored.
        XCTAssertNil(CaptureLocationService.validate(location: loc(acc: -1, age: 0, at: t),
                                                     captureTime: t, freshnessWindow: 60, maxAccuracyMeters: 100))
    }

    // MARK: - ISO-6709 location parsing

    func testParseISO6709_signedPair() {
        let r = ImportedMediaMetadata.parseISO6709("+37.33140-122.03010/")
        XCTAssertEqual(r?.lat ?? 0, 37.33140, accuracy: 0.00001)
        XCTAssertEqual(r?.lon ?? 0, -122.03010, accuracy: 0.00001)
    }

    func testParseISO6709_withAltitudeSuffix() {
        // lat, lon, then an altitude field — longitude must stop at the altitude sign.
        let r = ImportedMediaMetadata.parseISO6709("+37.3314-122.0301+010.5/")
        XCTAssertEqual(r?.lat ?? 0, 37.3314, accuracy: 0.0001)
        XCTAssertEqual(r?.lon ?? 0, -122.0301, accuracy: 0.0001)
    }

    func testParseISO6709_rejectsGarbageAndOutOfRange() {
        XCTAssertNil(ImportedMediaMetadata.parseISO6709("not-a-location"))
        XCTAssertNil(ImportedMediaMetadata.parseISO6709("+99.0+200.0/"))   // out of range
        XCTAssertNil(ImportedMediaMetadata.parseISO6709(""))
    }

    // MARK: - Capture-date parsing

    func testParseDate_iso8601() {
        XCTAssertNotNil(ImportedMediaMetadata.parseDate("2026-10-18T14:30:00Z"))
        XCTAssertNotNil(ImportedMediaMetadata.parseDate("2026-10-18T14:30:00-07:00"))
    }

    func testParseDate_rejectsGarbage() {
        XCTAssertNil(ImportedMediaMetadata.parseDate("yesterday"))
    }
}
