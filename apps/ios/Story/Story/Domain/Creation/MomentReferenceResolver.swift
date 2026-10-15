import Foundation

// Explicit Moment References — the SHARED resolution core used by BOTH pre-creation Creative Direction and
// post-generation Natural-Language Revision. Pure value types, no SwiftData / no UI, so it is unit-testable
// and there is exactly ONE parser + numbering + resolver implementation (owner rule: do not duplicate).
//
// RESPONSIBILITY (owner clarification #4): this maps user references -> stable Moment UUIDs. It does NOT judge
// whether the resulting EditPlan satisfies them — the backend `validate_plan` is the authority on satisfaction.
// Resolution success is NOT proof of correct event/source-range resolution (#5): event-level asks are carried
// as soft direction, never asserted as satisfied here.

/// One Story-scoped, display-numbered Moment. `number` is a 1-based display identifier (NOT a UUID, NOT global)
/// derived from the Story's visible ordering; `id` is the stable Moment UUID that is persisted and sent to the
/// planner.
struct NumberedMoment: Equatable {
    let number: Int
    let id: UUID
    let durationSeconds: Double
    /// Relative media path for the thumbnail (resolved to a URL by the UI via MediaStore). Nil-safe.
    let relativePath: String?
}

/// A STABLE snapshot of a Story's Moment numbering, captured when the user opens Creative Direction or Revision.
/// Typed "Moment N" references resolve against THIS snapshot, so a later reorder/add cannot silently change the
/// meaning of an instruction the user already wrote (owner clarification #1). Build once; keep for the session.
struct StoryMomentNumbering: Equatable {
    let items: [NumberedMoment]          // ordered by display number (1..N), gap-free
    private let byNumber: [Int: UUID]
    private let byId: [UUID: Int]

    init(ordered moments: [NumberedMoment]) {
        // Re-stamp numbers 1..N from the given order so the snapshot is always gap-free and 1-based,
        // regardless of how the caller built the list.
        var items: [NumberedMoment] = []
        var byNumber: [Int: UUID] = [:]
        var byId: [UUID: Int] = [:]
        for (i, m) in moments.enumerated() {
            let n = i + 1
            let nm = NumberedMoment(number: n, id: m.id, durationSeconds: m.durationSeconds,
                                    relativePath: m.relativePath)
            items.append(nm); byNumber[n] = m.id; byId[m.id] = n
        }
        self.items = items; self.byNumber = byNumber; self.byId = byId
    }

    var count: Int { items.count }

    /// Resolve a display number to a stable Moment UUID, or nil if out of range.
    func id(forNumber n: Int) -> UUID? { byNumber[n] }

    /// The display number a stable id currently maps to in THIS snapshot (for rendering chips), or nil.
    func number(forId id: UUID) -> Int? { byId[id] }

    func contains(id: UUID) -> Bool { byId[id] != nil }
}

/// A single parsed reference and the directive slot it targets.
enum DirectiveSlot: Equatable { case include, exclude, opening, ending }

struct ParsedReference: Equatable {
    let slot: DirectiveSlot
    let number: Int          // the display number the user typed
    let matchedText: String  // the exact phrase matched (for chip insertion / UI feedback)
}

/// The resolved set of hard directives, keyed by STABLE Moment UUID — this is exactly the shape the backend
/// `revision_context.directives` contract expects (must_include / exclude / opening / ending).
struct ResolvedDirectives: Equatable {
    var mustInclude: [UUID] = []
    var exclude: [UUID] = []
    var opening: UUID? = nil
    var ending: UUID? = nil
    /// [after, before] pairs: `after` appears somewhere after `before`.
    var orderAfter: [[UUID]] = []
    /// [after, before] pairs: `after` appears IMMEDIATELY after `before`.
    var orderAdjacent: [[UUID]] = []

    var isEmpty: Bool {
        mustInclude.isEmpty && exclude.isEmpty && opening == nil && ending == nil
        && orderAfter.isEmpty && orderAdjacent.isEmpty
    }

    /// Encode to the backend wire shape (lowercased uuid strings). Omits empty slots so an absent directive is
    /// simply not present (behavior-unchanged on the backend).
    func wireDictionary() -> [String: Any] {
        var d: [String: Any] = [:]
        if !mustInclude.isEmpty { d["must_include"] = mustInclude.map { $0.uuidString } }
        if !exclude.isEmpty { d["exclude"] = exclude.map { $0.uuidString } }
        if let o = opening { d["opening"] = o.uuidString }
        if let e = ending { d["ending"] = e.uuidString }
        if !orderAfter.isEmpty { d["order_after"] = orderAfter.map { $0.map { $0.uuidString } } }
        if !orderAdjacent.isEmpty { d["order_adjacent"] = orderAdjacent.map { $0.map { $0.uuidString } } }
        return d
    }

