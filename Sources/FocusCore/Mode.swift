import Foundation

// MARK: - Which brain this app talks to
//
// Three ways to run Hermes Focus:
//   owner  — the owner's `.env` exists: everything goes to his own server behind the secret prefix.
//   friend — joined a friend's server with an invite code: `/lb/focus/...` with `X-LB-Token`.
//   local  — "Run on my own keys": no server at all. Every route is answered on this Mac by `LocalBrain`, which
//            calls TypeSafe (and, if he added one, Anthropic) on his own keys. Nothing goes to anyone else.
// The choice is remembered in UserDefaults (`brainMode`); the owner's `.env` always wins.

public enum BrainMode: String, CaseIterable, Equatable, Sendable {
    case owner, friend, local

    /// UserDefaults key for the remembered choice ("local" / "friend").
    public static let defaultsKey = "brainMode"
    /// UserDefaults key that overrides the Anthropic model in local mode
    /// (`defaults write app.hermesfocus.mac anthropicModel claude-…`).
    public static let anthropicModelKey = "anthropicModel"

    /// Owner when the owner's `.env` exists. Otherwise the remembered "local" choice, else a joined friend.
    /// Nil = nothing chosen yet: the first-launch choice screen.
    public static func resolve(ownerEnvExists: Bool, friendJoined: Bool, stored: String?) -> BrainMode? {
        if ownerEnvExists { return .owner }
        if stored == BrainMode.local.rawValue { return .local }
        if friendJoined { return .friend }
        return nil
    }

    /// What to remember after a choice (the owner is never stored — the `.env` decides that).
    public var storedValue: String? { self == .owner ? nil : rawValue }

    /// A server is behind this mode (owner, friend).
    public var hasServer: Bool { self != .local }
    /// Judged on his own TypeSafe key: a missing key answers 402 and shows the "Add key" line.
    public var judgesOnOwnKey: Bool { self != .owner }
    /// The leaderboard, the Friends panel and the Board tab.
    public var showsFriends: Bool { self != .local }
    /// "Add friend" and "Share the app".
    public var showsSharing: Bool { self == .owner }
    /// The voice links (owner build only).
    public var showsVoice: Bool { self == .owner }
    /// Suggested blocks come from a server.
    public var showsSuggestions: Bool { self != .local }

    /// The routes this mode may call. Local answers everything a session needs, nothing that needs a server.
    public func canCall(_ route: FocusRoute) -> Bool {
        switch self {
        case .owner: return true
        case .friend: return route.friendCanCall
        case .local:
            switch route {
            case .goal, .frame, .tick, .block, .event, .now, .settings, .history, .sense, .exception: return true
            case .suggestions, .leaderboard: return false
            }
        }
    }

    /// The goal screen's bottom row for this mode (nil = not chosen yet: the timer alone, as a friend who
    /// hasn't joined). Local hides Friends and every voice link; suggestions only show when there are some.
    public static func goalScreenLinks(_ mode: BrainMode?, hasSuggestions: Bool) -> [GoalScreenLink] {
        GoalScreenLink.row(hasSuggestions: hasSuggestions && (mode?.showsSuggestions ?? true),
                           isOwner: mode == .owner)
            .filter { $0 != .friends || (mode?.showsFriends ?? true) }
    }
}

// MARK: - Where a call goes

/// One focus call: over HTTP (owner / friend), answered on this Mac (local), or nowhere.
public enum BrainDispatch: Equatable, Sendable {
    case http(FocusRoute.Target)
    /// The route and the query the local brain reads (`days=30` for history).
    case local(FocusRoute, query: String)
    case none

    public static func select(_ route: FocusRoute, mode: BrainMode?, owner: BrainConfig?, friend: FriendConfig?,
                              query: String = "") -> BrainDispatch {
        switch mode {
        case .owner?:
            return FocusRoute.target(route, owner: owner, friend: nil, query: query).map(BrainDispatch.http) ?? .none
        case .friend?:
            return FocusRoute.target(route, owner: nil, friend: friend, query: query).map(BrainDispatch.http) ?? .none
        case .local?:
            return BrainMode.local.canCall(route) ? .local(route, query: LocalRoute.query(route, query)) : .none
        case nil:
            return .none
        }
    }

    /// As a `Target`, so every caller keeps sending through the same client call: a local route becomes a
    /// `hermes-local://focus/<route>` address that the client answers with `LocalBrain` instead of the network.
    public var target: FocusRoute.Target? {
        switch self {
        case .http(let t): return t
        case .local(let r, let q): return LocalRoute.target(r, query: q)
        case .none: return nil
        }
    }
}

/// The in-app address of a local route. Never leaves the Mac: the client recognises the scheme first.
public enum LocalRoute {
    public static let scheme = "hermes-local"
    static let host = "focus"

