import Foundation

// The wire contract with the Hermes brain (`/admin/focus/*`). Field names are snake_case on the wire.

/// Arbitrary JSON, so frame responses and score `parts` pass through untouched.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return ["true", "1", "yes"].contains(s.lowercased())
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Trimmed string, "" when missing / not a string.
    public func str(_ key: String) -> String {
        (self[key]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A list of non-empty strings; objects with a `text` field are accepted too.
    public var stringList: [String] {
        (arrayValue ?? []).compactMap { v -> String? in
            let t = (v.stringValue ?? v["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }
}

public struct FramePayload: Codable, Equatable, Sendable {
    public var blockId: String
    public var goal: String
    public var understood: String
    public var at: Int
    public var imageJpegB64: String
    public var app: String
    public var title: String
    public var url: String
    public var specificGoal: String

    public init(blockId: String, goal: String, understood: String = "", at: Int, imageJpegB64: String, context: AppContext,
                specificGoal: String = "") {
        self.blockId = blockId; self.goal = goal; self.understood = understood; self.at = at; self.imageJpegB64 = imageJpegB64
        self.app = context.app; self.title = context.title; self.url = context.url
        self.specificGoal = specificGoal
    }

    enum CodingKeys: String, CodingKey {
        case blockId = "block_id", goal, understood, at, imageJpegB64 = "image_jpeg_b64", app, title, url,
             specificGoal = "specific_goal"
    }
}

public struct TickPayload: Codable, Equatable, Sendable {
    public var blockId: String
    public var goal: String
    public var understood: String
    public var at: Int
    public var phase: String
    public var activeS: Int
    public var switches: Int
    public var app: String
    public var title: String
    public var url: String
    /// Seconds since the last keyboard / mouse / scroll input, at tick time.
    public var idleS: Int = 0
    /// Seconds a clear distraction (Instagram, TikTok…) was in front during this minute.
    public var distractionS: Int = 0
    /// Seconds with scrolling / keystrokes (sampled ~1 s).
    public var scrollS: Int = 0
    public var keysS: Int = 0

    public init(blockId: String, goal: String, understood: String = "", at: Int, phase: Phase,
                window: MeasureWindow, context: AppContext, distractionS: Int = 0, idleS: Int = 0) {
        self.distractionS = distractionS
        self.idleS = max(0, idleS)
        self.scrollS = Int(window.scrollSeconds.rounded())
        self.keysS = Int(window.keySeconds.rounded())
        self.blockId = blockId; self.goal = goal; self.understood = understood; self.at = at
        self.phase = phase == .work ? "work" : "break"
        self.activeS = Int(window.activeSeconds.rounded())
        self.switches = window.switches
        self.app = context.app; self.title = context.title; self.url = context.url
    }

    enum CodingKeys: String, CodingKey {
        case blockId = "block_id", goal, understood, at, phase,
             activeS = "active_s", switches, app, title, url, idleS = "idle_s", distractionS = "distraction_s",
             scrollS = "scroll_s", keysS = "keys_s"
    }
}

public struct AppUsage: Codable, Equatable, Sendable {
    public var app: String
    public var title: String
    public var url: String
    public var seconds: Int
}

public struct BlockPayload: Codable, Equatable, Sendable {
    public var blockId: String
    public var goal: String
    public var understood: String
    public var startedAt: Int
    public var endedAt: Int
    public var plannedS: Int
    public var completed: Bool
    public var activeS: Int
    public var switches: Int
    public var apps: [AppUsage]
    public var frames: [JSONValue]
    public var distractionS: Int = 0
    public var scrollS: Int = 0
    public var keysS: Int = 0
    public var specificGoal: String = ""

    public init(timing: BlockTiming, window: MeasureWindow, frames: [JSONValue], distractionS: Int = 0,
                specificGoal: String = "") {
        self.distractionS = distractionS
        self.scrollS = Int(window.scrollSeconds.rounded())
        self.keysS = Int(window.keySeconds.rounded())
        self.specificGoal = specificGoal
        blockId = timing.blockId
        goal = timing.goal
        understood = timing.understood
        startedAt = Int(timing.startedAt)
        endedAt = Int(timing.endedAt)
        plannedS = Int(timing.plannedSeconds)
        completed = timing.completed
        activeS = Int(window.activeSeconds.rounded())
        switches = window.switches
        apps = window.topApps().map { AppUsage(app: $0.0.app, title: $0.0.title, url: $0.0.url, seconds: Int($0.1.rounded())) }
        self.frames = frames
    }

    enum CodingKeys: String, CodingKey {
        case blockId = "block_id", goal, understood, startedAt = "started_at", endedAt = "ended_at",
             plannedS = "planned_s", completed,
             activeS = "active_s", switches, apps, frames, distractionS = "distraction_s",
             scrollS = "scroll_s", keysS = "keys_s", specificGoal = "specific_goal"
    }

    /// Lenient on `understood`: pending-blocks.json written by the previous version lacks it. Older files
    /// also carry the camera's `attention` / `face_present` / `eye`; those keys are simply ignored now.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockId = try c.decode(String.self, forKey: .blockId)
        goal = try c.decode(String.self, forKey: .goal)
        understood = try c.decodeIfPresent(String.self, forKey: .understood) ?? ""
        startedAt = try c.decode(Int.self, forKey: .startedAt)
        endedAt = try c.decode(Int.self, forKey: .endedAt)
        plannedS = try c.decode(Int.self, forKey: .plannedS)
        completed = try c.decode(Bool.self, forKey: .completed)
        activeS = try c.decode(Int.self, forKey: .activeS)
        switches = try c.decode(Int.self, forKey: .switches)
        apps = try c.decode([AppUsage].self, forKey: .apps)
        frames = try c.decode([JSONValue].self, forKey: .frames)
        distractionS = try c.decodeIfPresent(Int.self, forKey: .distractionS) ?? 0
        scrollS = try c.decodeIfPresent(Int.self, forKey: .scrollS) ?? 0
        keysS = try c.decodeIfPresent(Int.self, forKey: .keysS) ?? 0
        specificGoal = try c.decodeIfPresent(String.self, forKey: .specificGoal) ?? ""
    }
}

public struct BlockResult: Equatable, Sendable {
    public var score: Int
    public var advice: String
    public var parts: JSONValue?
    /// Suggested length of the next work block, seconds (optional; see `AdaptiveLength`).
    public var nextWorkS: Int? = nil
    public var nextReason: String = ""
    /// The two halves of the score (each 1..1000; `score` is their mean). Nil when the brain didn't send them.
    public var focusScore: Int? = nil
    public var outputScore: Int? = nil

    /// Lenient parse of `{"score": 1..1000, "focus_score", "output_score", "parts": {...}, "advice": str,
    /// "next_work_s": int, "next_reason": str}`.
    public static func parse(_ json: JSONValue) -> BlockResult? {
        func clamp(_ k: String) -> Int? {
            guard let v = json[k]?.doubleValue, v.isFinite else { return nil }
            return min(1000, max(1, Int(v.rounded())))
        }
        guard let score = clamp("score") else { return nil }
        let next = NextBlockAdvice.parse(json)
        return BlockResult(score: score, advice: json["advice"]?.stringValue ?? "", parts: json["parts"],
                           nextWorkS: next?.workSeconds, nextReason: next?.reason ?? "",
                           focusScore: clamp("focus_score"), outputScore: clamp("output_score"))
    }
}

/// `next_work_s` / `next_reason` from a block response (independent of the score).
public struct NextBlockAdvice: Equatable, Sendable {
    public var workSeconds: Int
    public var reason: String
    public static func parse(_ json: JSONValue) -> NextBlockAdvice? {
        guard let v = json["next_work_s"]?.doubleValue, v.isFinite, v > 0 else { return nil }
        let reason = (json["next_reason"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return NextBlockAdvice(workSeconds: Int(min(v, 86_400).rounded()), reason: reason)
    }
}

/// The frame response: `{"quality": 0..1, "note": str, "nudge": str, "goal_progress": 0..1, "tip": str,
/// "goal_changed": {"goal","specific_goal"}, ...}` — every field optional. `goalProgress` / `tip` are nil when
/// the field was missing (keep the previous value). Tick replies are read the same way.
public struct FrameResult: Equatable, Sendable {
    public var quality: Double?
    public var note: String
    public var nudge: String
    public var goalProgress: Double? = nil
    public var tip: String? = nil
    /// The brain spotted that he moved to another goal and is scoring that one now.
    public var goalChanged: GoalChange? = nil
    /// The judge looked at a distraction-list site and said it is actually serving this block's goal
    /// (the Discord thread with his teammates, the tutorial on the topic). nil when the server didn't say.
    public var servesGoal: Bool? = nil
    public static func parse(_ json: JSONValue) -> FrameResult {
        let q = json["quality"]?.doubleValue.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        let p = json["goal_progress"]?.doubleValue.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        let tip = json["tip"]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return FrameResult(quality: q, note: json.str("note"), nudge: json.str("nudge"), goalProgress: p, tip: tip,
                           goalChanged: GoalChange.parse(json), servesGoal: json["serves_goal"]?.boolValue)
    }
}

// MARK: - Goal understanding

/// `POST /admin/focus/goal`
public struct GoalRequest: Codable, Equatable, Sendable {
    public var text: String
    public var previousGoal: String
    public var previousUnderstood: String
    /// Only sent when answering a clarifying question.
    public var clarifyAnswer: String?
    /// Only sent from the goal screen's "Fix…": one line on how to change the rubric (same goal text; the
    /// reply carries the regenerated `rubric` and never changes the goal or starts anything).
    public var rubricNote: String?
    public var at: Int

    public init(text: String, previousGoal: String, previousUnderstood: String, clarifyAnswer: String? = nil,
                rubricNote: String? = nil, at: Int) {
        self.text = text; self.previousGoal = previousGoal; self.previousUnderstood = previousUnderstood
        self.clarifyAnswer = clarifyAnswer; self.rubricNote = rubricNote; self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case text, previousGoal = "previous_goal", previousUnderstood = "previous_understood",
             clarifyAnswer = "clarify_answer", rubricNote = "rubric_note", at
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(previousGoal, forKey: .previousGoal)
        try c.encode(previousUnderstood, forKey: .previousUnderstood)
        try c.encodeIfPresent(clarifyAnswer, forKey: .clarifyAnswer)
        try c.encodeIfPresent(rubricNote, forKey: .rubricNote)
        try c.encode(at, forKey: .at)
    }
}

/// `{"status": "ok"|"clarify", "goal": str, "understood": str, "question": str,
///   "specific_goal": str, "specificity": 0..1, "specificity_hint": str, "rubric": {…} (see `Rubric`)}`
public struct GoalReply: Equatable, Sendable {
    public enum Status: String, Sendable { case ok, clarify }
    public var status: Status
    public var goal: String
    public var understood: String
    public var question: String
    public var specificGoal: String
    public var specificity: Double?
    public var specificityHint: String
    /// How the block will be judged (nil = none sent / unusable; the goal screen then shows nothing extra).
    public var rubric: Rubric?

    public init(status: Status, goal: String = "", understood: String = "", question: String = "",
                specificGoal: String = "", specificity: Double? = nil, specificityHint: String = "",
                rubric: Rubric? = nil) {
        self.status = status; self.goal = goal; self.understood = understood; self.question = question
        self.specificGoal = specificGoal; self.specificity = specificity
        self.specificityHint = specificityHint; self.rubric = rubric
    }

    /// Nil when the reply is unusable (unknown status, or "clarify" without a question).
    public static func parse(_ json: JSONValue) -> GoalReply? {
        let str = json.str
        guard let status = Status(rawValue: str("status").lowercased()) else { return nil }
        let spec = json["specificity"]?.doubleValue.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        let r = GoalReply(status: status, goal: str("goal"), understood: str("understood"), question: str("question"),
                          specificGoal: str("specific_goal"), specificity: spec, specificityHint: str("specificity_hint"),
                          rubric: Rubric.parse(json["rubric"]))
        if status == .clarify && r.question.isEmpty { return nil }
        return r
    }
}

public enum EventKind: String, Codable, Sendable {
    case sessionStarted = "session_started"
    case sessionStopped = "session_stopped"
    case breakSkipped = "break_skipped"
    case blockStarted = "block_started"
}

public struct EventPayload: Codable, Equatable, Sendable {
    public var kind: EventKind
    public var blockId: String
    public var goal: String
    public var at: Int
    public init(kind: EventKind, blockId: String, goal: String, at: Int) {
        self.kind = kind; self.blockId = blockId; self.goal = goal; self.at = at
    }
    enum CodingKeys: String, CodingKey { case kind, blockId = "block_id", goal, at }
}

// MARK: - Config

public struct BrainConfig: Equatable, Sendable {
    /// The server a blank address means. The standalone build has none: the address must be typed in.
    public static let defaultBaseURL = ""
    public static let userAgent = "Mozilla/5.0 (compatible; HermesFocus/1.0)"

    public var baseURL: String
    public var token: String

    public init(baseURL: String, token: String) {
        var b = baseURL.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        self.baseURL = b.isEmpty ? BrainConfig.defaultBaseURL : b
        self.token = token
    }

    /// Parse `KEY=VALUE` lines (quotes, `export`, comments tolerated). Nil without a token.
    public static func parse(env text: String) -> BrainConfig? {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == value.last, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        guard let token = values["BRAIN_API_TOKEN"], !token.isEmpty else { return nil }
        return BrainConfig(baseURL: values["BRAIN_URL"] ?? "", token: token)
    }

    /// `{base}{path}` with no secret prefix (friend leaderboard routes).
    public static func plainURL(base: String, path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        if b.isEmpty { b = defaultBaseURL }
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: b + p)
    }

    /// `{BRAIN_URL}/t/{BRAIN_API_TOKEN}{path}`
    public func url(path: String) -> URL? {
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: "\(baseURL)/t/\(token)\(p)")
    }
}

// MARK: - Retry queue for block summaries

/// Block summaries that have not reached the brain yet. Persisted as JSON (no images in it).
public struct PendingBlocks: Codable, Equatable, Sendable {
    public private(set) var items: [BlockPayload] = []
    public static let maxItems = 200
    public init() {}

    public mutating func enqueue(_ p: BlockPayload) {
        items.removeAll { $0.blockId == p.blockId }
        items.append(p)
        if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
    }

    public mutating func remove(blockId: String) {
        items.removeAll { $0.blockId == blockId }
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data("{\"items\":[]}".utf8) }

    public static func decode(_ data: Data?) -> PendingBlocks {
        guard let data, let q = try? JSONDecoder().decode(PendingBlocks.self, from: data) else { return PendingBlocks() }
        return q
    }
}