    /// Encode as a JSONValue `directives` object (the type the planner request carries). Nil when empty, so an
    /// absent directive set leaves the request byte-identical to today.
    func jsonValue() -> JSONValue? {
        if isEmpty { return nil }
        var o: [String: JSONValue] = [:]
        if !mustInclude.isEmpty { o["must_include"] = .array(mustInclude.map { .string($0.uuidString) }) }
        if !exclude.isEmpty { o["exclude"] = .array(exclude.map { .string($0.uuidString) }) }
        if let op = opening { o["opening"] = .string(op.uuidString) }
        if let en = ending { o["ending"] = .string(en.uuidString) }
        if !orderAfter.isEmpty {
            o["order_after"] = .array(orderAfter.map { .array($0.map { .string($0.uuidString) }) })
        }
        if !orderAdjacent.isEmpty {
            o["order_adjacent"] = .array(orderAdjacent.map { .array($0.map { .string($0.uuidString) }) })
        }
        return .object(o)
    }

    /// Decode persisted directives from the stored wire JSON (StoryModel.creativeDirectivesJSON).
    static func fromWireJSON(_ json: String?) -> ResolvedDirectives? {
        guard let json, let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func ids(_ v: Any?) -> [UUID] { ((v as? [String]) ?? []).compactMap { UUID(uuidString: $0) } }
        func pairs(_ v: Any?) -> [[UUID]] {
            ((v as? [[String]]) ?? []).compactMap { p in
                let us = p.compactMap { UUID(uuidString: $0) }
                return us.count == 2 ? us : nil
            }
        }
        var d = ResolvedDirectives()
        d.mustInclude = ids(obj["must_include"])
        d.exclude = ids(obj["exclude"])
        d.opening = (obj["opening"] as? String).flatMap { UUID(uuidString: $0) }
        d.ending = (obj["ending"] as? String).flatMap { UUID(uuidString: $0) }
        d.orderAfter = pairs(obj["order_after"])
        d.orderAdjacent = pairs(obj["order_adjacent"])
        return d.isEmpty ? nil : d
    }

