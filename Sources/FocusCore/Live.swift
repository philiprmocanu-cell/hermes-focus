import Foundation

// Pure logic for the third iteration: hours logged today + the daily goal, progress toward the sharpened goal,
// instant distraction interrupts, the leaderboard and friend mode, and the live `/admin/focus/now` snapshot.

// MARK: - Hours logged today

/// Work seconds finished today (local fallback for the server's `today.focus_s`).
public struct DayFocus: Codable, Equatable, Sendable {
    public var day: String = ""
    public var seconds: Double = 0
    /// Completed work blocks.
    public var blocks: Int = 0

    public init(day: String = "") { self.day = day }

    public mutating func rollover(day today: String) {
        if day != today { self = DayFocus(day: today) }
    }

    /// A work block ended on `day` after `seconds` of (unpaused) work.
    public mutating func record(seconds s: Double, completed: Bool, day today: String) {
        rollover(day: today)
        seconds += max(0, s)
        if completed { blocks += 1 }
    }

    public func seconds(today: String) -> Double { day == today ? seconds : 0 }
    public func blocks(today: String) -> Int { day == today ? blocks : 0 }
}

public enum HoursMath {
    public static let minGoalHours = 0.5
    public static let maxGoalHours = 16.0
    public static let defaultGoalHours = 4.0

    /// Seconds actually worked in a block that just ended: the full length when it ran out, otherwise the
    /// last measured work time (pauses excluded), never more than planned.
    public static func workedSeconds(completed: Bool, planned: TimeInterval, lastKnownWorked: TimeInterval) -> TimeInterval {
        completed ? planned : min(planned, max(0, lastKnownWorked))
    }

    /// Prefer the server's figure for today (it knows about other launches), never show less than what this Mac
    /// recorded, then add the block that is running right now.
    ///
    /// `localAtServer` is this Mac's own total at the moment the server figure was fetched: blocks finished here
    /// since then are added on top of the (now stale) server figure, so a block that just ended counts straight
    /// away even when the server total (other launches) is ahead of this Mac's.
    public static func loggedSeconds(serverFocusS: Double?, serverDay: String?, local: DayFocus, today: String,
                                     running: TimeInterval, localAtServer: Double? = nil) -> Double {
        let localNow = local.seconds(today: today)
        var server = (serverDay == today ? serverFocusS : nil) ?? 0
        if server > 0, let base = localAtServer { server += max(0, localNow - base) }
        return max(server, localNow) + max(0, running)
    }

    /// "2 h 35 m", "35 m", "0 m".
    public static func duration(_ seconds: Double) -> String {
        let m = Int((max(0, seconds) / 60).rounded(.down))
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r) m" }
        return r == 0 ? "\(h) h" : "\(h) h \(r) m"
    }

    public static func loggedText(_ seconds: Double) -> String { duration(seconds) + " logged" }

    /// "4 h", "4.5 h".
    public static func hoursText(_ hours: Double) -> String {
        let h = clampGoal(hours)
        return h == h.rounded() ? "\(Int(h)) h" : String(format: "%.1f h", h)
    }

    public static func goalText(_ hours: Double) -> String { "of \(hoursText(hours)) goal" }

    public static func progress(seconds: Double, goalHours: Double) -> Double {
        let g = clampGoal(goalHours) * 3600
        return min(1, max(0, seconds / g))
    }

    /// 0.5…16 in half-hour steps.
    public static func clampGoal(_ hours: Double) -> Double {
        guard hours.isFinite else { return defaultGoalHours }
        return min(maxGoalHours, max(minGoalHours, (hours * 2).rounded() / 2))
    }
}

// MARK: - Hours label on the black screens

/// Top-left "2 h 35 m / logged today · of 4 h" on the main display's black screens (goal, countdown, break).
public struct OverlayHours: Equatable, Sendable {
    public var seconds: Double
    /// nil = no daily hours goal set (no "of 4 h", no progress line).
    public var goalHours: Double?

    public init(seconds: Double, goalHours: Double?) {
        self.seconds = max(0, seconds.isFinite ? seconds : 0)
        self.goalHours = goalHours.flatMap { $0 > 0 && $0.isFinite ? HoursMath.clampGoal($0) : nil }
    }

    /// Same source as the control window: the server's `today.focus_s` (friends: nil), never less than this
    /// Mac's own total (which already holds a block that just finished), plus the running block's work.
    public static func make(serverFocusS: Double?, serverDay: String?, localAtServer: Double?, local: DayFocus,
                            today: String, running: TimeInterval, goalHours: Double?) -> OverlayHours {
        OverlayHours(seconds: HoursMath.loggedSeconds(serverFocusS: serverFocusS, serverDay: serverDay, local: local,
                                                      today: today, running: running, localAtServer: localAtServer),
                     goalHours: goalHours)
    }

    /// "2 h 35 m"
    public var text: String { HoursMath.duration(seconds) }
    public var caption: String { "logged today" }
    /// "of 4 h" (nil without a goal).
    public var goalText: String? { goalHours.map { "of " + HoursMath.hoursText($0) } }
    public var progress: Double? { goalHours.map { HoursMath.progress(seconds: seconds, goalHours: $0) } }
}

// MARK: - "+N min" landing in the hours label

