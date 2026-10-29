import Foundation

// Jev, the second-by-second judge (2026-09-27). The user: "I want Jev to be the verdict of whether or
// not it's off task or not, not the Gemini model. The Gemini model is only in uncertain situations."
//
// Once a second during work the app sends what is on the screen AS TEXT — front app, window title,
// tab URL, the visible text read through the accessibility system (or the page text of the Chrome /
// Safari tab), and what changed since the last second — to `POST /admin/focus/sense`. Since
// 2026-10-16 the same post also carries a screenshot when the screen needs one (`ImageGate`: a new
// screen, or every 5 s while the text alone can't say what he is looking at), and the brain hands it
// to Jev in the same call; Gemini is out of this loop and the brain no longer asks for `look`s. The
// brain answers with a verdict (with `serves_goal`), a nudge when he has been confidently off task for
// a while (with a `nudge_id` for the "I'm on task" button), and once a minute a `frame` that
// stands in for the old per-minute screenshot verdict. While the sense route is healthy the app takes
// no screenshots on a schedule; if it fails a few times in a row the old 60-second screenshot schedule
// (to `/admin/focus/frame`) comes back until it recovers, so a Jev outage never leaves a block unjudged.

/// `POST /admin/focus/sense` (and a friend's `/lb/focus/sense`).
public struct SensePayload: Codable, Equatable, Sendable {
    public var blockId: String
    public var goal: String
    public var understood: String
    public var specificGoal: String
    public var at: Int
    public var app: String
    public var title: String
    public var url: String
    /// The visible text, only when it changed since the last send (the brain keeps the last one).
    public var text: String?
    public var textDigest: String
    /// Share of the visible text that is new since the last second, 0…1.
    public var textChangedShare: Double
    public var typed: Bool
    public var scrolled: Bool
    public var idleS: Int
    public var appSwitched: Bool
    /// Whether the Accessibility permission is granted (the non-browser text path). Shown in the brain's
    /// second-by-second log so "no text" can be told apart from "no permission".
    public var axTrusted: Bool = false
    /// A sense-sized JPEG of the screen, base64, only on the seconds `ImageGate` picks (omitted otherwise).
    public var imageJpegB64: String?

    public init(blockId: String, goal: String, understood: String, specificGoal: String, at: Int,
                context: AppContext, text: String?, textDigest: String, textChangedShare: Double,
                typed: Bool, scrolled: Bool, idleS: Int, appSwitched: Bool, axTrusted: Bool = false,
                imageJpegB64: String? = nil) {
        self.axTrusted = axTrusted
        self.imageJpegB64 = imageJpegB64
        self.blockId = blockId; self.goal = goal; self.understood = understood; self.specificGoal = specificGoal
        self.at = at; self.app = context.app; self.title = context.title; self.url = context.url
        self.text = text; self.textDigest = textDigest; self.textChangedShare = textChangedShare
        self.typed = typed; self.scrolled = scrolled; self.idleS = idleS; self.appSwitched = appSwitched
    }

    enum CodingKeys: String, CodingKey {
        case blockId = "block_id", goal, understood, specificGoal = "specific_goal", at, app, title, url, text,
             textDigest = "text_digest", textChangedShare = "text_changed_share", typed, scrolled,
             idleS = "idle_s", appSwitched = "app_switched", axTrusted = "ax_trusted",
             imageJpegB64 = "image_jpeg_b64"
    }
}

/// What the brain answers a sense post with.
public struct SenseResult: Equatable, Sendable {
    public var onGoal: Double?
    public var mode: String
    public var confidence: Double?
    /// Whether what is on screen serves the goal (the verdict's `serves_goal`); nil when not said.
    /// Settles a distraction site the app is holding (`DistractionGate.frameVerdict`).
    public var servesGoal: Bool?
    public var nudge: String
    /// Names the nudge for the "I'm on task" button ("" when the brain sent none).
    public var nudgeId: String
    /// Once a minute: the seconds folded into one frame row, kept like a screenshot verdict.
    public var frame: JSONValue?
    public var goalProgress: Double?
    public var goalChanged: GoalChange?
    public var cached: Bool

