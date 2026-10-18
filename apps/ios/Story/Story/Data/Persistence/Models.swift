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

/// User-facing sound treatment for a Story. Wire values are snake_case to match the request DTOs.
/// immersive  = favor natural sound + environmental atmosphere.
/// balanced   = intelligently combine meaningful native audio with music (the resolution default).
/// music_led  = soundtrack leads, but important native sound is NOT auto-destroyed (NOT music-only).
enum SoundPreference: String, Codable, CaseIterable {
    case immersive
    case balanced
    case musicLed = "music_led"

    /// Advisory inference from CreativeIntent tone/theme/feeling text. Returns nil when nothing clearly signals
    /// a treatment (caller then leaves inferred nil and effective resolves to balanced). NEVER returns a forced
    /// value — a thin/neutral intent yields nil, not balanced, so "inferred" stays honest.
    static func infer(theme: String, tone: String, desiredFeeling: [String], styleTags: [String]) -> SoundPreference? {
        let hay = ([theme, tone] + desiredFeeling + styleTags).joined(separator: " ").lowercased()
        let immersiveHits = ["immersive","ambient","atmosphere","natural sound","environment","documentary",
                             "being there","wind","ambience","field recording","nature"]
        let musicHits = ["music video","music-forward","music forward","montage","hype","edm","beat drop",
                         "set to the music","music led","music-led","soundtrack-driven","stylized recap"]
        if musicHits.contains(where: hay.contains) { return .musicLed }
        if immersiveHits.contains(where: hay.contains) { return .immersive }
        return nil
    }

    /// Deterministic (soundtrack_role, native_audio_priority) for this preference, matching what the backend
    /// MusicPlan returns per preference. Used when there is NO backend plan — e.g. an imported My Music track
    /// chosen at create time or in Change Music. Mirrors the verified live A/B:
    ///   immersive -> sparse / important ; balanced -> supportive / selective ; music_led -> continuous / low.
    var localMixKnobs: (role: String, priority: String) {
        switch self {
        case .immersive: return ("sparse", "important")
        case .balanced:  return ("supportive", "selective")
        case .musicLed:  return ("continuous", "low")
        }
    }
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

    // Sound preference (immersive | balanced | music_led). Additive migration — optional + defaulted so existing
    // Stories stay valid. TWO fields by design: the user's EXPLICIT choice is authoritative and must survive
    // relaunch / regeneration / repeated Create flows; the INFERRED recommendation is advisory and recomputable.
    // An explicit choice is NEVER overwritten by inference. effectiveSoundPreference resolves explicit ?? inferred
    // ?? balanced (the fallback is NOT a forced selection — it is only the resolution default).
    var soundPreferenceExplicit: String?    // set only when the user picks; nil = not chosen
    var soundPreferenceInferred: String?     // recommendation from CreativeIntent; may be recomputed

    // M-e / editorial-mode: the user's Story-length editorial choice (highlights|full|custom), persisted so the
    // edit-plan request can tell the planner the intended BREADTH (not just the collapsed target duration).
    // Additive migration (optional + defaulted nil); nil = older Story / not chosen => planner infers as before.
    var editorialMode: String?

    // MVP Customize UX / Editing Approach: the user's chosen creative approach (storytelling|visual_first),
    // persisted independently of Story Length and Sound. Additive migration (optional + defaulted nil); nil =
    // older Story / not chosen => EditingApproach.default (storytelling, the device-verified text-only path).
    // Never overwritten during retries, recreation, or version generation (only acceptCustomize sets it).
    var editingApproachExplicit: String?

    // Explicit Moment References (MVP): resolved HARD directives captured in Creative Direction, as the encoded
    // backend contract {must_include/exclude/opening/ending} of STABLE Moment UUIDs — NEVER display numbers.
    // Additive migration (optional + defaulted nil); nil = no explicit references => behavior unchanged. Persists
    // the user's resolved instruction across the hop from setup to generation and across version re-creation.
    // Set only when the user adds references in Creative Direction; never overwritten by inference/retry.
    var creativeDirectivesJSON: String?

    // Stage 2 Creative Direction SOFT preferences — the user's free-text creative direction captured on the
    // Customize screen ("make the cuts faster", "use the most visually striking footage first"). DRAFT TEXT:
    // survives navigation + a failed generation so the Customize sheet can repopulate it. Additive migration
    // (optional + defaulted nil); nil => no soft direction => behavior unchanged. This is NOT the factual Story
    // description (intentText) — it never overwrites it. Forwarded as revision_context.soft_direction for the
    // ORIGINAL create only (createAnotherVersion uses explore, revision supplies its own), so a one-time
    // creative instruction is never silently inherited by an unrelated later version.
    var creativeDirectionText: String?

