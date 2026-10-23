import Foundation

// Story — frozen AI/boundary contract DTOs (Swift side), Milestone B.
//
// These Codable structs mirror the canonical JSON Schema in
// contracts/schemas/*.schema.json (source of truth: the Python Pydantic
// models in contracts/schemas/ai_contracts.py). They are the shapes iOS will
// DECODE from the Story API when the real engines land (Milestone C) — the
// Director returns StoryConcept + StoryPlan, validation returns
// ValidationResult, etc.
//
// LAYER SEPARATION (03-system-architecture.md §7, task §3):
//   - These DTOs are the WIRE/AI contract. They are DELIBERATELY NOT the
//     SwiftData @Model persistence types (Data/Persistence/Models.swift) and
//     NOT the transient domain value types (Domain/Engines/Engines.swift).
//   - Do NOT add SwiftData annotations here. Do NOT persist these directly.
//     Map explicitly at the edge (see "Mapping" notes per type).
//
// WIRE CONVENTIONS (frozen Milestone B):
//   - JSON is snake_case end-to-end. We use explicit CodingKeys so Swift stays
//     idiomatic camelCase while the wire stays snake_case (matches Python).
//   - Timestamps are ISO-8601 UTC strings; decode with a .iso8601 strategy.
//   - IDs are opaque UUID strings.
//
// NOTE: These types are NOT consumed by the Milestone A offline slice. They
// are the Milestone C seam. Decoding/HTTP wiring is intentionally absent here.

// MARK: - Enums (frozen vocabularies — must match ai_contracts.py)

enum OutputFormatDTO: String, Codable {
    case vertical, square, landscape
}

enum MusicEnergyDTO: String, Codable {
    case low, medium, high, dynamic
}

enum PaceDTO: String, Codable {
    case slow, moderate, fast
}

enum SubjectProminenceDTO: String, Codable {
    case high, medium, low
}

enum OperatorSpaceDTO: String, Codable {
    case veryLimited = "very_limited"
    case limited
    case moderate
    case open
    case unknown
}

enum CaptureEntryPointDTO: String, Codable {
    case createNow = "create_now"
    case shootMoment = "shoot_moment"
    case storyIdea = "story_idea"
}

enum CreativeIntentSourceTypeDTO: String, Codable {
    case text
    case template
    case referenceAsset = "reference_asset"
}

enum ValidationRecommendationDTO: String, Codable {
    case accept, retake
}

enum ValidationIssueDTO: String, Codable {
    case tooShort = "too_short"
    case severeShake = "severe_shake"
    case subjectMissing = "subject_missing"
    case severeUnderexposure = "severe_underexposure"
    case severeOverexposure = "severe_overexposure"
    case instructionNotFollowed = "instruction_not_followed"
}

enum DirectorActionTypeDTO: String, Codable {
    case captureShot = "capture_shot"
    case createNow = "create_now"
    case rescanScene = "rescan_scene"
    case retryShot = "retry_shot"
}

enum BeatStatusDTO: String, Codable {
    case unfulfilled, partial, fulfilled
}

// MARK: - CreativeIntent (02 §4)

struct CreativeIntentSourceDTO: Codable, Equatable {
    var type: CreativeIntentSourceTypeDTO
    var value: String?
    var templateId: String?
    var assetId: UUID?

    enum CodingKeys: String, CodingKey {
        case type, value
        case templateId = "template_id"
        case assetId = "asset_id"
    }
}

/// Mapping: seeds the SwiftData StoryModel.intent* columns. The Milestone-A
/// flat {intentRawText, intentTheme, intentTone, intentSummary} maps as
/// rawText -> rawUserDescription, summary -> summary, and theme/tone seed
/// styleTags/desiredFeeling until the real engine populates them.
struct CreativeIntentContractDTO: Codable, Equatable {
    var id: UUID
    var sourceInputs: [CreativeIntentSourceDTO]
    var summary: String
    var subject: String?
    var desiredFeeling: [String]
    var styleTags: [String]
    var pace: PaceDTO?
    var emphasis: [String]
    var creativeConstraints: [String]
    var targetDurationSeconds: Double?
    var targetFormat: OutputFormatDTO?
    var rawUserDescription: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, summary, subject, pace, emphasis
        case sourceInputs = "source_inputs"
        case desiredFeeling = "desired_feeling"
        case styleTags = "style_tags"
        case creativeConstraints = "creative_constraints"
        case targetDurationSeconds = "target_duration_seconds"
        case targetFormat = "target_format"
        case rawUserDescription = "raw_user_description"
        case createdAt = "created_at"
    }
}

