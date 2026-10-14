import XCTest
@testable import Story

// A1 richer-AU-forwarding tests (owner-approved 2026-10-12, multimodal experiment addendum).
//
// Verifies EditPlanRequestBuilder.richEvidence / evidenceField: the BOUNDED, STRUCTURED evidence object the Edit
// Planner now receives ALONGSIDE the legacy `summary`. Pure (JSONValue in -> JSONValue out), no network, no
// SwiftData, no model. Covers the owner's required cases: missing fields, long clips / long descriptions,
// multiple events (timestamps kept explicit), payload bounds, and backward compatibility (older/partial AU
// records produce NO evidence field, so the wire shape is byte-identical to pre-A1).
final class RenderSupportRichEvidenceTests: XCTestCase {

    // Build an AU understanding JSONValue with the given observed fields.
    private func au(summary: String? = "a woman at a balcony",
                    subjects: [String] = [],
                    events: [(Double, Double?, String)] = [],
                    note: String? = nil,
                    includeObserved: Bool = true) -> JSONValue {
        var observed: [String: JSONValue] = [:]
        if let summary { observed["summary"] = .string(summary) }
        if !subjects.isEmpty { observed["subjects"] = .array(subjects.map { .string($0) }) }
        if !events.isEmpty {
            observed["events"] = .array(events.map { e in
                var o: [String: JSONValue] = ["start_time": .number(e.0), "description": .string(e.2)]
                if let end = e.1 { o["end_time"] = .number(end) }
                return .object(o)
            })
        }
        if let note { observed["temporal_order_note"] = .string(note) }
        var root: [String: JSONValue] = ["story_context": .object(["story_utility": .string("useful_elsewhere")])]
        if includeObserved { root["observed"] = .object(observed) }
        return .object(root)
    }

    private func obj(_ v: JSONValue) -> [String: JSONValue]? {
        if case let .object(o) = v { return o }; return nil
    }

    // 1. Backward compatibility: an AU record with NO observed block yields NO evidence field.
    func testNoObservedBlockOmitsEvidence() {
        let ev = EditPlanRequestBuilder.richEvidence(from: au(includeObserved: false))
        guard case .null = ev else { return XCTFail("expected .null for missing observed block") }
        XCTAssertTrue(EditPlanRequestBuilder.evidenceField(au(includeObserved: false)).isEmpty,
                      "evidenceField must be empty (no-op merge) when observed is absent")
    }

    // 2. Missing fields: only present fields appear; nothing fabricated.
    func testMissingFieldsNotFabricated() {
        let ev = EditPlanRequestBuilder.richEvidence(from: au(summary: "just a summary", subjects: [], events: [], note: nil))
        let o = obj(ev)!
        XCTAssertEqual(o["summary"]?.stringValue, "just a summary")
        XCTAssertNil(o["subjects"], "no subjects in -> no subjects out")
        XCTAssertNil(o["events"], "no events in -> no events out")
        XCTAssertNil(o["temporal_order_note"])
    }

    // 3. Event timestamps are kept EXPLICIT and STRUCTURED (not buried in prose).
    func testEventTimestampsStructured() {
        let ev = EditPlanRequestBuilder.richEvidence(from: au(events: [
            (0.0, 2.0, "woman at railing"),
            (7.5, nil, "camera reveals cityscape"),
        ]))
        guard case let .array(evs)? = obj(ev)?["events"] else { return XCTFail("events missing") }
        XCTAssertEqual(evs.count, 2)
        guard case let .object(e0) = evs[0] else { return XCTFail() }
        XCTAssertEqual(e0["t"]?.doubleValue, 0.0)
        XCTAssertEqual(e0["t_end"]?.doubleValue, 2.0)
        XCTAssertEqual(e0["what"]?.stringValue, "woman at railing")
        guard case let .object(e1) = evs[1] else { return XCTFail() }
        XCTAssertEqual(e1["t"]?.doubleValue, 7.5)
        XCTAssertNil(e1["t_end"], "missing end_time -> no t_end")
    }

    // 4. Subjects de-duplicated (case-insensitive) and bounded.
    func testSubjectsDedupedAndBounded() {
        let many = (0..<20).map { "subject\($0)" } + ["Green Earrings", "green earrings"]
        let ev = EditPlanRequestBuilder.richEvidence(from: au(subjects: many))
        guard case let .array(subs)? = obj(ev)?["subjects"] else { return XCTFail("subjects missing") }
        XCTAssertLessThanOrEqual(subs.count, 10, "subjects bounded to MAX_SUBJECTS")
        // case-insensitive dedupe: both "Green Earrings" variants cannot both appear
        let strs = subs.compactMap { v -> String? in if case let .string(s) = v { return s.lowercased() }; return nil }
        XCTAssertEqual(Set(strs).count, strs.count, "no case-insensitive duplicates")
    }

    // 5. Long clips / many events: event count is bounded.
    func testManyEventsBounded() {
        let events = (0..<30).map { (Double($0) * 5.0, nil as Double?, "event number \($0) happening in the clip") }
        let ev = EditPlanRequestBuilder.richEvidence(from: au(events: events))
        guard case let .array(evs)? = obj(ev)?["events"] else { return XCTFail("events missing") }
        XCTAssertLessThanOrEqual(evs.count, 8, "events bounded to MAX_EVENTS")
    }

    // 6. Long descriptions trimmed per-field.
    func testLongDescriptionsTrimmed() {
        let longWhat = String(repeating: "x", count: 500)
        let longSummary = String(repeating: "s", count: 1000)
        let longNote = String(repeating: "n", count: 1000)
        let ev = EditPlanRequestBuilder.richEvidence(from: au(summary: longSummary,
                                                     events: [(0.0, nil, longWhat)], note: longNote))
        let o = obj(ev)!
        if case let .string(s)? = o["summary"] { XCTAssertLessThanOrEqual(s.count, 321) } else { XCTFail() }
        if case let .string(n)? = o["temporal_order_note"] { XCTAssertLessThanOrEqual(n.count, 201) } else { XCTFail() }
        if case let .array(evs)? = o["events"], case let .object(e0) = evs[0], case let .string(w)? = e0["what"] {
            XCTAssertLessThanOrEqual(w.count, 91)
        } else { XCTFail() }
    }

    // 7. Payload hard bound: a pathologically large AU still fits MAX_EVIDENCE_CHARS by dropping tail events.
    func testOverallPayloadBounded() {
        let events = (0..<8).map { (Double($0), nil as Double?, String(repeating: "z", count: 90)) }
        let subjects = (0..<10).map { _ in String(repeating: "q", count: 80) }
        let ev = EditPlanRequestBuilder.richEvidence(from: au(summary: String(repeating: "a", count: 320),
                                                     subjects: subjects, events: events,
                                                     note: String(repeating: "b", count: 200)))
        // sum of string lengths across the structured object must be within the ceiling (1400)
        func textLen(_ v: JSONValue) -> Int {
            guard case let .object(o) = v else { return 0 }
            var n = 0
            for (_, x) in o {
                switch x {
                case .string(let s): n += s.count
                case .array(let a):
                    for e in a {
                        if case let .string(s) = e { n += s.count }
                        else if case let .object(eo) = e { for (_, z) in eo { if case let .string(s) = z { n += s.count } } }
                    }
                default: break
                }
            }
            return n
        }
        XCTAssertLessThanOrEqual(textLen(ev), 1400, "evidence text bounded to MAX_EVIDENCE_CHARS")
    }
}
