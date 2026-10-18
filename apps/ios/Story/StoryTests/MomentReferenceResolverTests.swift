import XCTest
@testable import Story

// Explicit Moment References — pure resolution core (numbering snapshot + typed parser + resolver).
// No SwiftData, no UI: these lock the shared logic both Creative Direction and Revision depend on.
final class MomentReferenceResolverTests: XCTestCase {

    private func numbering(_ n: Int) -> (StoryMomentNumbering, [UUID]) {
        let ids = (0..<n).map { _ in UUID() }
        let items = ids.enumerated().map {
            NumberedMoment(number: $0.offset + 1, id: $0.element, durationSeconds: 5.0, relativePath: "m\($0.offset).mov")
        }
        return (StoryMomentNumbering(ordered: items), ids)
    }

    // 1. Story-scoped numbering is 1-based, gap-free, bidirectional.
    func test_numbering_is_one_based_and_bidirectional() {
        let (num, ids) = numbering(3)
        XCTAssertEqual(num.count, 3)
        XCTAssertEqual(num.id(forNumber: 1), ids[0])
        XCTAssertEqual(num.id(forNumber: 3), ids[2])
        XCTAssertNil(num.id(forNumber: 0))
        XCTAssertNil(num.id(forNumber: 4))
        XCTAssertEqual(num.number(forId: ids[1]), 2)
    }

    // 2. Numbering is a re-stamped snapshot: a DIFFERENT order yields different number->id, same ids.
    func test_numbering_restamps_from_given_order() {
        let (a, ids) = numbering(3)
        // reversed order snapshot
        let reversed = StoryMomentNumbering(ordered: a.items.reversed().map { $0 })
        XCTAssertEqual(reversed.id(forNumber: 1), ids[2])
        XCTAssertEqual(reversed.id(forNumber: 3), ids[0])
    }

    // 3. Typed parser: the four supported forms map to the right slots.
    func test_parse_four_supported_forms() {
        let refs = MomentReferenceResolver.parseTyped(
            "Start with Moment 8, include Moment 12, exclude Moment 4, end with Moment 15.")
        let slots = Dictionary(uniqueKeysWithValues: refs.map { ($0.slot, $0.number) })
        XCTAssertEqual(slots[.opening], 8)
        XCTAssertEqual(slots[.include], 12)
        XCTAssertEqual(slots[.exclude], 4)
        XCTAssertEqual(slots[.ending], 15)
    }

    // 3a. "Start from Moment N" (and "start with") parse to OPENING. Regression: the connector alternation
    // originally listed only with/on/off-with, so "start FROM moment N" fell through to no opening at all —
    // the clip never moved to the front despite the user asking for it.
    func test_parse_opening_start_from_and_with() {
        XCTAssertEqual(MomentReferenceResolver.parseTyped("Start from Moment 5").first?.slot, .opening)
        XCTAssertEqual(MomentReferenceResolver.parseTyped("Start from Moment 5").first?.number, 5)
        XCTAssertEqual(MomentReferenceResolver.parseTyped("Start with Moment 5").first?.slot, .opening)
        XCTAssertEqual(MomentReferenceResolver.parseTyped("start from moment 5 and make the cuts fast").first?.slot, .opening)
    }

    // 3b. "do not use" / "don't use" parse as exclude; "put Moment N at the end" as ending.
    func test_parse_exclude_and_put_at_end_variants() {
        XCTAssertEqual(MomentReferenceResolver.parseTyped("do not use moment 4").first?.slot, .exclude)
        XCTAssertEqual(MomentReferenceResolver.parseTyped("don't use Moment 4").first?.slot, .exclude)
        let r = MomentReferenceResolver.parseTyped("Put Moment 15 at the end")
        XCTAssertEqual(r.first?.slot, .ending)
        XCTAssertEqual(r.first?.number, 15)
    }

