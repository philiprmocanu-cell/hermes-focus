import Foundation

/// Where the session is. `idle` = no session running.
public enum Phase: String, Equatable, Sendable {
    case idle, goal, countdown, work, onBreak
}

/// Side effects the app must perform after a transition. The machine itself does no I/O.
public enum FocusEffect: Equatable, Sendable {
    case sessionStarted
    case showGoalPrompt(prefill: String)
    case countdownStarted
    case workStarted(blockId: String, goal: String, startedAt: TimeInterval)
    case workEnded(BlockTiming)
    case breakStarted(blockId: String)
    case breakSkipped(blockId: String)
    case breakEnded
    case sessionStopped
    case paused
    case resumed
}

/// Timing facts for one finished (or aborted) work block.
public struct BlockTiming: Equatable, Sendable {
    public let blockId: String
    /// What the block is scored against — the brain may move it mid-block (`GoalChange`).
    public var goal: String
    public let startedAt: TimeInterval
    public let endedAt: TimeInterval
    public let plannedSeconds: TimeInterval
    public let completed: Bool
    /// One plain sentence of what he was working on (from the brain's goal check); "" if unknown.
    public var understood: String = ""
}

/// idle → goal → countdown → work → onBreak → goal → …
/// Driven by explicit `now` timestamps so it is fully deterministic under test.
public struct PhaseMachine {
    public private(set) var phase: Phase = .idle
    public var durations: Durations
    /// The goal the user typed most recently (pre-fills the next prompt).
    public private(set) var lastGoal: String
    /// Goal for the current / most recent block.
    public private(set) var goal: String = ""
    /// The brain's one-sentence reading of `goal` ("" when unknown).
    public private(set) var understood: String = ""
    /// `understood` of the most recent goal (sent back to the brain as `previous_understood`).
    public private(set) var lastUnderstood: String
    /// Length of the running / most recent work block. Fixed when the block starts, so
    /// `durations.work` can be changed (adaptive length) at any time without affecting it.
    public private(set) var currentWorkLength: TimeInterval = 0
    /// Current work block id (kept through the following break).
    public private(set) var blockId: String?
    public private(set) var blockStartedAt: TimeInterval?
    public private(set) var isPaused = false
    /// Set when a block starts: if it completes, its break is the long one (4× the short one).
    public var nextBreakIsLong = false
    /// The running / most recent break is the long one.
    public private(set) var breakIsLong = false

    private var deadline: TimeInterval?
    private var pausedRemaining: TimeInterval?
    private let makeId: () -> String

    public init(durations: Durations, lastGoal: String = "", lastUnderstood: String = "",
                makeId: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.durations = durations
        self.lastGoal = lastGoal
        self.lastUnderstood = lastUnderstood
        self.makeId = makeId
    }

    public var isRunning: Bool { phase != .idle }

    /// Seconds left in the current timed phase (countdown / work / break); 0 otherwise.
    public func remaining(now: TimeInterval) -> TimeInterval {
        if isPaused, let r = pausedRemaining { return r }
        guard let deadline else { return 0 }
        return max(0, deadline - now)
    }

    /// The number to show during the countdown: 6, 5, … 1.
    public func countdownNumber(now: TimeInterval) -> Int {
        Int(remaining(now: now).rounded(.up))
    }

    // MARK: - Inputs

    public mutating func start(now: TimeInterval) -> [FocusEffect] {
        guard phase == .idle else { return [] }
        phase = .goal
        isPaused = false
        pausedRemaining = nil
        deadline = nil
        nextBreakIsLong = false
        breakIsLong = false
        return [.sessionStarted, .showGoalPrompt(prefill: lastGoal)]
    }

