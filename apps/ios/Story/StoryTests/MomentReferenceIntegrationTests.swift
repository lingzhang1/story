import XCTest
import SwiftData
@testable import Story

// Explicit Moment References — Increment 5 integration tests for the directive persistence / compose / revise
// seams. Standalone: pure value types + a tiny in-memory SwiftData container for the StoryModel-backed paths.
// Does NOT touch the pre-existing (broken) StoryCreationCoordinatorTests harness — these exercise the resolver
// output contract, not the coordinator's async run.
@MainActor
final class MomentReferenceIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
                 GeneratedOutputModel.self,
            configurations: config)
    }
    override func tearDown() { container = nil }

    // MARK: - helpers

    private func story() -> StoryModel {
        let s = StoryModel(title: "T",
                           intentRawText: "", intentTheme: "", intentTone: "", intentSummary: "")
        ctx.insert(s); return s
    }

    private func planJSON(_ assetIds: [String]) -> String {
        let segs = assetIds.enumerated().map { i, a in
            "{\"order\":\(i),\"asset_id\":\"\(a)\",\"source_start_seconds\":0,\"source_end_seconds\":4,\"output_duration_seconds\":4,\"native_audio\":\"keep\"}"
        }.joined(separator: ",")
        return "{\"schema_version\":\"edit_plan/2\",\"target_duration_seconds\":12,\"output_format\":\"vertical\",\"feasible\":true,\"segments\":[\(segs)]}"
    }

    private func output(_ story: StoryModel, assetIds: [String]) -> GeneratedOutputModel {
        let o = GeneratedOutputModel(title: "v", durationSeconds: Double(assetIds.count) * 4,
                                     momentIds: assetIds.compactMap { UUID(uuidString: $0) },
                                     relativeFilePath: "out.mp4",
                                     versionId: UUID(), operationType: "original",
                                     editPlanJSON: planJSON(assetIds))
        ctx.insert(o); return o
    }

    // MARK: - ResolvedDirectives wire round-trip (persistence)

    func test_directives_wire_roundtrip() {
        let a = UUID(), b = UUID(), c = UUID()
        var d = ResolvedDirectives()
        d.mustInclude = [a]; d.exclude = [b]; d.opening = a; d.ending = c
        let json = d.toWireJSON()
        XCTAssertNotNil(json)
        let back = ResolvedDirectives.fromWireJSON(json)
        XCTAssertEqual(back, d)
    }

    func test_empty_directives_wire_is_nil() {
        XCTAssertNil(ResolvedDirectives().toWireJSON())
        XCTAssertNil(ResolvedDirectives.fromWireJSON(nil))
        XCTAssertNil(ResolvedDirectives.fromWireJSON("{}"))
    }

    // MARK: - composeRevisionContext (planner request integration)

    func test_compose_nil_when_no_directives_no_base() {
        let s = story()
        s.creativeDirectivesJSON = nil
        XCTAssertNil(StoryCreationCoordinator.composeRevisionContext(base: nil, story: s))
    }

    func test_compose_wraps_persisted_directives_as_revise() {
        let s = story()
        let a = UUID()
        var d = ResolvedDirectives(); d.mustInclude = [a]
        s.creativeDirectivesJSON = d.toWireJSON()
        guard case .object(let o)? = StoryCreationCoordinator.composeRevisionContext(base: nil, story: s) else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(o["mode"], .string("revise"))
        guard case .object(let dir)? = o["directives"] else { return XCTFail("expected directives") }
        XCTAssertEqual(dir["must_include"], .array([.string(a.uuidString)]))
    }

    func test_compose_does_not_clobber_base_context_directives() {
        // A Revise base context already carrying its own directives must NOT be overwritten by the Story's
        // persisted creation directives.
        let s = story()
        let storyId = UUID(), reviseId = UUID()
        var sd = ResolvedDirectives(); sd.mustInclude = [storyId]
        s.creativeDirectivesJSON = sd.toWireJSON()
        let base = JSONValue.object([
            "mode": .string("revise"),
            "directives": .object(["opening": .string(reviseId.uuidString)]),
        ])
        guard case .object(let o)? = StoryCreationCoordinator.composeRevisionContext(base: base, story: s),
              case .object(let dir)? = o["directives"] else { return XCTFail("expected object") }
        // The base context's own directives win — the Story directives did not clobber them.
        XCTAssertEqual(dir["opening"], .string(reviseId.uuidString))
        XCTAssertNil(dir["must_include"])
    }

    // MARK: - Create Another Version: honor Customize-entered directives (the "Moment 15 then Moment 2" bug)

    func test_compose_anotherVersion_without_customize_drops_directives_stays_explore() {
        // One-tap Create Another Version (NOT via Customize) must NOT inherit the Story's persisted directives.
        let s = story()
        var d = ResolvedDirectives(); d.opening = UUID()
        s.creativeDirectivesJSON = d.toWireJSON()
        let base = JSONValue.object(["mode": .string("explore")])
        guard case .object(let o)? = StoryCreationCoordinator.composeRevisionContext(
            base: base, story: s, operationType: "another_version", directedByCustomize: false) else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(o["mode"], .string("explore"))
        XCTAssertNil(o["directives"], "a blind explore must not inherit persisted directives (test 12)")
    }

    func test_compose_anotherVersion_via_customize_stays_explore_with_directives() {
        // Owner decision 2026-10-22: Create Another Version launched FROM the Customize sheet with
        // "Start from Moment 15, then Moment 2" must KEEP mode=explore (a meaningfully-different NEW version)
        // while carrying the user's hard directives — it must NOT be rerouted to revise (which would preserve
        // the previous edit and conflict with Revise-vs-Create-Another-Version semantics).
        let s = story()
        let m15 = UUID(), m2 = UUID()
        var d = ResolvedDirectives(); d.opening = m15; d.orderAdjacent = [[m2, m15]]
        s.creativeDirectivesJSON = d.toWireJSON()
        let base = JSONValue.object(["mode": .string("explore")])
        guard case .object(let o)? = StoryCreationCoordinator.composeRevisionContext(
            base: base, story: s, operationType: "another_version", directedByCustomize: true),
              case .object(let dir)? = o["directives"] else {
            return XCTFail("expected object with directives")
        }
        XCTAssertEqual(o["mode"], .string("explore"), "directed Create Another Version must STAY explore")
        XCTAssertEqual(dir["opening"], .string(m15.uuidString), "opening=Moment 15 must still reach the planner")
        XCTAssertEqual(dir["order_adjacent"], .array([.array([.string(m2.uuidString), .string(m15.uuidString)])]))
    }

    func test_compose_anotherVersion_via_customize_carries_soft_direction_on_explore() {
        // The typed soft instruction must ride along on the explore request too (not dropped by routing).
        let s = story()
        s.creativeDirectionText = "Add more local-people conversations"
        var d = ResolvedDirectives(); d.opening = UUID()
        s.creativeDirectivesJSON = d.toWireJSON()
        let base = JSONValue.object(["mode": .string("explore")])
        guard case .object(let o)? = StoryCreationCoordinator.composeRevisionContext(
            base: base, story: s, operationType: "another_version", directedByCustomize: true) else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(o["mode"], .string("explore"))
        XCTAssertEqual(o["soft_direction"], .string("Add more local-people conversations"))
    }

    // MARK: - RevisionContextBuilder.revise carries the EXACT base plan

    func test_revise_carries_exact_base_plan() {
        let s = story()
        let a = UUID().uuidString, b = UUID().uuidString
        let base = output(s, assetIds: [a, b])
        var d = ResolvedDirectives(); d.exclude = [UUID(uuidString: b)!]
        guard case .object(let o) = RevisionContextBuilder.revise(base: base, directives: d,
                                                                  softDirection: "make it tighter") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(o["mode"], .string("revise"))
        XCTAssertEqual(o["soft_direction"], .string("make it tighter"))
        // base_plan is the EXACT plan (not a digest): same segments/asset_ids as the base output.
        guard case .object(let plan)? = o["base_plan"], case .array(let segs)? = plan["segments"] else {
            return XCTFail("expected base_plan with segments")
        }
        XCTAssertEqual(segs.count, 2)
        if case .object(let seg0) = segs[0] { XCTAssertEqual(seg0["asset_id"], .string(a)) }
        else { XCTFail("seg0") }
    }

    func test_revise_without_plan_omits_base_plan_but_keeps_instruction() {
        let s = story()
        let legacy = GeneratedOutputModel(title: "legacy", durationSeconds: 10, momentIds: [],
                                          relativeFilePath: "x.mp4", versionId: UUID(),
                                          operationType: "original", editPlanJSON: nil)
        ctx.insert(legacy)
        guard case .object(let o) = RevisionContextBuilder.revise(base: legacy, directives: ResolvedDirectives(),
                                                                  softDirection: "more cinematic") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(o["soft_direction"], .string("more cinematic"))
        XCTAssertNil(o["base_plan"])   // omitted, never fabricated
    }

    // MARK: - Source-Moment vs generated-segment distinction (Phase F)

    func test_segment_occurrence_phrasing_is_not_a_moment_reference() {
        // "Remove the third shot" refers to a generated SEGMENT occurrence, not source Moment 3 — it must NOT
        // parse as a Moment number (so it can never silently become a hard directive on Moment 3).
        let refs = MomentReferenceResolver.parseTyped("remove the third shot")
        XCTAssertTrue(refs.isEmpty)
        // Whereas "remove Moment 3" IS a source-Moment reference.
        let r = MomentReferenceResolver.parseTyped("remove Moment 3")
        XCTAssertEqual(r.first?.slot, .exclude)
        XCTAssertEqual(r.first?.number, 3)
    }

    // MARK: - Existing creation without references unchanged

    func test_no_references_produces_no_directives_json() {
        let s = story()
        // No chips, instruction with no "Moment N" phrasing.
        let n = StoryMomentNumbering(ordered: [])
        let res = MomentReferenceResolver.resolve(
            typed: MomentReferenceResolver.parseTyped("make it upbeat and cinematic"), in: n)
        s.creativeDirectivesJSON = res.directives.toWireJSON()
        XCTAssertNil(s.creativeDirectivesJSON)
        XCTAssertNil(StoryCreationCoordinator.composeRevisionContext(base: nil, story: s))
    }

    // MARK: - duration_target_source provenance (P0 revision precedence, owner 2026-10-18)

    private func durSrc(_ ctxVal: JSONValue?) -> String? {
        guard case .object(let o)? = ctxVal, case .string(let v)? = o["duration_target_source"] else { return nil }
        return v
    }

    func test_compose_custom_mode_marks_user_exact() {
        let s = story()
        s.editorialMode = "custom"
        let base: JSONValue = .object(["mode": .string("revise"),
                                       "base_plan": .object(["schema_version": .string("edit_plan/2")]),
                                       "soft_direction": .string("shorten each clip to ~5s")])
        XCTAssertEqual(durSrc(StoryCreationCoordinator.composeRevisionContext(base: base, story: s)), "user_exact")
    }

    func test_compose_highlights_mode_marks_ai_recommended() {
        let s = story()
        s.editorialMode = "highlights"
        let base: JSONValue = .object(["mode": .string("revise"),
                                       "base_plan": .object(["schema_version": .string("edit_plan/2")]),
                                       "soft_direction": .string("shorten each clip to ~5s")])
        XCTAssertEqual(durSrc(StoryCreationCoordinator.composeRevisionContext(base: base, story: s)), "ai_recommended")
    }

    func test_compose_full_mode_marks_ai_recommended() {
        let s = story()
        s.editorialMode = "full"
        let base: JSONValue = .object(["mode": .string("revise"),
                                       "base_plan": .object(["x": .string("y")])])
        XCTAssertEqual(durSrc(StoryCreationCoordinator.composeRevisionContext(base: base, story: s)), "ai_recommended")
    }

    func test_compose_no_editorial_mode_omits_source() {
        let s = story()
        s.editorialMode = nil
        let base: JSONValue = .object(["mode": .string("revise"),
                                       "base_plan": .object(["x": .string("y")])])
        XCTAssertNil(durSrc(StoryCreationCoordinator.composeRevisionContext(base: base, story: s)))
    }

    func test_compose_does_not_clobber_base_duration_source() {
        // A revise that already carries an explicit source (e.g. a newer explicit duration instruction) wins.
        let s = story()
        s.editorialMode = "highlights"   // would otherwise say ai_recommended
        let base: JSONValue = .object(["mode": .string("revise"),
                                       "base_plan": .object(["x": .string("y")]),
                                       "duration_target_source": .string("user_exact")])
        XCTAssertEqual(durSrc(StoryCreationCoordinator.composeRevisionContext(base: base, story: s)), "user_exact")
    }
}
