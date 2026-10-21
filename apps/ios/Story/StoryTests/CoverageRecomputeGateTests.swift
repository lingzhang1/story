import XCTest
@testable import Story

// P0 — CoverageRecomputeGate storm test. Reproduces the original scenario (a burst of ~20 rapid recompute
// requests for one Story) and proves the gate coalesces them so Bedrock is called at most once per distinct
// fingerprint, obsolete work is suppressed, and a newer fingerprint runs exactly one replacement.
@MainActor
final class CoverageRecomputeGateTests: XCTestCase {

    func test_20_rapid_same_fingerprint_calls_coalesce_to_one_execution() async {
        let gate = CoverageRecomputeGate()
        var executions = 0
        let work: () async -> StoryCoverageV2DTO? = {
            executions += 1
            try? await Task.sleep(nanoseconds: 50_000_000)   // simulate a slow Bedrock call
            return nil
        }
        // Fire 20 rapid requests for the SAME story + SAME fingerprint concurrently.
        let sid = UUID()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<20 {
                g.addTask { @MainActor in _ = await gate.run(storyId: sid, fingerprint: "fp-1", work) }
            }
        }
        XCTAssertEqual(executions, 1, "20 same-fingerprint requests must coalesce to ONE Bedrock call")
    }

    func test_newer_fingerprint_runs_exactly_one_replacement() async {
        let gate = CoverageRecomputeGate()
        var fps: [String] = []
        let sid = UUID()
        func work(_ fp: String) -> () async -> StoryCoverageV2DTO? {
            { fps.append(fp); try? await Task.sleep(nanoseconds: 30_000_000); return nil }
        }
        // Start fp-1; while it runs, request fp-2 and fp-3 (fp-3 is newest). Expect fp-1 then fp-3 only
        // (fp-2 is superseded as pending and dropped).
        async let a: StoryCoverageV2DTO? = gate.run(storyId: sid, fingerprint: "fp-1", work("fp-1"))
        try? await Task.sleep(nanoseconds: 5_000_000)
        async let b: StoryCoverageV2DTO? = gate.run(storyId: sid, fingerprint: "fp-2", work("fp-2"))
        try? await Task.sleep(nanoseconds: 2_000_000)
        async let c: StoryCoverageV2DTO? = gate.run(storyId: sid, fingerprint: "fp-3", work("fp-3"))
        _ = await (a, b, c)
        // fp-1 ran; fp-3 (latest pending) ran; fp-2 was superseded and never executed.
        XCTAssertTrue(fps.contains("fp-1"))
        XCTAssertTrue(fps.contains("fp-3"))
        XCTAssertFalse(fps.contains("fp-2"), "a superseded pending fingerprint must not execute")
    }

    func test_debounce_collapses_burst_to_one() async {
        let gate = CoverageRecomputeGate()
        var runs = 0
        let sid = UUID()
        for _ in 0..<20 { gate.debounce(storyId: sid) { runs += 1 } }   // 20 rapid triggers
        try? await Task.sleep(nanoseconds: 1_000_000_000)                // > debounce window
        XCTAssertEqual(runs, 1, "a burst of debounced triggers must collapse to one trailing run")
    }
}