// MARK: - MusicDirection (02 §6)

struct MusicDirectionContractDTO: Codable, Equatable {
    var summary: String
    var moodTags: [String]
    var energy: MusicEnergyDTO?
    var progression: String?
    var rawUserDescription: String?

    enum CodingKeys: String, CodingKey {
        case summary, energy, progression
        case moodTags = "mood_tags"
        case rawUserDescription = "raw_user_description"
    }
}

// MARK: - SceneUnderstanding (02 §15)

struct SceneSubjectDTO: Codable, Equatable {
    var label: String
    var note: String?
    var prominence: SubjectProminenceDTO?
}

struct SceneUnderstandingContractDTO: Codable, Equatable {
    var id: UUID
    var summary: String
    var environmentTags: [String]
    var subjects: [SceneSubjectDTO]
    var lighting: String?
    var operatorSpace: OperatorSpaceDTO?
    var motionOpportunities: [String]
    var compositionOpportunities: [String]
    var constraints: [String]
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, summary, subjects, lighting, constraints
        case environmentTags = "environment_tags"
        case operatorSpace = "operator_space"
        case motionOpportunities = "motion_opportunities"
        case compositionOpportunities = "composition_opportunities"
        case createdAt = "created_at"
    }
}

// MARK: - StoryConcept + StoryPlan + Shot (02 §16-18)

struct StoryConceptContractDTO: Codable, Equatable {
    var id: UUID
    var title: String
    var summary: String
    var rationale: String?
    var previewAssetId: UUID?
    var targetNarrativeNeedId: String?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, rationale
        case previewAssetId = "preview_asset_id"
        case targetNarrativeNeedId = "target_narrative_need_id"
    }
}

/// Frozen product name is `Shot` (element of StoryPlan.shots[]).
/// `purpose` = internal semantic reason; `instruction` = user-facing direction.
struct ShotContractDTO: Codable, Equatable {
    var id: UUID
    var order: Int
    var instruction: String
    var beatId: String?
    var purpose: String?
    var targetDurationSeconds: Double?
    var framing: String?
    var cameraMotion: String?
    var subjectAction: String?
    var exampleAssetId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, order, instruction, purpose, framing
        case beatId = "beat_id"
        case targetDurationSeconds = "target_duration_seconds"
        case cameraMotion = "camera_motion"
        case subjectAction = "subject_action"
        case exampleAssetId = "example_asset_id"
    }
}

/// A creative/narrative purpose the Story must express. Minimal planning object.
struct StoryBeatDTO: Codable, Equatable {
    var id: String
    var purpose: String
}

struct StoryPlanContractDTO: Codable, Equatable {
    var id: UUID
    var conceptId: UUID
    var beats: [StoryBeatDTO]
    var shots: [ShotContractDTO]
    var estimatedDurationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case id, beats, shots
        case conceptId = "concept_id"
        case estimatedDurationSeconds = "estimated_duration_seconds"
    }
}

// MARK: - ValidationResult (02 §20) — shot-level usability only

struct ValidationResultContractDTO: Codable, Equatable {
    var usable: Bool
    var recommendation: ValidationRecommendationDTO
    var confidence: Double?
    var issues: [ValidationIssueDTO]
    var shotId: UUID?
    var captureAssetId: UUID?

    enum CodingKeys: String, CodingKey {
        case usable, recommendation, confidence, issues
        case shotId = "shot_id"
        case captureAssetId = "capture_asset_id"
    }
}

// MARK: - Director decision loop (05-story-director.md §5, §7)

/// One strongest next action. StoryPlan = what material; this = what to do next.
struct DirectorDecisionDTO: Codable, Equatable {
    var action: DirectorActionTypeDTO
    var shot: ShotContractDTO?
    var reason: String?
}

