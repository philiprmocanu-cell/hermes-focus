import Foundation

// MARK: - The local brain: the server's focus routes, in-process (no server)
//
// The Hermes Focus app used to post every focus call to a server (`/admin/focus/*`). The local
// brain answers the same calls on the Mac, in the same JSON shapes, by tying together the ported pieces:
// the judge (`Judge`, brain/jev.py), the score and the day (`Scoring`, `FocusDay`), the rubric writer
// (`RubricWriter`) and the two API clients on the user's own keys (`TypeSafeClient` for Jev,
// `AnthropicClient` for the goal step, rubric, second opinion and end-of-block advice).
//
// What each route does is a port of its app.py handler (`_focus_goal`, `_focus_sense` + `_focus_sense_finish`
// + `_focus_second_gate`, `_focus_exception`, `_focus_frame`, `_focus_tick`, `_focus_event`, `_focus_block`,
// `_focus_now`, `_focus_history`, `_focus_settings*`, `_focus_labels_get`). Without a TypeSafe key nothing is
// judged (402, as for a friend without one). Without an Anthropic key the app still works on TypeSafe alone:
// the goal is taken as typed, the rubric is the fallback, there is no second opinion and no advice.

public final class LocalBrain: @unchecked Sendable {
    public struct Keys: Sendable {
        public var typesafe: String
        public var anthropic: String
        /// The Claude model for the goal step, rubric, second opinion and advice.
        public var model: String
        public init(typesafe: String = "", anthropic: String = "", model: String = AnthropicAPI.defaultModel) {
            self.typesafe = typesafe; self.anthropic = anthropic; self.model = model
        }
    }

    private let core: LocalBrainCore
    private let keys: @Sendable () -> Keys
    private let counters: LocalCounters

    public init(storeURL: URL, keys: @escaping @Sendable () -> Keys, transport: HTTPTransport,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.keys = keys
        counters = LocalCounters()
        core = LocalBrainCore(store: LocalStore(root: storeURL), keys: keys, transport: transport, clock: now,
                              counters: counters)
    }

    /// Mirrors one HTTP call: the route the app would have posted/got, its JSON body (nil for GET) →
    /// (status, JSON reply), same shapes as the server.
    public func handle(_ route: FocusRoute, body: JSONValue?) async -> (Int, JSONValue) {
        await handle(route, body: body, query: "")
    }

    /// The same, with the GET query the server read ("days=30" for history).
    public func handle(_ route: FocusRoute, body: JSONValue?, query: String) async -> (Int, JSONValue) {
        await core.handle(route, body: body, query: LocalJSON.query(query))
    }

    /// `GET /admin/focus/labels?days=14`: the nudge labels, newest first (there is no `FocusRoute` for it).
    public func labels(days: Int = 14) async -> (Int, JSONValue) { await core.labelsGet(days: days) }

    /// False until a TypeSafe key is set (then goal/sense/frame answer 402).
    public var ready: Bool { !keys().typesafe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Calls, errors, avg ms, tokens, images, second-opinion calls and the cost estimate since launch.
    public var health: JSONValue {
        let k = keys()
        return counters.json(typesafeReady: ready, anthropicKey: !k.anthropic.isEmpty, model: k.model)
    }

    /// Waits for the work a finished block left running in the background (the advice paragraph and the
    /// report rewrite after it). The app never needs this; tests do.
    public func settle() async { await core.settle() }
}

// MARK: - Small JSON helpers (Python's `_focus_str`, `_num`, …)

enum LocalJSON {
    typealias D = Judge.Dict

    /// `_focus_str`: " ".join(str(v or "").split())[:n].
    static func s(_ v: JSONValue?, _ n: Int) -> String { Judge.cut(Judge.squash(Judge.pyStrOr(v)), n) }
    static func num(_ v: JSONValue?) -> Double? { Judge.num(v) }
    static func num0(_ v: JSONValue?) -> Double { Judge.num0(v) }
    static func truthy(_ v: JSONValue?) -> Bool { Judge.truthy(v) }
    static func dict(_ v: JSONValue?) -> D? { Judge.dict(v) }
    static func list(_ v: JSONValue?) -> [JSONValue] { Judge.list(v) ?? [] }
    static func dicts(_ v: JSONValue?) -> [D] { list(v).compactMap { dict($0) } }
    static func n(_ x: Double) -> JSONValue { .number(x) }
    static func n(_ x: Int) -> JSONValue { .number(Double(x)) }
    static func n(_ x: Double?) -> JSONValue { x.map { .number($0) } ?? .null }
    static func r3(_ x: Double) -> Double { Judge.pyRound(x, 3) }
    static func toTs(_ v: JSONValue?) -> Double { Scoring.toTs(v) }
    static func norm(_ v: JSONValue?) -> String { Scoring.norm(v) }

