import XCTest
import SwiftData
@testable import Story

// Editorial Pipeline v2, P1-A — editorial-type semantics + backward compatibility + ownership.
// PURE logic + in-memory SwiftData. No planner behavior is exercised (P1-A changes none); these assert the
// representation is clean and historical values decode correctly.
@MainActor
final class EditorialTypeSemanticsTests: XCTestCase {

    // MARK: - backward-compatible legacy mapping

    func test_legacy_highlights_maps_to_highlights() {
        let r = ResolvedEditorial.fromLegacy("highlights")
        XCTAssertEqual(r.type, .highlights)
        XCTAssertFalse(r.isUserExactDuration)
        XCTAssertFalse(r.isUnspecified)
    }

    func test_legacy_full_maps_to_full_story() {
        let r = ResolvedEditorial.fromLegacy("full")
        XCTAssertEqual(r.type, .fullStory)
        XCTAssertFalse(r.isUserExactDuration)
    }

    func test_legacy_custom_is_NOT_an_editorial_type() {
        // OWNER: custom is a DURATION fact, never Full Story.
        let r = ResolvedEditorial.fromLegacy("custom")
        XCTAssertNil(r.type, "custom must NOT resolve to any editorial type")
        XCTAssertTrue(r.isUserExactDuration, "custom => user-exact duration")
        XCTAssertTrue(r.isUnspecified)
        XCTAssertEqual(r.typeForNewAttempt, .highlights, "a fresh attempt from a custom seed defaults to Highlights, not Full Story")
        XCTAssertEqual(DurationChoice.fromLegacy("custom"), .userExact)
    }

    func test_legacy_missing_or_unknown_is_unspecified() {
        for v in [nil, "", "   ", "garbage", "HIGHLIGHTSX"] {
            let r = ResolvedEditorial.fromLegacy(v)
            XCTAssertNil(r.type, "‘\(v ?? "nil")’ must be unspecified, not guessed")
            XCTAssertEqual(r.typeForNewAttempt, .highlights, "compatibility default is Highlights")
        }
        XCTAssertEqual(DurationChoice.fromLegacy(nil), .aiRecommended)
    }

    func test_case_insensitive_and_trimmed() {
        XCTAssertEqual(ResolvedEditorial.fromLegacy("  Highlights ").type, .highlights)
        XCTAssertEqual(ResolvedEditorial.fromLegacy("FULL").type, .fullStory)
    }

    // MARK: - wire mapping (no new wire contract)

    func test_wire_strings_match_live_v52_vocabulary() {
        XCTAssertEqual(EditorialType.highlights.legacyEditorialModeWire, "highlights")
        XCTAssertEqual(EditorialType.fullStory.legacyEditorialModeWire, "full")
    }

    func test_default_type_is_highlights() {
        XCTAssertEqual(EditorialType.defaultType, .highlights)
    }

    // MARK: - flag default (P1-A ships OFF)

    func test_flag_defaults_off() {
        UserDefaults.standard.removeObject(forKey: EditorialTypeFlag.key)
        // With no override and no env, P1-A is OFF so v5.2 behavior is unchanged.
        XCTAssertFalse(EditorialTypeFlag.enabled)
    }

    // MARK: - ownership: coexistence of types on ONE Story

