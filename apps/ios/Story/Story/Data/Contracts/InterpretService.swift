import Foundation

// Phase 1-3 — the SINGLE iOS client for the server NL interpreter (POST /v1/interpret-revision).
// Shared by BOTH Stage 2 Customize Your Story and post-generation Revise (owner rule: one interpretation
// entry point, no second interpreter, no duplicated Moment-reference resolution). This client is the LLM
// fallback half of the hybrid pipeline; the deterministic half stays in MomentReferenceResolver. The server
// maps display Moment numbers -> stable UUIDs (the model never sees or mints a UUID), runs preflight
// contradiction/unknown/unresolved validation, and returns can_submit. See InterpretationCoordinator for the
// deterministic-first routing that decides WHEN to call this.

/// The server's interpreted result, already resolved to stable Moment UUIDs.
/// `unresolved` + `blocking` are human-readable strings straight from the server; `canSubmit` gates the
/// expensive Edit Planning job (owner Phase 3: never launch planning when can_submit=false).
struct InterpretedInstruction: Equatable {
    var directives: ResolvedDirectives          // resolved hard directives (stable UUIDs)
    var softDirection: String                   // free-text creative/pacing prefs (edit-planner only)
    var unresolved: [String]                    // clauses the interpreter could not map (clarify)
    var blocking: [String]                      // preflight contradiction / unknown-reference reasons
    var canSubmit: Bool                         // server verdict: safe to launch Edit Planning
}

enum InterpretServiceError: Error {
    /// Model/provider unavailable (HTTP 503) — the caller falls back to its deterministic parse.
    case unavailable
    /// Transport / decoding failure — also a fall-back-to-deterministic signal.
    case transport
}

/// Seam for testing: the coordinator depends on this, so a stub can simulate server results/503 without a
/// network. InterpretService is the production conformer.
protocol Interpreting {
    func interpret(_ instruction: String,
                   numbering: StoryMomentNumbering,
                   summaryForId: (UUID) -> String?) async throws -> InterpretedInstruction
}

final class InterpretService: Interpreting {
    private let baseURL: URL
    private let session: URLSession
    init(baseURL: URL = StoryBackend.baseURL, session: URLSession = StoryBackend.longSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Interpret a free-form instruction against a STABLE numbering snapshot. The snapshot is the single source
    /// of truth for number<->UUID (owner #1): we send {number, id, summary?} so the server can resolve numbers
    /// to the SAME ids the client persists, and we decode the returned ids back through that snapshot's space.
    /// Throws InterpretServiceError on 503/transport so the caller can fall back to the deterministic parse.
    func interpret(_ instruction: String,
                   numbering: StoryMomentNumbering,
                   summaryForId: (UUID) -> String? = { _ in nil }) async throws -> InterpretedInstruction {
        let moments: [[String: Any]] = numbering.items.map { m in
            var d: [String: Any] = ["number": m.number, "id": m.id.uuidString]
            if let s = summaryForId(m.id), !s.isEmpty { d["summary"] = s }
            return d
        }
        let bodyObj: [String: Any] = ["instruction": instruction, "moments": moments]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyObj) else {
            throw InterpretServiceError.transport
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/interpret-revision"))
        StoryBackend.authorize(&req)  // P0 auth seam: bearer token when signed in
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw InterpretServiceError.transport }
        guard let http = resp as? HTTPURLResponse else { throw InterpretServiceError.transport }
        // 503 is the server's designed "retry / fall back to deterministic" signal.
        if http.statusCode == 503 { throw InterpretServiceError.unavailable }
        guard (200..<300).contains(http.statusCode) else { throw InterpretServiceError.transport }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InterpretServiceError.transport
        }
        return Self.decode(obj, numbering: numbering)
    }

    /// Decode the server response. The server already resolved numbers -> stable ids, so `directives` is the
    /// same wire shape persisted directives use — we reuse ResolvedDirectives decoding and KEEP only ids that
    /// are still in the snapshot (defensive: a snapshot drift becomes an unresolved clause, never a dangling id).
    static func decode(_ obj: [String: Any], numbering: StoryMomentNumbering) -> InterpretedInstruction {
        func ids(_ v: Any?) -> [UUID] {
            ((v as? [String]) ?? []).compactMap { UUID(uuidString: $0) }.filter { numbering.contains(id: $0) }
        }
        func pairs(_ v: Any?) -> [[UUID]] {
            ((v as? [[String]]) ?? []).compactMap { p in
                let us = p.compactMap { UUID(uuidString: $0) }.filter { numbering.contains(id: $0) }
                return us.count == 2 ? us : nil
            }
        }
        let dir = (obj["directives"] as? [String: Any]) ?? [:]
        var d = ResolvedDirectives()
        d.mustInclude = ids(dir["must_include"])
        d.exclude = ids(dir["exclude"])
        d.opening = (dir["opening"] as? String).flatMap { UUID(uuidString: $0) }.flatMap { numbering.contains(id: $0) ? $0 : nil }
        d.ending = (dir["ending"] as? String).flatMap { UUID(uuidString: $0) }.flatMap { numbering.contains(id: $0) ? $0 : nil }
        d.orderAfter = pairs(dir["order_after"])
        d.orderAdjacent = pairs(dir["order_adjacent"])

        let soft = (obj["soft_direction"] as? String) ?? ""
        let unresolved = (obj["unresolved"] as? [String]) ?? []
        let blocking = (obj["blocking"] as? [String]) ?? []
        // Trust the server's can_submit, but harden it: if a directive id dropped out during snapshot-filtering
        // above, treat it as not submittable (the drift is itself an unresolved reference).
        let serverCanSubmit = (obj["can_submit"] as? Bool) ?? (blocking.isEmpty && unresolved.isEmpty)
        return InterpretedInstruction(directives: d, softDirection: soft,
                                      unresolved: unresolved, blocking: blocking,
                                      canSubmit: serverCanSubmit)
    }
}
