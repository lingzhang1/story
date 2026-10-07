import Foundation
import SwiftData

// SwiftData persistence models — the LOCAL PERSISTENCE representation.
//
// This is deliberately distinct from:
//   - the domain model (pure business objects, see Domain/Models)
//   - the API DTO (network wire shapes, see Data/API)
//
// LOCAL-FIRST MEDIA (spec 03 §Media, 06-camera-capture.md):
//   The captured video ORIGINAL never lives in SwiftData and never goes
//   to the cloud. AssetModel stores only a RELATIVE file path under the
//   app's Documents directory. Resolve it through MediaStore — never
//   persist an absolute path (the app container path changes across
//   installs/launches) and never persist Data blobs.
//
// StoryStatus for MVP: active | completed. Creating a GeneratedOutput
// must NOT change status (Create != Complete).

enum StoryStatus: String, Codable {
    case active
    case completed
}

enum MomentSource: String, Codable {
    case directed
    case spontaneous
    case existingMedia = "existing_media"
    case cameraImport = "camera_import"
}

@Model
final class StoryModel {
    @Attribute(.unique) var id: UUID
    var title: String
    var statusRaw: String

    // Structured CreativeIntent, flattened for persistence.
    var intentRawText: String
    var intentTheme: String
    var intentTone: String
    var intentSummary: String

    // Milestone C1: the REAL model-resolved CreativeIntent fields. Optional +
    // defaulted so existing persisted Stories remain valid (additive migration).
    var intentSubject: String?
    var intentDesiredFeeling: [String] = []
    var intentStyleTags: [String] = []
    var intentEmphasis: [String] = []
    var intentConstraints: [String] = []
    var intentPace: String?
    var intentTargetDurationSeconds: Double?

    var createdAt: Date
    var updatedAt: Date

    // Cascade: deleting a Story removes its Moments and Outputs.
    @Relationship(deleteRule: .cascade, inverse: \MomentModel.story)
    var moments: [MomentModel] = []

    @Relationship(deleteRule: .cascade, inverse: \GeneratedOutputModel.story)
    var generatedOutputs: [GeneratedOutputModel] = []

