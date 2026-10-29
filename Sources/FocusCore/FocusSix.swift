import Foundation

// Pure logic for the sixth iteration: breaks that scale with the block that just finished, and the
// day-by-day history behind the goal screen's "History" link and the control window's History tab.

// MARK: - Breaks scale with the block

/// The break is a fifth of the block that just ended, rounded to the nearest minute and never under 3 min
/// (25 → 5, 50 → 10, 12.5 → 3, 60 → 12). The long break — after 2 h of work — is four of those, never
/// under 15 min (25-minute blocks → 20 min, 50 → 40).
///
/// Everything is worked out in *real* minutes: `scale` (this session's base block ÷ 25 min, 0.04 in test
/// mode) is divided out first and multiplied back in at the end, so test mode is the same rule, shrunk.
public enum BreakLength {
    /// The block is divided by this to get the short break.
    public static let divisor = 5.0
    /// Shortest short break, real minutes.
    public static let shortFloorMinutes = 3.0
    /// The long break is this many short breaks.
    public static let longMultiplier = 4.0
    /// Shortest long break, real minutes.
    public static let longFloorMinutes = 15.0

    /// Short break in real minutes for a block of `workMinutes` real minutes.
    public static func shortMinutes(workMinutes: Double) -> Double {
        guard workMinutes.isFinite, workMinutes > 0 else { return shortFloorMinutes }
        return max(shortFloorMinutes, (workMinutes / divisor).rounded())
    }

    /// Long break in real minutes for a block of `workMinutes` real minutes.
    public static func longMinutes(workMinutes: Double) -> Double {
        max(longFloorMinutes, shortMinutes(workMinutes: workMinutes) * longMultiplier)
    }

    /// Short break in this session's seconds for a block of `work` seconds.
    public static func short(work: TimeInterval, scale: Double = 1) -> TimeInterval {
        seconds(shortMinutes(workMinutes: realMinutes(work, scale)), scale)
    }

    /// Long break in this session's seconds for a block of `work` seconds.
    public static func long(work: TimeInterval, scale: Double = 1) -> TimeInterval {
        seconds(longMinutes(workMinutes: realMinutes(work, scale)), scale)
    }

    static func realMinutes(_ work: TimeInterval, _ scale: Double) -> Double {
        guard work.isFinite, work > 0 else { return 0 }
        return work / 60 / max(0.0001, scale.isFinite ? scale : 1)
    }

    static func seconds(_ minutes: Double, _ scale: Double) -> TimeInterval {
        max(1, (minutes * 60 * max(0.0001, scale.isFinite ? scale : 1)).rounded())
    }
}

// MARK: - History (the last 30 days)

/// `GET /admin/focus/history?days=30` (friends: `GET /lb/focus/history`) →
/// `{"days":[{"day","weekday","focus_s","blocks","avg_score","verdict","day_score","doc_url"}]}`.
/// Every field but `day` is optional — an older server, or a day the brain never judged, simply shows less.
public struct HistoryDay: Equatable, Sendable, Identifiable {
    /// The brain's verdict for the day. Proud is blue, Solid grey, Under orange.
    public enum Verdict: String, Equatable, Sendable, CaseIterable {
        case proud, solid, under

        public var title: String {
            switch self {
            case .proud: return "Proud"
            case .solid: return "Solid"
            case .under: return "Under"
            }
        }

        /// "proud" / "Proud" / " PROUD " all land here; anything else is nil.
        public static func parse(_ raw: String) -> Verdict? {
            Verdict(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    /// "YYYY-MM-DD".
    public var day: String
    /// The server's weekday name ("" when it didn't send one).
    public var weekday: String
    public var focusS: Double
    public var blocks: Int
    public var avgScore: Int?
    public var verdict: Verdict?
    public var dayScore: Int?
    /// The day's Google Doc ("Open doc"); nil in friend mode.
    public var docURL: String?

    public var id: String { day }

    public init(day: String, weekday: String = "", focusS: Double = 0, blocks: Int = 0,
                avgScore: Int? = nil, verdict: Verdict? = nil, dayScore: Int? = nil, docURL: String? = nil) {
        self.day = day
        self.weekday = weekday
        self.focusS = max(0, focusS.isFinite ? focusS : 0)
        self.blocks = max(0, blocks)
        self.avgScore = avgScore
        self.verdict = verdict
        self.dayScore = dayScore
        self.docURL = docURL
    }

    /// "2 h 35 m" — the same wording as the hours label.
    public var hoursText: String { HoursMath.duration(focusS) }

    /// "Mon 21 Sep" — the weekday the server sent (shortened) plus the date; the raw day if it can't be read.
    public var dateText: String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), (1...12).contains(m), let d = Int(parts[2]) else { return day }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let date = "\(d) \(months[m - 1])"
        let w = weekday.trimmingCharacters(in: .whitespaces)
        return w.isEmpty ? date : String(w.prefix(3)) + " " + date
    }

    /// "3 blocks", "1 block", "" when the server sent none.
    public var blocksText: String { blocks <= 0 ? "" : "\(blocks) block" + (blocks == 1 ? "" : "s") }

    /// The number shown in the score column: the day score when there is one, otherwise the block average.
    public var scoreShown: Int? { dayScore ?? avgScore }
    public var scoreText: String { scoreShown.map { "\($0)" } ?? "—" }
    public var verdictText: String { verdict?.title ?? "" }
    public var hasDoc: Bool { !(docURL ?? "").isEmpty }
}

public enum FocusHistory {
    /// How many days the goal screen and the control window ask for.
    public static let defaultDays = 30

    /// `?days=30` on the owner's route (friends get the whole thing their server decides).
    public static var ownerQuery: String { "?days=\(defaultDays)" }

    /// Newest first. Entries with no `day` are dropped, repeats keep the first one seen, and every other
    /// field is optional.
    public static func parse(_ json: JSONValue) -> [HistoryDay] {
        let list = json["days"]?.arrayValue ?? json["history"]?.arrayValue ?? json.arrayValue ?? []
        var out: [HistoryDay] = []
        var seen = Set<String>()
        for v in list {
            let day = v.str("day").trimmingCharacters(in: .whitespaces)
            guard !day.isEmpty, seen.insert(day).inserted else { continue }
            out.append(HistoryDay(day: day,
                                  weekday: v.str("weekday"),
                                  focusS: number(v, "focus_s") ?? 0,
                                  blocks: number(v, "blocks").map { Int($0.rounded()) } ?? 0,
                                  avgScore: score(v, "avg_score"),
                                  verdict: HistoryDay.Verdict.parse(v.str("verdict")),
                                  dayScore: score(v, "day_score"),
                                  docURL: url(v, "doc_url")))
        }
        return sort(out)
    }

    /// Newest first ("2026-09-21" before "2026-09-20"); ISO dates sort as text.
    public static func sort(_ days: [HistoryDay]) -> [HistoryDay] {
        days.sorted { $0.day > $1.day }
    }

    static func number(_ v: JSONValue, _ key: String) -> Double? {
        guard let d = v[key]?.doubleValue, d.isFinite else { return nil }
        return max(0, d)
    }

    static func score(_ v: JSONValue, _ key: String) -> Int? {
        guard let d = number(v, key) else { return nil }
        return min(1000, max(0, Int(d.rounded())))
    }

    static func url(_ v: JSONValue, _ key: String) -> String? {
        let s = v.str(key).trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
        return s
    }
}
