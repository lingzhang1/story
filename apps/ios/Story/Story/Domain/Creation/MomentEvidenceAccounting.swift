import Foundation

// MomentEvidenceAccounting — Editorial Pipeline v2, P0.
//
// A PRIVACY-SAFE, reconciling census of the create-time evidence funnel for ONE planning operation. It answers
// the owner's P0 question — "how much of the intended source evidence actually reached planning?" — with
// directly-established counts rather than inference from the final EditPlan.
//
// It carries NO raw media, NO frames, NO transcripts, NO prompt text, NO secrets. Only COUNTS and coarse,
// low-cardinality REASON buckets, plus opaque lowercased Moment-id lists for the two sets a developer must be
// able to intersect off-device (which eligible Moments lacked a sheet, and why). Moment ids are already
// non-secret identifiers that appear in the plan; no new user-content storage is created.
//
// Ownership of the stages (see the 12-stage funnel):
//   Device  (this struct, built in StoryCreationCoordinator): stages 1-10.
//   Backend (worker rev/plan diag):                            stages 11-12.
// The device serializes this into the plan request so the worker persists it on the job item alongside its own
// diagnostics — surviving the staging-payload TTL, since the item (not the staged body) is the durable record.

/// Why an eligible Moment ended up WITHOUT a contact sheet (stage 10). Low-cardinality, stable, greppable.
enum SheetMissReason: String, Codable, Equatable, CaseIterable {
    case notRequested          // visual evidence was not requested for this run (text-only approach)
    case evictedNotRestored    // local bytes absent and R6 restore did not make it local in time
    case unrestorable          // genuinely not restorable (reported by R6 as unavailable)
    case extractionEmpty       // frame extraction produced no frames (AVAssetImageGenerator empty)
    case extractionError       // frame extraction threw (unreadable / decode / track-load failure)
    case oversizeDropped       // sheet built but exceeded the per-sheet byte cap even at the smallest tier
    case budgetCoverageDropped // sheet built+sized but cut by the whole-payload byte budget (step 5)
}

/// Why a linked Moment was NOT eligible for planning (stages 2-5). Mutually exclusive, checked in gate order.
enum IneligibleReason: String, Codable, Equatable, CaseIterable {
    case noCompletedAU         // no completed/synced local MomentUnderstanding
    case noDuration            // AU present but no usable duration (local probe or cloud metadata both 0)
    case notRenderable         // bytes neither local nor cloud-restorable
}

/// One opaque, privacy-safe per-Moment accounting row. `id` is the lowercased Moment UUID string (the same
/// value already echoed in EditSegment.asset_id) — not new user content.
struct MomentEvidenceRow: Codable, Equatable {
    let id: String                      // lowercased Moment UUID
    let eligible: Bool
    let ineligibleReason: IneligibleReason?   // nil when eligible
    let hadSheet: Bool
    let sheetMissReason: SheetMissReason?     // nil when hadSheet, or when not eligible
}

/// The reconciling census. Every count is directly established on-device; none is inferred from EditPlan
/// segments. `reconciles` is a cheap invariant a test and the coordinator can both assert.
struct MomentEvidenceAccounting: Codable, Equatable {
    // Stage 1
    var linkedCount: Int = 0
    // Stages 2-5 (eligibility), per-reason
    var completedAUCount: Int = 0          // (2) linked Moments with a completed local AU
    var missingAUCount: Int = 0            // (3) linked Moments with NO completed local AU
    var positiveDurationCount: Int = 0     // (4) of AU-ready, those with a usable duration
    var renderableCount: Int = 0           // (5) of AU+duration, those renderable/restorable
    var eligibleCount: Int = 0             // (6) == serialized planner-Moment count (no cap/top-N)
    // Ineligibility reason tallies (sum == linkedCount - eligibleCount)
    var ineligibleNoAU: Int = 0
    var ineligibleNoDuration: Int = 0
    var ineligibleNotRenderable: Int = 0
    // Stages 7-10 (visual evidence)
    var visualRequested: Bool = false      // (8) whether this run requested contact sheets at all
    var sheetedCount: Int = 0              // (9) eligible Moments that got a sheet
    var missingSheetCount: Int = 0         // (10) eligible Moments without a sheet
    var sheetMissByReason: [String: Int] = [:]  // SheetMissReason.rawValue -> count (stable keys)
    // The two off-device-intersectable id sets (opaque, privacy-safe).
    var eligibleWithoutSheetIds: [String] = []   // eligible but planned blind this run
    var ineligibleIds: [String] = []             // linked but not planner-eligible

