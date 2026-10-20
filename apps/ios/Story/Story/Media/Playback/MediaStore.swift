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

    // MARK: - R6 download/restoration support

    private var downloadsDirName: String { "downloads" }
    private var downloadsDirURL: URL {
        documentsURL.appendingPathComponent(downloadsDirName, isDirectory: true)
    }

    /// A fresh temp URL under <Documents>/downloads/ for an in-flight restore. Lives under Documents (not the
    /// OS temp dir) so a partial survives relaunch and can be deterministically cleaned/restarted (req #5/#7).
    func newDownloadTempURL() -> URL {
        try? FileManager.default.createDirectory(at: downloadsDirURL, withIntermediateDirectories: true)
        return downloadsDirURL.appendingPathComponent(UUID().uuidString + ".download")
    }

    /// Discard any leftover partial downloads (called at launch — a whole-file-retry model never reuses them).
    func purgeDownloadTemps() {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: downloadsDirURL, includingPropertiesForKeys: nil) else { return }
        for u in items { try? FileManager.default.removeItem(at: u) }
    }

    /// Atomically INSTALL a verified downloaded original at `relativePath` (req #4 / safeguard #1). The source
    /// is a fully-downloaded+verified temp file; this replaces the (missing) original in one rename on the same
    /// volume, so a crash mid-install leaves either no file or the complete verified file — never a partial.
    /// Returns true on success. NEVER called with an unverified source (MediaDownloadService verifies first).
    @discardableResult
    func installDownloadedOriginal(from verifiedTempURL: URL, to relativePath: String) throws -> Bool {
        ensureMediaDirectory()
        let dest = absoluteURL(for: relativePath)
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Replace atomically. replaceItemAt is atomic when src+dst share a volume (both under Documents).
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: verifiedTempURL)
        } else {
            try FileManager.default.moveItem(at: verifiedTempURL, to: dest)
        }
        return true
    }
}
