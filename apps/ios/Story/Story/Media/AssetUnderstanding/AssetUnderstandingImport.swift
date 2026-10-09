import Foundation
import SwiftData

// AssetUnderstanding — IMPORT lifecycle integration (R-c.1). Imported video Moments must receive the SAME
// Asset Understanding as directed captures. This is a thin lifecycle layer over the FROZEN
// AssetUnderstandingQueue — it enqueues jobs and relies on the queue's existing guarantees (persistence,
// idempotent enqueue, orphan recovery, bounded backoff, idempotent MomentUnderstanding upsert, deleted-Moment
// discard). NO new queue, NO AU model/prompt/frame-policy change, NO Scene Understanding, NO photo understanding.
//
// Capture context is nil for imports: an imported clip has no requested Shot/Beat, and the AU request is
// explicitly contextless (06-asset-understanding.md allows a contextless Moment). We never fabricate one.
extension AssetUnderstandingQueue {

    /// A Moment is an ANALYZABLE VIDEO iff it has a resolvable local file AND a positive duration. Imported
    /// stills (a future photo path) would have duration 0 and are deliberately NOT enqueued into the video
    /// AU pipeline (§6). Source type is NOT a gate — directed, existing_media and camera_import all qualify;
    /// we only require real decodable video material.
    static func isAnalyzableVideo(_ moment: MomentModel) -> Bool {
        guard let asset = moment.asset else { return false }
        guard asset.durationSeconds > 0 else { return false }                 // stills / unreadable -> skip
        return MediaStore.shared.fileExists(relativePath: asset.relativePath)  // file must be durable on disk
    }

    /// Enqueue AU for freshly-imported VIDEO Moments (called AFTER addExistingMedia has persisted them and the
    /// files are durable in MediaStore). Contextless (no Shot/Beat). Idempotent via the queue's existing
    /// per-momentId guard, so re-calling is harmless. Returns the count actually enqueued (for logging/tests).
    @discardableResult
    func enqueueImportedVideos(_ moments: [MomentModel]) -> Int {
        var enqueued = 0
        for m in moments where Self.isAnalyzableVideo(m) {
            guard let rel = m.asset?.relativePath else { continue }
            enqueue(momentId: m.id, relativeMediaPath: rel, sourceCaptureId: nil, captureContext: nil)
            enqueued += 1
        }
        return enqueued
    }

    /// One-time LAZY backfill for videos imported BEFORE this feature existed. Enqueues an AU job for each
    /// analyzable-video Moment of the Story that has NEITHER a completed MomentUnderstanding NOR an existing
    /// job. Idempotent and cheap: a Moment already understood or already queued is skipped, so calling this on
    /// every Story-open does NOT re-enqueue or duplicate analysis. Preserves all media (never deletes). Returns
    /// the count enqueued. The `context` is the caller's ModelContext (used only to read existing MU/job rows).
    @discardableResult
    func backfillImports(for story: StoryModel, context: ModelContext) -> Int {
        // Moment ids that already have a completed/own understanding row.
        let understoodIds = Set(
            ((try? context.fetch(FetchDescriptor<MomentUnderstandingModel>())) ?? [])
                .map { $0.momentId }
        )
        // Moment ids that already have ANY job row (pending/running/complete) — the queue's own idempotency.
        let jobIds = Set(
            ((try? context.fetch(FetchDescriptor<AssetUnderstandingJobModel>())) ?? [])
                .map { $0.momentId }
        )
        var enqueued = 0
        for m in story.moments where Self.isAnalyzableVideo(m) {
            if understoodIds.contains(m.id) || jobIds.contains(m.id) { continue }
            guard let rel = m.asset?.relativePath else { continue }
            enqueue(momentId: m.id, relativeMediaPath: rel, sourceCaptureId: nil, captureContext: nil)
            enqueued += 1
        }
        return enqueued
    }
}