    public static func url(_ route: FocusRoute, query: String = "") -> URL {
        var c = URLComponents()
        c.scheme = scheme; c.host = host; c.path = "/" + route.rawValue
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { c.percentEncodedQuery = q.hasPrefix("?") ? String(q.dropFirst()) : q }
        return c.url!
    }

    public static func target(_ route: FocusRoute, query: String = "") -> FocusRoute.Target {
        FocusRoute.Target(url: url(route, query: query), headers: [:])
    }

    /// History asks for the same window of days as the owner's (`days=30`); anything else keeps its query.
    public static func query(_ route: FocusRoute, _ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if route == .history && q.isEmpty { return "days=\(FocusHistory.defaultDays)" }
        return q
    }

    /// The query on a local address ("" when none), for `LocalBrain.handle(_:body:query:)`.
    public static func query(from url: URL) -> String { url.query ?? "" }

    /// The route behind a local address; nil for any ordinary (http/https) URL.
    public static func route(from url: URL) -> FocusRoute? {
        guard url.scheme == scheme, url.host == host else { return nil }
        return FocusRoute(rawValue: url.lastPathComponent)
    }
}

// MARK: - First launch and the key screens

/// The control window's setup screens: the choice, then either Join or the two key steps.
public enum SetupScreen: String, Equatable, Sendable {
    case choose, join, typesafeKey, anthropicKey
}

public struct SetupFlow: Equatable, Sendable {
    public private(set) var screen: SetupScreen?

    public init() {}

    /// First launch: the choice, unless something is chosen already or he said "Not now".
    public init(mode: BrainMode?, skipped: Bool) {
        screen = (mode == nil && !skipped) ? .choose : nil
    }

    /// The choice screen on demand (Board tab, Dock click before anything is chosen).
    public mutating func open() { screen = .choose }

    /// "Run on my own keys": local mode starts now, the TypeSafe key is next.
    @discardableResult
    public mutating func pickOwnKeys() -> BrainMode {
        screen = .typesafeKey
        return .local
    }

    /// "Join a friend's leaderboard": the existing Join screen.
    public mutating func pickJoin() { screen = .join }

    /// "Back": Join and the TypeSafe step go back to the choice, the Anthropic step back to TypeSafe.
    public mutating func back() {
        switch screen {
        case .join?, .typesafeKey?: screen = .choose
        case .anthropicKey?: screen = .typesafeKey
        case .choose?, nil: break
        }
    }

    /// "Next" after "Key works" on the TypeSafe step: the optional Anthropic key. Without a working TypeSafe
    /// key there is nothing to add to yet, so the setup simply closes.
    public mutating func next(typesafeWorks: Bool) {
        guard screen == .typesafeKey else { return }
        screen = typesafeWorks ? .anthropicKey : nil
    }

    /// The "Add key" link (local mode): straight to the TypeSafe step.
    public mutating func openKey() { screen = .typesafeKey }

    /// "Later", "Skip", "Done", "Not now", or joined.
    public mutating func close() { screen = nil }
}

/// Local mode's key save: the key goes into the Keychain first (the local brain reads its keys from there),
/// then the brain checks it. A refused or unchecked key is taken back out and any earlier key restored.
public enum LocalKeyCommit: Equatable, Sendable {
    case keep, restore

    public static func decide(_ status: TypeSafeStatus?) -> LocalKeyCommit { status == .ok ? .keep : .restore }
}

/// The Anthropic key as typed: the same rules as the TypeSafe key (trimmed, one word).
public enum AnthropicKeyField {
    public static let keychainAccount = "anthropic_key"

    public static func clean(_ raw: String) -> String? { TypeSafeKeyField.clean(raw) }
    public static func isValid(_ raw: String) -> Bool { clean(raw) != nil }

    /// `anthropicModel` from defaults, or the default model.
    public static func model(stored: String?) -> String {
        let m = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? AnthropicAPI.defaultModel : m
    }
}

// MARK: - Local data on disk

public enum LocalData {
    /// `~/Library/Application Support/HermesFocus/local`
    public static func directory(support: URL) -> URL {
        support.appendingPathComponent("local", isDirectory: true)
    }

    /// The path as he would type it, with `~` for his home folder.
    public static func displayPath(_ url: URL, home: String = NSHomeDirectory()) -> String {
        let p = url.path
        guard !home.isEmpty, p.hasPrefix(home) else { return p }
        return "~" + p.dropFirst(home.count)
    }

    /// A day's `report_path` (absolute, `~/…`, or relative to the local store) as a file URL; nil when absent.
    public static func reportURL(_ path: String, store: URL, home: String = NSHomeDirectory()) -> URL? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        if p.hasPrefix("file://") { return URL(string: p) }
        if p.hasPrefix("/") { return URL(fileURLWithPath: p) }
        if p.hasPrefix("~/") { return URL(fileURLWithPath: home).appendingPathComponent(String(p.dropFirst(2))) }
        return store.appendingPathComponent(p)
    }
}