    // 4. Typed references resolve to stable UUIDs.
    func test_typed_resolves_to_stable_ids() {
        let (num, ids) = numbering(15)
        let res = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped("Start with Moment 8 and include Moment 12"),
            in: num)
        XCTAssertEqual(res.directives.opening, ids[7])        // Moment 8 -> index 7
        XCTAssertEqual(res.directives.mustInclude, [ids[11]]) // Moment 12 -> index 11
        XCTAssertFalse(res.needsClarification)
    }

    // 5. Reordering safety: a reference resolved against the OLD snapshot keeps its id even after reorder.
    func test_reordering_does_not_corrupt_resolved_reference() {
        let (oldNum, ids) = numbering(3)
        let resolvedOpening = oldNum.id(forNumber: 1)   // == ids[0]
        // user reorders: build a new snapshot where ids[0] is now number 3
        let reordered = StoryMomentNumbering(ordered: [
            NumberedMoment(number: 1, id: ids[1], durationSeconds: 5, relativePath: nil),
            NumberedMoment(number: 2, id: ids[2], durationSeconds: 5, relativePath: nil),
            NumberedMoment(number: 3, id: ids[0], durationSeconds: 5, relativePath: nil),
        ])
        // the PERSISTED id is unchanged; it still points at the same Moment, now displayed as #3.
        XCTAssertEqual(resolvedOpening, ids[0])
        XCTAssertEqual(reordered.number(forId: resolvedOpening!), 3)
    }

    // 6. Invalid number -> clarification, never silent drop/substitute.
    func test_invalid_number_requires_clarification() {
        let (num, _) = numbering(3)
        let res = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped("include Moment 9"), in: num)
        XCTAssertTrue(res.needsClarification)
        XCTAssertTrue(res.directives.mustInclude.isEmpty)
        if case .numberOutOfRange(let n) = res.unresolved.first?.reason { XCTAssertEqual(n, 9) }
        else { XCTFail("expected numberOutOfRange") }
    }

    // 7. Duplicate references are de-duplicated safely.
    func test_duplicate_references_safe() {
        let (num, ids) = numbering(5)
        let res = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped("include Moment 2 and include Moment 2"), in: num)
        XCTAssertEqual(res.directives.mustInclude, [ids[1]])
    }

    // 8. Visual chips carrying a stable id resolve without number lookup.
    func test_chips_resolve_by_stable_id() {
        let (num, ids) = numbering(5)
        let res = MomentReferenceResolver.resolve(
            typed: [], chips: [(.include, ids[2]), (.opening, ids[0])], in: num)
        XCTAssertEqual(res.directives.mustInclude, [ids[2]])
        XCTAssertEqual(res.directives.opening, ids[0])
    }

    // 9. A chip whose Moment was removed from the Story -> clarification (owner #1/#2).
    func test_removed_chip_requires_clarification() {
        let (num, _) = numbering(3)
        let ghost = UUID()
        let res = MomentReferenceResolver.resolve(typed: [], chips: [(.include, ghost)], in: num)
        XCTAssertTrue(res.needsClarification)
        if case .momentUnavailable(let id) = res.unresolved.first?.reason { XCTAssertEqual(id, ghost) }
        else { XCTFail("expected momentUnavailable") }
    }

    // 10. opening/ending are single-valued: a later instruction overrides an earlier one.
    func test_later_opening_overrides() {
        let (num, ids) = numbering(5)
        let res = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped("start with Moment 1 then start with Moment 3"), in: num)
        XCTAssertEqual(res.directives.opening, ids[2])
    }

    // 11. Wire encoding matches the backend contract (snake_case keys, uuid strings, omit empties).
    func test_wire_dictionary_matches_backend_contract() {
        let (num, ids) = numbering(5)
        var res = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped("include Moment 2, exclude Moment 4, start with Moment 1"),
            in: num)
        res.directives.ending = ids[4]
        let wire = res.directives.wireDictionary()
        XCTAssertEqual(wire["must_include"] as? [String], [ids[1].uuidString])
        XCTAssertEqual(wire["exclude"] as? [String], [ids[3].uuidString])
        XCTAssertEqual(wire["opening"] as? String, ids[0].uuidString)
        XCTAssertEqual(wire["ending"] as? String, ids[4].uuidString)
    }

    // 12. No references -> empty directives, nothing encoded (existing creation unchanged).
    func test_no_references_is_empty() {
        let (num, _) = numbering(3)
        let res = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped("make it cinematic and upbeat"), in: num)
        XCTAssertTrue(res.directives.isEmpty)
        XCTAssertFalse(res.needsClarification)
        XCTAssertTrue(res.directives.wireDictionary().isEmpty)
    }

    // ---- Phase 6: the owner's 16 instruction cases (deterministic path coverage) ----
    // Cases needing creative/free-text interpretation (12 "blue-dress clip", 9/10 pacing soft) or the AI
    // interpreter (compound ambiguity) are validated on the backend interpreter path, noted inline.

    private func num5() -> (StoryMomentNumbering, [UUID]) { numbering(8) }

    func test_case1_use_moment5_to_start() {
        let (n, ids) = num5()
        let r = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped("Use Moment 5 to start."),
            ordering: MomentReferenceResolver.parseOrdering("Use Moment 5 to start."),
            implicitFollow: MomentReferenceResolver.parseImplicitFollow("Use Moment 5 to start."), in: n)
        XCTAssertEqual(r.directives.opening, ids[4])
    }

    func test_case2_start_with_moment5() {
        let (n, ids) = num5()
        let r = MomentReferenceResolver.resolve(typed: MomentReferenceResolver.parseTyped("Start with Moment 5."), in: n)
        XCTAssertEqual(r.directives.opening, ids[4])
    }

    func test_case3_use_moment5_to_start_and_moment2_follow() {
        let (n, ids) = num5()
        let t = "Use Moment 5 to start and Moment 2 follow."
        let r = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped(t),
            ordering: MomentReferenceResolver.parseOrdering(t),
            implicitFollow: MomentReferenceResolver.parseImplicitFollow(t), in: n)
        XCTAssertEqual(r.directives.opening, ids[4])
        XCTAssertEqual(r.directives.orderAdjacent, [[ids[1], ids[4]]])   // 2 immediately after 5
    }

    func test_case4_start_with_moment5_then_moment2() {
        let (n, ids) = num5()
        let t = "Start with Moment 5, then Moment 2."
        let r = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped(t),
            ordering: MomentReferenceResolver.parseOrdering(t), in: n)
        XCTAssertEqual(r.directives.opening, ids[4])
        XCTAssertEqual(r.directives.orderAdjacent, [[ids[1], ids[4]]])
    }

    func test_case5_moment2_immediately_after_moment5() {
        let (n, ids) = num5()
        let t = "Put Moment 2 immediately after Moment 5."
        let r = MomentReferenceResolver.resolve(typed: [], ordering: MomentReferenceResolver.parseOrdering(t), in: n)
        XCTAssertEqual(r.directives.orderAdjacent, [[ids[1], ids[4]]])
    }

    func test_case6_moment2_somewhere_after_moment5() {
        let (n, ids) = num5()
        let t = "Show Moment 2 somewhere after Moment 5."
        let r = MomentReferenceResolver.resolve(typed: [], ordering: MomentReferenceResolver.parseOrdering(t), in: n)
        XCTAssertEqual(r.directives.orderAfter, [[ids[1], ids[4]]])
        XCTAssertTrue(r.directives.orderAdjacent.isEmpty)
    }

    func test_case7_include_moment8() {
        let (n, ids) = num5()
        let r = MomentReferenceResolver.resolve(typed: MomentReferenceResolver.parseTyped("Include Moment 8."), in: n)
        XCTAssertEqual(r.directives.mustInclude, [ids[7]])
    }

    func test_case8_exclude_moment4() {
        let (n, ids) = num5()
        let r = MomentReferenceResolver.resolve(typed: MomentReferenceResolver.parseTyped("Exclude Moment 4."), in: n)
        XCTAssertEqual(r.directives.exclude, [ids[3]])
    }

    func test_case9_make_cuts_faster_is_no_hard_directive() {
        let (n, _) = num5()
        // Pure pacing: no hard directive (goes to soft_direction on the planner path).
        let r = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped("Make the cuts faster."),
            ordering: MomentReferenceResolver.parseOrdering("Make the cuts faster."), in: n)
        XCTAssertTrue(r.directives.isEmpty)
    }

    func test_case10_opening_plus_pacing() {
        let (n, ids) = num5()
        let t = "Start with Moment 5 and make the cuts faster."
        let r = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped(t),
            ordering: MomentReferenceResolver.parseOrdering(t), in: n)
        XCTAssertEqual(r.directives.opening, ids[4])   // hard part captured; pacing stays soft (raw text)
    }

    func test_case14_unknown_moment_number_unresolved() {
        let (n, _) = num5()
        let r = MomentReferenceResolver.resolve(typed: MomentReferenceResolver.parseTyped("Include Moment 99."), in: n)
        XCTAssertTrue(r.needsClarification)
        XCTAssertTrue(r.directives.isEmpty)
    }

    func test_case16_unsupported_mixed_with_supported() {
        let (n, ids) = num5()
        // "make it dreamier" (unsupported) + "exclude Moment 4" (supported): supported part still resolves;
        // the unsupported clause is handled by the backend interpreter's `unsupported` list, not dropped here.
        let r = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped("Make it dreamier and exclude Moment 4."), in: n)
        XCTAssertEqual(r.directives.exclude, [ids[3]])
    }
}

