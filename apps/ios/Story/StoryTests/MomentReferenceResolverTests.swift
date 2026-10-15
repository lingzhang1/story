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
}
