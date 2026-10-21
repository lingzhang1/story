import Foundation
import CryptoKit

// R7 Phase 4 — ai_artifact externalization.
//
// The backend caps a Story document at 350 KB and FAILS explicitly (413) rather than truncating, so a Story
// with many large validated EditPlans must externalize the oversized plans out of the inline doc. This engine
// does that WITHOUT inventing a second artifact store: an EditPlan blob is immutable, content-addressed bytes,
// so it rides the EXISTING R4 media upload / R6 verified download pipeline with media_kind="ai_artifact". The
// Story document then carries a durable reference — {cloud_media_id, sha256, bytes, schema_version} — in place
// of the inline JSON, and Device B resolves it by the normal size+full-file-SHA256-verified download.
//
// Guarantees (owner Phase 4):
//   • content-addressed + immutable (cloud_media_id = uuid5(owner+sha256), server-side)
//   • account-scoped authorization (the media download endpoint 404s another account)
//   • FULL SHA256 verification before the bytes are trusted (MediaDownloadService verifies size+sha256)
//   • version/schema metadata carried on the reference
//   • durable references from the Story document
//   • NO deletion of referenced artifacts (the media store never deletes; retention is reference-safe)
//   • EXPLICIT failure if an artifact cannot be restored (throws — never silently omits a version)
//   • NO silent omission of version history (we externalize, we do not drop)

/// A durable, content-addressed reference to an externalized AI blob, stored inside the Story doc in place of
/// the inline JSON. Shape (JSON): {"cloud_media_id","sha256","bytes","schema_version","kind":"edit_plan"}.
struct AIArtifactRef: Equatable {
    let cloudMediaId: String
    let sha256: String
    let bytes: Int
    let schemaVersion: String
    let kind: String            // "edit_plan"

    var asDict: [String: Any] {
        ["cloud_media_id": cloudMediaId, "sha256": sha256, "bytes": bytes,
         "schema_version": schemaVersion, "kind": kind]
    }

    init(cloudMediaId: String, sha256: String, bytes: Int, schemaVersion: String, kind: String = "edit_plan") {
        self.cloudMediaId = cloudMediaId; self.sha256 = sha256; self.bytes = bytes
        self.schemaVersion = schemaVersion; self.kind = kind
    }

    init?(_ dict: [String: Any]) {
        guard let cmid = dict["cloud_media_id"] as? String, !cmid.isEmpty,
              let sha = dict["sha256"] as? String, !sha.isEmpty else { return nil }
        self.cloudMediaId = cmid
        self.sha256 = sha
        self.bytes = (dict["bytes"] as? Int) ?? (dict["bytes"] as? NSNumber)?.intValue ?? 0
        self.schemaVersion = (dict["schema_version"] as? String) ?? "edit_plan/2"
        self.kind = (dict["kind"] as? String) ?? "edit_plan"
    }
}

enum AIArtifactError: LocalizedError {
    case uploadFailed(String)
    case resolveFailed(cloudMediaId: String, underlying: String)
    case integrity(cloudMediaId: String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let m): return "ai_artifact upload failed: \(m)"
        case .resolveFailed(let cmid, let u): return "ai_artifact \(cmid) could not be restored: \(u)"
        case .integrity(let cmid): return "ai_artifact \(cmid) failed integrity verification"
        }
    }
}

/// Externalize / resolve engine. Owner is bound per call (never read from a global). Uses the existing media
/// upload + download services; a scratch file carries the JSON bytes (the upload path is file-based). The
/// scratch file is always removed after the upload attempt.
struct AIArtifactStore {
    var uploader: MediaUploading = MediaUploadService()
    var downloader: MediaDownloading = MediaDownloadService()

    /// Upload an immutable JSON blob as an ai_artifact and return its durable reference. Content-addressed:
    /// re-uploading identical bytes by the same owner maps to the SAME cloud_media_id (idempotent, no dup).
    /// Throws if the upload cannot be verified — the caller must NOT externalize (it would drop a version).
    func externalize(json: String, accessToken: String, sourceOutputId: String,
                     schemaVersion: String) async throws -> AIArtifactRef {
        let data = Data(json.utf8)
        let sha = Self.sha256Hex(data)
        let size = data.count
        // Write to scratch (the media upload path PUTs a file). $KIROCREW_SCRATCH is session-owned; on device
        // this resolves to the app's temp dir. Always cleaned up.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiartifact-\(sha).json")
        try data.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let init0 = try await uploader.initiate(
                accessToken: accessToken, sha256: sha, size: size,
                deviceAssetId: "", sourceMomentId: "",
                mediaKind: CloudMediaKind.aiArtifact, sourceOutputId: sourceOutputId,
                contentType: "application/json")
            // ai_artifacts are small relative to video; a single presigned PUT is always sufficient here.
            try await uploader.putToS3(uploadURL: init0.uploadURL, fileURL: tmp,
                                       sha256Hex: sha, contentType: "application/json")
            try await uploader.complete(accessToken: accessToken, cloudMediaId: init0.cloudMediaId)
            return AIArtifactRef(cloudMediaId: init0.cloudMediaId, sha256: sha, bytes: size,
                                 schemaVersion: schemaVersion)
        } catch {
            throw AIArtifactError.uploadFailed("\(error)")
        }
    }

    /// Resolve a reference to its verified JSON string. Downloads to scratch, verifying size+full-file sha256
    /// (the download service enforces both), re-checks the declared sha, reads the bytes back, and removes the
    /// scratch file. Throws explicitly if the artifact cannot be restored — NEVER returns partial/empty.
    func resolve(_ ref: AIArtifactRef, accessToken: String) async throws -> String {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiartifact-dl-\(ref.cloudMediaId).json")
        try? FileManager.default.removeItem(at: dest)
        defer { try? FileManager.default.removeItem(at: dest) }
        do {
            let target = try await downloader.presignDownload(accessToken: accessToken,
                                                              cloudMediaId: ref.cloudMediaId)
            try await downloader.download(target: target, to: dest, progress: nil)
        } catch {
            throw AIArtifactError.resolveFailed(cloudMediaId: ref.cloudMediaId, underlying: "\(error)")
        }
        guard let data = try? Data(contentsOf: dest) else {
            throw AIArtifactError.resolveFailed(cloudMediaId: ref.cloudMediaId, underlying: "read")
        }
        // Belt-and-braces: the download service already verified against the SERVER's sha; re-check against the
        // sha the Story doc declared, so a doc/record mismatch is caught rather than trusted.
        guard Self.sha256Hex(data) == ref.sha256 else { throw AIArtifactError.integrity(cloudMediaId: ref.cloudMediaId) }
        guard let s = String(data: data, encoding: .utf8) else {
            throw AIArtifactError.resolveFailed(cloudMediaId: ref.cloudMediaId, underlying: "utf8")
        }
        return s
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
