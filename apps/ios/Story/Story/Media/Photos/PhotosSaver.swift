import Foundation
import Photos
import CoreLocation

// PhotosSaver — save a user-owned COPY of a captured original into Apple Photos,
// using ADD-ONLY permission (never full read access). This is a product-trust
// feature (Milestone D §13): Story's working copy under <Documents>/media stays
// authoritative; Photos gets an independent copy the user sees and owns outside
// Story, so deleting Story/the app does not destroy the only copy.
//
// CONTRACT (deliberate, do not couple to Moment creation):
//  - Moment creation NEVER depends on this. Call it AFTER the Moment is already
//    persisted, fire-and-forget.
//  - Add-only authorization (.addOnly). We never request read/full access.
//  - Denial or failure degrades silently (logged); the Story copy is untouched.
//  - Duplicate storage is accepted for MVP (one copy in Photos, one in Story).
//  - Imported media is OUT OF SCOPE: only direct captures call this.
enum PhotosSaveOutcome: Equatable {
    case saved
    case permissionDenied
    case failed(String)
    case skipped(String)
}

enum PhotosSaver {
    /// Save `fileURL` (an on-device original) as a video into the user's Photos
    /// library, add-only. Non-blocking: returns via completion on a background queue.
    /// Safe to call even if authorization is undetermined — it requests add-only.
    ///
    /// Camera Metadata P0: when known, the capture `creationDate` and a trustworthy `location` are set on
    /// the Photos asset so the user's own copy is correctly dated + placed. Both optional — nil leaves the
    /// Photos default (file date, no location). Location is coordinates+accuracy only; never a place name.
    static func saveVideoCopy(at fileURL: URL,
                              creationDate: Date? = nil,
                              location: CLLocation? = nil,
                              completion: ((PhotosSaveOutcome) -> Void)? = nil) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            completion?(.skipped("source file missing")); return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges {
                    let req = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                    if let creationDate { req?.creationDate = creationDate }
                    if let location { req?.location = location }
                } completionHandler: { ok, error in
                    if ok {
                        completion?(.saved)
                    } else {
                        completion?(.failed(error?.localizedDescription ?? "unknown Photos error"))
                    }
                }
            case .denied, .restricted:
                completion?(.permissionDenied)
            case .notDetermined:
                completion?(.skipped("authorization still undetermined"))
            @unknown default:
                completion?(.skipped("unknown authorization status"))
            }
        }
    }
}