    // Async Edit Planning (Phase 2): the in-flight planning job for THIS creation attempt. operation_id is the
    // idempotency key — persisted BEFORE submitting so a crash/restart/retry reuses the SAME job (no duplicate
    // inference). job_id is the server's handle for polling + restart recovery. A deliberate "Create Another
    // Version" mints a NEW operation_id. Cleared when the Story completes or the attempt is abandoned.
    var planOperationId: String?
    var planJobId: String?
    var planJobStatus: String?   // last observed: queued|running|completed|failed|cancelled|expired (advisory UI)

    var createdAt: Date
    var updatedAt: Date

    // GLOBAL MOMENTS: a Story no longer OWNS Moments. It references them through StoryMomentLink join rows.
    // Deleting a Story cascades its LINKS (and its outputs) only — never the Moments or their media.
    @Relationship(deleteRule: .cascade, inverse: \StoryMomentLink.story)
    var momentLinks: [StoryMomentLink] = []

    @Relationship(deleteRule: .cascade, inverse: \GeneratedOutputModel.story)
    var generatedOutputs: [GeneratedOutputModel] = []

    /// The Story's Moments, in per-Story order, resolved through the links. Read-only convenience so existing
    /// call sites (`story.moments`) keep working after the global-Moments migration. Nil-moment links (a Moment
    /// deleted out from under a link) are skipped. Ordering: `orderIndex` asc, then link `addedAt`.
    var moments: [MomentModel] {
        momentLinks
            .sorted { a, b in
                let (ai, bi) = (a.orderIndex ?? Int.max, b.orderIndex ?? Int.max)
                return ai != bi ? ai < bi : a.addedAt < b.addedAt
            }
            .compactMap { $0.moment }
    }

    /// Attach a Moment to this Story by appending a link DIRECTLY to momentLinks (not just inserting a link and
    /// relying on SwiftData's inverse backfill, which is not synchronous for an unsaved context). Returns the
    /// created link so the caller can ctx.insert it. Idempotent: no-op if the Moment is already linked.
    @discardableResult
    func attach(_ moment: MomentModel, orderIndex: Int? = nil) -> StoryMomentLink? {
        if momentLinks.contains(where: { $0.moment?.id == moment.id }) { return nil }
        let order = orderIndex ?? ((momentLinks.compactMap { $0.orderIndex }.max() ?? -1) + 1)
        let link = StoryMomentLink(story: self, moment: moment, orderIndex: order)
        momentLinks.append(link)   // immediate in-memory inverse — story.moments resolves without a save
        return link
    }