    /// "days=30&x=1" → ["days": "30", "x": "1"].
    static func query(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        let trimmed = q.hasPrefix("?") ? String(q.dropFirst()) : q
        for part in trimmed.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard let k = kv.first, !k.isEmpty else { continue }
            out[k] = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
        }
        return out
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "EEEE"
        return f
    }()

    /// `_focus_day_of`: the local calendar day of a timestamp.
    static func dayOf(_ ts: Double) -> String { dayFormatter.string(from: Date(timeIntervalSince1970: ts)) }

    static func weekday(_ day: String) -> String {
        guard let d = dayFormatter.date(from: day) else { return "" }
        return weekdayFormatter.string(from: d)
    }
}

// MARK: - The brain's working state

/// The running block's second-by-second memory (app.py `_focus_sense_state`). Never written to disk: it holds
/// the visible text and the latest screenshot.
struct LocalSenseMemory {
    var blockId = ""
    var text = ""
    var digest = ""
    var rows: [Judge.Dict] = []
    var lastCallAt = 0.0
    var last: Judge.Dict?
    var minuteAt = 0.0
    var screenSince = 0.0
    var screenKey = ""
    var started = 0.0
    var trail: [Judge.Dict] = []
    var image: (b64: String, key: String, at: Double)?
    var site = ""
    var siteSince = 0.0
    var nudge: Judge.Dict?
    var secondAt = 0.0
}