    /// Serialize to the persisted wire JSON string for StoryModel.creativeDirectivesJSON.
    func toWireJSON() -> String? {
        guard !isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: wireDictionary()) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A reference that could NOT be resolved — the user must clarify (owner: never silently substitute/drop).
struct UnresolvedReference: Equatable {
    enum Reason: Equatable { case numberOutOfRange(Int); case momentUnavailable(UUID) }
    let reason: Reason
    let matchedText: String
}

struct ResolutionResult: Equatable {
    var directives: ResolvedDirectives
    var unresolved: [UnresolvedReference]
    /// True when at least one reference failed to resolve — the UI must request clarification before submit.
    var needsClarification: Bool { !unresolved.isEmpty }
}

enum MomentReferenceResolver {
    /// Parse typed "Moment N" references from free text. Deterministic, order-preserving. Recognizes the four
    /// supported forms (owner #3): include / exclude / start-with (opening) / end-with (ending). Anything not
    /// matching a supported pattern is left for the planner as free text (soft direction) — NOT invented.
    static func parseTyped(_ text: String) -> [ParsedReference] {
        guard !text.isEmpty else { return [] }
        // Verb cues -> slot, HIGHEST priority first (an earlier match claims its char range so a lower
        // pattern cannot re-match the same words — this is what stops "start WITH moment 5" also matching the
        // bare include "with moment 5"). Covers natural phrasings: "start with M5" / "use M5 to start" /
        // "M5 to start" / "open on M5" for opening; "end with M8" / "M8 at the end" / "finish on M8" for
        // ending; include/exclude verbs. Anything unmatched stays free-text soft direction (never invented).
        let patterns: [(DirectiveSlot, String)] = [
            // OPENING — verb-before-number ("start with / open on / begin with moment 5")
            (.opening, #"(?:start|open|begin|lead)(?:ing)?\s+(?:with|on|off\s+with)?\s*moment\s+#?(\d+)"#),
            // OPENING — number-before-cue ("use moment 5 to start", "moment 5 first", "moment 5 to open")
            (.opening, #"moment\s+#?(\d+)\s+(?:to\s+)?(?:start|open|begin|first|lead|up\s+front|at\s+the\s+(?:start|beginning)|as\s+the\s+(?:opening|first))"#),
            // ENDING — verb-before-number ("end with / finish on / close with moment 8")
            (.ending,  #"(?:end|finish|close)(?:ing)?\s+(?:with|on)?\s*moment\s+#?(\d+)"#),
            // ENDING — number-before-cue ("put moment 8 at the end", "moment 8 last", "moment 8 to end")
            (.ending,  #"moment\s+#?(\d+)\s+(?:to\s+)?(?:at\s+the\s+end|last|to\s+end|to\s+finish|as\s+the\s+(?:ending|last|finale))"#),
            (.ending,  #"put\s+moment\s+#?(\d+)\s+(?:at\s+the\s+end|last)"#),
            // EXCLUDE
            (.exclude, #"(?:exclude|do\s*n[o']?t\s+use|don[o']?t\s+use|remove|drop|skip|without|leave\s+out)\s+moment\s+#?(\d+)"#),
            // INCLUDE (lowest priority; NOT a bare "with" — that over-matched "start with")
            (.include, #"(?:include|use|add|keep|feature)\s+moment\s+#?(\d+)"#),
        ]
        let ns = text as NSString
        var claimed = IndexSet()  // character ranges already consumed by a higher-priority pattern
        var withPos: [(pos: Int, ref: ParsedReference)] = []
        for (slot, pat) in patterns {
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let full = m.range(at: 0)
                // Skip if this span overlaps a region already claimed by an earlier (higher-priority) pattern.
                if (full.location..<(full.location + full.length)).contains(where: { claimed.contains($0) }) {
                    continue
                }
                guard m.numberOfRanges > 1, let n = Int(ns.substring(with: m.range(at: 1))) else { continue }
                withPos.append((full.location,
                                ParsedReference(slot: slot, number: n, matchedText: ns.substring(with: full))))
                for i in full.location..<(full.location + full.length) { claimed.insert(i) }
            }
        }
        // Return in order of appearance in the text.
        return withPos.sorted { $0.pos < $1.pos }.map { $0.ref }
    }

    /// Parse ORDERING relations between two typed Moment numbers. Returns (after, before, adjacent) triples:
    /// `after` should come after `before`; `adjacent` means immediately after. Deterministic, bounded to the
    /// clear phrasings — anything looser is left to the structured-AI interpretation step (Phase 2).
    ///   "start with M5 then M2"      -> (2, 5, adjacent)   ("then" = immediately next)
    ///   "M5, M2 follows"             -> (2, 5, adjacent)
    ///   "M2 immediately after M5"    -> (2, 5, adjacent)
    ///   "M2 right after M5"          -> (2, 5, adjacent)
    ///   "M2 after M5" / "M2 somewhere after M5" -> (2, 5, non-adjacent)
    static func parseOrdering(_ text: String) -> [(after: Int, before: Int, adjacent: Bool)] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var out: [(Int, Int, Bool)] = []
        func scan(_ pattern: String, adjacent: Bool, swap: Bool = false) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard m.numberOfRanges > 2,
                      let x = Int(ns.substring(with: m.range(at: 1))),
                      let y = Int(ns.substring(with: m.range(at: 2))) else { continue }
                // swap=false: first number is `after`? depends on pattern; callers set it so (after, before).
                let after = swap ? y : x
                let before = swap ? x : y
                out.append((after, before, adjacent))
            }
        }
        // "moment A immediately/right after moment B"  => A after B, adjacent
        scan(#"moment\s+#?(\d+)\s+(?:immediately|right|directly)\s+(?:after|following)\s+moment\s+#?(\d+)"#, adjacent: true)
        // "moment A after moment B" (plain / somewhere) => A after B, non-adjacent
        scan(#"moment\s+#?(\d+)\s+(?:somewhere\s+)?after\s+moment\s+#?(\d+)"#, adjacent: false)
        // "moment B, then moment A" / "moment B then A"  => A after B, adjacent  (swap: first is `before`)
        scan(#"moment\s+#?(\d+)\s*,?\s+then\s+(?:moment\s+)?#?(\d+)"#, adjacent: true, swap: true)
        // "moment B, moment A follows/next" => A after B, adjacent (swap: first is before)
        scan(#"moment\s+#?(\d+)[,\s]+(?:then\s+)?(?:moment\s+)?#?(\d+)\s+(?:follows?|follow|next|afterwards?|comes\s+next)"#, adjacent: true, swap: true)
        // "moment B ... moment A follow(s)" with an opening/start antecedent: "<start X> and moment A follow"
        // The antecedent is the opening Moment named earlier. Handled by resolveImplicitFollow (below) when a
        // bare "moment A follow(s)" has no explicit before-number — it attaches to the opening directive.
        // de-dupe
        var seen = Set<String>(); var uniq: [(Int, Int, Bool)] = []
        for t in out {
            let k = "\(t.0)-\(t.1)-\(t.2)"
            if !seen.contains(k) { seen.insert(k); uniq.append(t) }
        }
        return uniq
    }

    /// Numbers in a bare "moment A follow(s)/next" clause that has NO explicit "before" number — the user means
    /// A follows whatever was just named (typically the opening). The caller attaches these to the opening
    /// directive. Only returns a number when no explicit ordering already covers it.
    static func parseImplicitFollow(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var nums: [Int] = []
        // "moment A follow" / "moment A follows" / "moment A next" NOT preceded directly by another "moment N"
        if let re = try? NSRegularExpression(
            pattern: #"moment\s+#?(\d+)\s+(?:to\s+)?(?:follow|follows|next|comes\s+next|afterwards?)"#,
            options: [.caseInsensitive]) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if m.numberOfRanges > 1, let n = Int(ns.substring(with: m.range(at: 1))) { nums.append(n) }
            }
        }
        return nums
    }

    /// Resolve parsed typed references + any visually-selected chip ids against a STABLE numbering snapshot.
    /// `chipSlots` are references already carrying a stable UUID (from the visual picker), so they bypass the
    /// number lookup entirely. Opening/ending are single-valued: the LAST one wins (a later instruction
    /// overrides an earlier one) — surfaced, never silently merged.
    static func resolve(typed: [ParsedReference],
                        chips: [(slot: DirectiveSlot, id: UUID)] = [],
                        ordering: [(after: Int, before: Int, adjacent: Bool)] = [],
                        implicitFollow: [Int] = [],
                        in numbering: StoryMomentNumbering) -> ResolutionResult {
        var d = ResolvedDirectives()
        var unresolved: [UnresolvedReference] = []

        func add(_ slot: DirectiveSlot, _ id: UUID) {
            switch slot {
            case .include: if !d.mustInclude.contains(id) { d.mustInclude.append(id) }
            case .exclude: if !d.exclude.contains(id) { d.exclude.append(id) }
            case .opening: d.opening = id
            case .ending:  d.ending = id
            }
        }

        for r in typed {
            guard let id = numbering.id(forNumber: r.number) else {
                unresolved.append(.init(reason: .numberOutOfRange(r.number), matchedText: r.matchedText))
                continue
            }
            add(r.slot, id)
        }
        for c in chips {
            guard numbering.contains(id: c.id) else {
                // A chip whose Moment was removed from the Story after it was inserted (owner #1 / #2):
                // request clarification rather than sending a dangling id.
                unresolved.append(.init(reason: .momentUnavailable(c.id), matchedText: "Moment \(c.id.uuidString.prefix(8))"))
                continue
            }
            add(c.slot, c.id)
        }
        for o in ordering {
            guard let aid = numbering.id(forNumber: o.after) else {
                unresolved.append(.init(reason: .numberOutOfRange(o.after), matchedText: "Moment \(o.after)")); continue
            }
            guard let bid = numbering.id(forNumber: o.before) else {
                unresolved.append(.init(reason: .numberOutOfRange(o.before), matchedText: "Moment \(o.before)")); continue
            }
            let pair = [aid, bid]
            if o.adjacent {
                if !d.orderAdjacent.contains(pair) { d.orderAdjacent.append(pair) }
            } else {
                if !d.orderAfter.contains(pair) { d.orderAfter.append(pair) }
            }
        }
        // Implicit "moment A follows" with no explicit antecedent attaches to the opening (A immediately after
        // the opening Moment). Only when an opening is set and A resolves and A != opening.
        if let openId = d.opening {
            for n in implicitFollow {
                guard let aid = numbering.id(forNumber: n) else {
                    unresolved.append(.init(reason: .numberOutOfRange(n), matchedText: "Moment \(n)")); continue
                }
                let pair = [aid, openId]
                if aid != openId && !d.orderAdjacent.contains(pair) { d.orderAdjacent.append(pair) }
            }
        }
        return ResolutionResult(directives: d, unresolved: unresolved)
    }
}


// MARK: - SwiftData bridge (keeps the resolver core pure/testable above)

extension StoryMomentNumbering {
    /// Build a snapshot from a Story's ordered Moments (`story.moments`, already ordered by StoryMomentLink
    /// orderIndex then addedAt). Numbers are the 1-based display indices into that order. Reuses the existing
    /// link ordering — no new numbering system, no model change (owner clarification #1).
    init(story moments: [MomentModel]) {
        self.init(ordered: moments.map {
            NumberedMoment(number: 0,  // re-stamped 1..N by the designated init
                           id: $0.id,
                           durationSeconds: $0.asset?.durationSeconds ?? 0,
                           relativePath: $0.asset?.relativePath)
        })
    }
}
