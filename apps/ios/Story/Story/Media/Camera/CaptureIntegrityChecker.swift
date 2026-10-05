import Foundation
import AVFoundation

// CaptureIntegrityChecker — C4-Lite (Milestone C4-Lite).
//
// A LOCAL, synchronous, no-AI / no-network / no-AWS capture-INTEGRITY gate. It answers
// exactly one narrow question after a clip is recorded: "is this an OBVIOUSLY broken
// capture?" It is NOT a Shot-success validator and makes NO semantic claim — it never
// decides Shot fulfilled, Beat fulfilled, semantic success, or Story utility. Those move
// to the future asynchronous Asset Understanding.
//
// Adoption (per milestone-c4l-a-heuristic-adoption-report.md): the T01 no-AI heuristic
// sweep found that ONLY file-readability and an absolute catastrophic-duration floor
// separate obvious failures from legitimate footage with zero false rejection. Exposure
// (over), shake, and focus heuristics all overlapped legitimate footage and were REJECTED;
// underexposure had a clean gap but only one failure sample, so it is NOT a default gate.
// => C4-Lite MVP ships exactly file_readable + duration. Bias is strongly toward SAVE.
//
// CaptureIntegrityVerdict is the SOURCE OF TRUTH for C4-Lite. ValidationResult (frozen
// contract) is produced only as an adapter at a boundary that needs it; `.accept` there
// means "no obvious integrity failure", NOT semantic Shot success.

/// The physical, non-semantic reasons a capture can be rejected as obviously broken.
/// Each maps to a frozen `ValidationIssue` code (02 §20) via the adapter.
enum CaptureIntegrityIssue: String, Equatable, Codable, CaseIterable {
    case unreadableFile          // file missing / empty / not a decodable video
    case tooShort                // duration below the catastrophic absolute floor

    /// Plain, physical, NON-semantic user sentence. Never mentions shot/beat/purpose.
    var userReason: String {
        switch self {
        case .unreadableFile: return "That one didn't record properly."
        case .tooShort:       return "That one was too short to use."
        }
    }

    /// Frozen `ValidationIssue` enum code (02 §20) for the adapter, or nil when the frozen
    /// enum has no honest code for this physical failure. The frozen enum has no
    /// "unreadable/corrupt file" code, so `unreadableFile` maps to nil (the adapter emits
    /// usable:false/retake with an empty issues list) rather than borrowing a semantic code
    /// like `subject_missing`. C4-Lite deliberately adds NO new ValidationIssue code.
    var validationIssueCode: ValidationIssueDTO? {
        switch self {
        case .unreadableFile: return nil         // no honest frozen code; keep issues empty
        case .tooShort:       return .tooShort
        }
    }
}

/// C4-Lite source-of-truth verdict. `.save` or `.fail(issue)`.
enum CaptureIntegrityVerdict: Equatable {
    case save
    case fail(CaptureIntegrityIssue)

    var isSave: Bool { if case .save = self { return true } else { return false } }
    var issue: CaptureIntegrityIssue? { if case .fail(let i) = self { return i } else { return nil } }
}

/// Tunable C4-Lite thresholds. Chosen from the C4L-A corpus scan, not model output.
struct CaptureIntegrityConfig {
    /// Catastrophic absolute duration floor (seconds). The corpus had exactly two clips
    /// under 1.0s (both 0.47s) and the next legitimate clip at 1.37s — so 0.8s isolates
    /// the obviously-too-short captures with wide margin and zero false rejection.
    /// This is NOT the Director's requested `target_duration_seconds`: a clip shorter than
    /// the requested length is still a usable Moment; C4-Lite only flags obvious breakage.
    var minDurationSeconds: Double = 0.8
    static let `default` = CaptureIntegrityConfig()
}

/// Pure, local capture-integrity checker. No AI, no network, no AWS.
struct CaptureIntegrityChecker {
    let config: CaptureIntegrityConfig
    init(config: CaptureIntegrityConfig = .default) { self.config = config }

    // MARK: pure derivation (the testable core)

    /// Derive the verdict from already-measured facts. SAVE unless a hard check fails.
    /// Order: unreadable (MUST) before too-short, so a broken file reports the file
    /// problem rather than an incidental zero duration.
    func verdict(isReadableVideo: Bool, durationSeconds: Double) -> CaptureIntegrityVerdict {
        if !isReadableVideo { return .fail(.unreadableFile) }
        if durationSeconds < config.minDurationSeconds { return .fail(.tooShort) }
        return .save   // bias toward SAVE; no semantic judgment made
    }

    // MARK: device entry (measures facts locally, then derives)

    /// Evaluate a captured temp file on-device. Loads the asset to confirm it is a
    /// readable video with a positive duration, then applies `verdict(...)`.
    func evaluate(fileURL: URL) -> CaptureIntegrityVerdict {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > 0 else {
            return .fail(.unreadableFile)
        }
        let asset = AVURLAsset(url: fileURL)
        let dur = CMTimeGetSeconds(asset.duration)
        let hasVideoTrack = !asset.tracks(withMediaType: .video).isEmpty
        let readable = hasVideoTrack && dur.isFinite && dur > 0
        return verdict(isReadableVideo: readable, durationSeconds: readable ? dur : 0)
    }
}

// MARK: - Frozen-contract adapter (only where a boundary needs ValidationResult)

/// Adapter to the frozen `ValidationResult` (02 §20) for any boundary that still speaks
/// that contract. `.save` -> usable/accept; `.fail` -> unusable/retake with the issue code.
/// NOTE: `.accept` here asserts "no obvious integrity failure", NOT semantic Shot success —
/// C4-Lite never claims the requested Shot/Beat was fulfilled.
extension CaptureIntegrityVerdict {
    func asValidationResult() -> ValidationResultContractDTO {
        switch self {
        case .save:
            return ValidationResultContractDTO(usable: true, recommendation: .accept,
                                               confidence: nil, issues: [],
                                               shotId: nil, captureAssetId: nil)
        case .fail(let issue):
            let issues = issue.validationIssueCode.map { [$0] } ?? []
            return ValidationResultContractDTO(usable: false, recommendation: .retake,
                                               confidence: nil, issues: issues,
                                               shotId: nil, captureAssetId: nil)
        }
    }
}