actor LocalBrainCore {
    typealias D = Judge.Dict

    // app.py's limits.
    static let senseRows = 130
    static let framesPerBlock = 70
    static let ticksKept = 130
    static let sessionStaleS = 10.0 * 60
    static let breakStaleS = 35.0 * 60
    static let goalDone = 0.9
    static let secondUnsureGapS = 15.0
    static let labelNoClickS = 60.0
    static let eventsKept = 400
    static let maxImageBytes = 2 * 1024 * 1024
    static let typesafeMissing: JSONValue = .object([
        "error": .string("Add your TypeSafe key in Settings to be judged"), "typesafe": .string("missing")])
    static let user = "local"

    let store: LocalStore
    let keysSource: @Sendable () -> LocalBrain.Keys
    let transport: HTTPTransport
    let clock: @Sendable () -> Date
    let counters: LocalCounters

    var st: D
    var sense = LocalSenseMemory()
    /// The block's last screenshot, memory only, for the one advice call at its end.
    var lastFrame: (blockId: String, b64: String)?
    var history: [JSONValue]
    var background: [Task<Void, Never>] = []

    init(store: LocalStore, keys: @escaping @Sendable () -> LocalBrain.Keys, transport: HTTPTransport,
         clock: @escaping @Sendable () -> Date, counters: LocalCounters) {
        self.store = store
        keysSource = keys
        self.transport = transport
        self.clock = clock
        self.counters = counters
        st = Self.blankState().merging(store.loadState() ?? [:]) { $1 }
        history = store.loadHistory()
    }

    /// `_focus_blank_state`.
    static func blankState() -> D {
        ["active": .bool(false), "block_id": .string(""), "goal": .string(""), "phase": .string(""),
         "last_seen": .number(0), "ticks": .array([]), "frames": .array([]),
         "goal_label": .string(""), "goal_text": .string(""), "understood": .string(""), "goal_at": .number(0),
         "nudged_at": .number(0), "specific_goal": .string(""), "specificity": .null,
         "specificity_hint": .string(""), "goal_progress": .number(0), "progress_block": .string(""),
         "inferred_goal": .string(""), "tip": .string(""), "next_tip": .string(""),
         "block_started_at": .number(0), "block_planned_s": .number(0), "original_goal": .string(""),
         "goal_related": .object([:]), "goal_questions": .array([]), "rubric": .null,
         "milestones_reached": .array([]), "milestones_block": .string(""), "exceptions": .null,
         "settings": .object([:]), "events": .array([])]
    }

    var keys: LocalBrain.Keys {
        var k = keysSource()
        k.typesafe = k.typesafe.trimmingCharacters(in: .whitespacesAndNewlines)
        k.anthropic = k.anthropic.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.model.trimmingCharacters(in: .whitespaces).isEmpty { k.model = AnthropicAPI.defaultModel }
        return k
    }

    var nowTs: Double { clock().timeIntervalSince1970 }

    func save() { store.saveState(st) }

    func settle() async {
        while !background.isEmpty {
            let tasks = background
            background = []
            for t in tasks { await t.value }
        }
    }

    // MARK: Routing

    func handle(_ route: FocusRoute, body: JSONValue?, query: [String: String]) async -> (Int, JSONValue) {
        let data = LocalJSON.dict(body) ?? [:]
        switch route {
        case .goal: return await goal(data)
        case .sense:
            if body == nil { return senseGet() }
            return await senseRoute(data)
        case .frame: return await frame(data)
        case .exception: return exception(data)
        case .tick: return tick(data)
        case .event: return event(data)
        case .block: return block(data)
        case .now: return now()
        case .history:
            let days = Int(query["days"] ?? "") ?? Self.historyDaysDefault
            return (200, .object(["days": .array(historyRows(days: days))]))
        case .settings:
            if body == nil { return settingsGet() }
            return await settingsPost(data)
        case .suggestions: return (200, .object(["suggestions": .array([])]))
        case .leaderboard:
            return (404, .object(["error": .string("not available without a server")]))
        }
    }

    // MARK: Session helpers (callers are on the actor)

    func str(_ k: String) -> String { Judge.pyStrOr(st[k]) }
    func dbl(_ k: String) -> Double { Judge.num0(st[k]) }

    /// `_focus_switch_block`: a new block starts with an empty rolling window, no progress and no tip.
    func switchBlock(_ blockId: String, goal: String, plannedS: JSONValue? = nil) {
        let now = nowTs
        if !blockId.isEmpty && blockId != str("block_id") {
            st["block_id"] = .string(blockId)
            st["ticks"] = .array([]); st["frames"] = .array([]); st["nudged_at"] = .number(0)
            st["tip"] = .string(str("next_tip")); st["next_tip"] = .string("")
            st["inferred_goal"] = .string(""); st["block_started_at"] = .number(now)
            st["block_planned_s"] = .number(0); st["original_goal"] = .string("")
        }
        if !blockId.isEmpty && str("progress_block") != blockId {
            st["progress_block"] = .string(blockId); st["goal_progress"] = .number(0)
        }
        if !blockId.isEmpty && str("milestones_block") != blockId {
            st["milestones_block"] = .string(blockId); st["milestones_reached"] = .array([])
        }
        if let planned = LocalJSON.num(plannedS), planned > 0 {
            st["block_planned_s"] = .number(min(planned, 4 * 3600))
        }
        if !goal.isEmpty { st["goal"] = .string(goal) }
    }

    /// `_focus_session_active`.
    func sessionActive(_ now: Double) -> Bool {
        let stale = str("phase") == "break" ? Self.breakStaleS : Self.sessionStaleS
        return Judge.truthy(st["active"]) && now - dbl("last_seen") < stale
    }

    /// `_focus_understood_for`.
    func understoodFor(_ goal: String) -> String {
        let g = Scoring.norm(goal)
        guard !str("understood").isEmpty else { return "" }
        if g.isEmpty || g == Scoring.norm(str("goal_label")) || g == Scoring.norm(str("goal_text")) {
            return str("understood")
        }
        return ""
    }

    /// `_focus_rubric_live`: the goal's rubric while it is in force (not the fallback).
    func rubricLive() -> JSONValue? {
        guard let r = st["rubric"], case .object = r, !Judge.truthy(r["fallback"]) else { return nil }
        return r
    }

    /// `_focus_rubric_view`: {md, balance, kind, milestones, milestones_reached} or null.
    func rubricView() -> JSONValue {
        guard let r = st["rubric"], case .object = r else { return .null }
        let ms = str("milestones_block")
        let here = !ms.isEmpty && ms == str("block_id")
        return .object(["md": .string(Judge.pyStrOr(r["md"])), "balance": r["balance"] ?? .null,
                        "kind": r["kind"] ?? .null, "milestones": .array(LocalJSON.list(r["milestones"])),
                        "milestones_reached": here ? .array(LocalJSON.list(st["milestones_reached"])) : .array([])])
    }

    /// `_focus_rulings`: his (and the second opinion's) rulings for this block.
    func rulings(_ blockId: String) -> [D] {
        guard let ex = LocalJSON.dict(st["exceptions"]), Judge.pyStrOr(ex["block_id"]) == blockId else { return [] }
        return LocalJSON.dicts(ex["rules"])
    }

    /// `_focus_add_ruling`.
    func addRuling(_ blockId: String, _ rule: D) {
        var rules = rulings(blockId)
        if !rules.contains(where: { $0["site"] == rule["site"] && $0["title"] == rule["title"] }) {
            rules = Array((rules + [rule]).suffix(10))
        }
        st["exceptions"] = .object(["block_id": .string(blockId), "rules": .array(rules.map { .object($0) })])
    }

    // MARK: History helpers

    func blocksOf(day: String) -> [D] {
        LocalJSON.dicts(.array(history)).filter { b in
            let s = LocalJSON.toTs(b["started_at"])
            return LocalJSON.dayOf(s != 0 ? s : LocalJSON.toTs(b["ended_at"])) == day
        }.sorted { LocalJSON.num0($0["ended_at"]) < LocalJSON.num0($1["ended_at"]) }
    }

    func blocksToday() -> [D] { blocksOf(day: LocalJSON.dayOf(nowTs)) }

    func storedBlock(_ blockId: String) -> D? {
        LocalJSON.dicts(.array(history)).last { Judge.pyStrOr($0["block_id"]) == blockId }
    }
}