extension HoursMath {
    /// What the hours label should count up to when a block just ended.
    ///
    /// The server's `today.focus_s` may already include the block that just finished (it was submitted) or not
    /// (it is stale) — so the target is the larger of the server's own figure and this Mac's total including the
    /// block, never the two added together. `before` is the label's figure before the block was recorded.
    public static func addedTotal(serverFocusS: Double?, serverDay: String?, today: String,
                                  before: Double, worked: Double) -> Double {
        let local = max(0, before) + max(0, worked)
        let server = (serverDay == today ? serverFocusS : nil) ?? 0
        return max(server.isFinite ? server : 0, local)
    }
}

/// The "+25 min" hand-off on the break screen, as one small timeline.
///
/// It starts the moment the reveal's chip lands on the top-left hours label: (1) the chip sits in blue beside the
/// label for `chipHold`, (2) the digits count up from the old total to the new one over `countUpDuration` while the
/// chip shrinks and fades into them, (3) it is `done` — the label shows the new total and there is no chip anywhere
/// until the next block ends.
public struct HoursAddition: Equatable, Sendable {
    /// The chip sits beside the label before the digits move.
    public static let chipHold: TimeInterval = 0.6
    /// The digits climb to the new total.
    public static let countUpDuration: TimeInterval = 1.2

    public enum Stage: Equatable, Sendable { case chip, countUp, done }

    /// "+25 min".
    public var addedMinutes: Int
    /// Seconds on the label before the block that just ended.
    public var from: Double
    /// Seconds on the label once the block is counted (never below `from`).
    public var to: Double
    /// When the chip landed.
    public var startedAt: Date

    public init(addedMinutes: Int, from: Double, to: Double, startedAt: Date) {
        self.addedMinutes = max(0, addedMinutes)
        let f = max(0, from.isFinite ? from : 0)
        self.from = f
        self.to = max(f, to.isFinite ? to : f)
        self.startedAt = startedAt
    }

    /// From the block that just ended: `+N min` is always the minutes actually worked (a block stopped early
    /// contributes what it really ran), and the total counted up to never double-adds the server's figure.
    public static func make(before: Double, worked: Double, serverFocusS: Double?, serverDay: String?,
                            today: String, startedAt: Date) -> HoursAddition {
        let w = max(0, worked.isFinite ? worked : 0)
        return HoursAddition(addedMinutes: max(1, Int((w / 60).rounded())),
                             from: before,
                             to: HoursMath.addedTotal(serverFocusS: serverFocusS, serverDay: serverDay,
                                                      today: today, before: before, worked: w),
                             startedAt: startedAt)
    }

    public var countUpStartsAt: TimeInterval { Self.chipHold }
    public var countUpEndsAt: TimeInterval { Self.chipHold + Self.countUpDuration }
    /// The whole sequence, chip landing to chip gone.
    public var duration: TimeInterval { countUpEndsAt }

    public func elapsed(at now: Date) -> TimeInterval { now.timeIntervalSince(startedAt) }

    public func stage(at now: Date) -> Stage {
        let t = elapsed(at: now)
        if t < countUpStartsAt { return .chip }
        return t < countUpEndsAt ? .countUp : .done
    }

    public func isDone(at now: Date) -> Bool { stage(at: now) == .done }

    /// 0…1 through the count-up (0 while the chip is still just sitting there).
    public func countUpProgress(at now: Date) -> Double {
        let t = elapsed(at: now) - countUpStartsAt
        if t <= 0 { return 0 }
        return min(1, t / Self.countUpDuration)
    }

    /// The seconds the label should show right now: the old total, then climbing, then the new total.
    public func seconds(at now: Date) -> Double {
        let p = countUpProgress(at: now)
        // Ease out so the digits sprint and then settle on the last minute.
        let eased = p >= 1 ? 1 : 1 - pow(1 - p, 3)
        return from + (to - from) * eased
    }

    /// "1 h 19 m" → … → "1 h 39 m".
    public func text(at now: Date) -> String { HoursMath.duration(seconds(at: now)) }

    /// The blue line under the label grows with the digits.
    public func progress(at now: Date, goalHours: Double?) -> Double? {
        goalHours.map { HoursMath.progress(seconds: seconds(at: now), goalHours: $0) }
    }

    /// The chip is full size beside the label, then shrinks into the digits and is gone.
    public func chipOpacity(at now: Date) -> Double {
        let t = elapsed(at: now)
        if t < 0 { return 0 }
        if t < countUpStartsAt { return 1 }
        // Fade over the first half of the count-up: it is absorbed well before the digits settle.
        return max(0, 1 - countUpProgress(at: now) / 0.5)
    }

    public func chipScale(at now: Date) -> Double {
        let t = elapsed(at: now)
        if t < countUpStartsAt { return 1 }
        return max(0.4, 1 - 0.6 * min(1, countUpProgress(at: now) / 0.5))
    }
}

// MARK: - Progress toward the goal

/// One number, 0..1: how far along the sharpened goal he is (from frame replies and `/now`).
public enum GoalProgress {
    /// Within one block the bar only moves forward: a later screenshot of other work doesn't take ground back.
    public static func merge(_ current: Double?, _ incoming: Double?) -> Double? {
        guard let i = incoming.flatMap({ $0.isFinite ? min(1, max(0, $0)) : nil }) else { return current }
        return max(current ?? 0, i)
    }

    /// `/now` progress only applies when it is about the same goal as this Mac's block.
    public static func sameGoal(_ a: String, _ b: String) -> Bool {
        func k(_ s: String) -> String {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        }
        let x = k(a), y = k(b)
        return !x.isEmpty && x == y
    }