// Stage 2 music-intent routing — deterministic classifier that separates MUSIC preference from EDIT/beat-sync
// intent (owner Music-Routing milestone). These lock the boundary that CreateStoryPreviewView routes on; the
// SwiftData authority/cache behavior (tests 6/9) is enforced in MusicDirectionCoordinator (no overwrite of a
// user-authored row; music-only change regenerates nothing) and asserted structurally here via the classifier.
final class MusicIntentRoutingTests: XCTestCase {

    // Test 1: pure visual pacing — NO music preference, NO beat-sync (never fabricate music from visual words).
    func test_make_cuts_faster_is_not_music() {
        let m = MomentReferenceResolver.parseMusicIntent("Make the cuts faster")
        XCTAssertNil(m.preference)
        XCTAssertFalse(m.beatSync)
        XCTAssertTrue(m.isEmpty)
    }

    // Test 2: "match cuts to the music" is beat-sync (edit-side) only — NO soundtrack preference.
    func test_match_cuts_to_music_is_beatsync_not_preference() {
        let m = MomentReferenceResolver.parseMusicIntent("Make the cuts faster to match the music")
        XCTAssertNil(m.preference, "beat-sync must not become a soundtrack preference")
        XCTAssertTrue(m.beatSync)
    }

    // Test 3: explicit "gentle acoustic music" IS a music preference reaching MusicPlan.
    func test_gentle_acoustic_music_is_preference() {
        let m = MomentReferenceResolver.parseMusicIntent("Use gentle acoustic music")
        XCTAssertNotNil(m.preference)
        XCTAssertTrue(m.preference!.moodTags.contains("acoustic"))
        XCTAssertFalse(m.beatSync)
    }