/// Director-level fulfillment of one beat. NOT ValidationResult, NOT planning.
struct BeatProgressDTO: Codable, Equatable {
    var beatId: String
    var status: BeatStatusDTO
    var supportingAssetIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case status
        case beatId = "beat_id"
        case supportingAssetIds = "supporting_asset_ids"
    }
}

/// Mutable DIRECT execution state, owned by the CaptureSession.
struct DirectorStateDTO: Codable, Equatable {
    var currentBeatId: String?
    var beatProgress: [BeatProgressDTO]
    var lastDecision: DirectorDecisionDTO?

    enum CodingKeys: String, CodingKey {
        case currentBeatId = "current_beat_id"
        case beatProgress = "beat_progress"
        case lastDecision = "last_decision"
    }
}

/// The Story Director's output envelope — the response of
/// POST /v1/director/initialize (and /next). Composed from the frozen
/// contracts; this is a transport shape, not a new canonical contract.
struct DirectorOutputDTO: Codable, Equatable {
    var concept: StoryConceptContractDTO
    var plan: StoryPlanContractDTO
    var directorState: DirectorStateDTO
    var decision: DirectorDecisionDTO
    /// Ephemeral ranked ALTERNATIVES for the current recommendation slot (DIRECT UX).
    /// candidates[0] == decision. NOT persisted into StoryPlan, NOT extra required
    /// captures — the user captures at most one. Defaults to [] when the server omits it.
    var candidates: [DirectorDecisionDTO] = []

    enum CodingKeys: String, CodingKey {
        case concept, plan, decision, candidates
        case directorState = "director_state"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        concept = try c.decode(StoryConceptContractDTO.self, forKey: .concept)
        plan = try c.decode(StoryPlanContractDTO.self, forKey: .plan)
        directorState = try c.decode(DirectorStateDTO.self, forKey: .directorState)
        decision = try c.decode(DirectorDecisionDTO.self, forKey: .decision)
        candidates = try c.decodeIfPresent([DirectorDecisionDTO].self, forKey: .candidates) ?? []
    }

    init(concept: StoryConceptContractDTO, plan: StoryPlanContractDTO,
         directorState: DirectorStateDTO, decision: DirectorDecisionDTO,
         candidates: [DirectorDecisionDTO] = []) {
        self.concept = concept; self.plan = plan
        self.directorState = directorState; self.decision = decision
        self.candidates = candidates
    }
}

// MARK: - CaptureSession (02 §14) — composes the above

struct CaptureSessionContractDTO: Codable, Equatable {
    var id: UUID
    var entryPoint: CaptureEntryPointDTO
    var creativeIntent: CreativeIntentContractDTO
    var storyId: UUID?
    var sceneUnderstanding: SceneUnderstandingContractDTO?
    var selectedConcept: StoryConceptContractDTO?
    var storyPlan: StoryPlanContractDTO?
    var directorState: DirectorStateDTO?
    var captureAssetIds: [UUID]
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case entryPoint = "entry_point"
        case creativeIntent = "creative_intent"
        case storyId = "story_id"
        case sceneUnderstanding = "scene_understanding"
        case selectedConcept = "selected_concept"
        case storyPlan = "story_plan"
        case directorState = "director_state"
        case captureAssetIds = "capture_asset_ids"
        case createdAt = "created_at"
    }
}

// MARK: - Story Coverage (story_coverage/1 — Milestone E, FROZEN)
//
// The DERIVED, RECOMPUTABLE, ADVISORY snapshot of "what the collection of
// understood Moments MEANS for the Story". Produced by the backend
// StoryCoverageEngine (Opus 4.6, original pre-restraint prompt) from
// CreativeIntent + completed MomentUnderstanding[] + pending_count.
//
// HARD RULES encoded by this shape (must match ai_contracts.StoryCoverageContract):
//   - HYBRID dimensions: stable STRUCTURE, intent-derived LABELS/PURPOSES.
//   - A dimension `id` is a WITHIN-SNAPSHOT handle ONLY. It is NOT durable
//     identity: never key persistent state on it, never expect it stable across
//     recomputes (semantic drift is expected and accepted).
//   - `coverage` is CATEGORICAL (NarrativeCoverage) — NEVER a number/percent.
//   - `storyIdea` is NULLABLE; null is a first-class correct result (no card).
//   - pending media is UNKNOWN, not absent (pendingCount is honest, not a gap).

