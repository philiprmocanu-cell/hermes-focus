import Foundation

// MARK: - The block's rubric (how the brain will judge this goal)

/// What the goal reply's `rubric` says the block will be judged on:
/// `{"kind", "balance": {"focus", "output"}, "milestones": [{"id","text"}], "on_tells", "off_tells", "smart", "md"}`.
/// Every field may be missing; anything odd is dropped rather than failing the goal screen.
public struct Rubric: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case reading, study, writing, building, outreach, planning, review, mixed
    }

    public struct Item: Equatable, Sendable {
        public var id: String
        public var text: String
        /// "ruling" for a tell added from his own "I'm on task" rulings (`RubricWriter.mergeRulings`), else nil.
        public var from: String?
        public init(id: String, text: String, from: String? = nil) { self.id = id; self.text = text; self.from = from }
    }

    /// Shares of the score, summing to 1.
    public struct Balance: Equatable, Sendable {
        public var focus: Double
        public var output: Double
        public init(focus: Double, output: Double) { self.focus = focus; self.output = output }
    }

    public static let maxMilestones = 5
    public static let maxSummaryLines = 6
    public static let maxLineLength = 90

    public var kind: Kind?
    public var balance: Balance?
    public var milestones: [Item]
    public var onTells: [Item]
    public var offTells: [Item]
    public var smart: [String]
    public var md: String
    /// The writer failed and this is the half-and-half stand-in (`RubricWriter.fallback`); scores like no rubric.
    public var fallback: Bool
    /// His one typed fix the rubric was (re)written with ("" = none).
    public var note: String

    public init(kind: Kind? = nil, balance: Balance? = nil, milestones: [Item] = [], onTells: [Item] = [],
                offTells: [Item] = [], smart: [String] = [], md: String = "", fallback: Bool = false,
                note: String = "") {
        self.kind = kind; self.balance = balance; self.milestones = Array(milestones.prefix(Self.maxMilestones))
        self.onTells = onTells; self.offTells = offTells; self.smart = smart; self.md = md
        self.fallback = fallback; self.note = note
    }

    public var isEmpty: Bool {
        kind == nil && balance == nil && milestones.isEmpty && onTells.isEmpty && offTells.isEmpty
            && smart.isEmpty && md.isEmpty
    }

    /// Nil when there is no usable rubric (missing, not an object, or nothing in it).
    public static func parse(_ json: JSONValue?) -> Rubric? {
        guard let json, case .object = json else { return nil }
        let r = Rubric(kind: Kind(rawValue: json.str("kind").lowercased()),
                       balance: parseBalance(json["balance"]),
                       milestones: items(json["milestones"], prefix: "m"),
                       onTells: items(json["on_tells"], prefix: "on"),
                       offTells: items(json["off_tells"], prefix: "off"),
                       smart: (json["smart"]?.stringList) ?? [],
                       md: json.str("md"))
        return r.isEmpty ? nil : r
    }

    /// `{"focus": 0.9, "output": 0.1}`; percents (90 / 10) and a single side are accepted too.
    public static func parseBalance(_ json: JSONValue?) -> Balance? {
        func num(_ k: String) -> Double? {
            json?[k]?.doubleValue.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        var f = num("focus"), o = num("output")
        if (f ?? 0) > 1 || (o ?? 0) > 1 { f = f.map { $0 / 100 }; o = o.map { $0 / 100 } }
        switch (f, o) {
        case (nil, nil): return nil
        case (let f?, nil): let c = min(1, f); return Balance(focus: c, output: 1 - c)
        case (nil, let o?): let c = min(1, o); return Balance(focus: 1 - c, output: c)
        case (let f?, let o?):
            let sum = f + o
            guard sum > 0 else { return nil }
            return Balance(focus: f / sum, output: o / sum)
        }
    }

    /// Strings or `{"id","text"}` objects; ids default to "<prefix>1", "<prefix>2", … by position.
    static func items(_ json: JSONValue?, prefix: String) -> [Item] {
        var out: [Item] = []
        for (i, v) in (json?.arrayValue ?? []).enumerated() {
            let text = (v.stringValue ?? v["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var id = (v["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty, let n = v["id"]?.doubleValue { id = String(Int(n)) }
            out.append(Item(id: id.isEmpty ? "\(prefix)\(i + 1)" : id, text: text))
        }
        return out
    }

    // MARK: Lines the user sees

    /// "Judged 90% on focus, 10% on output" (whole percents); "Judged half on focus, half on output" at 50/50.
    public var balanceLine: String? {
        guard let balance else { return nil }
        let f = Int((min(1, max(0, balance.focus)) * 100).rounded())
        if f == 50 { return "Judged half on focus, half on output" }
        return "Judged \(f)% on focus, \(100 - f)% on output"
    }

    /// "1. …", "2. …" — the milestones, numbered, each kept short.
    public var milestoneLines: [String] {
        milestones.enumerated().map { "\($0.offset + 1). " + Self.clip($0.element.text) }
    }

    /// "Watching for: a · b · c" (the first three on-task tells), nil when there are none.
    public var watchingLine: String? {
        let tells = onTells.prefix(3).map(\.text)
        guard !tells.isEmpty else { return nil }
        return Self.clip("Watching for: " + tells.joined(separator: " · "))
    }

    /// Up to six short lines for the goal screen: the balance line, the milestones, then what it watches for.
    public var summaryLines: [String] {
        var lines: [String] = []
        if let b = balanceLine { lines.append(b) }
        lines += milestoneLines
        if let w = watchingLine { lines.append(w) }
        return Array(lines.prefix(Self.maxSummaryLines))
    }

    /// The control window's one line while a block runs: the balance, then the numbered milestones, a check
    /// mark on the ones in `reached` (ids, milestone texts or 1-based numbers). Nothing about reached or missed
    /// when `reached` is nil (the payload had no `milestones_reached`).
    public func nowLine(reached: [String]?) -> String {
        var parts: [String] = []
        if let b = balanceLine { parts.append(b) }
        let done = Set((reached ?? []).map { $0.lowercased() })
        for (i, m) in milestones.enumerated() {
            let hit = done.contains(m.id.lowercased()) || done.contains(m.text.lowercased()) || done.contains("\(i + 1)")
            parts.append((hit ? "✓ " : "") + "\(i + 1). " + Self.clip(m.text, to: 48))
        }
        return parts.joined(separator: " · ")
    }

    /// The Now tab's line: the running block's rubric from `/now`, its milestones filled in from the goal
    /// screen's rubric when `/now` only sent the balance and md. "" when `/now` has no rubric.
    public static func nowLine(now: Rubric?, local: Rubric?, reached: [String]?) -> String {
        guard var r = now else { return "" }
        if r.milestones.isEmpty, let local { r.milestones = local.milestones }
        return r.nowLine(reached: reached)
    }

    static func clip(_ s: String, to n: Int = maxLineLength) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard t.count > n else { return t }
        return String(t.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - "Fix…" on the goal screen

/// The small "Fix…" link under the rubric summary: closed → editing (one-line field) → rewriting ("Rewriting…",
/// the same goal POSTed again with `rubric_note`) → closed with the new summary. Esc or an empty Return closes it;
/// a failed or slow rewrite keeps the old summary. While it is open the goal screen waits (he chose to); closed,
/// it never holds Start, and with no rubric there is nothing to fix.
public struct RubricFix: Equatable, Sendable {
    public enum Stage: Equatable, Sendable { case closed, editing, rewriting }

    public static let linkTitle = "Fix…"
    public static let placeholder = "Tell it what to change, e.g. this is mostly reading"
    public static let rewritingLine = "Rewriting…"
    public static let maxNote = 300
    /// A rewrite that hasn't come back by then is given up (the old summary stays).
    public static let timeout: TimeInterval = 8

    public private(set) var rubric: Rubric?
    public private(set) var stage: Stage = .closed
    public private(set) var requestId = 0
    private var sentAt: TimeInterval = 0

    public init(rubric: Rubric? = nil) { self.rubric = rubric }

    /// What to show under the goal: "Rewriting…" while a rewrite is out, else the summary (empty = nothing).
    public var lines: [String] { stage == .rewriting ? [Self.rewritingLine] : (rubric?.summaryLines ?? []) }
    /// The "Fix…" link is offered.
    public var canFix: Bool { stage == .closed && !(rubric?.summaryLines.isEmpty ?? true) }
    public var isEditing: Bool { stage == .editing }
    /// The goal screen waits for him while the field is open or a rewrite is out.
    public var holdsStart: Bool { stage != .closed }

    /// "Fix…" clicked. False when there is nothing to fix.
    @discardableResult
    public mutating func open() -> Bool {
        guard canFix else { return false }
        stage = .editing
        return true
    }

    /// Return in the field. The note to send (one line, ≤ 300 chars), or nil: empty closes the field.
    public mutating func submit(_ raw: String, now: TimeInterval) -> String? {
        guard stage == .editing else { return nil }
        let line = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { stage = .closed; return nil }
        requestId += 1
        sentAt = now
        stage = .rewriting
        return String(line.prefix(Self.maxNote))
    }

    /// Esc. True when it closed something (the key is used up); a rewrite in flight is abandoned.
    @discardableResult
    public mutating func escape() -> Bool {
        guard stage != .closed else { return false }
        stage = .closed
        return true
    }

    /// The rewrite came back (nil rubric = failed / none in the reply: the old one stays). False when stale.
    @discardableResult
    public mutating func receive(_ new: Rubric?, requestId id: Int) -> Bool {
        guard stage == .rewriting, id == requestId else { return false }
        if let new { rubric = new }
        stage = .closed
        return true
    }

    /// Call often. True when a slow rewrite was just given up.
    @discardableResult
    public mutating func tick(now: TimeInterval) -> Bool {
        guard stage == .rewriting, now >= sentAt + Self.timeout else { return false }
        stage = .closed
        return true
    }
}
