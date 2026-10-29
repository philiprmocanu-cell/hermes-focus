import Foundation

// Pure logic for the second iteration of the app: goal understanding, the final-20-second
// edge pulse, adaptive block length, nudges, today's stats and the control window.

// MARK: - Goal understanding flow

/// What a settled goal carries into the block: his words, the brain's sentence and the sharpened goal.
public struct GoalPlan: Codable, Equatable, Sendable {
    public var goal: String
    public var understood: String
    public var specificGoal: String

    public init(goal: String, understood: String = "", specificGoal: String = "") {
        self.goal = goal; self.understood = understood; self.specificGoal = specificGoal
    }

    /// What of the saved plan may travel with `goal` (the goal screen's "same as before" path). The
    /// understood sentence and the sharpened goal belong to the goal they were made for: they come along only
    /// when `goal` IS that goal, otherwise the new goal goes out alone (specific "" — the brain then works
    /// from the goal itself). Oct 15 2026: a sharpened goal saved by a mid-block goal change rode along with
    /// "Make the Website" for four blocks as "DO the Anth reading", and every screen was judged against it.
    public static func carried(_ saved: GoalPlan?, to goal: String) -> GoalPlan {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let saved, GoalProgress.sameGoal(saved.goal, g) else { return GoalPlan(goal: g) }
        return GoalPlan(goal: g, understood: saved.understood, specificGoal: saved.specificGoal)
    }
}