/// Advisory per-dimension coverage (02 §8) — never a progress bar. Matches
/// ai_contracts.NarrativeCoverage.
enum NarrativeCoverageDTO: String, Codable, Equatable {
    case unknown
    case couldUseMore = "could_use_more"
    case lookingGood = "looking_good"
    case strong
}

/// Can a Story meeting the user's intent be made from the understood material?
/// Relative to intent + scope + complementarity + redundancy + pending
/// uncertainty — NEVER derived from Moment count. Matches ai_contracts.SufficiencyStatus.
enum SufficiencyStatusDTO: String, Codable, Equatable {
    case insufficient
    case workable
    case sufficient
}

struct CoverageDimensionDTO: Codable, Identifiable {
    /// Within-snapshot handle ONLY — not durable identity (semantic drift expected).
    let id: String
    let label: String
    let purpose: String?
    let coverage: NarrativeCoverageDTO
    let note: String?
    let evidenceMomentIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case id, label, purpose, coverage, note
        case evidenceMomentIds = "evidence_moment_ids"
    }
}

struct CoverageSufficiencyDTO: Codable, Equatable {
    let status: SufficiencyStatusDTO
    let reason: String?
}

/// ONE optional high-level narrative opportunity. NOT scene-specific, NOT camera
/// direction. The whole object is nullable at `StoryCoverageDTO.storyIdea`.
struct CoverageStoryIdeaDTO: Codable {
    let title: String
    let description: String
    let rationale: String?
}

struct StoryCoverageDTO: Codable {
    let schemaVersion: String
    let storyId: UUID
    let momentCount: Int
    let pendingCount: Int
    /// Which MomentUnderstanding records this was computed from (staleness/provenance).
    let sourceUnderstandingIds: [UUID]

    let dimensions: [CoverageDimensionDTO]
    let strengths: [String]
    let redundancies: [String]
    let sufficiency: CoverageSufficiencyDTO
    /// null is a first-class "no interruption" result — DO NOT render a card when nil.
    let storyIdea: CoverageStoryIdeaDTO?

    let generatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case storyId = "story_id"
        case momentCount = "moment_count"
        case pendingCount = "pending_count"
        case sourceUnderstandingIds = "source_understanding_ids"
        case dimensions, strengths, redundancies, sufficiency
        case storyIdea = "story_idea"
        case generatedAt = "generated_at"
    }
}

// MARK: - StoryGuide (E2-a, FROZEN) — persistent creative map, generated ONCE from CreativeIntent

struct CapturePossibilityDTO: Codable, Identifiable, Equatable {
    /// Server-minted stable id (drives the Figma represented/Shoot/Reshoot affordance). NEVER a model id.
    let id: String
    let label: String
    let semanticPurpose: String?
    enum CodingKeys: String, CodingKey { case id, label; case semanticPurpose = "semantic_purpose" }
}

struct StoryGuideDimensionDTO: Codable, Identifiable, Equatable {
    /// Server-minted STABLE Story-local identity — Coverage references this by id.
    let id: String
    let label: String
    let purpose: String
    let capturePossibilities: [CapturePossibilityDTO]
    enum CodingKeys: String, CodingKey { case id, label, purpose; case capturePossibilities = "capture_possibilities" }
}

struct StoryGuideDTO: Codable, Equatable {
    let schemaVersion: String
    let storyId: UUID
    let sourceCreativeIntentVersion: String?
    let framingSummary: String
    let dimensions: [StoryGuideDimensionDTO]
    let generatedAt: Date?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case storyId = "story_id"
        case sourceCreativeIntentVersion = "source_creative_intent_version"
        case framingSummary = "framing_summary"
        case dimensions
        case generatedAt = "generated_at"
    }
}

// MARK: - StoryGuide/2 (AI shooting script, additive) — scenes, not dimensions

/// ONE example way a scene's `what_to_capture` could be realized. Mirrors CapturePossibilityDTO so the
/// Coverage/2 represented/Shoot/Reshoot affordances work against a v2 scene exactly like a v1 dimension.
struct SceneCapturePossibilityDTO: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let semanticPurpose: String?
    enum CodingKeys: String, CodingKey { case id, label; case semanticPurpose = "semantic_purpose" }
}

