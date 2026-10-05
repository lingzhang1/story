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

// MARK: - Shared coder helpers

enum StoryContractCoding {
    /// JSONDecoder configured for the frozen wire conventions
    /// (snake_case handled per-type via CodingKeys; ISO-8601 timestamps).
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
