import XCTest
@testable import Story

// Unified NL interpretation — pipeline tests. Verifies INTERPRETATION correctness (routing + resolution +
// error semantics) separately from EditPlan satisfaction (owner Phase 5-A/B split): a successful interpretation
// is asserted here; whether the resulting plan honors it is the backend validator's job and is covered by the
// device acceptance pass, not this suite.
final class InterpretationPipelineTests: XCTestCase {

    private func numbering(_ n: Int) -> (StoryMomentNumbering, [UUID]) {
        let ids = (0..<n).map { _ in UUID() }
        let items = ids.enumerated().map {
            NumberedMoment(number: $0.offset + 1, id: $0.element, durationSeconds: 5.0, relativePath: "m\($0.offset).mov")
        }
        return (StoryMomentNumbering(ordered: items), ids)
    }

    // A stub interpreter: records whether it was called, and returns a scripted result or throws.
    final class StubInterpreter: Interpreting {
        var called = false
        var result: InterpretedInstruction?
        var error: Error?
        init(result: InterpretedInstruction? = nil, error: Error? = nil) { self.result = result; self.error = error }
        func interpret(_ instruction: String, numbering: StoryMomentNumbering,
                       summaryForId: (UUID) -> String?) async throws -> InterpretedInstruction {
            called = true
            if let error { throw error }
            return result ?? InterpretedInstruction(directives: ResolvedDirectives(), softDirection: instruction,
                                                    unresolved: [], blocking: [], canSubmit: true)
        }
    }

    // MARK: - Routing: simple whole-instruction commands stay LOCAL (no server call)

    func test_simple_commands_stay_local() async {
        let (num, ids) = numbering(12)
        for text in ["Start with Moment 5.", "Start from Moment 5.", "Use Moment 5 to start.",
                     "Remove Moment 8.", "Include Moment 12.", "Make the video more cinematic."] {
            let stub = StubInterpreter()
            let o = await InterpretationCoordinator.interpret(text, numbering: num, service: stub)
            XCTAssertFalse(stub.called, "‘\(text)’ should be handled locally, not sent to the server")
            XCTAssertEqual(o.source, .deterministic)
        }
        // Spot-check resolution: "Start with Moment 5" -> opening == ids[4].
        let o = await InterpretationCoordinator.interpret("Start with Moment 5.", numbering: num, service: StubInterpreter())
        XCTAssertEqual(o.directives.opening, ids[4])
        XCTAssertTrue(o.canSubmit)
    }

    // MARK: - Routing: compound/partial/unrecognized go to the SERVER

    func test_partial_and_unrecognized_route_to_server() async {
        let (num, _) = numbering(12)
        for text in ["Kick off with Moment 5.",                       // unrecognized opening verb
                     "Moment 5 should open the video.",               // unrecognized phrasing
                     "Use Moment 5 first and Moment 2 immediately after.",  // PARTIAL: adjacency dropped locally
                     "Use the girl in the green dress as the opening."] {   // semantic ref
            let stub = StubInterpreter(result: InterpretedInstruction(
                directives: ResolvedDirectives(), softDirection: text, unresolved: [], blocking: [], canSubmit: true))
            let o = await InterpretationCoordinator.interpret(text, numbering: num, service: stub)
            XCTAssertTrue(stub.called, "‘\(text)’ must route to the server (partial/unrecognized)")
            XCTAssertEqual(o.source, .server)
        }
    }

    // The #7 partial case is the key regression: opening recognized but adjacency NOT -> must not stay local.
    func test_partial_adjacency_is_not_treated_as_complete() {
        let typed = MomentReferenceResolver.parseTyped("Use Moment 5 first and Moment 2 immediately after.")
        let ordering = MomentReferenceResolver.parseOrdering("Use Moment 5 first and Moment 2 immediately after.")
        let implicit = MomentReferenceResolver.parseImplicitFollow("Use Moment 5 first and Moment 2 immediately after.")
        XCTAssertFalse(InterpretationCoordinator.deterministicIsComplete(
            "Use Moment 5 first and Moment 2 immediately after.",
            typed: typed, ordering: ordering, implicit: implicit))
    }

    // MARK: - Error semantics

    func test_server_503_with_residual_is_serviceFailure_retry() async {
        let (num, _) = numbering(12)
        // "Kick off with Moment 5" has a residual actionable clause locally; 503 -> serviceFailure (retry).
        let stub = StubInterpreter(error: InterpretServiceError.unavailable)
        let o = await InterpretationCoordinator.interpret("Kick off with Moment 5.", numbering: num, service: stub)
        XCTAssertEqual(o.kind, .serviceFailure)
        XCTAssertFalse(o.canSubmit)
        XCTAssertEqual(o.source, .deterministicFallbackAfterServerError)
    }

    func test_server_unknown_moment_is_clarify_not_submit() async {
        let (num, _) = numbering(8)
        let stub = StubInterpreter(result: InterpretedInstruction(
            directives: ResolvedDirectives(), softDirection: "", unresolved: ["Moment 99 is not in this Story"],
            blocking: [], canSubmit: false))
        let o = await InterpretationCoordinator.interpret("Kick off with Moment 99.", numbering: num, service: stub)
        XCTAssertEqual(o.kind, .clarify)
        XCTAssertFalse(o.canSubmit)
        XCTAssertEqual(o.unresolvedMomentNumbers, [99])   // drives thumbnail clarify
    }