    /// Goal confirmed (after the brain's goal check, or its timeout). An empty field falls back
    /// to the last goal; if there is none, nothing happens.
    public mutating func submitGoal(_ text: String, understood: String = "", now: TimeInterval) -> [FocusEffect] {
        guard phase == .goal else { return [] }
        var g = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var u = understood.trimmingCharacters(in: .whitespacesAndNewlines)
        if g.isEmpty {
            g = lastGoal
            if u.isEmpty { u = lastUnderstood }
        }
        guard !g.isEmpty else { return [] }
        goal = g
        lastGoal = g
        self.understood = u
        lastUnderstood = u
        if durations.countdown <= 0 {
            return beginWork(now: now)
        }
        phase = .countdown
        deadline = now + TimeInterval(durations.countdown)
        return [.countdownStarted]
    }

    /// Call frequently (e.g. 4×/s). Performs at most one transition per call.
    public mutating func tick(now: TimeInterval) -> [FocusEffect] {
        guard !isPaused, let deadline, now >= deadline else { return [] }
        switch phase {
        case .countdown:
            return beginWork(now: now)
        case .work:
            let timing = endWork(endedAt: deadline, completed: true)
            phase = .onBreak
            breakIsLong = nextBreakIsLong
            nextBreakIsLong = false
            let length = breakLength
            self.deadline = deadline + length
            // If the Mac slept through the whole break, don't show a break that is already over.
            if self.deadline! <= now { self.deadline = now + length }
            return [.workEnded(timing), .breakStarted(blockId: timing.blockId)]
        case .onBreak:
            phase = .goal
            self.deadline = nil
            return [.breakEnded, .showGoalPrompt(prefill: lastGoal)]
        case .idle, .goal:
            return []
        }
    }

    public mutating func skipBreak(now: TimeInterval) -> [FocusEffect] {
        guard phase == .onBreak else { return [] }
        phase = .goal
        deadline = nil
        isPaused = false
        pausedRemaining = nil
        return [.breakSkipped(blockId: blockId ?? ""), .showGoalPrompt(prefill: lastGoal)]
    }

    public mutating func stop(now: TimeInterval) -> [FocusEffect] {
        guard phase != .idle else { return [] }
        var effects: [FocusEffect] = []
        if phase == .work {
            effects.append(.workEnded(endWork(endedAt: now, completed: false)))
        }
        phase = .idle
        deadline = nil
        isPaused = false
        pausedRemaining = nil
        effects.append(.sessionStopped)
        return effects
    }

    /// Pause only applies to work and break (the goal prompt and countdown are interactive).
    public mutating func pause(now: TimeInterval) -> [FocusEffect] {
        guard !isPaused, phase == .work || phase == .onBreak, let deadline else { return [] }
        pausedRemaining = max(0, deadline - now)
        self.deadline = nil
        isPaused = true
        return [.paused]
    }

    public mutating func resume(now: TimeInterval) -> [FocusEffect] {
        guard isPaused else { return [] }
        deadline = now + (pausedRemaining ?? 0)
        pausedRemaining = nil
        isPaused = false
        return [.resumed]
    }

    /// Length of the running / most recent break — decided by the block that just finished: a fifth of it
    /// (min 3 min), or four of those for a long break (min 15 min). `BreakLength`.
    public var breakLength: TimeInterval {
        let w = currentWorkLength > 0 ? currentWorkLength : durations.work
        return breakIsLong ? durations.longBreak(work: w) : durations.shortBreak(work: w)
    }

    // MARK: - Internals

    private mutating func beginWork(now: TimeInterval) -> [FocusEffect] {
        let id = makeId()
        blockId = id
        blockStartedAt = now
        phase = .work
        currentWorkLength = durations.work
        deadline = now + currentWorkLength
        return [.workStarted(blockId: id, goal: goal, startedAt: now)]
    }

    private mutating func endWork(endedAt: TimeInterval, completed: Bool) -> BlockTiming {
        BlockTiming(blockId: blockId ?? "", goal: goal,
                    startedAt: blockStartedAt ?? endedAt, endedAt: endedAt,
                    plannedSeconds: currentWorkLength, completed: completed, understood: understood)
    }
}
