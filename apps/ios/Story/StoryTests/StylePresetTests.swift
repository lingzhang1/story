import XCTest
@testable import Story

// StylePreset tests (Phase B). Pure, deterministic — no model, no persistence. Validates owner decisions
// 2B–2E: presets are optional, map to EXISTING style/feeling + music semantics, pace only when unambiguous,
// NL/user-music precedence, and per-output composition (nothing here touches durable CreativeIntent).
final class StylePresetTests: XCTestCase {

    func test_pace_mapped_only_when_unambiguous() {   // 2C
        XCTAssertEqual(StylePreset.energetic.forcedPace, "fast")
        XCTAssertEqual(StylePreset.calm.forcedPace, "slow")
        XCTAssertNil(StylePreset.cinematic.forcedPace)
        XCTAssertNil(StylePreset.emotional.forcedPace)
        XCTAssertNil(StylePreset.playful.forcedPace)
    }

    func test_none_selected_is_none() {
        XCTAssertEqual(StylePresetContribution.from([], userHasMusicPreference: false), .none)
    }

    func test_single_preset_maps_phrase_and_moods() {
        let c = StylePresetContribution.from([.cinematic], userHasMusicPreference: false)
        XCTAssertEqual(c.directionSuffix, "Give it a cinematic feel")
        XCTAssertEqual(c.musicMoodTags, ["cinematic"])
        XCTAssertNil(c.forcedPace)
    }

    func test_user_music_preference_suppresses_preset_music_seed() {   // 2D
        let c = StylePresetContribution.from([.energetic], userHasMusicPreference: true)
        XCTAssertEqual(c.musicMoodTags, [], "an explicit user music ask wins — no preset seed")
        XCTAssertEqual(c.forcedPace, "fast", "edit pace still applies")
    }

    func test_conflicting_pace_forces_none() {
        let c = StylePresetContribution.from([.energetic, .calm], userHasMusicPreference: false)
        XCTAssertNil(c.forcedPace, "energetic + calm must not force a pace")
        XCTAssertEqual(c.musicMoodTags, ["energetic", "calm"])
    }

    func test_multi_preset_phrase_is_order_stable() {
        let c = StylePresetContribution.from([.energetic, .cinematic], userHasMusicPreference: false)
        XCTAssertEqual(c.directionSuffix, "Give it a cinematic feel. Make it energetic")
    }

    func test_all_presets_have_label_phrase_and_music() {
        for p in StylePreset.allCases {
            XCTAssertFalse(p.label.isEmpty)
            XCTAssertFalse(p.directionPhrase.isEmpty)
            XCTAssertFalse(p.musicMoodTags.isEmpty)
        }
    }

    func test_expanded_preset_set() {   // owner #4 2026-10-24
        XCTAssertEqual(StylePreset.allCases.count, 12)
        XCTAssertEqual(StylePreset.upbeat.forcedPace, "fast")
        XCTAssertEqual(StylePreset.minimal.forcedPace, "slow")
        XCTAssertNil(StylePreset.nostalgic.forcedPace)
        XCTAssertNil(StylePreset.dreamy.forcedPace)
        XCTAssertEqual(StylePreset.nostalgic.musicMoodTags, ["emotional"])
        XCTAssertEqual(StylePreset.dreamy.musicMoodTags, ["atmospheric"])
        XCTAssertEqual(StylePreset.epic.musicMoodTags, ["cinematic"])
    }
}
