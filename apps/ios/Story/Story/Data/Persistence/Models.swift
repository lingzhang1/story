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