    // Build-provenance is attached separately (BuildProvenance) but echoed here for a single durable blob.

    /// True when the funnel is internally consistent — the coordinator asserts this before submit and a test
    /// asserts it on fixtures. It does NOT require sheet==eligible (text-only runs legitimately have 0 sheets);
    /// it requires the arithmetic between stages to hold.
    var reconciles: Bool {
        let eligibilityOK =
            completedAUCount == positiveDurationCountUpperBoundOK() &&   // see note below
            eligibleCount + ineligibleNoAU + ineligibleNoDuration + ineligibleNotRenderable == linkedCount &&
            missingAUCount == ineligibleNoAU &&
            eligibleCount == renderableCount
        let sheetOK =
            sheetedCount + missingSheetCount == eligibleCount &&
            sheetMissByReason.values.reduce(0, +) == missingSheetCount &&
            eligibleWithoutSheetIds.count == missingSheetCount &&
            ineligibleIds.count == (linkedCount - eligibleCount)
        return eligibilityOK && sheetOK
    }

    // completedAUCount counts AU-ready Moments; positiveDurationCount counts the subset with a duration. The
    // identity we assert is that every AU-ready Moment that was NOT dropped for noDuration had a duration, i.e.
    // positiveDurationCount == completedAUCount - ineligibleNoDuration.
    private func positiveDurationCountUpperBoundOK() -> Int {
        // Returns the value completedAUCount MUST equal for consistency, given the duration drops.
        positiveDurationCount + ineligibleNoDuration
    }

    /// A compact, stable dictionary for the plan-request JSON (privacy-safe; counts + reason buckets + the two
    /// id sets). Mirrors the backend's expected `evidence_accounting` shape.
    func asRequestDictionary() -> [String: Any] {
        [
            "linked": linkedCount,
            "completed_au": completedAUCount,
            "missing_au": missingAUCount,
            "positive_duration": positiveDurationCount,
            "renderable": renderableCount,
            "eligible": eligibleCount,
            "ineligible_no_au": ineligibleNoAU,
            "ineligible_no_duration": ineligibleNoDuration,
            "ineligible_not_renderable": ineligibleNotRenderable,
            "visual_requested": visualRequested,
            "sheeted": sheetedCount,
            "missing_sheet": missingSheetCount,
            "sheet_miss_by_reason": sheetMissByReason,
            "eligible_without_sheet_ids": eligibleWithoutSheetIds,
            "ineligible_ids": ineligibleIds,
            "reconciles": reconciles,
        ]
    }
}

/// Build provenance — proves WHICH code a run executed (so "the fix is on master" is never mistaken for "the
/// installed app ran the fix"). Privacy-safe: version strings and policy identifiers only.
struct BuildProvenance: Codable, Equatable {
    let appVersion: String          // CFBundleShortVersionString
    let buildNumber: String         // CFBundleVersion
    let commitSHA: String           // short git sha baked at build time (or "unknown")
    let framePolicy: String         // au_frames/1
    let extractionPolicy: String    // frame-extraction reliability policy version (this milestone bumps it)
    let requestedApproach: String   // storytelling | visual_first
    let multimodalEnabled: Bool

    func asRequestDictionary() -> [String: Any] {
        [
            "app_version": appVersion,
            "build_number": buildNumber,
            "commit_sha": commitSHA,
            "frame_policy": framePolicy,
            "extraction_policy": extractionPolicy,
            "requested_approach": requestedApproach,
            "multimodal_enabled": multimodalEnabled,
        ]
    }

    /// Resolve from the main bundle + the compile-time commit sha. `commitSHA` is read from Info.plist key
    /// `GitCommitSHA` when the build injects it; otherwise "unknown" (never inferred).
    static func current(requestedApproach: String, multimodalEnabled: Bool,
                        extractionPolicy: String) -> BuildProvenance {
        let info = Bundle.main.infoDictionary ?? [:]
        let app = (info["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (info["CFBundleVersion"] as? String) ?? "unknown"
        let sha = (info["GitCommitSHA"] as? String)?.trimmingCharacters(in: .whitespaces)
        return BuildProvenance(
            appVersion: app, buildNumber: build,
            commitSHA: (sha?.isEmpty == false ? sha! : "unknown"),
            framePolicy: MomentFrameExtractor.framePolicy,
            extractionPolicy: extractionPolicy,
            requestedApproach: requestedApproach,
            multimodalEnabled: multimodalEnabled)
    }
}
