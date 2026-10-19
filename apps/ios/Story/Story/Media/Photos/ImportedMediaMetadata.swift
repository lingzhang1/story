import Foundation
import AVFoundation
import CoreLocation

// ImportedMediaMetadata — recover the ORIGINAL capture date + location of an imported video from the
// file's OWN embedded metadata (Camera Metadata P0, safeguard 5).
//
// Deliberately does NOT depend on a PHAsset / PhotosPicker asset identifier: PhotosPicker does not reliably
// expose one without Photos READ authorization (we only ever use add-only), so relying on it would silently
// fail. Reading the copied file's AVAsset common metadata works with NO extra authorization. When the file
// carries neither, both fields are nil ("unknown") — never fabricated.
enum ImportedMediaMetadata {

    struct Recovered: Equatable {
        var capturedAt: Date?
        var latitude: Double?
        var longitude: Double?
    }

    /// Read creationDate + ISO-6709 location from an asset's common metadata. Async (AVAsset load).
    static func recover(from asset: AVAsset) async -> Recovered {
        var out = Recovered()
        let items = (try? await asset.load(.commonMetadata)) ?? []
        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyCreationDate:
                if let s = try? await item.load(.stringValue), let d = parseDate(s) { out.capturedAt = d }
                else if let d = try? await item.load(.dateValue) { out.capturedAt = d }
            case .commonKeyLocation:
                if let s = try? await item.load(.stringValue), let (lat, lon) = parseISO6709(s) {
                    out.latitude = lat; out.longitude = lon
                }
            default:
                break
            }
        }
        return out
    }

    /// Parse an ISO-6709 location string like "+37.33140-122.03010/" → (lat, lon). Pure/testable.
    /// Handles the leading-sign coordinate pairs QuickTime/MP4 use; returns nil on anything unexpected.
    static func parseISO6709(_ raw: String) -> (lat: Double, lon: Double)? {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        // Find the split between latitude and longitude: the SECOND sign character (the start of lon).
        guard let first = s.first, first == "+" || first == "-" else { return nil }
        var splitIndex: String.Index?
        var idx = s.index(after: s.startIndex)
        while idx < s.endIndex {
            let c = s[idx]
            if c == "+" || c == "-" { splitIndex = idx; break }
            idx = s.index(after: idx)
        }
        guard let split = splitIndex else { return nil }
        let latStr = String(s[s.startIndex..<split])
        // Longitude runs to the next sign (altitude, if present) or end.
        var lonEnd = s.index(after: split)
        while lonEnd < s.endIndex {
            let c = s[lonEnd]
            if c == "+" || c == "-" { break }
            lonEnd = s.index(after: lonEnd)
        }
        let lonStr = String(s[split..<lonEnd])
        guard let lat = Double(latStr), let lon = Double(lonStr) else { return nil }
        guard lat >= -90, lat <= 90, lon >= -180, lon <= 180 else { return nil }
        return (lat, lon)
    }

    /// Parse the common ISO-8601 forms QuickTime/MP4 creation-date metadata uses. Pure/testable.
    static func parseDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        // QuickTime sometimes omits the colon in the zone or uses a space — try a couple of fallbacks.
        let fmts = ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZZZZZ"]
        for f in fmts {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = f
            if let d = df.date(from: raw) { return d }
        }
        return nil
    }
}