    var status: StoryStatus {
        get { StoryStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    /// Resolved sound preference the pipeline should use: the user's EXPLICIT choice wins; else the INFERRED
    /// recommendation; else balanced. The fallback is a resolution default, not a forced user selection.
    var effectiveSoundPreference: SoundPreference {
        SoundPreference(rawValue: soundPreferenceExplicit ?? "")
            ?? SoundPreference(rawValue: soundPreferenceInferred ?? "")
            ?? .balanced
    }
    /// True when the user has explicitly chosen (so the UI shows a user selection, not just a recommendation).
    var hasExplicitSoundPreference: Bool { SoundPreference(rawValue: soundPreferenceExplicit ?? "") != nil }

    /// Resolved editing approach the pipeline should use. Tolerant of nil/unknown (older Stories) -> the safe
    /// default (storytelling / text-only). Independent of Length + Sound.
    var effectiveEditingApproach: EditingApproach { EditingApproach.fromRaw(editingApproachExplicit) }
    /// True when the user explicitly chose an editing approach on the Customize screen.
    var hasExplicitEditingApproach: Bool { EditingApproach(rawValue: editingApproachExplicit ?? "") != nil }

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
    var caption: String?
    var sourceRaw: String
    var createdAt: Date

    // Moment OWNS its media: deleting the Moment deletes its asset file. Independent of any Story.
    @Relationship(deleteRule: .cascade)
    var asset: AssetModel?

    // GLOBAL MOMENTS: a Moment can be referenced by MANY Stories through links. Deleting the Moment cascades
    // its links (removing it from those Stories) but a Story deletion never reaches here.
    @Relationship(deleteRule: .cascade, inverse: \StoryMomentLink.moment)
    var links: [StoryMomentLink] = []

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

// GLOBAL MOMENTS join entity. One row = "this Moment is in this Story, at this per-Story order".
// Owned by BOTH ends via cascade-from-parent (StoryModel.momentLinks / MomentModel.links): deleting either a
// Story OR a Moment removes the link, but never the OTHER end's durable data (Moments/media survive a Story
// delete; a Story's outputs are separate). Duplicate (story,moment) pairs are prevented at the write layer
// (SwiftData has no composite-unique constraint), see MomentLibrary.link(_:to:).
@Model
final class StoryMomentLink {
    @Attribute(.unique) var id: UUID
    var story: StoryModel?
    var moment: MomentModel?
    var addedAt: Date
    /// Per-Story ordering of this Moment (ascending). nil sorts last.
    var orderIndex: Int?

    init(id: UUID = UUID(), story: StoryModel?, moment: MomentModel?, addedAt: Date = .now, orderIndex: Int? = nil) {
        self.id = id
        self.story = story
        self.moment = moment
        self.addedAt = addedAt
        self.orderIndex = orderIndex
    }
}

// R-c Batch A: GeneratedOutputModel is now a REAL persisted render output, not
// mock metadata. ADDITIVE / MIGRATION-SAFE evolution — the existing Milestone-A
// stores stay valid without a schema migration step:
//   - every field kept: id (unique), story, title, durationSeconds, createdAt.
//   - `momentIds` is KEPT for back-compat (old mock outputs set only this). New
//     real outputs ALSO populate `sourceMomentIds` (the ordered set the staleness
//     fingerprint is computed over). `momentIds` therefore stays authoritative for
//     already-persisted rows; `sourceMomentIds` is the forward field. We keep both
//     rather than migrate because a lightweight SwiftData migration cannot run in
//     the sandbox and the duplication is cheap + non-lossy.
//   - all NEW fields carry defaults (String? = nil, [] , "" , false), so an old
//     store that never wrote them decodes cleanly (SwiftData lightweight migration
//     requirement: added properties must be optional or defaulted).
//
// LOCAL-FIRST: `relativeFilePath` is the RenderOutputStore relative path under
// <Documents>/rendered/ — we NEVER store the video bytes in SwiftData and never a
// cloud URL. A nil `relativeFilePath` means "mock / metadata-only" (legacy row).
@Model
final class GeneratedOutputModel {
    // A Story may have MANY GeneratedOutputs.
    @Attribute(.unique) var id: UUID
    var story: StoryModel?
    var title: String
    var durationSeconds: Double
    // LEGACY snapshot of the moment ids this output was planned from (mock path).
    // Kept for back-compat; real outputs mirror this into `sourceMomentIds`.
    var momentIds: [UUID]
    var createdAt: Date

    // --- R-c Batch A real-render fields (all defaulted = migration-safe) ---

    // RenderOutputStore RELATIVE path (e.g. "rendered/<uuid>.mp4"). nil = legacy/mock.
    // Never the absolute container path (it changes across installs/launches) and
    // NEVER the video bytes.
    var relativeFilePath: String?

    // The ordered set of Moment ids this output was rendered from. Drives the
    // staleness fingerprint (see StoryCreationCoordinator.fingerprint).
    var sourceMomentIds: [UUID] = []

    // Stable hash of {sorted included Moment ids + each Moment's asset.relativePath
    // + durationSeconds}. Replacing media under an UNCHANGED Moment id invalidates
    // the output (the fingerprint changes). Computed by the coordinator.
    var sourceFingerprint: String = ""

    // SHORT provenance string: schema_version + planner model (or "none") + planned
    // duration. NOT the raw plan JSON (we never persist that here).
    var editPlanProvenance: String = ""

    // Render shape (echoed from the EditPlan / RenderResult).
    var outputFormat: String = "vertical"
    var renderWidth: Double = 0
    var renderHeight: Double = 0

    // Set true when the Story's current inputs no longer match `sourceFingerprint`.
    // Advisory UX flag; recomputed, never user-authored.
    var isStale: Bool = false

    /// R-d: the title of the soundtrack baked into THIS output, or nil for a no-music render. Migration-safe
    /// (optional, defaulted nil) so existing persisted outputs stay valid and read as no-music. Result shows
    /// the real title when present; NEVER a fabricated track name.
    var soundtrackTitle: String? = nil

    // --- M-e shared versioning foundation (all defaulted = migration-safe) ---
    // A GeneratedOutput row IS a version. A Story has many; they are ADDITIVE and never overwritten.
    //
    // versionId      : stable version handle (defaults to `id` for originals + legacy rows).
    // parentVersionId: nil for an original render; the SOURCE output's versionId for a derived version
    //                  (e.g. a Change-Music re-render points at the version it replaced the soundtrack of).
    // operationType  : "original" | "change_music"  (future: "another_version", "edit_ai"). Legacy rows read "original".
    // editPlanJSON   : the EXACT executable EditPlanV2 this output rendered from, as canonical snake_case JSON
    //                  (the POST-refinement plan). This is what makes the visual edit faithfully reconstructable
    //                  for Change Music — the Edit Planner is never re-invoked. nil on legacy rows (which are
    //                  therefore not Change-Music eligible — honest, not a crash).
    // soundtrackRole / nativeAudioPriority: the mix knobs used, re-applied verbatim on a soundtrack-only re-render
    //                  so native-audio treatment is identical.
    // soundPreferenceRaw: effective sound preference at render time (provenance).
    // musicAssetRef  : soundtrack identity — "provider:<trackId>" | "mymusic:<MyMusicAssetModel.id>" | "none".
    var versionId: UUID = UUID()
    var parentVersionId: UUID? = nil
    var operationType: String = "original"
    var editPlanJSON: String? = nil
    var soundtrackRole: String? = nil
    var nativeAudioPriority: String? = nil
    var soundPreferenceRaw: String? = nil
    var musicAssetRef: String? = nil

    init(
        id: UUID = UUID(),
        title: String,
        durationSeconds: Double,
        momentIds: [UUID],
        relativeFilePath: String? = nil,
        sourceMomentIds: [UUID] = [],
        sourceFingerprint: String = "",
        editPlanProvenance: String = "",
        outputFormat: String = "vertical",
        renderWidth: Double = 0,
        renderHeight: Double = 0,
        isStale: Bool = false,
        soundtrackTitle: String? = nil,
        versionId: UUID? = nil,
        parentVersionId: UUID? = nil,
        operationType: String = "original",
        editPlanJSON: String? = nil,
        soundtrackRole: String? = nil,
        nativeAudioPriority: String? = nil,
        soundPreferenceRaw: String? = nil,
        musicAssetRef: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.durationSeconds = durationSeconds
        self.momentIds = momentIds
        self.relativeFilePath = relativeFilePath
        self.sourceMomentIds = sourceMomentIds
        self.sourceFingerprint = sourceFingerprint
        self.editPlanProvenance = editPlanProvenance
        self.outputFormat = outputFormat
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        self.isStale = isStale
        self.soundtrackTitle = soundtrackTitle
        self.versionId = versionId ?? id
        self.parentVersionId = parentVersionId
        self.operationType = operationType
        self.editPlanJSON = editPlanJSON
        self.soundtrackRole = soundtrackRole
        self.nativeAudioPriority = nativeAudioPriority
        self.soundPreferenceRaw = soundPreferenceRaw
        self.musicAssetRef = musicAssetRef
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

// ---------------------------------------------------------------------------
// My Music — Milestone M-e (user-imported audio library)
//
// A user-provided audio file imported through the iOS Files picker, copied into
// managed LOCAL storage. LOCAL-FIRST: the bytes live under <Documents>/mymusic/
// (relativePath), NEVER uploaded to the backend and NEVER a cloud URL. This is a
// LIBRARY — one row is reusable across many Stories and survives relaunch.
//
// Distinct from PROVIDER tracks (which are resolved transiently per-create and are
// NEVER permanently copied, for licensing). Only user-owned imports are stored here.
//
// Identity + dedup: `contentHash` is sha256 of the imported bytes. A re-import of
// the same file reuses the existing row (no second copy). `id` is the stable
// MusicAsset identity a GeneratedOutput version references as "mymusic:<id>".
//
// Analysis is LOCAL and HONEST: duration + a coarse energy curve always; bpm/beats
// ONLY when a validated local estimate exists, else nil/empty. NEVER fabricated.
// ---------------------------------------------------------------------------
@Model
final class MyMusicAssetModel {
    @Attribute(.unique) var id: UUID
    var displayName: String                 // user-facing; defaults to the filename stem, renamable
    var relativePath: String                // under <Documents>/mymusic/<uuid>.<ext>; resolve via MyMusicStore
    var originalFilename: String
    var durationSeconds: Double
    // sha256 of imported bytes, or "provider:<trackId>" for a saved favorite. Dedup is enforced in CODE (fetch
    // by contentHash before insert), NOT a DB unique constraint — a second @Attribute(.unique) on a freshly
    // added model is a lightweight-migration hazard on an existing on-device store.
    var contentHash: String
    var energyCurveJSON: String             // coarse normalized (0..1) amplitude curve, locally derived ("[]" if none)
    var bpm: Double?                        // ONLY if validated locally; nil otherwise (never fabricated)
    // M-e (save-from-list): when non-nil, this row is a SAVED PROVIDER FAVORITE — a reference to a provider
    // track by id, NOT a local audio copy. LICENSING: provider favorites must never become permanent byte
    // copies, so a favorite stores NO bytes (relativePath == "") and is re-resolved LIVE from the provider
    // each time it is used. When nil, this row is an IMPORTED file (bytes under relativePath). contentHash is
    // "provider:<trackId>" for a favorite (dedups favorites; keeps the unique constraint meaningful).
    var providerTrackId: String? = nil
    var createdAt: Date
    var lastUsedAt: Date?

    /// True when this is a saved provider favorite (reference only) rather than an imported local file.
    var isProviderFavorite: Bool { providerTrackId != nil }

    init(
        id: UUID = UUID(),
        displayName: String,
        relativePath: String,
        originalFilename: String,
        durationSeconds: Double,
        contentHash: String,
        energyCurveJSON: String = "[]",
        bpm: Double? = nil,
        providerTrackId: String? = nil,
        createdAt: Date = .now,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.durationSeconds = durationSeconds
        self.contentHash = contentHash
        self.energyCurveJSON = energyCurveJSON
        self.bpm = bpm
        self.providerTrackId = providerTrackId
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

// MARK: - Pending AI operation (durable recovery state)
//
// P0 RECOVERY (Phases 1-3): a completed backend edit-plan MUST NOT be silently lost because the app was
// backgrounded, suspended, force-quit, or the Story was reopened. The in-flight state the coordinator used to
// keep only in memory (operation_type, parent version, music, the plan itself) is NOT enough to recover after a
// relaunch, and a single mutable `story.planJobId` cannot tell a RESUMABLE operation apart from a finished one.
//
// This row is the DURABLE source of truth for ONE unfinished operation. It is written BEFORE the job is
// submitted (so a crash between submit and the first poll is recoverable) and is DELETED only when the
// operation reaches a logical terminal state the user keeps (saved) or explicitly abandons. Exactly one row
// per (storyId) may be non-terminal at a time — the coordinator enforces single-flight.
//
// Idempotency is preserved: `operationId` is the backend idempotency key. Resume/transport-retry REUSE this
// row's operationId (never a new job); a deliberate "Create Another Version" / "Revise" creates a NEW row with
// a NEW operationId. So recovery never triggers a second inference.
@Model
final class PendingOperationModel {
    @Attribute(.unique) var id: UUID

    // Identity needed to recover the operation WITHOUT re-inference.
    var storyId: UUID
    var operationId: String          // backend idempotency key — reused on resume/retry, new on deliberate create
    var jobId: String?               // server job handle for polling; nil until submit returns
    var operationType: String        // "original" | "another_version" | "revision"
    var baseVersionId: String?       // Explore/revision: the user-selected parent/base version row id
    var requestFingerprint: String?  // included-Moments fingerprint at submit time (drift detection; advisory)

    // Lifecycle. `phase` tracks the exactly-once pipeline: submitted -> planning -> plan_ready -> rendering ->
    // saved. `status` mirrors the last observed backend job status (queued|running|completed|failed|...).
    var phase: String                // submitted|planning|plan_ready|rendering|saved|abandoned
    var jobStatus: String?           // last observed backend status (advisory)
    var failureCategory: String?     // backend failure_category when phase ended in failure

    // The completed, VALIDATED-on-fetch EditPlan/2 JSON — persisted at plan_ready so rendering can resume after
    // a force-quit WITHOUT re-polling or re-inference. Canonical snake_case wire shape (EditPlan/2).
    var planJSON: String?

    // Render context needed to reproduce the SAME output on a resumed render (music + settings + format/target).
    var musicSelectionRef: String?   // resolved music handle so a resumed render keeps the same soundtrack
    // Render-time music facts captured at plan_ready so a render-resume can rebuild MediaEngineInputs WITHOUT a
    // fresh MusicPlan (recommend()) call — the plan was already planned music-aware; recovery only needs the
    // soundtrack file + analysis by trackId, and these two mixing knobs. nil => no-music render.
    var soundtrackRole: String?
    var nativeAudioPriority: String?
    var outputFormat: String?
    var targetSeconds: Double?

    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        storyId: UUID,
        operationId: String,
        jobId: String? = nil,
        operationType: String,
        baseVersionId: String? = nil,
        requestFingerprint: String? = nil,
        phase: String = "submitted",
        jobStatus: String? = nil,
        failureCategory: String? = nil,
        planJSON: String? = nil,
        musicSelectionRef: String? = nil,
        soundtrackRole: String? = nil,
        nativeAudioPriority: String? = nil,
        outputFormat: String? = nil,
        targetSeconds: Double? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.storyId = storyId
        self.operationId = operationId
        self.jobId = jobId
        self.operationType = operationType
        self.baseVersionId = baseVersionId
        self.requestFingerprint = requestFingerprint
        self.phase = phase
        self.jobStatus = jobStatus
        self.failureCategory = failureCategory
        self.planJSON = planJSON
        self.musicSelectionRef = musicSelectionRef
        self.soundtrackRole = soundtrackRole
        self.nativeAudioPriority = nativeAudioPriority
        self.outputFormat = outputFormat
        self.targetSeconds = targetSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Non-terminal operations are the ones recovery acts on.
    var isRecoverable: Bool { phase != "saved" && phase != "abandoned" }
}


// ---------------------------------------------------------------------------
// MusicPlan cache — latency P0. The MusicPlan LLM call (frozen music_plan/1, ~10s) was re-run on EVERY
// "find music" open even when nothing changed. This caches the plan per Story keyed by a canonical fingerprint
// of ALL inputs that feed /v1/music-plan (creative intent, music direction, story guide, coverage, sound
// preference, target duration, prompt version). A hit skips the 10s inference; any input change -> fingerprint
// miss -> recompute. ADVISORY/RECOMPUTABLE: never user-authored, safe to drop/rebuild. DERIVED, so a migration
// failure that loses it only costs one recompute. Restart-safe (persisted). One row per Story (upsert).
@Model
final class MusicPlanCacheModel {
    @Attribute(.unique) var storyId: UUID
    var planJSON: String                 // the cached MusicPlan/1 wire JSON (snake_case), reused verbatim
    var inputFingerprint: String         // stable hash of every output-affecting MusicPlan input + prompt ver
    var promptVersion: String            // the music_plan prompt version the cached plan was produced under
    var createdAt: Date
    var updatedAt: Date

    init(storyId: UUID, planJSON: String, inputFingerprint: String,
         promptVersion: String = "music_plan/1", createdAt: Date = .now, updatedAt: Date = .now) {
        self.storyId = storyId
        self.planJSON = planJSON
        self.inputFingerprint = inputFingerprint
        self.promptVersion = promptVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}


// ---------------------------------------------------------------------------
// Duration recommendation cache — latency P0. "Sizing your Story" is a ~4-9s LLM call
// (duration_recommendation/1) re-run on every Customize open. Cache the recommendation per Story keyed by a
// canonical fingerprint of its inputs (creative intent + the moments snapshot + prompt version). Advisory /
// recomputable (same safety profile as the MusicPlan cache); one row per Story (upsert); restart-safe.
@Model
final class DurationRecCacheModel {
    @Attribute(.unique) var storyId: UUID
    var recommendationJSON: String       // cached DurationRecommendation wire JSON, decoded + reused verbatim
    var inputFingerprint: String         // stable hash of creative intent + moments + prompt version
    var promptVersion: String
    var createdAt: Date
    var updatedAt: Date

    init(storyId: UUID, recommendationJSON: String, inputFingerprint: String,
         promptVersion: String = "duration_recommendation/1", createdAt: Date = .now, updatedAt: Date = .now) {
        self.storyId = storyId
        self.recommendationJSON = recommendationJSON
        self.inputFingerprint = inputFingerprint
        self.promptVersion = promptVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