    var status: StoryStatus {
        get { StoryStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        status: StoryStatus = .active,
        intentRawText: String,
        intentTheme: String,
        intentTone: String,
        intentSummary: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.statusRaw = status.rawValue
        self.intentRawText = intentRawText
        self.intentTheme = intentTheme
        self.intentTone = intentTone
        self.intentSummary = intentSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class AssetModel {
    @Attribute(.unique) var id: UUID
    // RELATIVE path under Documents/ (e.g. "media/<uuid>.mov").
    // Resolve to an absolute URL only via MediaStore.
    var relativePath: String
    var durationSeconds: Double
    var sourceRaw: String
    var createdAt: Date

    var source: MomentSource {
        get { MomentSource(rawValue: sourceRaw) ?? .directed }
        set { sourceRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        relativePath: String,
        durationSeconds: Double,
        source: MomentSource,
        createdAt: Date = .now
    ) {
        self.id = id
        self.relativePath = relativePath
        self.durationSeconds = durationSeconds
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
    }
}

@Model
final class MomentModel {
    @Attribute(.unique) var id: UUID
    var story: StoryModel?
    var caption: String?
    var sourceRaw: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade)
    var asset: AssetModel?

    var source: MomentSource {
        get { MomentSource(rawValue: sourceRaw) ?? .directed }
        set { sourceRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        source: MomentSource,
        caption: String? = nil,
        asset: AssetModel? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceRaw = source.rawValue
        self.caption = caption
        self.asset = asset
        self.createdAt = createdAt
    }
}

@Model
final class GeneratedOutputModel {
    // A Story may have MANY GeneratedOutputs. This is METADATA only —
    // no rendered video for Milestone A (mock EditEngine).
    @Attribute(.unique) var id: UUID
    var story: StoryModel?
    var title: String
    var durationSeconds: Double
    // Snapshot of the moment ids this output was planned from.
    var momentIds: [UUID]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        durationSeconds: Double,
        momentIds: [UUID],
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.durationSeconds = durationSeconds
        self.momentIds = momentIds
        self.createdAt = createdAt
    }
}

// Opaque local identity — no account required (spec 03 §9).
@Model
final class LocalIdentityModel {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
    }
}

// ---------------------------------------------------------------------------
// Asset Understanding — Milestone D (06-asset-understanding.md, FROZEN)
//
// Two persisted records, both local-first:
//   - MomentUnderstandingModel: the ONE current understanding per Moment
//     (upsert by momentId). Stores the structured result as snake_case JSON
//     (the moment_understanding/1 wire contract) + provenance/version strings.
//     NEVER stores frame/image blobs (frames are transient request inputs).
//   - AssetUnderstandingJobModel: the persistent AU job queue state machine
//     (PENDING -> RUNNING -> COMPLETE; RUNNING -> PENDING on interruption),
//     with bounded exponential backoff. Keyed to the Moment + version triple
//     for idempotency; survives app termination.
// ---------------------------------------------------------------------------

enum AUJobState: String, Codable {
    case pending
    case running
    case complete
}

@Model
final class MomentUnderstandingModel {
    // One current record per Moment (upsert target). momentId is unique so a
    // re-run REPLACES rather than duplicates (idempotency, 06 §9).
    @Attribute(.unique) var momentId: UUID
    var sourceCaptureId: UUID?

    // Provenance / version (06 §3). Lets a corpus re-score know what produced this.
    var schemaVersion: String
    var framePolicy: String
    var promptVersion: String
    var modelId: String?
    var nFrames: Int?

    // The structured MomentUnderstanding, stored as the snake_case wire JSON
    // (moment_understanding/1). Decoded on read into the DTO. Keeping it as JSON
    // avoids a second hand-maintained SwiftData shape of the same contract.
    var understandingJSON: String

    var createdAt: Date
    var updatedAt: Date

    init(
        momentId: UUID,
        sourceCaptureId: UUID? = nil,
        schemaVersion: String,
        framePolicy: String,
        promptVersion: String,
        modelId: String?,
        nFrames: Int?,
        understandingJSON: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.momentId = momentId
        self.sourceCaptureId = sourceCaptureId
        self.schemaVersion = schemaVersion
        self.framePolicy = framePolicy
        self.promptVersion = promptVersion
        self.modelId = modelId
        self.nFrames = nFrames
        self.understandingJSON = understandingJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class AssetUnderstandingJobModel {
    // One job per Moment. momentId unique so enqueue is idempotent — re-adding a
    // Moment that already has a job does not create a second (06 §9).
    @Attribute(.unique) var momentId: UUID
    var relativeMediaPath: String
    var sourceCaptureId: UUID?

    // Capture context (requested Shot/Beat) as JSON, or nil for spontaneous/imported.
    var captureContextJSON: String?

    // Version triple the job is pinned to; a version change permits re-analysis.
    var framePolicy: String
    var promptVersion: String
    var schemaVersion: String

    var stateRaw: String
    var attempts: Int
    var lastError: String?
    // Earliest wall-clock time this job is eligible to run again (backoff).
    var nextEligibleAt: Date
    var createdAt: Date
    var updatedAt: Date

    var state: AUJobState {
        get { AUJobState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    init(
        momentId: UUID,
        relativeMediaPath: String,
        sourceCaptureId: UUID? = nil,
        captureContextJSON: String? = nil,
        framePolicy: String,
        promptVersion: String,
        schemaVersion: String,
        state: AUJobState = .pending,
        attempts: Int = 0,
        nextEligibleAt: Date = .now,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.momentId = momentId
        self.relativeMediaPath = relativeMediaPath
        self.sourceCaptureId = sourceCaptureId
        self.captureContextJSON = captureContextJSON
        self.framePolicy = framePolicy
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.stateRaw = state.rawValue
        self.attempts = attempts
        self.lastError = nil
        self.nextEligibleAt = nextEligibleAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// ---------------------------------------------------------------------------
// Story Coverage — Milestone E (story_coverage/1, FROZEN)
//
// The persisted CACHE of the latest valid StoryCoverage snapshot, one per Story
// (upsert by storyId). DERIVED, RECOMPUTABLE, ADVISORY — never user-authored
// truth. Full recomputation (no event sourcing, no incremental mutation): a new
// snapshot REPLACES the old one wholesale.
//
// LOCAL-FIRST / layer separation: like MomentUnderstandingModel, the structured
// result is stored as the snake_case wire JSON (story_coverage/1) and decoded on
// read into StoryCoverageDTO — we do NOT hand-maintain a second SwiftData shape
// of the same contract, and dimension ids are NOT persisted as identity (they
// live only inside the JSON blob as within-snapshot handles).
//
// STALENESS is computed from provenance, NOT a flag we mutate on the AI output:
//   - sourceUnderstandingIdsFingerprint: a stable hash of the SORTED set of
//     completed MomentUnderstanding ids (+ their updatedAt) the snapshot was
//     computed from. Changes when AU completes / a Moment is added or re-analyzed.
//   - creativeIntentFingerprint: a stable hash of the resolved CreativeIntent.
//   - pendingCount: stored so the UX can be honest about uncertainty.
// Coverage is STALE when either fingerprint no longer matches the Story's current
// inputs. A failed recompute preserves this row untouched (keep last valid).
@Model
final class StoryCoverageModel {
    @Attribute(.unique) var storyId: UUID

    // The structured StoryCoverage, stored as snake_case wire JSON (story_coverage/1).
    var coverageJSON: String

    // Provenance for staleness (NOT the AI's own fields).
    var sourceUnderstandingIdsFingerprint: String
    var creativeIntentFingerprint: String
    // E2-c: Coverage/2 is Guide-relative — a Guide change (new version) also makes Coverage stale.
    var storyGuideFingerprint: String = ""
    var pendingCount: Int

    var schemaVersion: String
    var modelId: String?
    var promptVersion: String

    var createdAt: Date
    var updatedAt: Date

    init(
        storyId: UUID,
        coverageJSON: String,
        sourceUnderstandingIdsFingerprint: String,
        creativeIntentFingerprint: String,
        pendingCount: Int,
        storyGuideFingerprint: String = "",
        schemaVersion: String = "story_coverage/2",
        modelId: String? = nil,
        promptVersion: String = "story_coverage/v2",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.storyId = storyId
        self.coverageJSON = coverageJSON
        self.sourceUnderstandingIdsFingerprint = sourceUnderstandingIdsFingerprint
        self.creativeIntentFingerprint = creativeIntentFingerprint
        self.storyGuideFingerprint = storyGuideFingerprint
        self.pendingCount = pendingCount
        self.schemaVersion = schemaVersion
        self.modelId = modelId
        self.promptVersion = promptVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// E2-c: the persistent StoryGuide (one active version per Story for MVP). Generated ONCE from
// CreativeIntent; stable while Coverage recomputes. Canonical server-minted dimension/possibility
// ids live inside guideJSON (story_guide/1). No automatic Guide evolution; a future evolution
// creates a NEW version rather than mutating this.
@Model
final class StoryGuideModel {
    @Attribute(.unique) var storyId: UUID
    var guideJSON: String                 // snake_case wire JSON (story_guide/1), canonical ids inside
    var schemaVersion: String
    var modelId: String?
    var promptVersion: String
    var createdAt: Date
    var updatedAt: Date

    init(
        storyId: UUID,
        guideJSON: String,
        schemaVersion: String = "story_guide/1",
        modelId: String? = nil,
        promptVersion: String = "story_guide/v1",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.storyId = storyId
        self.guideJSON = guideJSON
        self.schemaVersion = schemaVersion
        self.modelId = modelId
        self.promptVersion = promptVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}


// M-c: the persistent MusicDirection (intended soundtrack FEEL, one per Story). Inferred ONCE from
// CreativeIntent (+ Guide framing) when absent; a user edit sets userAuthored=true and is NEVER
// overwritten by inference (relaunch/migration/Coverage recompute). directionJSON holds the wire
// MusicDirectionContract (music_direction/1). `fingerprint` lets a FUTURE MusicPlan cache detect that
// the direction changed and invalidate itself — MusicDirection changes regenerate NOTHING else.
@Model
final class StoryMusicDirectionModel {
    @Attribute(.unique) var storyId: UUID
    var directionJSON: String             // snake_case wire JSON (MusicDirectionContract)
    var userAuthored: Bool                // true = user edited; inference must NOT overwrite
    var fingerprint: String               // stable hash of the direction (future MusicPlan staleness)
    var createdAt: Date
    var updatedAt: Date

    init(
        storyId: UUID,
        directionJSON: String,
        userAuthored: Bool = false,
        fingerprint: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.storyId = storyId
        self.directionJSON = directionJSON
        self.userAuthored = userAuthored
        self.fingerprint = fingerprint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