    // Test 4: "energetic electronic music" reaches MusicPlan with energetic/electronic moods.
    func test_energetic_electronic_music_is_preference() {
        let m = MomentReferenceResolver.parseMusicIntent("Use energetic electronic music")
        XCTAssertNotNil(m.preference)
        XCTAssertTrue(m.preference!.moodTags.contains("electronic"))
        XCTAssertTrue(m.preference!.moodTags.contains("energetic"))
    }

    // Test 5: mixed edit + music — the Moment directive resolves AND the music preference is extracted, each
    // from the same string, independently (routing separation).
    func test_mixed_moment_and_music_separate() {
        let ids = (0..<6).map { _ in UUID() }
        let items = ids.enumerated().map {
            NumberedMoment(number: $0.offset + 1, id: $0.element, durationSeconds: 5, relativePath: nil)
        }
        let num = StoryMomentNumbering(ordered: items)
        let text = "Start with Moment 5 and use energetic music"
        let typed = MomentReferenceResolver.parseTyped(text)
        let res = MomentReferenceResolver.resolve(typed: typed, in: num)
        XCTAssertEqual(res.directives.opening, ids[4], "opening directive -> edit planner")
        let m = MomentReferenceResolver.parseMusicIntent(text)
        XCTAssertTrue(m.preference?.moodTags.contains("energetic") ?? false, "music pref -> MusicPlan")
    }

    // Test 8 (classifier side): empty / non-music text yields an empty intent (preserves existing behavior).
    func test_empty_and_visual_only_preserve_behavior() {
        XCTAssertTrue(MomentReferenceResolver.parseMusicIntent("").isEmpty)
        XCTAssertTrue(MomentReferenceResolver.parseMusicIntent("Use the most visually striking footage first").isEmpty,
                      "generic visual language must not fabricate a music preference")
    }

    // Test 10: beat-alignment phrasings all classify as beat-sync (reach edit planning, not track change).
    func test_beat_alignment_variants_are_beatsync() {
        for s in ["Sync the cuts to the beat", "Cut on the beat", "Match the beat", "beat-sync the edit"] {
            XCTAssertTrue(MomentReferenceResolver.parseMusicIntent(s).beatSync, "\(s) should be beat-sync")
            XCTAssertNil(MomentReferenceResolver.parseMusicIntent(s).preference, "\(s) must not change the track")
        }
    }

    // A music CONTEXT word is required — "energetic opening" (visual) is not a music preference, but
    // "energetic music" is. This is the guard that makes tests 1/5/8 hold.
    func test_music_context_word_required() {
        XCTAssertNil(MomentReferenceResolver.parseMusicIntent("Give it an energetic opening").preference)
        XCTAssertNotNil(MomentReferenceResolver.parseMusicIntent("Give it an energetic soundtrack").preference)
    }
}