    /// "40% of the way there".
    public static func text(_ p: Double) -> String {
        let pct = Int((min(1, max(0, p)) * 100).rounded())
        return pct >= 100 ? "Done — nice." : "\(pct)% of the way there"
    }
}

// MARK: - Distractions

/// Clear distractions, spotted from the front app or the browser tab URL.
public enum Distraction {
    public struct Site: Sendable {
        public let label: String
        public let domains: [String]
        /// Only URLs whose path starts with this count ("" = the whole site).
        public let pathPrefix: String
        /// A goal mentioning any of these exempts the site.
        public let exemptWords: [String]
        public let social: Bool
    }

    /// Kept as one list so it's easy to read and change.
    public static let sites: [Site] = [
        Site(label: "Instagram", domains: ["instagram.com"], pathPrefix: "", exemptWords: ["instagram", "reels"], social: true),
        Site(label: "TikTok", domains: ["tiktok.com"], pathPrefix: "", exemptWords: ["tiktok", "tik tok"], social: true),
        Site(label: "Facebook", domains: ["facebook.com", "fb.com"], pathPrefix: "", exemptWords: ["facebook"], social: true),
        Site(label: "X", domains: ["x.com", "twitter.com"], pathPrefix: "", exemptWords: ["twitter", "tweet", "x.com", "x post", "x thread"], social: true),
        Site(label: "Reddit", domains: ["reddit.com"], pathPrefix: "", exemptWords: ["reddit", "subreddit"], social: true),
        Site(label: "YouTube Shorts", domains: ["youtube.com"], pathPrefix: "/shorts", exemptWords: ["shorts"], social: true),
        Site(label: "Netflix", domains: ["netflix.com"], pathPrefix: "", exemptWords: ["netflix"], social: false),
        Site(label: "Twitch", domains: ["twitch.tv"], pathPrefix: "", exemptWords: ["twitch", "livestream"], social: false),
        Site(label: "Snapchat", domains: ["snapchat.com"], pathPrefix: "", exemptWords: ["snapchat"], social: true),
        Site(label: "Discord", domains: ["discord.com", "discord.gg", "discordapp.com"], pathPrefix: "", exemptWords: ["discord"], social: false),
    ]

    /// Native apps (matched on the app name).
    public static let apps: [String: String] = [
        "netflix": "Netflix", "discord": "Discord", "snapchat": "Snapchat", "tiktok": "TikTok",
        "instagram": "Instagram", "twitch": "Twitch", "facebook": "Facebook", "reddit": "Reddit",
    ]

    /// Words that make regular YouTube part of the work.
    public static let videoWords = ["youtube", "video", "lecture", "tutorial", "course", "lesson", "podcast",
                                    "documentary", "thumbnail"]

    static let stopWords: Set<String> = ["with", "that", "this", "from", "into", "about", "work", "working", "finish",
                                         "start", "make", "doing", "some", "more", "then", "your", "have", "will",
                                         "google", "chrome", "safari", "youtube"]

    /// The label to toast ("Instagram"), or nil when the front thing is fine. `goal` = everything he said
    /// about the block (typed goal + sharpened goal + understood sentence).
    public static func classify(_ ctx: AppContext, goal: String) -> String? {
        let g = " " + goal.lowercased() + " "
        func exempt(_ words: [String], social: Bool) -> Bool {
            if social && (g.contains("social media") || g.contains("socials")) { return true }
            return words.contains { g.contains($0) }
        }

        if let label = apps[ctx.app.lowercased()] {
            let site = sites.first { $0.label == label }
            return exempt(site?.exemptWords ?? [label.lowercased()], social: site?.social ?? false) ? nil : label
        }

        guard let (host, path) = hostAndPath(ctx.url) else { return nil }
        for site in sites where site.domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            guard site.pathPrefix.isEmpty || path.hasPrefix(site.pathPrefix) else { continue }
            return exempt(site.exemptWords, social: site.social) ? nil : site.label
        }
        // Regular YouTube: a distraction unless the goal relates to it.
        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if exempt(videoWords, social: false) { return nil }
            if path.hasPrefix("/watch") || host == "youtu.be", titleRelates(ctx.title, goal: goal) { return nil }
            return "YouTube"
        }
        return nil
    }

    /// The video's title shares a real word with the goal ("Fourier transform" goal, "Fourier series explained").
    static func titleRelates(_ title: String, goal: String) -> Bool {
        let words = significantWords(goal)
        guard !words.isEmpty else { return false }
        return !words.isDisjoint(with: significantWords(title))
    }

    static func significantWords(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) })
    }

    static func hostAndPath(_ raw: String) -> (String, String)? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let withScheme = t.contains("://") ? t : "https://" + t
        guard let c = URLComponents(string: withScheme), var host = c.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return (host, c.path.lowercased())
    }

    /// "Instagram isn't maths sheet 4 — back to it."
    public static func toastText(label: String, goal: String) -> String {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return g.isEmpty ? "\(label) isn't the plan — back to it." : "\(label) isn't \(g) — back to it."
    }
}

/// Turns samples of "what's in front" into toasts and distraction seconds.
/// A distraction must be seen on two samples in a row (the browser URL can lag one sample), then it toasts
/// at once and again every 60 s while it stays in front.
public struct DistractionTracker: Equatable, Sendable {
    public static let repeatInterval: TimeInterval = 60
    public static let confirmSamples = 2
    /// Longer gaps (sleep, pause) are not counted as distraction time.
    public static let maxGap: TimeInterval = 10
    /// How often the app samples during work.
    public static let sampleInterval: TimeInterval = 3

