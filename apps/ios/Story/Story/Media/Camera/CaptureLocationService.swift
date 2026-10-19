import Foundation
import CoreLocation

// CaptureLocationService — OPTIONAL location tagging for captured Moments (Camera Metadata P0, Part A).
//
// Safeguards baked in (owner-approved):
//  • OPTIONAL + benefit-first: `requestWhenInUseIfNeeded()` is called only AFTER the UI has shown the
//    user WHY (the pre-permission explainer). We only ever request When-In-Use — never Always.
//  • NON-BLOCKING: recording NEVER awaits a fix. The service keeps the most-recent fix passively; a
//    capture reads whatever is cached at that instant via `fix(at:)`, or nil.
//  • QUALITY, not just freshness: `fix(at:)` returns a trustworthy fix ONLY when it is BOTH recent
//    (within `freshnessWindow` of the capture time) AND horizontally accurate (<= `maxAccuracyMeters`,
//    and horizontalAccuracy > 0). Otherwise it returns nil → the caller stores "unknown". We NEVER
//    reverse-geocode or fabricate a venue/place name (coordinates + accuracy only).
//
// This is a thin, self-contained wrapper; it holds no app state and is safe to construct once and share.
final class CaptureLocationService: NSObject, CLLocationManagerDelegate {

    /// A validated capture-time location fix. Coordinates + accuracy + the fix's own timestamp. No place name.
    struct LocationFix: Equatable {
        let latitude: Double
        let longitude: Double
        let horizontalAccuracyMeters: Double
        let timestamp: Date
    }

    static let shared = CaptureLocationService()

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?

    /// A capture's location must be no older than this relative to the capture timestamp.
    private let freshnessWindow: TimeInterval = 60
    /// Horizontal accuracy must be at least this good (meters). A 100m-accurate fix on a video is useless
    /// precision-wise and is treated as "unknown" rather than stored as if it were the capture location.
    private let maxAccuracyMeters: Double = 100

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters   // not Best — battery-friendly, plenty for tagging
    }

    /// Current authorization. The UI uses this to decide whether to show the explainer + request, or to
    /// simply reflect that tagging is off.
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// True when we may collect location (authorized when-in-use/always).
    var isAuthorized: Bool {
        let s = manager.authorizationStatus
        return s == .authorizedWhenInUse || s == .authorizedAlways
    }

    /// Request When-In-Use — call ONLY after showing the benefit explainer. No-op if already decided.
    /// Does not block; authorization + fixes arrive via the delegate. Starts passive updates once allowed.
    func requestWhenInUseIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isAuthorized {
            startIfAuthorized()
        }
    }

    /// Begin passive location updates when authorized (idempotent). Called on auth grant + camera open.
    func startIfAuthorized() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
    }

    /// Stop updates (camera closed) to save battery. Safe to call anytime.
    func stop() { manager.stopUpdatingLocation() }

    /// The trustworthy fix for a capture at `captureTime`, or nil ("unknown"). Validates BOTH freshness
    /// (relative to the capture instant) AND horizontal accuracy. Pure read of the cached location.
    func fix(at captureTime: Date) -> LocationFix? {
        guard isAuthorized, let loc = lastLocation else { return nil }
        return Self.validate(location: loc, captureTime: captureTime,
                             freshnessWindow: freshnessWindow, maxAccuracyMeters: maxAccuracyMeters)
    }

    /// Pure validation (unit-testable without CoreLocation delegate plumbing): a fix is trustworthy iff
    /// its horizontal accuracy is positive and within bound AND it is within the freshness window of the
    /// capture time (in either direction — a fix slightly after the start is still the capture location).
    static func validate(location loc: CLLocation,
                         captureTime: Date,
                         freshnessWindow: TimeInterval,
                         maxAccuracyMeters: Double) -> LocationFix? {
        let acc = loc.horizontalAccuracy
        guard acc > 0, acc <= maxAccuracyMeters else { return nil }
        guard abs(loc.timestamp.timeIntervalSince(captureTime)) <= freshnessWindow else { return nil }
        return LocationFix(latitude: loc.coordinate.latitude,
                           longitude: loc.coordinate.longitude,
                           horizontalAccuracyMeters: acc,
                           timestamp: loc.timestamp)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        startIfAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let latest = locations.last { lastLocation = latest }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Non-fatal: keep the last good fix (if any); a capture simply reads nil if none is trustworthy.
    }
}