    private func makeContainer() throws -> ModelContainer {
        let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
                 PendingOperationModel.self, MyMusicAssetModel.self,
            configurations: cfg)
    }

    func test_outputs_of_different_types_coexist_on_one_story() throws {
        let ctx = try makeContainer().mainContext
        let story = StoryModel(title: "TMB", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s")
        story.editorialMode = "highlights"   // the Story's preferred default seed
        ctx.insert(story)

        let o1 = GeneratedOutputModel(title: "TMB", durationSeconds: 30, momentIds: [],
                                      editorialTypeRaw: EditorialType.highlights.rawValue)
        let o2 = GeneratedOutputModel(title: "TMB", durationSeconds: 120, momentIds: [],
                                      editorialTypeRaw: EditorialType.fullStory.rawValue)
        let o3 = GeneratedOutputModel(title: "TMB", durationSeconds: 25, momentIds: [],
                                      editorialTypeRaw: EditorialType.highlights.rawValue)
        for o in [o1, o2, o3] { o.story = story; ctx.insert(o); story.generatedOutputs.append(o) }
        try ctx.save()

        // Each output's type is AUTHORITATIVE and independent — Highlights + Full Story + Highlights coexist.
        XCTAssertEqual(o1.editorialType, .highlights)
        XCTAssertEqual(o2.editorialType, .fullStory)
        XCTAssertEqual(o3.editorialType, .highlights)
        // The Story keeps only a preferred default; it does NOT force one type across outputs.
        XCTAssertEqual(story.preferredEditorialType, .highlights)
        XCTAssertEqual(Set(story.generatedOutputs.compactMap { $0.editorialType }), [.highlights, .fullStory])
    }

    func test_legacy_output_has_nil_type_never_guessed() throws {
        let ctx = try makeContainer().mainContext
        // A historical output predating P1-A: editorialTypeRaw defaulted nil.
        let legacy = GeneratedOutputModel(title: "old", durationSeconds: 40, momentIds: [])
        ctx.insert(legacy); try ctx.save()
        XCTAssertNil(legacy.editorialType, "a legacy output must stay unspecified, never relabeled Full Story")
    }

    func test_story_custom_seed_defaults_newAttempt_to_highlights_but_output_stays_unspecified() throws {
        let ctx = try makeContainer().mainContext
        let story = StoryModel(title: "custom-dur", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "s"); story.editorialMode = "custom"; ctx.insert(story)
        try ctx.save()
        // A fresh attempt inherits Highlights (compatibility default), but a persisted custom output records nil.
        XCTAssertEqual(story.preferredEditorialType, .highlights)
        XCTAssertEqual(story.durationChoice, .userExact)
        let out = GeneratedOutputModel(title: "custom-dur", durationSeconds: 47, momentIds: [],
                                       editorialTypeRaw: ResolvedEditorial.fromLegacy(story.editorialMode).type?.rawValue)
        ctx.insert(out); try ctx.save()
        XCTAssertNil(out.editorialType, "custom seed yields an unspecified output type, not Full Story")
    }

    // MARK: - provenance is honest (owner §2): flag-OFF runs are NOT labeled with a P1 type

    func test_provenance_stamp_is_nil_when_flag_off() {
        // The coordinator stamps editorialTypeRaw ONLY when the flag is ON (an explicit P1 selection). With the
        // flag OFF — plain v5.2 behavior — the stamp mirrors this expression and must be nil, so a v5.2 output
        // is never mislabeled with a guessed/inferred type. (Mirrors StoryCreationCoordinator.persist.)
        UserDefaults.standard.removeObject(forKey: EditorialTypeFlag.key)
        XCTAssertFalse(EditorialTypeFlag.enabled)
        let editorialMode = "highlights"   // even a resolvable seed must NOT be stamped while the flag is off
        let stamped: String? = EditorialTypeFlag.enabled
            ? ResolvedEditorial.fromLegacy(editorialMode).type?.rawValue
            : nil
        XCTAssertNil(stamped, "flag OFF must not stamp an inferred editorial type (honest provenance)")
    }

    func test_provenance_stamp_reflects_selection_when_flag_on() {
        EditorialTypeFlag.setOverride(true)
        defer { UserDefaults.standard.removeObject(forKey: EditorialTypeFlag.key) }
        XCTAssertTrue(EditorialTypeFlag.enabled)
        let stamped: String? = EditorialTypeFlag.enabled
            ? ResolvedEditorial.fromLegacy("full").type?.rawValue
            : nil
        XCTAssertEqual(stamped, EditorialType.fullStory.rawValue)
        // A custom seed is still unspecified even with the flag on (never guessed).
        let customStamp: String? = EditorialTypeFlag.enabled
            ? ResolvedEditorial.fromLegacy("custom").type?.rawValue
            : nil
        XCTAssertNil(customStamp)
    }
}