    public private(set) var current: String?
    public private(set) var streak = 0
    /// Distraction seconds since the last `reset()`.
    public private(set) var seconds: Double = 0
    private var lastSampleAt: TimeInterval?
    private var lastToastAt: TimeInterval = -.infinity

    public init() {}

    /// Returns the label to toast now, if any.
    public mutating func observe(_ label: String?, now: TimeInterval) -> String? {
        defer { lastSampleAt = now }
        guard let label else {
            current = nil; streak = 0
            return nil
        }
        if label == current {
            streak += 1
            if let last = lastSampleAt, now - last <= Self.maxGap, now > last { seconds += now - last }
        } else {
            current = label
            streak = 1
            lastToastAt = -.infinity
        }
        guard streak >= Self.confirmSamples, now - lastToastAt >= Self.repeatInterval else { return nil }
        lastToastAt = now
        return label
    }

    /// Forget the streak and the time between samples (pause / block end); keeps nothing.
    public mutating func reset() { self = DistractionTracker() }
}

// MARK: - Relevance before the note

/// The user's rulebook, 2026-09-22: "before noting, check whether the site serves the goal (e.g. Discord
/// with teammates about the work) — if it does, no note." The app cannot read the screen; the brain's
/// screenshot judge can, and it answers `serves_goal` on every frame.
///
/// So the toast for a distraction-list site is HELD instead of fired: the next frame verdict arrives
/// within about a minute and decides. `serves_goal` true → no toast, and the seconds it took are not
/// counted as distraction either (and that site stays cleared for the rest of the block). Anything else
/// → the toast fires then, with the seconds it was in front.
///
/// Instagram and TikTok are the exception and stay instant: nothing on them serves a goal that does not
/// literally name them, and `Distraction.classify` already returns nil when the goal does.
public struct DistractionGate: Equatable, Sendable {
    /// Toasted the moment the tracker confirms them, with no wait for the judge.
    public static let instantLabels: Set<String> = ["Instagram", "TikTok"]
    /// A held toast waits no longer than this for a verdict (frames come every ~60 s), then fires anyway.
    public static let maxHold: TimeInterval = 75

    /// What the caller should do with this sample.
    public enum Outcome: Equatable, Sendable {
        /// Nothing in front worth a thought.
        case none
        /// Count these distraction seconds; say nothing.
        case counted(Double)
        /// Toast this label and count these seconds.
        case toast(String, Double)
        /// Seconds parked, waiting on the screenshot judge.
        case held
        /// The judge said it serves the goal: forget these seconds, say nothing.
        case dropped(Double)
    }

    public private(set) var heldLabel: String?
    public private(set) var heldSince: TimeInterval = 0
    public private(set) var heldSeconds: Double = 0
    /// The tracker wanted to toast while the label was held.
    public private(set) var wantsToast = false
    /// Labels a verdict cleared for the rest of this block.
    public private(set) var serving: Set<String> = []

    public init() {}

    public static func isInstant(_ label: String) -> Bool { instantLabels.contains(label) }

    /// One sample. `label` is what `Distraction.classify` saw (nil = fine), `toastNow` is what
    /// `DistractionTracker.observe` returned, `seconds` the distraction time this sample added.
    public mutating func sample(label: String?, toastNow: String?, seconds: Double,
                                now: TimeInterval) -> Outcome {
        guard let label else { return release() }
        // He moved from one held site straight to another: settle the first one
        // (this sample's few seconds go with it) and hold the new one next time.
        if label != heldLabel, heldLabel != nil {
            heldSeconds += max(0, seconds)
            return release()
        }
        if serving.contains(label) { return .dropped(max(0, seconds)) }
        if Self.isInstant(label) {
            return toastNow != nil ? .toast(label, max(0, seconds)) : .counted(max(0, seconds))
        }
        if heldLabel == nil {
            heldLabel = label
            heldSince = now
            heldSeconds = 0
            wantsToast = false
        }
        heldSeconds += max(0, seconds)
        if toastNow != nil { wantsToast = true }
        return .held
    }

    /// A frame verdict came back while something was held.
    public mutating func frameVerdict(servesGoal: Bool?) -> Outcome {
        guard let label = heldLabel else { return .none }
        let seconds = heldSeconds, wanted = wantsToast
        clearHold()
        if servesGoal == true {
            serving.insert(label)
            return .dropped(seconds)
        }
        return wanted ? .toast(label, seconds) : .counted(seconds)
    }

    /// No verdict came back in time — the note must not wait forever.
    public mutating func expire(now: TimeInterval) -> Outcome {
        guard heldLabel != nil, now - heldSince >= Self.maxHold else { return .none }
        return frameVerdict(servesGoal: false)
    }

    /// He left the site before anything decided: keep the seconds, say nothing.
    private mutating func release() -> Outcome {
        guard heldLabel != nil else { return .none }
        let seconds = heldSeconds
        clearHold()
        return seconds > 0 ? .counted(seconds) : .none
    }

    private mutating func clearHold() {
        heldLabel = nil
        heldSince = 0
        heldSeconds = 0
        wantsToast = false
    }

    /// Block end, pause, or a new goal: nothing is held and nothing is cleared any more.
    public mutating func reset() { self = DistractionGate() }
}

// MARK: - Friend mode

/// `~/Library/Application Support/HermesFocus/friend.json` (0600).
public struct FriendConfig: Codable, Equatable, Sendable {
    public var baseURL: String
    public var token: String
    public var name: String

