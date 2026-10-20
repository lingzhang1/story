import Foundation
import SwiftData
import CryptoKit

// R7-C — `story_doc/1` cloud mapping. Encodes a StoryModel + its relations into the account-owned cloud
// document shape the backend stores, and decodes a pulled document back into local SwiftData. PURE mapping
// logic lives in `StoryDocCodec` (dictionary <-> fields) so it is unit-testable without SwiftData; the
// SwiftData bridge (`encode(story:)` / `apply(_:into:)`) sits at the edges.
//
// INVARIANTS (owner):
//  - schema_version is "story_doc/1"; an UNSUPPORTED version is REJECTED explicitly (never best-effort decoded).
//  - NEVER carry a device-local absolute/relative file path as an authoritative cloud reference. A Moment ref
//    carries its STABLE moment_id + cloud_media_id (bytes resolve via R6); relativePath is intentionally absent.
//  - Frozen EditPlan contract is reused UNCHANGED (R7-C stores output METADATA + lineage; full edit-plan JSON
//    externalization and MP4 backup are R7-D — here outputs carry provenance + a nil cloud_media_id).

enum StoryDocError: Error, LocalizedError {
    case unsupportedSchema(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): return "Unsupported story document schema: \(v)"
        }
    }
}

enum StoryDocCodec {
    static let schemaVersion = "story_doc/1"

    // MARK: - encode (SwiftData -> cloud dict)

    @MainActor
    static func encode(story s: StoryModel) -> [String: Any] {
        var story: [String: Any] = [
            "id": s.id.uuidString,
            "title": s.title,
            "status": s.statusRaw,
            "intent": [
                "raw_text": s.intentRawText, "theme": s.intentTheme, "tone": s.intentTone,
                "summary": s.intentSummary,
                "subject": s.intentSubject as Any,
                "desired_feeling": s.intentDesiredFeeling, "style_tags": s.intentStyleTags,
                "emphasis": s.intentEmphasis, "constraints": s.intentConstraints,
                "pace": s.intentPace as Any, "target_duration_seconds": s.intentTargetDurationSeconds as Any,
            ],
            "created_at": s.createdAt.timeIntervalSince1970,
            "updated_at": s.updatedAt.timeIntervalSince1970,
        ]
        // Optional preferences / direction (only when present — keeps the doc compact + stable).
        story["sound_preference_explicit"] = s.soundPreferenceExplicit as Any
        story["editorial_mode"] = s.editorialMode as Any
        story["editing_approach_explicit"] = s.editingApproachExplicit as Any
        story["creative_directives_json"] = s.creativeDirectivesJSON as Any
        story["creative_direction_text"] = s.creativeDirectionText as Any
        story["plan_operation_id"] = s.planOperationId as Any
        story["plan_job_id"] = s.planJobId as Any

        // Moment refs in link order (NO local path — stable id + cloud ref only).
        let links = s.momentLinks.sorted {
            ($0.orderIndex ?? Int.max, $0.addedAt) < ($1.orderIndex ?? Int.max, $1.addedAt)
        }
        let momentRefs: [[String: Any]] = links.compactMap { link in
            guard let m = link.moment else { return nil }
            return [
                "moment_id": m.id.uuidString,
                "order_index": link.orderIndex as Any,
                "added_at": link.addedAt.timeIntervalSince1970,
                "caption": m.caption as Any,
                "source": m.sourceRaw,
                "cloud_media_id": m.cloudMediaId as Any,
                "cloud_verified": (m.cloudStateRaw == "cloud_verified"),
                "duration_seconds": m.asset?.durationSeconds as Any,
                "captured_at": m.asset?.capturedAt?.timeIntervalSince1970 as Any,
            ]
        }

        // GeneratedOutput METADATA + lineage (R7-C: metadata only; cloud_media_id is nil until R7-D backup).
        let outputs: [[String: Any]] = s.generatedOutputs.sorted { $0.createdAt < $1.createdAt }.map { o in
            [
                "output_id": o.id.uuidString,
                "title": o.title,
                "duration_seconds": o.durationSeconds,
                "source_moment_ids": (o.sourceMomentIds.isEmpty ? o.momentIds : o.sourceMomentIds).map { $0.uuidString },
                "source_fingerprint": o.sourceFingerprint,
                "edit_plan_provenance": o.editPlanProvenance,
                "cloud_media_id": NSNull(),   // R7-D will populate this + the full edit-plan reference
                "cloud_verified": false,
            ]
        }

        var doc: [String: Any] = [
            "schema_version": schemaVersion,
            "story": story,
            "moment_refs": momentRefs,
            "outputs": outputs,
        ]
        doc["music_direction"] = NSNull()   // populated by the SwiftData bridge when a direction row exists
        return doc
    }

    /// All cloud_media_ids the doc depends on (for the PUT's referenced_cloud_media_ids — server verifies C3).
    static func referencedCloudMediaIds(_ doc: [String: Any]) -> [String] {
        var ids: [String] = []
        for r in (doc["moment_refs"] as? [[String: Any]]) ?? [] {
            if let c = r["cloud_media_id"] as? String, !c.isEmpty { ids.append(c) }
        }
        for o in (doc["outputs"] as? [[String: Any]]) ?? [] {
            if let c = o["cloud_media_id"] as? String, !c.isEmpty { ids.append(c) }
        }
        return Array(Set(ids))
    }

    /// True if any referenced Moment is not yet cloud_verified — the caller reports incomplete backup honestly.
    static func hasIncompleteDependencies(_ doc: [String: Any]) -> Bool {
        for r in (doc["moment_refs"] as? [[String: Any]]) ?? [] {
            let verified = (r["cloud_verified"] as? Bool) ?? false
            if !verified { return true }
        }
        return false
    }

    /// Reject an unsupported schema BEFORE any decode (owner: explicit rejection, never best-effort).
    static func validateSchema(_ doc: [String: Any]) throws {
        let v = (doc["schema_version"] as? String) ?? ""
        guard v == schemaVersion else { throw StoryDocError.unsupportedSchema(v) }
    }

    /// A stable content hash of the SYNCED fields, used to decide dirtiness (current vs last-synced) without
    /// instrumenting every mutation site. Order-independent via sorted JSON.
    static func contentHash(_ doc: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data()
        return sha256Hex(data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