/// One shooting-script scene. `id` is the server-minted STABLE Story-local id (Coverage/2 keys state on it
/// exactly like a v1 dimension id). `visualReferenceQuery` is a GENERIC composition phrase (no personal
/// data) used to fetch ONE reference image via the backend proxy; nil => text-only card.
struct StoryGuideSceneDTO: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let whatToCapture: String
    let howToShoot: String
    let whyItMatters: String
    let visualReferenceQuery: String?
    let capturePossibilities: [SceneCapturePossibilityDTO]
    enum CodingKeys: String, CodingKey {
        case id, title
        case whatToCapture = "what_to_capture"
        case howToShoot = "how_to_shoot"
        case whyItMatters = "why_it_matters"
        case visualReferenceQuery = "visual_reference_query"
        case capturePossibilities = "capture_possibilities"
    }
    // capture_possibilities may be absent in older payloads — decode tolerantly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        whatToCapture = try c.decode(String.self, forKey: .whatToCapture)
        howToShoot = try c.decode(String.self, forKey: .howToShoot)
        whyItMatters = try c.decode(String.self, forKey: .whyItMatters)
        visualReferenceQuery = (try? c.decodeIfPresent(String.self, forKey: .visualReferenceQuery)).flatMap { $0 }
        capturePossibilities = (try? c.decodeIfPresent([SceneCapturePossibilityDTO].self, forKey: .capturePossibilities)).flatMap { $0 } ?? []
    }
}

struct StoryGuideV2DTO: Codable, Equatable {
    let schemaVersion: String
    let storyId: UUID
    let sourceCreativeIntentVersion: String?
    let framingSummary: String
    let scenes: [StoryGuideSceneDTO]
    let generatedAt: Date?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case storyId = "story_id"
        case sourceCreativeIntentVersion = "source_creative_intent_version"
        case framingSummary = "framing_summary"
        case scenes
        case generatedAt = "generated_at"
    }
}

// MARK: - StoryGuide/2 REFINEMENT ("Update Guide", Guide v2.1) — result + change log

/// One change-log entry: what a refinement did to one scene (for the history view / "3 preserved,
/// 1 improved, 2 added, 1 archived" summary). `sceneId` is the stable id the disposition applies to.
struct SceneChangeDTO: Codable, Equatable, Identifiable {
    var id: String { sceneId + ":" + disposition }
    let sceneId: String
    let disposition: String   // preserved | improved | added | archived
    let title: String
    let reason: String?
    enum CodingKeys: String, CodingKey {
        case sceneId = "scene_id"
        case disposition, title, reason
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sceneId = try c.decode(String.self, forKey: .sceneId)
        disposition = try c.decode(String.self, forKey: .disposition)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)).flatMap { $0 } ?? ""
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)).flatMap { $0 }
    }
}

/// Result of a Guide refinement: the next active v2 shooting script (`guide`, a normal StoryGuideV2DTO so
/// every existing consumer works unchanged) + the change log + the retired scene ids (history).
struct StoryGuideRefinementResultDTO: Codable, Equatable {
    let guide: StoryGuideV2DTO
    let changes: [SceneChangeDTO]
    let archivedSceneIds: [String]
    enum CodingKeys: String, CodingKey {
        case guide, changes
        case archivedSceneIds = "archived_scene_ids"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guide = try c.decode(StoryGuideV2DTO.self, forKey: .guide)
        changes = (try? c.decodeIfPresent([SceneChangeDTO].self, forKey: .changes)).flatMap { $0 } ?? []
        archivedSceneIds = (try? c.decodeIfPresent([String].self, forKey: .archivedSceneIds)).flatMap { $0 } ?? []
    }
}

/// Metadata-only reference image (from the backend /v1/scene-image proxy). NO image bytes — `imageURL` is a
/// hotlinked Unsplash CDN URL the UI loads via AsyncImage. Attribution + source links are mandatory to show.
struct SceneImageDTO: Codable, Equatable {
    let photoId: String
    let imageURL: String
    let thumbURL: String
    let attributionText: String
    let photographerName: String
    let photographerURL: String
    let sourceURL: String
    let downloadLocation: String
    let width: Int?
    let height: Int?
    let color: String?
    let altDescription: String?
    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case imageURL = "image_url"
        case thumbURL = "thumb_url"
        case attributionText = "attribution_text"
        case photographerName = "photographer_name"
        case photographerURL = "photographer_url"
        case sourceURL = "source_url"
        case downloadLocation = "download_location"
        case width, height, color
        case altDescription = "alt_description"
    }
}