    public init(baseURL: String, token: String, name: String) {
        self.baseURL = baseURL; self.token = token; self.name = name
    }

    enum CodingKeys: String, CodingKey { case baseURL = "base_url", token, name }

    public static func load(from url: URL) -> FriendConfig? {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(FriendConfig.self, from: data),
              !c.token.isEmpty else { return nil }
        return c
    }

    /// Written atomically, readable only by him.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Owner (the user: the bridge `.env` exists) → full app. Otherwise friend mode: joined or not yet.
public enum AppMode: Equatable, Sendable {
    case owner
    case friend(FriendConfig)
    case needsJoin

    public static func resolve(ownerEnvExists: Bool, friend: FriendConfig?) -> AppMode {
        if ownerEnvExists { return .owner }
        if let friend { return .friend(friend) }
        return .needsJoin
    }

    public var isOwner: Bool { self == .owner }
    public var friend: FriendConfig? { if case .friend(let f) = self { return f }; return nil }
}

/// `POST /lb/join`
public struct LBJoinRequest: Codable, Equatable, Sendable {
    public var code: String
    public var name: String
    public init(code: String, name: String) {
        self.code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `{"token","name"}` → the config to store (nil without a token).
    public static func config(from json: JSONValue, baseURL: String, fallbackName: String) -> FriendConfig? {
        let token = json.str("token")
        guard !token.isEmpty else { return nil }
        let name = json.str("name")
        var b = baseURL.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        return FriendConfig(baseURL: b.isEmpty ? BrainConfig.defaultBaseURL : b, token: token,
                            name: name.isEmpty ? fallbackName : name)
    }
}

/// `POST /lb/report`
public struct LBReport: Codable, Equatable, Sendable {
    public var token: String
    public var day: String
    public var focusS: Int
    public var blocks: Int
    public init(token: String, day: String, focusS: Int, blocks: Int) {
        self.token = token; self.day = day; self.focusS = focusS; self.blocks = blocks
    }
    enum CodingKeys: String, CodingKey { case token, day, focusS = "focus_s", blocks }
}

/// When a friend's app reports: after every completed block, and every 5 min of work.
public enum LBReportSchedule {
    public static let interval: TimeInterval = 300
}

// MARK: - Leaderboard

public struct LeaderboardRow: Equatable, Sendable, Identifiable {
    public var rank: Int
    public var name: String
    public var todayS: Double
    public var weekS: Double
    public var blocksToday: Int
    public var me: Bool
    /// Today's average block score, 1–1000. Only the user's own row carries one (rulebook 2026-09-22:
    /// his score may be visible to his brother); every friend's row leaves it nil.
    public var scoreToday: Int?
    /// OUTPUT: the average `output_score` of today's blocks (1–1000), and of this week's. Every row may carry
    /// them (friends included); nil = the server sent none (older server, or no scored block yet).
    public var outputToday: Int?
    public var outputWeek: Int?
    public var id: String { "\(rank)-\(name)" }

    public init(rank: Int = 0, name: String, todayS: Double, weekS: Double, blocksToday: Int, me: Bool,
                scoreToday: Int? = nil, outputToday: Int? = nil, outputWeek: Int? = nil) {
        self.rank = rank; self.name = name; self.todayS = todayS; self.weekS = weekS
        self.blocksToday = blocksToday; self.me = me; self.scoreToday = scoreToday
        self.outputToday = outputToday; self.outputWeek = outputWeek
    }

    /// "742", or "—" when there is no output score.
    public var outputText: String { outputToday.map(String.init) ?? "—" }
}

/// The board's sort toggle: "Hardest working" (hours today, then this week) or "Most output" (today's average
/// output score, then this week's, then hours; rows with no score go last).
public enum LeaderboardSort: String, CaseIterable, Sendable {
    case hours, output

    public var title: String {
        switch self {
        case .hours: return "Hardest working"
        case .output: return "Most output"
        }
    }

    /// Unknown or missing stored value → hours (the board as it always was).
    public init(stored: String?) { self = stored.flatMap(LeaderboardSort.init(rawValue:)) ?? .hours }
}

public enum Leaderboard {
    /// `{"rows": [...], "updated_at"}` or a bare array. Sorted by today, then week, then name; ranked 1…n
    /// (ties on today+week share a rank).
    public static func parse(_ json: JSONValue) -> [LeaderboardRow] {
        let list = json["rows"]?.arrayValue ?? json.arrayValue ?? []
        let rows = list.compactMap { r -> LeaderboardRow? in
            let name = r.str("name")
            guard !name.isEmpty else { return nil }
            func num(_ k: String) -> Double { max(0, r[k]?.doubleValue.flatMap { $0.isFinite ? $0 : nil } ?? 0) }
            func score(_ k: String) -> Int? {
                r[k]?.doubleValue.flatMap { $0.isFinite && $0 >= 1 ? min(1000, Int($0.rounded())) : nil }
            }
            return LeaderboardRow(name: name, todayS: num("today_s"), weekS: num("week_s"),
                                  blocksToday: Int(num("blocks_today")), me: r["me"]?.boolValue ?? false,
                                  scoreToday: score("score_today"),
                                  outputToday: score("output_today"), outputWeek: score("output_week"))
        }
        return rank(rows)
    }

