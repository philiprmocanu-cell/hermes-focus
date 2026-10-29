import Foundation

// MARK: - Activity

/// App + window + URL the user was in.
public struct AppContext: Hashable, Sendable {
    public var app: String
    public var title: String
    public var url: String
    public init(app: String = "", title: String = "", url: String = "") {
        self.app = app; self.title = title; self.url = url
    }
}

public enum ActivityMath {
    /// Seconds of input to credit for one sample: the whole interval if there was any
    /// keyboard/mouse event within it, else nothing.
    public static func activeSeconds(sinceLastEvent: TimeInterval, interval: TimeInterval) -> TimeInterval {
        sinceLastEvent < interval ? interval : 0
    }
}

/// Everything measured over some span (one minute for ticks, one block for summaries).
public struct MeasureWindow: Equatable, Sendable {
    public private(set) var activeSeconds: TimeInterval = 0
    public private(set) var switches = 0
    /// Seconds with scroll-wheel / trackpad scrolling, and with keystrokes (sampled about once a second).
    public private(set) var scrollSeconds: TimeInterval = 0
    public private(set) var keySeconds: TimeInterval = 0
    public private(set) var appSeconds: [AppContext: TimeInterval] = [:]
    public init() {}

    public mutating func addSwitch() { switches += 1 }

    /// One ~1 s input sample: a scroll / keystroke happened within the last `interval` seconds.
    public mutating func addInput(interval: TimeInterval, sinceScroll: TimeInterval, sinceKey: TimeInterval) {
        guard interval > 0 else { return }
        if sinceScroll < interval { scrollSeconds += interval }
        if sinceKey < interval { keySeconds += interval }
    }

    /// One activity sample covering `interval` seconds spent in `context`.
    public mutating func addActivity(context: AppContext, interval: TimeInterval, sinceLastEvent: TimeInterval) {
        activeSeconds += ActivityMath.activeSeconds(sinceLastEvent: sinceLastEvent, interval: interval)
        if !context.app.isEmpty { appSeconds[context, default: 0] += interval }
    }

    /// Apps sorted by time, longest first, capped at `limit`.
    public func topApps(limit: Int = 20) -> [(AppContext, TimeInterval)] {
        appSeconds.sorted { a, b in a.value == b.value ? a.key.app < b.key.app : a.value > b.value }
            .prefix(limit).map { ($0.key, $0.value) }
    }
}

// MARK: - Screenshots

public enum ScreenshotSchedule {
    /// Delay until the next screenshot: interval ± jitter, `unitRandom` in 0…1. Never under 5 s.
    public static func nextDelay(interval: TimeInterval, jitter: TimeInterval, unitRandom: Double) -> TimeInterval {
        let r = min(1, max(0, unitRandom))
        return max(5, interval + (2 * r - 1) * jitter)
    }

    public static func shouldCapture(phase: Phase, paused: Bool, screenLocked: Bool, displayAsleep: Bool) -> Bool {
        phase == .work && !paused && !screenLocked && !displayAsleep
    }

    /// An app switch also earns a shot, ~5 s later (the new window has settled by then).
    public static let switchDelay: TimeInterval = 5
    /// …but only when the last shot was this long ago, so flicking between two apps can't spam the brain.
    public static let switchMinGap: TimeInterval = 20

    /// When to take the extra shot after an app switch: `now + switchDelay`, or nil to leave the schedule
    /// alone (a shot less than 20 s ago, or one already due sooner).
    /// `lastShotAt` is nil when nothing has been captured in this block yet.
    public static func shotAfterSwitch(now: TimeInterval, lastShotAt: TimeInterval?,
                                       nextShotAt: TimeInterval) -> TimeInterval? {
        if let last = lastShotAt, now - last < switchMinGap { return nil }
        let at = now + switchDelay
        return at < nextShotAt ? at : nil
    }

    /// The app's own ceiling on screenshots per block: one per interval plus room for the app-switch shots.
    /// (The server has its own cap too.) 25 min at 60 s → 45; 60 min → 80.
    public static let switchAllowance = 20
    public static func maxPerBlock(workSeconds: TimeInterval, interval: TimeInterval) -> Int {
        guard workSeconds.isFinite, workSeconds > 0, interval.isFinite, interval > 0 else { return 12 }
        let cadence = Int((workSeconds / interval).rounded(.up))
        return max(12, cadence + switchAllowance)
    }

    /// Output size for a capture, downscaled to `maxWidth` (never upscaled), aspect preserved.
    public static func targetSize(width: Int, height: Int, maxWidth: Int = 1920) -> (width: Int, height: Int) {
        guard width > maxWidth, width > 0 else { return (width, height) }
        let h = Int((Double(height) * Double(maxWidth) / Double(width)).rounded())
        return (maxWidth, max(1, h))
    }
}

// MARK: - Display text

public enum FocusText {
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    public static func scoreLine(_ score: Int?) -> String {
        guard let score else { return "Score pending" }
        return "Last block: \(score) / 1000"
    }
}
