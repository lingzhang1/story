import AVFoundation
import Foundation

// RenderSupport — bridges persisted Moments to the Media Engine and builds a deterministic, known-valid
// EditPlan/2 fixture for the DEBUG render harness. NO network, NO Epidemic, NO creative decisions.

struct MomentMedia {
    let momentId: UUID
    let relativePath: String
    let durationSeconds: Double
}

enum MomentResolver {
    /// Resolve a Story's Moments to their on-device media (id, relative path, duration). Skips Moments whose
    /// file is missing — the CALLER decides whether that is fatal (the renderer hard-fails on an unresolved id).
    static func resolve(moments: [MomentModel]) -> [MomentMedia] {
        var out: [MomentMedia] = []
        for m in moments.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let rel = m.asset?.relativePath, MediaStore.shared.fileExists(relativePath: rel) else { continue }
            let url = MediaStore.shared.absoluteURL(for: rel)
            let dur = AVURLAsset(url: url).duration.seconds
            out.append(MomentMedia(momentId: m.id, relativePath: rel,
                                   durationSeconds: dur.isFinite && dur > 0 ? dur : 0))
        }
        return out
    }

    /// A Media-Engine URL resolver closure keyed by the Moment id STRING (matches EditSegmentV2.assetId).
    static func urlResolver(for media: [MomentMedia]) -> (String) -> URL? {
        let map = Dictionary(uniqueKeysWithValues: media.map { ($0.momentId.uuidString, $0.relativePath) })
        return { id in map[id].map { MediaStore.shared.absoluteURL(for: $0) } }
    }
}

enum DebugEditPlanFixture {
    /// A deterministic, KNOWN-VALID EditPlan/2 over the given resolved Moments: straight cuts, each Moment
    /// trimmed to a short head window, native_audio=keep on the first (so Case B is exercisable), duck on the
    /// rest, output = vertical, no music_alignment (no analysis). Scales output to a target.
    static func montage(media: [MomentMedia], targetSeconds: Double = 12.0, outputFormat: String = "vertical") -> EditPlanV2 {
        let n = max(1, media.count)
        let per = max(1.0, targetSeconds / Double(n))
        var segs: [EditSegmentV2] = []
        for (i, m) in media.enumerated() {
            let span = min(per, max(1.0, m.durationSeconds))
            segs.append(EditSegmentV2(
                order: i, assetId: m.momentId.uuidString,
                sourceStartSeconds: 0.0, sourceEndSeconds: span,
                outputDurationSeconds: round(span * 100) / 100,
                speed: 1.0, nativeAudio: i == 0 ? "keep" : "duck", musicAlignment: nil))
        }
        let total = segs.reduce(0.0) { $0 + $1.outputDurationSeconds }
        return EditPlanV2(schemaVersion: "edit_plan/2", targetDurationSeconds: total,
                          outputFormat: outputFormat, musicAssetId: nil, feasible: true, segments: segs)
    }

    /// Decode a real EditPlan/2 JSON (e.g. from the deployed /v1/edit-plan) into the renderer DTO.
    static func decode(_ json: Data) throws -> EditPlanV2 {
        try JSONDecoder().decode(EditPlanV2.self, from: json)
    }
}
