import Foundation

// SceneScanStore — EPHEMERAL staging for Scene Scan frames.
//
// These JPEG frames are transient INFERENCE INPUTS, not user media. They are
// NEVER Moments or Assets, NEVER adopted via MediaStore.adoptCapturedFile, and
// NEVER persisted. They live under a temporary directory and MUST be swept
// away once the scene-understanding call completes (success or failure).
//
// This exists only because some callers prefer file URLs over in-memory Data;
// it owns nothing durable and guarantees cleanup.
struct SceneScanStore {

    private static let rootDirName = "scene-scan"

    private var rootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            Self.rootDirName, isDirectory: true)
    }

    private func sessionURL(_ sessionId: UUID) -> URL {
        rootURL.appendingPathComponent(sessionId.uuidString, isDirectory: true)
    }

    /// Write frames under scene-scan/<sessionId>/ and return their URLs.
    func writeFrames(_ frames: [Data], sessionId: UUID) throws -> [URL] {
        let dir = sessionURL(sessionId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, data) in frames.enumerated() {
            let url = dir.appendingPathComponent("frame-\(index).jpg")
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    /// Remove one session's staged frames. Best-effort; never throws.
    func cleanup(sessionId: UUID) {
        try? FileManager.default.removeItem(at: sessionURL(sessionId))
    }

    /// Remove the entire scene-scan directory (any leftover sessions).
    func sweepStale() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