    public static func parse(_ json: JSONValue) -> SenseResult {
        let v = json["verdict"]
        func unit(_ x: JSONValue?) -> Double? { x?.doubleValue.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } }
        let serves = v?["serves_goal"]?.boolValue ?? json["serves_goal"]?.boolValue
        return SenseResult(onGoal: unit(v?["on_goal"]), mode: v?.str("mode") ?? "",
                           confidence: unit(v?["confidence"]), servesGoal: serves, nudge: json.str("nudge"),
                           nudgeId: json.str("nudge_id"), frame: json["frame"],
                           goalProgress: unit(json["goal_progress"]), goalChanged: GoalChange.parse(json),
                           cached: json["cached"]?.boolValue ?? false)
    }
}

/// The text side of "what changed since last second".
public enum TextChange {
    /// Cheap, stable digest of the visible text (whitespace-normalised).
    public static func digest(_ text: String) -> String {
        let norm = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var h: UInt64 = 0xcbf29ce484222325
        for b in norm.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Share of the new text's lines that were not in the old text, 0…1 (0 when both are empty).
    public static func share(old: String, new: String) -> Double {
        func lines(_ s: String) -> Set<Substring> {
            Set(s.split(whereSeparator: { $0.isNewline }).map { $0.drop(while: { $0.isWhitespace }) }
                    .filter { !$0.isEmpty })
        }
        let a = lines(old), b = lines(new)
        guard !b.isEmpty else { return a.isEmpty ? 0 : 1 }
        return Double(b.subtracting(a).count) / Double(b.count)
    }

    /// The text is sent only when it changed; the cap keeps a giant page from becoming a giant post.
    public static let maxChars = 6000
    public static func trimmed(_ text: String) -> String {
        text.count <= maxChars ? text : String(text.prefix(maxChars))
    }
}

/// When to post, and whether the old screenshot schedule should be running instead.
public struct SenseHealth: Equatable, Sendable {
    public static let interval: TimeInterval = 1
    /// This many failed or unanswered posts in a row hand the block back to the screenshot schedule.
    public static let failuresBeforeFallback = 3
    public private(set) var failures = 0
    public private(set) var successes = 0
    public init() {}

    public mutating func succeeded() { failures = 0; successes += 1 }
    public mutating func failed() { failures += 1 }
    public mutating func reset() { failures = 0; successes = 0 }

    /// Jev is judging: no screenshots on a schedule (the sense posts carry their own).
    public var isJudging: Bool { successes > 0 && failures < Self.failuresBeforeFallback }
    /// The screenshot schedule should run (Jev not yet answering, or failing).
    public var screenshotsOnSchedule: Bool { !isJudging }
}

// MARK: - Screenshots on the sense post

/// Whether this second's sense post carries a screenshot (2026-10-16). Yes when the screen is a new one
/// (app + title + URL differ from the last screenshot sent), and every `repeatEvery` seconds while the
/// screen keeps needing pictures: the visible text is thin, it is a picture app or site (design tools,
/// video, photos…), or it is the Claude desktop app (whose window text doesn't say what the chat is
/// about). Otherwise the text is enough. `sent` is called only when an image actually went out.
public struct ImageGate: Equatable, Sendable {
    public static let repeatEvery: TimeInterval = 5
    /// Fewer visible characters than this (after trimming) and the text can't say what he is looking at.
    public static let thinTextChars = 200
    /// Lower-cased fragments of app names that are about pictures, not words.
    public static let pictureApps = ["figma", "sketch", "photoshop", "illustrator", "final cut", "imovie", "preview",
                                     "photos", "quicktime", "keynote", "blender", "fusion", "kicad", "eagle", "altium"]
    /// Sites whose page text says little about what is on screen (the host or any subdomain of it).
    public static let pictureHosts = ["youtube.com", "youtu.be", "vimeo.com", "figma.com", "canva.com", "netflix.com",
                                      "twitch.tv", "instagram.com", "tiktok.com", "cosmos.so"]

