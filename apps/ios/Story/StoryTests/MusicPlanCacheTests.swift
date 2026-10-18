import XCTest
import SwiftData
@testable import Story

// MusicPlan cache (latency P0). Verifies the fingerprint is deterministic and sensitive to every
// output-affecting input, and that the SwiftData cache round-trips + misses on a changed fingerprint.
@MainActor
final class MusicPlanCacheTests: XCTestCase {

    private func inputs() -> (JSONValue, JSONValue, JSONValue, JSONValue, String, Double) {
        (.object(["theme": .string("travel")]),          // intent
         .object(["mood": .array([.string("calm")])]),   // direction
         .object(["dimensions": .array([.string("a")])]),// guide
         .object(["sufficiency": .string("sufficient")]),// coverage
         "balanced",                                      // sound preference
         90.0)                                            // target
    }

    func test_fingerprint_is_deterministic() {
        let (i, d, g, c, s, t) = inputs()
        let a = MusicSelectionResolver.musicPlanFingerprint(intent: i, direction: d, guide: g, coverage: c, soundPreference: s, target: t)
        let b = MusicSelectionResolver.musicPlanFingerprint(intent: i, direction: d, guide: g, coverage: c, soundPreference: s, target: t)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)   // SHA256 hex
    }

    func test_fingerprint_changes_with_each_input() {
        let (i, d, g, c, s, t) = inputs()
        let base = MusicSelectionResolver.musicPlanFingerprint(intent: i, direction: d, guide: g, coverage: c, soundPreference: s, target: t)
        XCTAssertNotEqual(base, MusicSelectionResolver.musicPlanFingerprint(intent: .object(["theme": .string("food")]), direction: d, guide: g, coverage: c, soundPreference: s, target: t))
        XCTAssertNotEqual(base, MusicSelectionResolver.musicPlanFingerprint(intent: i, direction: .object(["mood": .array([.string("upbeat")])]), guide: g, coverage: c, soundPreference: s, target: t))
        XCTAssertNotEqual(base, MusicSelectionResolver.musicPlanFingerprint(intent: i, direction: d, guide: .object(["dimensions": .array([.string("b")])]), coverage: c, soundPreference: s, target: t))
        XCTAssertNotEqual(base, MusicSelectionResolver.musicPlanFingerprint(intent: i, direction: d, guide: g, coverage: .object(["sufficiency": .string("insufficient")]), soundPreference: s, target: t))
        XCTAssertNotEqual(base, MusicSelectionResolver.musicPlanFingerprint(intent: i, direction: d, guide: g, coverage: c, soundPreference: "energetic", target: t))
        XCTAssertNotEqual(base, MusicSelectionResolver.musicPlanFingerprint(intent: i, direction: d, guide: g, coverage: c, soundPreference: s, target: 60.0))
        XCTAssertNotEqual(base, MusicSelectionResolver.musicPlanFingerprint(intent: i, direction: d, guide: g, coverage: c, soundPreference: s, target: t, promptVersion: "music_plan/2"))
    }

    func test_fingerprint_ignores_volatile_provenance() {
        // Regression: the same semantic content with a DIFFERENT generated_at/updated_at/id must hash the
        // same — otherwise a reopen with unchanged inputs misses the cache every time (observed in the field:
        // two reopens -> two fingerprints -> two ~14s music_plan calls).
        let a = MusicSelectionResolver.musicPlanFingerprint(
            intent: .object(["theme": .string("travel"), "generated_at": .string("2026-10-17T22:00:00Z")]),
            direction: .object(["mood": .string("calm"), "updated_at": .string("2026-10-17T22:00:00Z")]),
            guide: .object(["dimensions": .array([.string("a")]), "id": .string("g1")]),
            coverage: .object(["sufficiency": .string("sufficient"), "model_id": .string("m1")]),
            soundPreference: "balanced", target: 90)
        let b = MusicSelectionResolver.musicPlanFingerprint(
            intent: .object(["theme": .string("travel"), "generated_at": .string("2026-10-17T23:30:00Z")]),
            direction: .object(["mood": .string("calm"), "updated_at": .string("2026-10-18T01:00:00Z")]),
            guide: .object(["dimensions": .array([.string("a")]), "id": .string("g2")]),
            coverage: .object(["sufficiency": .string("sufficient"), "model_id": .string("m2")]),
            soundPreference: "balanced", target: 90)
        XCTAssertEqual(a, b, "fingerprint must ignore generated_at/updated_at/id/model_id")
    }

    func test_fingerprint_key_order_independent() {
        // Sorted-keys canonicalization: the same object written in a different key order hashes identically.
        let a = MusicSelectionResolver.musicPlanFingerprint(
            intent: .object(["a": .string("1"), "b": .string("2")]),
            direction: .object([:]), guide: .object([:]), coverage: .object([:]), soundPreference: "x", target: 30)
        let b = MusicSelectionResolver.musicPlanFingerprint(
            intent: .object(["b": .string("2"), "a": .string("1")]),
            direction: .object([:]), guide: .object([:]), coverage: .object([:]), soundPreference: "x", target: 30)
        XCTAssertEqual(a, b)
    }

    func test_cache_roundtrip_hit_and_miss() throws {
        let schema = Schema([MusicPlanCacheModel.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let sid = UUID()
        let plan: JSONValue = .object(["character": .object(["energy": .string("low")])])

        XCTAssertNil(MusicSelectionResolver.cachedMusicPlan(storyId: sid, fingerprint: "fp1", context: ctx))
        MusicSelectionResolver.storeMusicPlan(storyId: sid, fingerprint: "fp1", plan: plan, context: ctx)
        // Hit on the same fingerprint.
        XCTAssertEqual(MusicSelectionResolver.cachedMusicPlan(storyId: sid, fingerprint: "fp1", context: ctx), plan)
        // Miss on a changed fingerprint (input changed) — must NOT return the stale plan.
        XCTAssertNil(MusicSelectionResolver.cachedMusicPlan(storyId: sid, fingerprint: "fp2", context: ctx))
        // Upsert: storing a new fingerprint replaces the row (one row per Story).
        let plan2: JSONValue = .object(["character": .object(["energy": .string("high")])])
        MusicSelectionResolver.storeMusicPlan(storyId: sid, fingerprint: "fp2", plan: plan2, context: ctx)
        XCTAssertEqual(MusicSelectionResolver.cachedMusicPlan(storyId: sid, fingerprint: "fp2", context: ctx), plan2)
        XCTAssertNil(MusicSelectionResolver.cachedMusicPlan(storyId: sid, fingerprint: "fp1", context: ctx))
    }
}