/// typing → understanding → (clarifying → understanding)* → understood (1.5 s: "Got it — <sharpened goal>", or the
/// understood sentence when there is no sharpened goal) → done. The goal screen stays minimal: no review card.
/// The sharpened goal travels on in `proceed` (the control window shows it).
/// Any failure or a 6 s silence proceeds with the text as typed. "same" / the unchanged pre-fill skips straight
/// through with the previous plan (the request is still sent so the brain knows).
public struct GoalFlow: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case typing
        case understanding
        case clarifying(question: String)
        case understood(GoalPlan)
        case done
    }

    public enum Effect: Equatable, Sendable {
        /// POST this to `/admin/focus/goal`; hand the reply back with the same `requestId`.
        case post(GoalRequest, requestId: Int)
        /// Show "Understanding your goal…" (field locked).
        case showUnderstanding
        /// Show the question under the field (in blue) and clear the field for the answer.
        case showQuestion(String)
        /// Show "Got it — <sharpened goal or understood sentence>" for `understoodHold`.
        case showUnderstood(String)
        /// Show the rubric summary under it (only with a usable rubric; the hold is then `rubricHold`).
        case showRubric(Rubric)
        /// Goal settled: start the countdown with these.
        case proceed(goal: String, understood: String, specificGoal: String = "")
    }

    public static let timeout: TimeInterval = 6
    public static let understoodHold: TimeInterval = 1.5
    /// With a rubric summary under the goal: long enough to read it and reach "Fix…".
    public static let rubricHold: TimeInterval = 4
    /// After "Fix…" closes (new summary, Esc, or given up): a moment to read the result, then Start.
    public static let afterFixHold: TimeInterval = 3
    /// After this many questions the next "clarify" is ignored and the text is used as typed.
    public static let maxQuestions = 2

    public private(set) var stage: Stage = .typing
    public let previousGoal: String
    public let previousUnderstood: String
    public let previousSpecific: String
    /// The goal text as first submitted (clarify answers are sent alongside it).
    public private(set) var text = ""
    public private(set) var requestId = 0
    private var sentAt: TimeInterval = 0
    private var understoodUntil: TimeInterval = 0
    private var questions = 0

    public init(previousGoal: String, previousUnderstood: String, previousSpecific: String = "") {
        self.previousGoal = previousGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.previousUnderstood = previousUnderstood.trimmingCharacters(in: .whitespacesAndNewlines)
        self.previousSpecific = previousSpecific.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isBusy: Bool {
        switch stage {
        case .understanding, .understood, .done: return true
        case .typing, .clarifying: return false
        }
    }

    /// Enter pressed.
    public mutating func submit(_ raw: String, now: TimeInterval) -> [Effect] {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stage {
        case .typing:
            let t = typed.isEmpty ? previousGoal : typed
            guard !t.isEmpty else { return [] }
            text = t
            if !previousGoal.isEmpty && Self.meansSame(t, previousGoal: previousGoal) {
                // Straight through: tell the brain, but don't wait for it or show a review.
                let post = send(clarifyAnswer: nil, now: now).filter { if case .post = $0 { return true }; return false }
                return post + finish(fallback)
            }
            return send(clarifyAnswer: nil, now: now)
        case .clarifying:
            // Enter on an empty answer = "just go with what I wrote".
            guard !typed.isEmpty else { return finish(fallback) }
            return send(clarifyAnswer: typed, now: now)
        case .understanding, .understood, .done:
            return []
        }
    }

    /// The brain's reply (nil = request failed / no brain configured).
    public mutating func receive(_ reply: GoalReply?, requestId id: Int, now: TimeInterval) -> [Effect] {
        guard stage == .understanding, id == requestId else { return [] }
        guard let reply else { return finish(fallback) }
        switch reply.status {
        case .clarify:
            guard questions < Self.maxQuestions else { return finish(fallback) }
            questions += 1
            stage = .clarifying(question: reply.question)
            return [.showQuestion(reply.question)]
        case .ok:
            let goal = reply.goal.isEmpty ? fallback.goal : reply.goal
            var understood = reply.understood.isEmpty && reply.goal.isEmpty ? fallback.understood : reply.understood
            var specific = reply.specificGoal
            // A new goal never carries the old goal's sentence or sharpened goal, even if a reply echoes them.
            if !previousGoal.isEmpty, !GoalProgress.sameGoal(goal, previousGoal) {
                if GoalProgress.sameGoal(specific, previousSpecific) { specific = "" }
                if GoalProgress.sameGoal(understood, previousUnderstood) { understood = "" }
            }
            let plan = GoalPlan(goal: goal, understood: understood, specificGoal: specific)
            let line = plan.specificGoal.isEmpty ? understood : plan.specificGoal
            guard !line.isEmpty else { return finish(plan) }
            stage = .understood(plan)
            if let rubric = reply.rubric, !rubric.summaryLines.isEmpty {
                understoodUntil = now + Self.rubricHold
                return [.showUnderstood(line), .showRubric(rubric)]
            }
            understoodUntil = now + Self.understoodHold
            return [.showUnderstood(line)]
        }
    }

    /// Keep the "Got it" screen up until at least `t` (after "Fix…" closes). Only while it is showing.
    public mutating func holdUntil(_ t: TimeInterval) {
        guard case .understood = stage else { return }
        understoodUntil = max(understoodUntil, t)
    }

    /// Call often (the app's 0.1 s loop).
    public mutating func tick(now: TimeInterval) -> [Effect] {
        switch stage {
        case .understanding where now >= sentAt + Self.timeout:
            return finish(fallback)
        case .understood(let plan) where now >= understoodUntil:
            return finish(plan)
        default:
            return []
        }
    }

    /// What to use when the brain can't help: the text as typed, or the previous goal (and its
    /// understood sentence and sharpened goal) when he clearly meant "same as before".
    public var fallback: GoalPlan {
        if !previousGoal.isEmpty && Self.meansSame(text, previousGoal: previousGoal) {
            return GoalPlan(goal: previousGoal, understood: previousUnderstood, specificGoal: previousSpecific)
        }
        return GoalPlan(goal: text)
    }

    public static func meansSame(_ text: String, previousGoal: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if t == previousGoal.lowercased() { return true }
        return ["same", "same thing", "same as before", "same as last time", "continue", "keep going"].contains(t)
    }

    private mutating func send(clarifyAnswer: String?, now: TimeInterval) -> [Effect] {
        requestId += 1
        sentAt = now
        stage = .understanding
        let req = GoalRequest(text: text, previousGoal: previousGoal, previousUnderstood: previousUnderstood,
                              clarifyAnswer: clarifyAnswer, at: Int(now))
        return [.showUnderstanding, .post(req, requestId: requestId)]
    }

    private mutating func finish(_ p: GoalPlan) -> [Effect] {
        stage = .done
        return [.proceed(goal: p.goal, understood: p.understood, specificGoal: p.specificGoal)]
    }
}