    func test_local_out_of_range_is_clarify_without_server() async {
        let (num, _) = numbering(8)
        let stub = StubInterpreter()
        let o = await InterpretationCoordinator.interpret("Start with Moment 99.", numbering: num, service: stub)
        XCTAssertFalse(stub.called)             // simple shape -> resolved locally, found out-of-range
        XCTAssertEqual(o.kind, .clarify)
        XCTAssertFalse(o.canSubmit)
    }

    // MARK: - Music honesty (#5)

    func test_music_ask_surfaces_note_not_silent() async {
        let (num, _) = numbering(5)
        let o = await InterpretationCoordinator.interpret("Make it more cinematic with a jazzy soundtrack",
                                                          numbering: num, service: StubInterpreter())
        XCTAssertNotNil(o.unsupportedMusicNote)
    }

    // MARK: - Server decode (number->UUID already resolved server-side; client filters to snapshot)

    func test_decode_filters_ids_to_snapshot() {
        let (num, ids) = numbering(3)
        let obj: [String: Any] = [
            "directives": ["opening": ids[0].uuidString,
                           "must_include": [ids[1].uuidString, UUID().uuidString /* stray, filtered */]],
            "soft_direction": "cinematic", "unresolved": [], "blocking": [], "can_submit": true]
        let decoded = InterpretService.decode(obj, numbering: num)
        XCTAssertEqual(decoded.directives.opening, ids[0])
        XCTAssertEqual(decoded.directives.mustInclude, [ids[1]])   // stray id dropped
        XCTAssertEqual(decoded.softDirection, "cinematic")
        XCTAssertTrue(decoded.canSubmit)
    }

    func test_decode_blocking_blocks_submit() {
        let (num, ids) = numbering(2)
        let obj: [String: Any] = [
            "directives": ["opening": ids[0].uuidString],
            "soft_direction": "", "unresolved": [],
            "blocking": ["Moment is both required and excluded"], "can_submit": false]
        let decoded = InterpretService.decode(obj, numbering: num)
        XCTAssertFalse(decoded.canSubmit)
        XCTAssertEqual(decoded.blocking.count, 1)
    }

    // MARK: - Phase 1 — redundant soft_direction suppression (deterministic revision routing)

    /// A PURE-STRUCTURAL instruction yields EMPTY soft_direction, so the engine's deterministic revision path
    /// runs (preserving every base clip) instead of a model re-plan that drops clips. (The 2-clips-dropped bug.)
    func test_pureStructural_hasEmptySoftDirection() async {
        let (num, _) = numbering(14)
        let stub = StubInterpreter()
        let o = await InterpretationCoordinator.interpret(
            "Start with Moment 1, then Moment 6, and end with Moment 2", numbering: num, service: stub)
        XCTAssertFalse(stub.called, "fully structural -> handled locally")
        XCTAssertEqual(o.kind, .ok)
        XCTAssertEqual(o.softDirection, "", "pure-structural revise must carry NO soft_direction")
        XCTAssertNotNil(o.directives.opening)
        XCTAssertNotNil(o.directives.ending)
        XCTAssertFalse(o.directives.orderAdjacent.isEmpty)
    }

    /// A STRUCTURAL + CREATIVE instruction keeps the creative residual as soft_direction (never silently lost),
    /// so the model path still receives it.
    func test_structuralPlusCreative_keepsResidual() async {
        let (num, _) = numbering(14)
        // Has a residual actionable+creative clause -> routed to server; stub echoes a residual soft_direction.
        let stub = StubInterpreter(result: InterpretedInstruction(
            directives: ResolvedDirectives(),
            softDirection: "make it more cinematic", unresolved: [], blocking: [], canSubmit: true))
        let o = await InterpretationCoordinator.interpret(
            "Start with Moment 1, make it more cinematic and add a glow", numbering: num, service: stub)
        XCTAssertFalse(o.softDirection.isEmpty, "creative residual must be preserved, never dropped")
    }

    // MARK: - residualSoftDirection pure helper

    func test_residual_pureStructural_empty() {
        let text = "Start with Moment 1, then Moment 6, and end with Moment 2"
        let typed = MomentReferenceResolver.parseTyped(text)
        let ordering = MomentReferenceResolver.parseOrdering(text)
        let implicit = MomentReferenceResolver.parseImplicitFollow(text)
        XCTAssertEqual(InterpretationCoordinator.residualSoftDirection(
            text, typed: typed, ordering: ordering, implicit: implicit), "")
    }

    func test_residual_structuralPlusCreative_keepsCreative() {
        let text = "Start with Moment 1, then Moment 6, end with Moment 2, make it more cinematic"
        let typed = MomentReferenceResolver.parseTyped(text)
        let ordering = MomentReferenceResolver.parseOrdering(text)
        let implicit = MomentReferenceResolver.parseImplicitFollow(text)
        let r = InterpretationCoordinator.residualSoftDirection(
            text, typed: typed, ordering: ordering, implicit: implicit).lowercased()
        XCTAssertTrue(r.contains("cinematic"), "creative residual retained; got '\(r)'")
    }

    func test_residual_excludeOnly_empty() {
        let text = "exclude Moment 4"
        let typed = MomentReferenceResolver.parseTyped(text)
        let ordering = MomentReferenceResolver.parseOrdering(text)
        let implicit = MomentReferenceResolver.parseImplicitFollow(text)
        XCTAssertEqual(InterpretationCoordinator.residualSoftDirection(
            text, typed: typed, ordering: ordering, implicit: implicit), "")
    }
}