    /// Sorted and ranked 1…n by `sort` (ties on both of its keys share a rank).
    public static func rank(_ rows: [LeaderboardRow], by sort: LeaderboardSort = .hours) -> [LeaderboardRow] {
        let sorted = rows.sorted { a, b in
            if sort == .output {
                // A missing score counts as below any score.
                let ao = a.outputToday ?? 0, bo = b.outputToday ?? 0
                if ao != bo { return ao > bo }
                let aw = a.outputWeek ?? 0, bw = b.outputWeek ?? 0
                if aw != bw { return aw > bw }
            }
            if a.todayS != b.todayS { return a.todayS > b.todayS }
            if a.weekS != b.weekS { return a.weekS > b.weekS }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        func tied(_ a: LeaderboardRow, _ b: LeaderboardRow) -> Bool {
            switch sort {
            case .hours: return a.todayS == b.todayS && a.weekS == b.weekS
            case .output: return a.outputToday == b.outputToday && a.outputWeek == b.outputWeek
                && (a.outputToday != nil || (a.todayS == b.todayS && a.weekS == b.weekS))
            }
        }
        var out: [LeaderboardRow] = []
        for (i, var r) in sorted.enumerated() {
            if let prev = out.last, tied(prev, r) { r.rank = prev.rank } else { r.rank = i + 1 }
            out.append(r)
        }
        return out
    }
}

/// `POST /admin/focus/settings`
public struct FocusSettings: Codable, Equatable, Sendable {
    public var dailyHoursGoal: Double
    public init(dailyHoursGoal: Double) { self.dailyHoursGoal = HoursMath.clampGoal(dailyHoursGoal) }
    enum CodingKeys: String, CodingKey { case dailyHoursGoal = "daily_hours_goal" }
}

// MARK: - Live snapshot

/// `GET /admin/focus/now` — every field optional.
public struct NowSnapshot: Equatable, Sendable {
    public struct Today: Equatable, Sendable {
        public var focusS: Double?
        public var blocks: Int?
        public var avgScore: Int?
        public var goalHours: Double?
        public var progress: Double?
    }

    public var active: Bool
    public var phase: String
    public var goal: String
    public var specificGoal: String
    public var goalProgress: Double?
    public var tip: String
    public var blockEndsAt: Double?
    public var today: Today
    /// The running block's rubric (`{"md","balance"}`, milestones if sent); nil = none.
    public var rubric: Rubric? = nil
    /// `milestones_reached` (top level or inside `rubric`): ids, texts or 1-based numbers. Nil = not sent.
    public var milestonesReached: [String]? = nil

    public static func parse(_ json: JSONValue) -> NowSnapshot? {
        guard case .object = json else { return nil }
        let t = json["today"] ?? .object([:])
        func num(_ k: String) -> Double? { t[k]?.doubleValue.flatMap { $0.isFinite ? $0 : nil } }
        let today = Today(focusS: num("focus_s").map { max(0, $0) }, blocks: num("blocks").map { Int($0) },
                          avgScore: num("avg_score").map { Int($0.rounded()) },
                          goalHours: num("goal_hours").flatMap { $0 > 0 ? HoursMath.clampGoal($0) : nil },
                          progress: num("progress").map { min(1, max(0, $0)) })
        return NowSnapshot(active: json["active"]?.boolValue ?? false, phase: json.str("phase"), goal: json.str("goal"),
                           specificGoal: json.str("specific_goal"),
                           goalProgress: json["goal_progress"]?.doubleValue.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil },
                           tip: json.str("tip"),
                           blockEndsAt: json["block_ends_at"]?.doubleValue, today: today,
                           rubric: Rubric.parse(json["rubric"]),
                           milestonesReached: reachedList(json["milestones_reached"] ?? json["rubric"]?["milestones_reached"]))
    }

