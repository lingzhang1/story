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
struct ShotContractDTO: Codable, Equatable {
    var id: UUID
    var order: Int
    var instruction: String
    var targetDurationSeconds: Double?
    var framing: String?
    var cameraMotion: String?
    var subjectAction: String?
    var exampleAssetId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, order, instruction, framing
        case targetDurationSeconds = "target_duration_seconds"
        case cameraMotion = "camera_motion"
        case subjectAction = "subject_action"
        case exampleAssetId = "example_asset_id"
    }
}

struct StoryPlanContractDTO: Codable, Equatable {
    var id: UUID
    var conceptId: UUID
    var shots: [ShotContractDTO]
    var estimatedDurationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case id, shots
        case conceptId = "concept_id"
        case estimatedDurationSeconds = "estimated_duration_seconds"
    }
}

// MARK: - ValidationResult (02 §20)

struct ValidationResultContractDTO: Codable, Equatable {
    var usable: Bool
    var recommendation: ValidationRecommendationDTO
    var confidence: Double?
    var issues: [ValidationIssueDTO]

    enum CodingKeys: String, CodingKey {
        case usable, recommendation, confidence, issues
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
