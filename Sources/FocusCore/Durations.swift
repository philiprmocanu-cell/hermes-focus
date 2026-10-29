import Foundation

/// All timings the app uses, in seconds.
public struct Durations: Equatable, Sendable {
    public var work: TimeInterval
    /// A fixed break length (the `breakSeconds` default) that overrides the block-scaled rule. Normally nil:
    /// the break is a fifth of the block that just finished (`BreakLength`).
    public var breakOverride: TimeInterval?
    /// Number of "3, 2, 1" countdown steps (one per second).
    public var countdown: Int
    public var screenshotInterval: TimeInterval
    public var screenshotJitter: TimeInterval
    public var tickInterval: TimeInterval
    public var activitySampleInterval: TimeInterval
    public var isTestMode: Bool
    /// This session's block scale: 1 normally, 60 s / 25 min (0.04) in test mode. Everything that is written
    /// in real minutes — the break rule, the long-break 2 h — is scaled by it.
    public var blockScale: Double

    public init(work: TimeInterval, breakOverride: TimeInterval? = nil, countdown: Int,
                screenshotInterval: TimeInterval, screenshotJitter: TimeInterval,
                tickInterval: TimeInterval, activitySampleInterval: TimeInterval,
                isTestMode: Bool = false, blockScale: Double = 1) {
        self.work = work
        self.breakOverride = breakOverride
        self.countdown = countdown
        self.screenshotInterval = screenshotInterval
        self.screenshotJitter = screenshotJitter
        self.tickInterval = tickInterval
        self.activitySampleInterval = activitySampleInterval
        self.isTestMode = isTestMode
        self.blockScale = blockScale
    }

    /// The short break after a block of `work` seconds (the `breakSeconds` default wins when set).
    public func shortBreak(work: TimeInterval) -> TimeInterval {
        breakOverride ?? BreakLength.short(work: work, scale: blockScale)
    }

    /// The long break after a block of `work` seconds — four short breaks, never under 15 real minutes.
    public func longBreak(work: TimeInterval) -> TimeInterval {
        if let o = breakOverride { return max(1, (o * BreakLength.longMultiplier).rounded()) }
        return BreakLength.long(work: work, scale: blockScale)
    }

    /// 25 min work / 3 s countdown ("3, 2, 1, GO"), screenshot every 60 s ± 10 s, tick every minute.
    /// The break is not a fixed number any more: it is a fifth of the block that just finished (5 min here).
    public static let standard = Durations(work: 25 * 60, countdown: 3,
                                           screenshotInterval: 60, screenshotJitter: 10,
                                           tickInterval: 60, activitySampleInterval: 5)

    /// Short timings for verification: 60 s work / 2 s countdown (the 3-2-1 scaled down). The break scales
    /// with the block just the same: 60 s of work → 12 s, and the long break → 48 s.
    public static let test = Durations(work: 60, countdown: 2,
                                       screenshotInterval: 10, screenshotJitter: 2,
                                       tickInterval: 15, activitySampleInterval: 2,
                                       isTestMode: true, blockScale: 60.0 / (25 * 60))

    /// Resolve durations from launch arguments and user defaults.
    ///
    /// - `--test` launch argument, or defaults key `testMode` = true → `Durations.test` as the base.
    /// - Then any of these defaults keys (numbers, seconds) override individual values:
    ///   `workSeconds`, `breakSeconds`, `countdownSeconds`, `screenshotSeconds`, `tickSeconds`.
    /// - `lookup` returns the defaults value for a key (nil when unset).
    public static func resolve(arguments: [String], forceTest: Bool = false,
                               lookup: (String) -> Any?) -> Durations {
        let testFlag = forceTest || arguments.contains("--test") || boolValue(lookup("testMode"))
        var d = testFlag ? Durations.test : Durations.standard
        if let v = positive(lookup("workSeconds")) { d.work = v }
        if let v = positive(lookup("breakSeconds")) { d.breakOverride = v }
        if let v = lookup("countdownSeconds").flatMap(number), v >= 0 { d.countdown = Int(v) }
        if let v = positive(lookup("screenshotSeconds")) {
            d.screenshotInterval = v
            d.screenshotJitter = min(d.screenshotJitter, v / 4)
        }
        if let v = positive(lookup("tickSeconds")) { d.tickInterval = v }
        d.blockScale = max(0.0001, d.work / Durations.standard.work)
        return d
    }

    static func number(_ any: Any) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func positive(_ any: Any?) -> Double? {
        guard let any, let v = number(any), v > 0 else { return nil }
        return v
    }

    static func boolValue(_ any: Any?) -> Bool {
        switch any {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["1", "true", "yes"].contains(s.lowercased())
        default: return false
        }
    }
}
