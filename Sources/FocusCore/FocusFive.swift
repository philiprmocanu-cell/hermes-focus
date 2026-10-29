import Foundation

// Pure logic for the fifth iteration: the break screen that is only rest (the score reveal moves to a small
// corner card and fades out), the clickable daily-hours goal, "he moved to another goal" from the server,
// the links at the bottom of the goal screen, and friend mode running the whole app against the
// `/lb/focus/...` routes.

// MARK: - Break screen: the score reveal in the corner

/// The break is rest: the middle of the screen holds BREAK, the clock and the long-break dots and nothing else.
/// The score reveal is a small card in the top-right corner that fades away 30 s after the break starts, so the
/// last half of the break has nothing to look at.
public enum BreakReveal {
    /// Seconds after the break started when the card starts fading.
    public static let fadeStartsAt: TimeInterval = 30
    public static let fadeDuration: TimeInterval = 1.5

    /// 1 → fully there, 0 → gone. `since` = seconds since the break began.
    public static func opacity(since: TimeInterval) -> Double {
        guard since.isFinite else { return 0 }
        if since < fadeStartsAt { return 1 }
        let t = (since - fadeStartsAt) / fadeDuration
        return max(0, 1 - min(1, t))
    }

    public static func isVisible(since: TimeInterval) -> Bool { opacity(since: since) > 0 }

    /// One quiet line under the card; the numbers themselves live in the day's report.
    public static let footnote = "Review it later in History"
}

// MARK: - Daily hours goal, edited from the top-left label

/// The tiny editor behind the hours label on the black screens: 0.5–16 h, half-hour steps, typed or stepped.
/// `commit` gives the value to send to `POST /admin/focus/settings`; out-of-range input is clamped, nonsense
/// input keeps the current value.
public struct HoursGoalEditor: Equatable, Sendable {
    public static let step = 0.5
    public private(set) var hours: Double
    /// What is in the text field (always in step with `hours` after a bump).
    public private(set) var text: String

    public init(hours: Double) {
        let h = HoursMath.clampGoal(hours)
        self.hours = h
        self.text = HoursGoalEditor.field(h)
    }

    /// "4", "4.5" — no unit, so typing over it is easy.
    public static func field(_ h: Double) -> String {
        h == h.rounded() ? "\(Int(h))" : String(format: "%.1f", h)
    }

    public mutating func bump(_ direction: Int) {
        set(hours + Double(direction) * Self.step)
    }

    public mutating func set(_ h: Double) {
        hours = HoursMath.clampGoal(h)
        text = Self.field(hours)
    }

    /// Typing: accepts "3", "3.5", "3,5"; anything else leaves the goal alone. Returns whether it applied.
    @discardableResult
    public mutating func type(_ raw: String) -> Bool {
        text = raw
        let t = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(t), v.isFinite else { return false }
        hours = HoursMath.clampGoal(v)
        return true
    }

    /// Leaving the field / pressing Enter: the text goes back in step with the (clamped) goal.
    public mutating func commit() -> Double {
        text = Self.field(hours)
        return hours
    }

    /// "of 4 h" — the caption under the big figure, straight away.
    public var caption: String { "of " + HoursMath.hoursText(hours) }
    public var canIncrease: Bool { hours < HoursMath.maxGoalHours }
    public var canDecrease: Bool { hours > HoursMath.minGoalHours }
}

// MARK: - "You moved to another goal" (the server decides)

/// `"goal_changed": {"goal": str, "specific_goal": str}` on a frame or tick reply: he is clearly working on
/// something else, and the brain is already scoring that. The block's goal is replaced (later frames / ticks /
/// the block summary carry the new one) and a blue toast says so.
public struct GoalChange: Equatable, Sendable {
    public var goal: String
    public var specificGoal: String