/// Envelope for /v1/scene-image: {image: SceneImageDTO?, status: "ok"|"no_match"|...}.
struct SceneImageResponseDTO: Codable, Equatable {
    let image: SceneImageDTO?
    let status: String
}

// MARK: - StoryCoverage/2 (E2-b, FROZEN) — Guide-relative state + independent sufficiency/idea

struct DimensionCoverageDTO: Codable, Identifiable, Equatable {
    var id: String { storyGuideDimensionId }
    let storyGuideDimensionId: String
    let state: NarrativeCoverageDTO
    let note: String?
    let evidenceMomentIds: [UUID]
    /// UI-ONLY (Figma [x]/Reshoot). NEVER drives state/sufficiency/idea. May be empty while state is strong.
    let representedPossibilityIds: [String]
    enum CodingKeys: String, CodingKey {
        case storyGuideDimensionId = "story_guide_dimension_id"
        case state, note
        case evidenceMomentIds = "evidence_moment_ids"
        case representedPossibilityIds = "represented_possibility_ids"
    }
}

/// ONE optional opportunity. Independent of sufficiency. description = card copy (concise); rationale internal.
struct CoverageStoryIdeaV2DTO: Codable, Equatable {
    let title: String
    let description: String
    let rationale: String?
    let targetStoryGuideDimensionId: String?
    enum CodingKeys: String, CodingKey {
        case title, description, rationale
        case targetStoryGuideDimensionId = "target_story_guide_dimension_id"
    }
}

struct StoryCoverageV2DTO: Codable, Equatable {
    let schemaVersion: String
    let storyId: UUID
    let storyGuideId: String
    let storyGuideVersion: String
    let momentCount: Int
    let pendingCount: Int
    let sourceUnderstandingIds: [UUID]
    let dimensionCoverage: [DimensionCoverageDTO]
    let strengths: [String]
    let redundancies: [String]
    let sufficiency: CoverageSufficiencyDTO
    /// null is a first-class "no interruption" result — DO NOT render a card when nil.
    let storyIdea: CoverageStoryIdeaV2DTO?
    let generatedAt: Date?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case storyId = "story_id"
        case storyGuideId = "story_guide_id"
        case storyGuideVersion = "story_guide_version"
        case momentCount = "moment_count"
        case pendingCount = "pending_count"
        case sourceUnderstandingIds = "source_understanding_ids"
        case dimensionCoverage = "dimension_coverage"
        case strengths, redundancies, sufficiency
        case storyIdea = "story_idea"
        case generatedAt = "generated_at"
    }
}

/// The high-level narrative opportunity the user explicitly chose (Story Idea -> Show me, or Guide
/// possibility -> Shoot). Carried into the Director initialize path. Semantic WHAT, never a shot.
struct SelectedOpportunityDTO: Codable, Equatable {
    let storyGuideDimensionId: String?
    let label: String
    let purpose: String
    let capturePossibilityLabel: String?
    enum CodingKeys: String, CodingKey {
        case storyGuideDimensionId = "story_guide_dimension_id"
        case label, purpose
        case capturePossibilityLabel = "capture_possibility_label"
    }
}

enum StoryContractCoding {
    /// JSONDecoder configured for the frozen wire conventions
    /// (snake_case handled per-type via CodingKeys; ISO-8601 timestamps).
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        // The backend emits ISO-8601 with FRACTIONAL seconds (e.g. 2026-10-15T20:01:17.701578Z). The stock
        // .iso8601 strategy uses ISO8601DateFormatter's default options, which do NOT parse fractional
        // seconds and THROW — silently failing the whole DTO decode (this is why a completed coverage result
        // was discarded and the Guide never marked). Accept both fractional and whole-second forms.
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let dt = withFrac.date(from: s) { return dt }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let dt = plain.date(from: s) { return dt }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "unparseable ISO-8601 date: \(s)"))
        }
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