/// Local history: the same `days` payload as the server, plus `report_path` per day — the day's report as a
/// Markdown file on this Mac. The doc icon opens that file; without a `report_path` there is no icon.
public enum LocalHistory {
    public static func parse(_ json: JSONValue, store: URL, home: String = NSHomeDirectory()) -> [HistoryDay] {
        var reports: [String: String] = [:]
        let list = json["days"]?.arrayValue ?? json["history"]?.arrayValue ?? json.arrayValue ?? []
        for v in list {
            let day = v.str("day").trimmingCharacters(in: .whitespaces)
            guard !day.isEmpty, reports[day] == nil,
                  let url = LocalData.reportURL(v.str("report_path"), store: store, home: home) else { continue }
            reports[day] = url.absoluteString
        }
        return FocusHistory.parse(json).map { d in
            var d = d
            d.docURL = reports[d.day]
            return d
        }
    }
}

/// The one Health line in local Settings, from `LocalBrain.health` (counted since the app opened):
/// `{"calls", "errors", "cost_usd", "jev": {...}, "second_opinion": {...}, ...}` →
/// "412 calls since the app opened · about $0.38 · 2 errors".
public enum LocalHealth {
    public static func line(_ json: JSONValue?) -> String {
        guard let json, let calls = number(json["calls"]), calls >= 1 else { return ModeText.healthUnknown }
        let n = Int(calls.rounded())
        var parts = ["\(n) \(n == 1 ? "call" : "calls") since the app opened"]
        if let cost = number(json["cost_usd"]) { parts.append("about " + dollars(cost)) }
        if let e = number(json["errors"]), e >= 1 {
            let k = Int(e.rounded())
            parts.append("\(k) \(k == 1 ? "error" : "errors")")
        }
        return parts.joined(separator: " · ")
    }

    /// "$0.38"; under a cent → "under $0.01".
    public static func dollars(_ v: Double) -> String {
        if v > 0 && v < 0.01 { return "under $0.01" }
        return String(format: "$%.2f", max(0, v))
    }

    private static func number(_ v: JSONValue?) -> Double? {
        guard let d = v?.doubleValue, d.isFinite else { return nil }
        return d
    }
}

// MARK: - Every word on the mode screens

public enum ModeText {
    // The first-launch choice.
    public static let chooseTitle = "How do you want to run Hermes Focus?"
    public static let chooseSubtitle = "You can use it on your own, or next to a friend on their leaderboard."
    public static let ownKeysTitle = "Run on my own keys"
    public static let ownKeysBadge = "Recommended"
    public static let ownKeysBody = "Everything stays on this Mac. Your screen is judged by TypeSafe with your own key. Nothing is sent to anyone else."
    public static let joinTitle = "Join a friend's leaderboard"
    public static let joinBody = "Use an invite code from a friend. Your hours show up next to theirs, and their server does the judging."
    public static let notNow = "Not now"
    public static let back = "Back"

    // The TypeSafe step (local mode). Field, save, "Key works", refused and the reminder are TypeSafeText's.
    public static let typesafeExplainer = "TypeSafe's Jev model judges your screen, on your own key — about a dollar or two for a full day. Get a key at console.typesafe.ai/keys."
    public static let typesafeUnreachable = "Couldn't reach TypeSafe — check your internet and try again"
    public static let next = "Next"

    // The Anthropic step (optional).
    public static let anthropicTitle = "Your Anthropic key (optional)"
    public static let anthropicExplainer = "Adds a written plan for each goal, a second look before a nudge, and advice after each block. Skip and the app still judges and scores with TypeSafe alone."
    public static let anthropicWhere = "Get a key at console.anthropic.com/settings/keys."
    public static let anthropicField = "Anthropic key"
    public static let anthropicPrompt = "Paste your Anthropic key"
    public static let anthropicSaved = "Key saved"
    public static let anthropicSaveFailed = "Couldn't save the key on this Mac — try again"
    public static let skip = "Skip"
    public static func anthropicRow(set: Bool) -> String { "Anthropic key: " + (set ? "set" : "not set") }

    // Settings in local mode.
    public static func dataLine(_ path: String) -> String { "Your data: " + path }
    public static let showInFinder = "Show in Finder"
    public static let healthTitle = "Health"
    public static let healthUnknown = "No calls yet since the app opened"

    // History.
    public static let historyNeedsChoice = "Choose how to run Hermes Focus first (Dock icon → Board)."
    public static let historyNoDays = "No days yet."
    public static let historyLocalFailed = "Couldn't read your history on this Mac."


    /// The "unreachable" line under a TypeSafe key save, per mode.
    public static func typesafeResult(_ status: TypeSafeStatus?, mode: BrainMode?) -> (text: String, ok: Bool) {
        if status == nil, mode == .local { return (typesafeUnreachable, false) }
        return TypeSafeText.result(for: status)
    }
}
