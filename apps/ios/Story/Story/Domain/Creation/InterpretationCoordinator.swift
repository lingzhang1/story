import Foundation

// Phase 1-2 — the ONE shared interpretation entry point used by BOTH Stage 2 Customize and post-generation
// Revise. It runs the deterministic parser first and adopts its result ONLY when the parser demonstrably
// understood the ENTIRE actionable instruction; otherwise it routes to the server interpreter
// (/v1/interpret-revision) via InterpretService. On a server 503/transport failure it falls back to the
// deterministic result so the user is never blocked by a model outage.
//
// Owner Phase 2 rules enforced here:
//  • "at least one regex matched" is NOT the completeness criterion — a PARTIAL parse (e.g. opening recognized
//    but a trailing "Moment 2 immediately after" dropped) routes to the server.
//  • never silently downgrade an unrecognized HARD clause to soft_direction — a residual actionable clause
//    forces the server path, and if the server also cannot resolve it the result carries `unresolved` (the UI
//    must clarify, per Phase 5).
//  • semantic references ("the girl in the green dress") are NOT resolved locally and are NOT in the deferred
//    interpreter yet, so they surface as unresolved -> clarify, never as a silent soft nudge (Phase 6).

struct InterpretationOutcome: Equatable {
    enum Source: Equatable { case deterministic, server, deterministicFallbackAfterServerError }
    /// The user-facing resolution class the UI must branch on (owner safeguard #2: distinguish ambiguous from
    /// service failure from cancellation).
    enum Kind: Equatable {
        case ok                       // canSubmit — safe to launch planning
        case clarify                  // unresolved/ambiguous references — show clarification (thumbnails when numeric)
        case serviceFailure           // 503 / transport with a residual actionable clause — show RETRY
    }
    var directives: ResolvedDirectives
    var softDirection: String
    var unresolved: [String]
    var blocking: [String]
    var canSubmit: Bool
    var source: Source
    var kind: Kind
    /// Moment display numbers the user referenced that could not be resolved — drives the thumbnail
    /// clarification UI (owner #2). Empty when the ambiguity is non-numeric (e.g. a semantic reference).
    var unresolvedMomentNumbers: [Int]
    /// True when the instruction contained an explicit music/soundtrack ask the current interpreter cannot
    /// express as a typed directive (owner #5: report honestly, never silently discard).
    var unsupportedMusicNote: String?
}

enum InterpretationCoordinator {

    /// Interpret `instruction` against a STABLE numbering snapshot. `summaryForId` lets the server match a
    /// Moment by its short summary when numbers alone are ambiguous (the server still refers to Moments by
    /// NUMBER; summaries only help it pick the right number).
    static func interpret(_ instruction: String,
                          numbering: StoryMomentNumbering,
                          service: Interpreting = InterpretService(),
                          summaryForId: @escaping (UUID) -> String? = { _ in nil }) async -> InterpretationOutcome {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return InterpretationOutcome(directives: ResolvedDirectives(), softDirection: "",
                                         unresolved: [], blocking: [], canSubmit: true,
                                         source: .deterministic, kind: .ok,
                                         unresolvedMomentNumbers: [], unsupportedMusicNote: nil)
        }

        // 1. Deterministic parse (fast, free, no model).
        let typed = MomentReferenceResolver.parseTyped(trimmed)
        let ordering = MomentReferenceResolver.parseOrdering(trimmed)
        let implicit = MomentReferenceResolver.parseImplicitFollow(trimmed)
        let det = MomentReferenceResolver.resolve(typed: typed, chips: [], ordering: ordering,
                                                  implicitFollow: implicit, in: numbering)
        let musicNote = unsupportedMusicNote(trimmed)   // owner #5: never silently discard music asks

        // 2. Completeness gate — adopt deterministic ONLY if it consumed the whole ACTIONABLE instruction.
        if deterministicIsComplete(trimmed, typed: typed, ordering: ordering, implicit: implicit) {
            // A local out-of-range reference ("Moment 99") is a hard clarify, not a server call.
            if det.needsClarification {
                return InterpretationOutcome(
                    directives: det.directives, softDirection: trimmed,
                    unresolved: det.unresolved.map(humanReadable), blocking: [],
                    canSubmit: false, source: .deterministic, kind: .clarify,
                    unresolvedMomentNumbers: unresolvedNumbers(det.unresolved),
                    unsupportedMusicNote: musicNote)
            }
            return InterpretationOutcome(
                directives: det.directives, softDirection: trimmed,
                unresolved: [], blocking: [], canSubmit: true,
                source: .deterministic, kind: .ok,
                unresolvedMomentNumbers: [], unsupportedMusicNote: musicNote)
        }

