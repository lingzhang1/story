import Foundation

// P0 — CoverageRecomputeGate: a PROCESS-WIDE coordinator that makes Story Coverage recomputation storm-proof.
// It is a shared singleton (NOT per engine instance), so SwiftUI view recreation — which builds a fresh
// StoryCoverageEngine on every refresh — can no longer reset the in-flight guard and spawn duplicate jobs.
//
// Guarantees per Story:
//   • AT MOST ONE active compute at a time.
//   • A request arriving while one is active records only the LATEST fingerprint as "pending" (at most one
//     pending replacement), coalescing an arbitrary burst into 1 active + 1 trailing.
//   • A SAME-FINGERPRINT request reuses the in-flight task's result (no new Bedrock job).
//   • Debounce folds a burst of AU-triggered triggers into a single trailing compute.
@MainActor
final class CoverageRecomputeGate {
    static let shared = CoverageRecomputeGate()

    private struct InFlight {
        let fingerprint: String
        let task: Task<StoryCoverageV2DTO?, Never>
    }
    private var active: [UUID: InFlight] = [:]
    private var pending: [UUID: (fingerprint: String, work: () async -> StoryCoverageV2DTO?)] = [:]
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private let debounceNanos: UInt64 = 800_000_000   // ~0.8s — fold a burst of AU completions into one compute

    /// Run `work` for `storyId`, coalesced by `fingerprint`:
    ///  - same fingerprint already in flight -> await it (no new job);
    ///  - a different compute in flight -> record THIS as the pending-latest (replacing any older pending) and
    ///    await the current one (the pending runs after, exactly once, at the latest fingerprint);
    ///  - nothing in flight -> start it.
    @discardableResult
    func run(storyId: UUID, fingerprint: String,
             _ work: @escaping () async -> StoryCoverageV2DTO?) async -> StoryCoverageV2DTO? {
        if let inflight = active[storyId] {
            if inflight.fingerprint == fingerprint {
                return await inflight.task.value              // reuse identical in-flight work
            }
            // Different work requested while one runs -> keep only the LATEST as pending (obsolete pending dropped).
            pending[storyId] = (fingerprint, work)
            _ = await inflight.task.value                     // let the current one finish
            // If we are still the latest pending, run it now (exactly one replacement).
            if let p = pending[storyId], p.fingerprint == fingerprint {
                pending[storyId] = nil
                return await run(storyId: storyId, fingerprint: fingerprint, work)
            }
            return nil
        }
        // Nothing in flight -> start.
        let task = Task { await work() }
        active[storyId] = InFlight(fingerprint: fingerprint, task: task)
        let result = await task.value
        active[storyId] = nil
        // Drain a pending-latest that queued while this ran.
        if let p = pending[storyId] {
            pending[storyId] = nil
            return await run(storyId: storyId, fingerprint: p.fingerprint, p.work)
        }
        return result
    }

    /// Debounced trigger: a burst of AU completions / view refreshes for a Story collapses to one trailing call.
    func debounce(storyId: UUID, _ work: @escaping () async -> Void) {
        debounceTasks[storyId]?.cancel()
        debounceTasks[storyId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanos ?? 0)
            if Task.isCancelled { return }
            self?.debounceTasks[storyId] = nil
            await work()
        }
    }
}