    public private(set) var lastKey: String?
    public private(set) var lastSentAt: TimeInterval?

    public init() {}

    /// "app|title|url" — what makes a screen a different screen.
    public static func screenKey(_ ctx: AppContext) -> String { ctx.app + "|" + ctx.title + "|" + ctx.url }

    /// The screen keeps needing pictures (thin text, a picture app or site, or Claude).
    public static func needsPictures(context ctx: AppContext, text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < thinTextChars { return true }
        let app = ctx.app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if app == "claude" { return true }
        if pictureApps.contains(where: { app.contains($0) }) { return true }
        if let host = host(of: ctx.url), pictureHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        return false
    }

    /// The URL's host, lower-cased; a URL typed without a scheme still has one.
    public static func host(of url: String) -> String? {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return nil }
        let h = URL(string: u)?.host ?? URL(string: "https://" + u)?.host
        guard let h, !h.isEmpty else { return nil }
        return h.lowercased()
    }

    /// Should the post for this second carry a screenshot?
    public func wants(context ctx: AppContext, text: String, now: TimeInterval) -> Bool {
        if Self.screenKey(ctx) != lastKey { return true }
        guard Self.needsPictures(context: ctx, text: text) else { return false }
        guard let last = lastSentAt else { return true }
        return now - last >= Self.repeatEvery
    }

    /// A screenshot of this screen went out with a post.
    public mutating func sent(context ctx: AppContext, now: TimeInterval) {
        lastKey = Self.screenKey(ctx)
        lastSentAt = now
    }

    /// A new block: the first screen always gets a picture.
    public mutating func reset() { self = ImageGate() }
}

/// The size of the screenshot that rides on a sense post: the longest side at most 1280 px (never
/// upscaled), each side at least 280 px, aspect kept otherwise. JPEG quality ~0.6, memory only.
public enum SenseImage {
    public static let maxSide = 1280
    public static let minSide = 280
    public static let quality = 0.6

    public static func targetSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (max(minSide, width), max(minSide, height)) }
        let longest = max(width, height)
        let scale = longest > maxSide ? Double(maxSide) / Double(longest) : 1
        let w = Int((Double(width) * scale).rounded()), h = Int((Double(height) * scale).rounded())
        return (min(maxSide, max(minSide, w)), min(maxSide, max(minSide, h)))
    }
}

// MARK: - "I'm on task"

/// `POST /admin/focus/exception` (friend: `/lb/focus/exception`): he clicked "I'm on task" on a
/// sense nudge. Carries the screen as it was when the nudge was shown; the brain answers
/// `{"ok": true, "rule": "..."}` and stops counting that screen against the goal for the rest of the block.
public struct ExceptionPayload: Codable, Equatable, Sendable {
    public var blockId: String
    public var nudgeId: String
    public var app: String
    public var title: String
    public var url: String
    public var at: Int

    public init(blockId: String, nudgeId: String, context: AppContext, at: Int) {
        self.blockId = blockId; self.nudgeId = nudgeId
        self.app = context.app; self.title = context.title; self.url = context.url; self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case blockId = "block_id", nudgeId = "nudge_id", app, title, url, at
    }
}

public struct ExceptionReply: Equatable, Sendable {
    public var ok: Bool
    public var rule: String

    public static func parse(_ json: JSONValue) -> ExceptionReply {
        ExceptionReply(ok: json["ok"]?.boolValue ?? false, rule: json.str("rule"))
    }

    public static let buttonTitle = "I'm on task"
    public static let confirmation = "Got it — that counts as work for the rest of this block."
    public static let failure = "Couldn't reach Hermes — try again."
}