    static func reachedList(_ json: JSONValue?) -> [String]? {
        guard let list = json?.arrayValue else { return nil }
        return list.compactMap { v -> String? in
            if let n = v.doubleValue, v.stringValue == nil { return n.isFinite ? String(Int(n)) : nil }
            let t = (v.stringValue ?? v["id"]?.stringValue ?? v["text"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }
}

// MARK: - Long break

/// After 2 HOURS of work since the last long break, the break is the long one (4× the short break, at least
/// 15 min). The user's rulebook, 2026-09-22: "long break comes after 2 HOURS of work only — not after 4 blocks",
/// so four short 15-minute blocks no longer earn one and a single long stretch does. Ending the session, or
/// 25+ min away (idle or asleep), resets the count (being away IS the long break). Skipping short breaks
/// doesn't. Test mode scales the 2 h by the same factor as the blocks (`scale` = base block / 25 min).
public struct LongBreak: Codable, Equatable, Sendable {
    public static let standardWork: TimeInterval = 2 * 3600
    public static let standardAway: TimeInterval = 25 * 60

    public private(set) var blocks = 0
    public private(set) var worked: TimeInterval = 0

    public init() {}

    public func isDue(scale: Double) -> Bool {
        worked >= Self.standardWork * scale - 0.5
    }

    /// Asked when a block starts: will its break be the long one if he finishes it?
    public func wouldBeDue(afterBlock seconds: TimeInterval, scale: Double) -> Bool {
        var c = self
        c.recordBlock(worked: seconds)
        return c.isDue(scale: scale)
    }

    public mutating func recordBlock(worked s: TimeInterval) {
        blocks += 1
        worked += max(0, s)
    }

    /// Session ended, or the long break was taken.
    public mutating func reset() { self = LongBreak() }

    /// He's been away (no input, or the Mac asleep) this long. Returns true when that reset the count.
    @discardableResult
    public mutating func noteAway(seconds: TimeInterval, scale: Double) -> Bool {
        guard seconds >= Self.standardAway * scale, blocks > 0 || worked > 0 else { return false }
        reset()
        return true
    }

    /// How far through the two hours he is, 0…1 — what the small line under the timer fills.
    public func progress(scale: Double) -> Double {
        let whole = Self.standardWork * max(0.0001, scale.isFinite ? scale : 1)
        return min(1, max(0, worked / whole))
    }

    /// "1 h 20 of 2 h until your long break" — real minutes, so test mode reads the same.
    public func progressText(scale: Double = 1) -> String {
        let s = max(0.0001, scale.isFinite ? scale : 1)
        let done = HoursMath.duration(min(Self.standardWork, max(0, worked) / s))
        return "\(done) of \(HoursMath.duration(Self.standardWork)) until your long break"
    }
}

// MARK: - Block length (chosen on the goal screen)

/// Pills 15 / 25 / 45 / 60 + a custom 5–60 min field. Every goal screen starts at 25; the brain's
/// `next_work_s` is only a suggestion chip that selects its length when clicked.
public struct BlockLengthChoice: Equatable, Sendable {
    public struct Suggestion: Equatable, Sendable {
        public var minutes: Int
        public var reason: String
        public init(minutes: Int, reason: String) { self.minutes = minutes; self.reason = reason }
    }

    public static let presets = [15, 25, 45, 60]
    public static let defaultMinutes = 25
    public static let customRange = 5...60

    public private(set) var minutes = BlockLengthChoice.defaultMinutes
    public private(set) var isCustom = false
    public let suggestion: Suggestion?

    /// A fresh goal screen: always 25, whatever was chosen last time.
    public init(suggestion: Suggestion? = nil) {
        self.suggestion = suggestion.flatMap { $0.minutes == Self.defaultMinutes ? nil : $0 }
    }

    public mutating func select(_ m: Int) {
        minutes = Self.clamp(m)
        isCustom = !Self.presets.contains(minutes)
    }

    /// Custom field text; ignored unless it's a whole number (then clamped to 5–60). Returns whether it applied.
    @discardableResult
    public mutating func setCustom(_ text: String) -> Bool {
        guard let m = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        minutes = Self.clamp(m)
        isCustom = true
        return true
    }

    public mutating func applySuggestion() {
        guard let s = suggestion else { return }
        select(s.minutes)
    }

    public static func clamp(_ m: Int) -> Int { min(customRange.upperBound, max(customRange.lowerBound, m)) }

    /// Block seconds; `scale` = base block / 25 min (1 normally, 0.04 in test mode).
    public func seconds(scale: Double) -> TimeInterval {
        max(1, (Double(minutes) * 60 * scale).rounded())
    }

    /// "Suggested: 15 min — your focus slipped around minute 18".
    public var chipText: String? {
        guard let s = suggestion else { return nil }
        let r = s.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? "Suggested: \(s.minutes) min" : "Suggested: \(s.minutes) min — \(r)"
    }

    /// The brain's `next_work_s` (in this session's seconds) as a suggestion in real minutes.
    public static func suggestion(from advice: NextBlockAdvice, scale: Double) -> Suggestion {
        let m = Double(advice.workSeconds) / 60 / max(0.0001, scale)
        return Suggestion(minutes: clamp(Int(m.rounded())), reason: advice.reason)
    }
}

/// The last suggestion, kept for the next goal screen the same day.
public struct StoredSuggestion: Codable, Equatable, Sendable {
    public var minutes: Int
    public var reason: String
    public var day: String
    public init(minutes: Int, reason: String, day: String) { self.minutes = minutes; self.reason = reason; self.day = day }

    public func suggestion(today: String) -> BlockLengthChoice.Suggestion? {
        day == today ? .init(minutes: minutes, reason: reason) : nil
    }
}

// MARK: - Suggested blocks (goal screen)

/// `GET /admin/focus/suggestions` → `{"suggestions":[{"goal","specific_goal","minutes","why","source"}]}`.
public struct BlockSuggestion: Equatable, Sendable, Identifiable {
    public var goal: String
    public var specificGoal: String
    /// Clamped to 5–60; 25 when missing.
    public var minutes: Int
    public var why: String
    public var source: String
    public var id: String { goal + "|" + String(minutes) }

    public init(goal: String, specificGoal: String = "", minutes: Int = BlockLengthChoice.defaultMinutes,
                why: String = "", source: String = "") {
        self.goal = goal; self.specificGoal = specificGoal; self.minutes = minutes; self.why = why; self.source = source
    }

    public static let maxShown = 5

    /// At most 5, in the server's order; entries without a goal (or repeats) are dropped.
    public static func parse(_ json: JSONValue) -> [BlockSuggestion] {
        let list = json["suggestions"]?.arrayValue ?? json.arrayValue ?? []
        var out: [BlockSuggestion] = []
        for v in list {
            let goal = v.str("goal")
            guard !goal.isEmpty, !out.contains(where: { $0.goal.lowercased() == goal.lowercased() }) else { continue }
            let m = v["minutes"]?.doubleValue.flatMap { $0.isFinite ? Int($0.rounded()) : nil }
            out.append(BlockSuggestion(goal: goal, specificGoal: v.str("specific_goal"),
                                       minutes: m.map(BlockLengthChoice.clamp) ?? BlockLengthChoice.defaultMinutes,
                                       why: v.str("why"), source: v.str("source")))
            if out.count == maxShown { break }
        }
        return out
    }
}

/// The suggestions on the goal screen and which one ↓ / ↑ highlight (Enter on a highlighted row picks it).
public struct SuggestionPicker: Equatable, Sendable {
    public private(set) var items: [BlockSuggestion]
    public private(set) var highlighted: Int?

    public init(items: [BlockSuggestion] = []) { self.items = items }

    public var isEmpty: Bool { items.isEmpty }
    public var highlightedItem: BlockSuggestion? { highlighted.map { items[$0] } }

    /// ↓: first press highlights the first card; stops at the last.
    public mutating func moveDown() {
        guard !items.isEmpty else { return }
        highlighted = min(items.count - 1, (highlighted ?? -1) + 1)
    }

    /// ↑: back up; above the first card the highlight goes away (back to the field).
    public mutating func moveUp() {
        guard let h = highlighted else { return }
        highlighted = h == 0 ? nil : h - 1
    }

    public mutating func clearHighlight() { highlighted = nil }

    /// What a pick does: the field gets the goal, the length picker its minutes (both still editable).
    public static func apply(_ s: BlockSuggestion, to length: inout BlockLengthChoice) -> String {
        length.select(s.minutes)
        return s.goal
    }
}

// MARK: - Goal screen disclosures

/// The minimal goal screen: only the question and the field in the middle. Small grey links sit at the very
/// bottom — Suggestions · Settings · Friends · History · … · End session; the first four fold a panel open.
/// All panels start CLOSED every time
/// the goal screen appears, and at most one is open at a time. ↓ from the field opens Suggestions and walks its rows,
/// ↑ walks back, Enter on a highlighted row picks it, Esc closes whatever is open (and only then ends the session).
public struct GoalScreenDisclosure: Equatable, Sendable {
    public private(set) var suggestionsOpen = false
    public private(set) var settingsOpen = false
    /// The Friends panel (the leaderboard).
    public private(set) var friendsOpen = false
    /// The History panel (the last 30 days, newest first).
    public private(set) var historyOpen = false

    /// A fresh goal screen: all closed.
    public init() {}

    public var anyOpen: Bool { suggestionsOpen || settingsOpen || friendsOpen || historyOpen }

    /// Which panel is open, if any.
    public var open: GoalScreenLink? {
        if suggestionsOpen { return .suggestions }
        if settingsOpen { return .settings }
        if friendsOpen { return .friends }
        if historyOpen { return .history }
        return nil
    }

    /// Click on one of the three panel links: it opens (closing the others), or closes if it was open.
    public mutating func toggle(_ link: GoalScreenLink, _ picker: inout SuggestionPicker) {
        switch link {
        case .suggestions: toggleSuggestions(&picker)
        case .settings: toggleSettings(&picker)
        case .friends: toggleFriends(&picker)
        case .history: toggleHistory(&picker)
        // End session (and any other link) opens no panel.
        default: break
        }
    }

    public mutating func toggleSuggestions(_ picker: inout SuggestionPicker) {
        if suggestionsOpen { closeSuggestions(&picker) } else if !picker.isEmpty {
            suggestionsOpen = true; settingsOpen = false; friendsOpen = false; historyOpen = false
        }
    }

    public mutating func toggleFriends(_ picker: inout SuggestionPicker) {
        if friendsOpen { friendsOpen = false } else {
            closeSuggestions(&picker); settingsOpen = false; historyOpen = false; friendsOpen = true
        }
    }

    public mutating func toggleSettings(_ picker: inout SuggestionPicker) {
        if settingsOpen { settingsOpen = false } else {
            closeSuggestions(&picker); friendsOpen = false; historyOpen = false; settingsOpen = true
        }
    }

    public mutating func toggleHistory(_ picker: inout SuggestionPicker) {
        if historyOpen { historyOpen = false } else {
            closeSuggestions(&picker); settingsOpen = false; friendsOpen = false; historyOpen = true
        }
    }

    public mutating func closeSuggestions(_ picker: inout SuggestionPicker) {
        suggestionsOpen = false
        picker.clearHighlight()
    }

    /// ↓ from the field: opens Suggestions (closing Settings) and moves down a row. False = not handled.
    public mutating func keyDown(_ picker: inout SuggestionPicker) -> Bool {
        guard !picker.isEmpty else { return false }
        suggestionsOpen = true
        settingsOpen = false
        friendsOpen = false
        historyOpen = false
        picker.moveDown()
        return true
    }

    /// ↑: back up a row while Suggestions is open (above the first row = back in the field, list stays open).
    public mutating func keyUp(_ picker: inout SuggestionPicker) -> Bool {
        guard suggestionsOpen, picker.highlighted != nil else { return false }
        picker.moveUp()
        return true
    }

    /// Enter: the highlighted row when Suggestions is open (nil = Enter submits the field as usual).
    public func enter(_ picker: SuggestionPicker) -> BlockSuggestion? {
        suggestionsOpen ? picker.highlightedItem : nil
    }

    /// Esc: closes whatever is open. False = nothing was open (Esc ends the session as before).
    public mutating func escape(_ picker: inout SuggestionPicker) -> Bool {
        guard anyOpen else { return false }
        closeSuggestions(&picker)
        settingsOpen = false
        friendsOpen = false
        historyOpen = false
        return true
    }

    /// A suggestion was picked: fill the field and the length, close the list. Returns the goal text.
    public mutating func pick(_ s: BlockSuggestion, picker: inout SuggestionPicker,
                              length: inout BlockLengthChoice) -> String {
        closeSuggestions(&picker)
        return SuggestionPicker.apply(s, to: &length)
    }
}