        // 3. Incomplete / compound / uncertain -> server interpreter.
        do {
            let s = try await service.interpret(trimmed, numbering: numbering, summaryForId: summaryForId)
            let kind: InterpretationOutcome.Kind = s.canSubmit ? .ok : .clarify
            // Numeric unresolved references drive thumbnail clarify; non-numeric (semantic) stay text-only.
            let nums = unresolvedNumbers(s.unresolved)
            return InterpretationOutcome(directives: s.directives, softDirection: s.softDirection,
                                         unresolved: s.unresolved, blocking: s.blocking,
                                         canSubmit: s.canSubmit, source: .server, kind: kind,
                                         unresolvedMomentNumbers: nums, unsupportedMusicNote: musicNote)
        } catch let e as InterpretServiceError {
            // Distinguish SERVICE FAILURE (retry) from genuine ambiguity. A residual actionable clause we
            // could not interpret because the service was down is a RETRY case, not a clarify — never ship a
            // partial directive set as if it were understood (owner #2/#3).
            let residual = residualActionableClause(trimmed, typed: typed, ordering: ordering, implicit: implicit)
            if residual {
                _ = e   // 503 vs transport both surface as serviceFailure (retry); detail kept for logging only
                return InterpretationOutcome(
                    directives: det.directives, softDirection: trimmed,
                    unresolved: det.unresolved.map(humanReadable),
                    blocking: ["Couldn't reach the interpreter — tap Retry."],
                    canSubmit: false, source: .deterministicFallbackAfterServerError,
                    kind: .serviceFailure,
                    unresolvedMomentNumbers: unresolvedNumbers(det.unresolved),
                    unsupportedMusicNote: musicNote)
            }
            // No residual actionable clause: the deterministic result safely covers the whole instruction, so
            // fall back to it cleanly (owner #2: deterministic fallback only when the whole instruction is
            // safely understood).
            return InterpretationOutcome(
                directives: det.directives, softDirection: trimmed,
                unresolved: det.unresolved.map(humanReadable), blocking: [],
                canSubmit: !det.needsClarification,
                source: .deterministicFallbackAfterServerError,
                kind: det.needsClarification ? .clarify : .ok,
                unresolvedMomentNumbers: unresolvedNumbers(det.unresolved),
                unsupportedMusicNote: musicNote)
        } catch {
            return InterpretationOutcome(
                directives: det.directives, softDirection: trimmed,
                unresolved: det.unresolved.map(humanReadable),
                blocking: ["Couldn't reach the interpreter — tap Retry."],
                canSubmit: false, source: .deterministicFallbackAfterServerError,
                kind: .serviceFailure,
                unresolvedMomentNumbers: unresolvedNumbers(det.unresolved),
                unsupportedMusicNote: musicNote)
        }
    }

    /// Unresolved display numbers for thumbnail clarify — parse "Moment N" out of the human-readable strings.
    static func unresolvedNumbers(_ unresolved: [String]) -> [Int] {
        var out: [Int] = []
        let re = try? NSRegularExpression(pattern: #"moment\s+#?(\d+)"#, options: [.caseInsensitive])
        for s in unresolved {
            let ns = s as NSString
            re?.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m, m.numberOfRanges > 1, let n = Int(ns.substring(with: m.range(at: 1))) { out.append(n) }
            }
        }
        return Array(Set(out)).sorted()
    }

    static func unresolvedNumbers(_ unresolved: [UnresolvedReference]) -> [Int] {
        unresolved.compactMap { if case .numberOutOfRange(let n) = $0.reason { return n } else { return nil } }
    }

    /// Detect an EXPLICIT music/soundtrack ask so the UI can tell the user it isn't a typed directive yet
    /// (deferred contract), instead of silently dropping it. Returns a short note or nil.
    static func unsupportedMusicNote(_ text: String) -> String? {
        let lower = text.lowercased()
        let musicWords = ["soundtrack", "song", " track", "music", "tune", "score", "jazzy", "jazz",
                          "acoustic", "upbeat", "beat drop", "lo-fi", "lofi", "orchestral"]
        guard musicWords.contains(where: { lower.contains($0) }) else { return nil }
        return "Music preferences aren't applied as a directive yet — this part is passed as a general note only."
    }

    // MARK: - Completeness

    /// True when the deterministic parse understood the WHOLE actionable instruction, so no server call is
    /// needed. Conservative by design (owner Phase 2 MVP): we only keep the local result for simple, fully
    /// consumed commands; anything with a residual actionable clause returns false -> server.
    static func deterministicIsComplete(_ text: String,
                                        typed: [ParsedReference],
                                        ordering: [(after: Int, before: Int, adjacent: Bool)],
                                        implicit: [Int]) -> Bool {
        // Nothing hard parsed at all: this is either pure soft direction (fine to keep local) OR an
        // unrecognized hard instruction. Distinguish by whether an actionable token remains unclaimed.
        return !residualActionableClause(text, typed: typed, ordering: ordering, implicit: implicit)
    }

    /// Does the instruction still contain an ACTIONABLE clause the deterministic parse did NOT claim?
    /// Actionable = a "Moment N" reference, or an ordering/position keyword, not accounted for by a parsed
    /// directive. This is what makes "opening recognized but adjacency dropped" (#7) route to the server, and
    /// what keeps a bare "make it more cinematic" (pure soft, no actionable token) local.
    static func residualActionableClause(_ text: String,
                                         typed: [ParsedReference],
                                         ordering: [(after: Int, before: Int, adjacent: Bool)],
                                         implicit: [Int]) -> Bool {
        let lower = text.lowercased()

        // All distinct Moment numbers mentioned anywhere in the text.
        let mentioned = momentNumbers(in: lower)
        // Numbers the deterministic parse actually claimed (typed slots + ordering pairs + implicit follows).
        var claimed = Set<Int>()
        for r in typed { claimed.insert(r.number) }
        for o in ordering { claimed.insert(o.after); claimed.insert(o.before) }
        for n in implicit { claimed.insert(n) }
        // A mentioned Moment number that was NOT claimed is a dropped hard reference -> actionable residual.
        if !mentioned.subtracting(claimed).isEmpty { return true }

        // Ordering / adjacency keywords present but NO ordering/implicit pair parsed => a relative-order
        // requirement was dropped (e.g. "immediately after" with an implicit antecedent). Actionable residual.
        let orderingWords = ["immediately after", "right after", "directly after", "then", "follows", "follow",
                             "comes next", "after moment", "before moment"]
        let hasOrderingWord = orderingWords.contains { lower.contains($0) }
        if hasOrderingWord && ordering.isEmpty && implicit.isEmpty { return true }

        // Position keywords (open/start/end/exclude/include) present but produced NO typed directive => the
        // phrasing wasn't recognized (e.g. "kick off with", "should open the video") -> route to server.
        let positionWords = ["open", "start", "begin", "end", "finish", "close", "first", "last",
                             "exclude", "include", "remove", "drop", "skip", "without", "lead off", "kick off"]
        let hasPositionWord = positionWords.contains { lower.contains($0) }
        if hasPositionWord && typed.isEmpty { return true }

        return false
    }

    /// Extract distinct "moment N" numbers from text (handles "moment 5", "moment #5", "moment5").
    static func momentNumbers(in lower: String) -> Set<Int> {
        var out = Set<Int>()
        if let re = try? NSRegularExpression(pattern: #"moment\s*#?(\d+)"#, options: [.caseInsensitive]) {
            let ns = lower as NSString
            for m in re.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
                if m.numberOfRanges > 1, let n = Int(ns.substring(with: m.range(at: 1))) { out.insert(n) }
            }
        }
        return out
    }

    static func humanReadable(_ u: UnresolvedReference) -> String {
        switch u.reason {
        case .numberOutOfRange(let n): return "Moment \(n) doesn't exist in this Story."
        case .momentUnavailable: return "A referenced Moment is no longer in this Story."
        }
    }
}