    public init(goal: String, specificGoal: String = "") {
        self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.specificGoal = specificGoal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil unless there is a real new goal (an empty object, or a string field, is ignored).
    public static func parse(_ json: JSONValue) -> GoalChange? {
        guard let node = json["goal_changed"] else { return nil }
        let goal = node.str("goal")
        let specific = node.str("specific_goal")
        guard !goal.isEmpty else { return nil }
        return GoalChange(goal: goal, specificGoal: specific)
    }

    /// "Looks like you moved to reading Kant — scoring that now"
    public var toastText: String { "Looks like you moved to \(goal) — scoring that now" }

    /// The block's plan after the change: his understood sentence goes (it described the old goal), and so
    /// does the old sharpened goal unless this is the same goal — a new goal with no sharpened goal of its own
    /// goes out with specific "" so the brain works from the goal itself.
    public func applied(to plan: GoalPlan) -> GoalPlan {
        let keep = specificGoal.isEmpty && GoalProgress.sameGoal(goal, plan.goal)
        return GoalPlan(goal: goal, understood: "", specificGoal: keep ? plan.specificGoal : specificGoal)
    }

    /// The same change twice in a row changes nothing.
    public func changes(_ plan: GoalPlan) -> Bool {
        !GoalProgress.sameGoal(goal, plan.goal) || (!specificGoal.isEmpty && !GoalProgress.sameGoal(specificGoal, plan.specificGoal))
    }
}

// MARK: - Owner routes vs friend routes

/// Everything the app sends now goes out over one of two route sets: the owner's secret-prefixed
/// `{base}/t/{token}/admin/focus/...` or a friend's `{base}/lb/focus/...` with an `X-LB-Token` header.
/// A friend's app runs exactly the same session — goal understanding, screenshots, ticks, block
/// scoring, suggestions — only the address differs.
public enum FocusRoute: String, CaseIterable, Sendable {
    case goal, frame, tick, block, event, now, suggestions, settings, leaderboard, history
    /// Once a second during work: what is on the screen as text, for Jev (see Sense.swift).
    case sense
    /// "I'm on task" on a sense nudge (see `ExceptionPayload`).
    case exception

    /// Which of these a friend's app is allowed to call (no sharing, no voice, no invites).
    public var friendCanCall: Bool {
        switch self {
        case .goal, .frame, .tick, .block, .event, .now, .suggestions, .settings, .history, .sense, .exception:
            return true
        case .leaderboard: return false
        }
    }

    public var ownerPath: String {
        switch self {
        case .leaderboard: return "/admin/focus/leaderboard"
        // The owner asks for a window of days; a friend's server decides.
        case .history: return "/admin/focus/history" + FocusHistory.ownerQuery
        default: return "/admin/focus/\(rawValue)"
        }
    }

    public var friendPath: String { "/lb/focus/\(rawValue)" }

    /// Where this call goes, and the headers it needs. Owner config wins; otherwise the friend's token.
    /// Nil when there is nothing to call (no config, or a friend asking for an owner-only route).
    /// `query` is appended as-is ("days=30"); it joins an existing query with `&`.
    public static func target(_ route: FocusRoute, owner: BrainConfig?, friend: FriendConfig?,
                              query: String = "") -> Target? {
        if let owner, let url = owner.url(path: add(query, to: route.ownerPath)) {
            return Target(url: url, headers: [:])
        }
        guard let friend, route.friendCanCall,
              let url = BrainConfig.plainURL(base: friend.baseURL,
                                             path: add(query, to: route.friendPath)) else { return nil }
        return Target(url: url, headers: ["X-LB-Token": friend.token])
    }

    private static func add(_ query: String, to path: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return path }
        return path + (path.contains("?") ? "&" : "?") + q
    }

    public struct Target: Equatable, Sendable {
        public var url: URL
        public var headers: [String: String]
        /// For logs — never the token.
        public var label: String { url.path.contains("/lb/focus/") ? "/lb/focus" + (url.path as NSString).lastPathComponent : "/admin/focus/" + (url.path as NSString).lastPathComponent }
    }
}

// MARK: - The links at the bottom of the goal screen

/// Suggestions · Settings · Friends · History · End session. The first four open a small grey panel (one at
/// a time, all closed every time the goal screen appears); "End session" ends the session.
public enum GoalScreenLink: String, CaseIterable, Equatable, Sendable {
    case suggestions, settings, friends, history
    case endSession

    public var title: String {
        switch self {
        case .suggestions: return "Suggestions"
        case .settings: return "Settings"
        case .friends: return "Friends"
        case .history: return "History"
        case .endSession: return "End session"
        }
    }

    /// True for the four that fold a panel open above the row.
    public var isPanel: Bool {
        switch self {
        case .suggestions, .settings, .friends, .history: return true
        default: return false
        }
    }

    /// What the bottom row shows. `hasSuggestions` hides an empty Suggestions link; only the owner's app
    /// has the voice links.
    public static func row(hasSuggestions: Bool, isOwner: Bool) -> [GoalScreenLink] {
        allCases.filter { link in
            if link == .suggestions { return hasSuggestions }
            return !link.isVoice || isOwner
        }
    }

    /// One of the voice links (always false without them).
    public var isVoice: Bool {
        return false
    }
}