// MARK: - Final-seconds edge pulse

/// The lightning-blue outline that beats once per second at the end of a work block.
public enum EdgePulse {
    public static let standardWindow: TimeInterval = 20

    /// 20 s, but never more than a third of the block (test mode's 60 s block → 20 s; a 30 s block → 10 s).
    public static func window(work: TimeInterval) -> TimeInterval {
        min(standardWindow, max(0, work / 3))
    }

    public static func isActive(phase: Phase, paused: Bool, remaining: TimeInterval, work: TimeInterval) -> Bool {
        phase == .work && !paused && remaining > 0 && remaining <= window(work: work)
    }

    /// Lit for the first half of every second (a heartbeat: on at 20.0, off at 19.5, on at 19.0 …).
    public static func isLit(remaining: TimeInterval) -> Bool {
        guard remaining > 0 else { return false }
        let intoSecond = remaining.rounded(.up) - remaining
        return intoSecond < 0.5
    }
}

// MARK: - Adaptive block length

/// "Next block: 20 min". Stored as a fraction of a 25-minute block so test mode scales with it.
/// Only ever shortens (10–25 min); resets on a new calendar day.
public struct AdaptiveLength: Codable, Equatable, Sendable {
    public static let referenceWork: TimeInterval = 25 * 60
    public static let minFraction = 10.0 / 25.0
    public static let maxFraction = 1.0

    public var fraction: Double = 1
    public var reason: String = ""
    /// `DayKey` of the day it was set; "" = never.
    public var day: String = ""

    public init() {}

    public static func fraction(nextWorkS: Int) -> Double {
        min(maxFraction, max(minFraction, Double(nextWorkS) / referenceWork))
    }

    public mutating func apply(_ advice: NextBlockAdvice, day: String) {
        fraction = Self.fraction(nextWorkS: advice.workSeconds)
        reason = advice.reason
        self.day = day
    }

    /// A session starting on a different day than the stored advice goes back to full length.
    public mutating func startSession(day today: String) {
        if day != today { self = AdaptiveLength() }
    }

    /// Next work length for a session whose normal block is `base` seconds. Whole minutes for
    /// normal blocks, whole seconds for short (test) ones; never longer than `base`.
    public func workSeconds(base: TimeInterval) -> TimeInterval {
        guard base > 0 else { return base }
        let raw = base * min(Self.maxFraction, max(Self.minFraction, fraction))
        let rounded = base >= 600 ? (raw / 60).rounded() * 60 : raw.rounded()
        return min(base, max(1, rounded))
    }
}

// MARK: - Nudges

/// Small toasts from the frame responses: one on screen at a time, 8 s each, a short gap between.
public struct NudgeQueue: Equatable, Sendable {
    public enum Change: Equatable, Sendable { case show(String), hide }

    public static let displaySeconds: TimeInterval = 8
    public static let gap: TimeInterval = 1.2
    public static let maxQueued = 3

    public private(set) var current: String?
    public private(set) var queue: [String] = []
    private var currentUntil: TimeInterval = 0
    private var nextAllowedAt: TimeInterval = 0

    public init() {}

    public mutating func push(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != current, !queue.contains(text) else { return }
        queue.append(text)
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
    }

    /// At most one change per call.
    public mutating func tick(now: TimeInterval) -> Change? {
        if current != nil {
            guard now >= currentUntil else { return nil }
            current = nil
            nextAllowedAt = now + Self.gap
            return .hide
        }
        guard !queue.isEmpty, now >= nextAllowedAt else { return nil }
        let next = queue.removeFirst()
        current = next
        currentUntil = now + Self.displaySeconds
        return .show(next)
    }

