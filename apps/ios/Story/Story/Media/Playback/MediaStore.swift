import Foundation

// MediaStore — the ONLY place that maps a persisted relative media path
// to an absolute on-device URL. Everything else stores/reads relative
// paths so media survives app relaunches (the container path changes,
// the relative path does not).
//
// Media lives under: <Documents>/media/<uuid>.mov
// Originals stay on-device. Nothing here uploads or creates cloud URLs.

struct MediaStore {
    static let shared = MediaStore()

    private let mediaDirName = "media"

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var mediaDirURL: URL {
        documentsURL.appendingPathComponent(mediaDirName, isDirectory: true)
    }

    /// Ensure the media directory exists; call once at launch.
    func ensureMediaDirectory() {
        try? FileManager.default.createDirectory(
            at: mediaDirURL, withIntermediateDirectories: true)
    }

    /// A fresh relative path for a new capture, e.g. "media/<uuid>.mov".
    func newRelativeVideoPath() -> String {
        "\(mediaDirName)/\(UUID().uuidString).mov"
    }

    /// Resolve a persisted relative path to an absolute URL.
    func absoluteURL(for relativePath: String) -> URL {
        documentsURL.appendingPathComponent(relativePath)
    }

    /// Whether the media file actually exists on disk (survives relaunch check).
    func fileExists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: absoluteURL(for: relativePath).path)
    }

    /// Move a freshly-captured temp file into the media directory,
    /// returning the RELATIVE path to persist.
    @discardableResult
    func adoptCapturedFile(tempURL: URL) throws -> String {
        ensureMediaDirectory()
        let relative = newRelativeVideoPath()
        let dest = absoluteURL(for: relative)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return relative
    }
}