    /// Show this now, replacing whatever is on screen (distraction interrupts can't wait 8 s). `seconds` is how
    /// long it stays up (a short confirmation can go sooner than a nudge).
    public mutating func interrupt(_ raw: String, now: TimeInterval, for seconds: TimeInterval = displaySeconds) -> Change? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        queue.removeAll { $0 == text }
        let wasSame = current == text
        current = text
        currentUntil = now + max(0, seconds)
        return wasSame ? nil : .show(text)
    }

    /// Drop everything (block ended). Returns true when a toast was on screen.
    @discardableResult
    public mutating func clear() -> Bool {
        let wasShowing = current != nil
        self = NudgeQueue()
        return wasShowing
    }
}

// MARK: - Today

public enum DayKey {
    /// "2026-09-21" in the given calendar's time zone.
    public static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Finished blocks and their scores for one calendar day.
public struct DayStats: Codable, Equatable, Sendable {
    public var day: String = ""
    public var blocks = 0
    public var scoreSum = 0
    public var scored = 0

    public init(day: String = "") { self.day = day }

    public var averageScore: Int? { scored == 0 ? nil : Int((Double(scoreSum) / Double(scored)).rounded()) }

    public mutating func rollover(day today: String) {
        if day != today { self = DayStats(day: today) }
    }

    public mutating func recordBlock(day today: String) {
        rollover(day: today)
        blocks += 1
    }

    public mutating func recordScore(_ score: Int, day today: String) {
        rollover(day: today)
        scoreSum += score
        scored += 1
    }

    public func line(today: String) -> String {
        guard day == today, blocks > 0 else { return "No blocks yet today" }
        let b = blocks == 1 ? "1 block today" : "\(blocks) blocks today"
        guard let avg = averageScore else { return b }
        return "\(b) · avg \(avg) / 1000"
    }
}

// MARK: - Control window

/// Everything the Dock control window shows, derived from the phase machine.
public struct ControlState: Equatable, Sendable {
    public var phaseLabel: String
    public var timeText: String
    public var goal: String
    public var understood: String
    public var todayLine: String
    public var canStart: Bool
    public var canPause: Bool
    public var pauseTitle: String
    public var canEnd: Bool
    /// True while the clock is counting (drives the glow in the window).
    public var isLive: Bool

    public static func make(phase: Phase, isPaused: Bool, remaining: TimeInterval, nextWork: TimeInterval,
                            goal: String, understood: String, todayLine: String) -> ControlState {
        let label: String
        var time = FocusText.clock(remaining)
        switch phase {
        case .idle: label = "Ready"; time = FocusText.clock(nextWork)
        case .goal: label = "Choosing a goal"; time = FocusText.clock(nextWork)
        case .countdown: label = "Starting"
        case .work: label = isPaused ? "Paused" : "Focus"
        case .onBreak: label = isPaused ? "Break paused" : "Break"
        }
        let pausable = phase == .work || phase == .onBreak
        return ControlState(phaseLabel: label, timeText: time,
                            goal: phase == .idle ? "" : goal,
                            understood: phase == .idle ? "" : understood,
                            todayLine: todayLine,
                            canStart: phase == .idle,
                            canPause: pausable,
                            pauseTitle: isPaused ? "Resume" : "Pause",
                            canEnd: phase != .idle,
                            isLive: pausable && !isPaused)
    }
}

// MARK: - More display text

extension FocusText {
    /// "25 minutes", "1 minute", "45 seconds".
    public static func lengthPhrase(_ seconds: TimeInterval) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s % 60 == 0 || s >= 600 {
            let m = max(1, Int((Double(s) / 60).rounded()))
            return m == 1 ? "1 minute" : "\(m) minutes"
        }
        return s == 1 ? "1 second" : "\(s) seconds"
    }

    /// "Next block: 20 min — your focus slipped around minute 18".
    public static func nextBlockLine(seconds: TimeInterval, reason: String) -> String {
        let s = max(1, Int(seconds.rounded()))
        let len = (s % 60 == 0 || s >= 600) ? "\(max(1, Int((Double(s) / 60).rounded()))) min" : "\(s) s"
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? "Next block: \(len)" : "Next block: \(len) — \(r)"
    }
}
