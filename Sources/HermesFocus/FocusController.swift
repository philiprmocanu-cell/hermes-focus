import AppKit
import FocusCore

/// Glue: runs the pure `PhaseMachine` (+ `GoalFlow`, `NudgeQueue`, `LongBreak`, `DistractionTracker`),
/// turns their effects into UI, sensors and brain calls.
///
/// Three modes (`BrainMode`): owner (his own server's `.env` exists), friend (joined with a code)
/// and local ("Run on my own keys": `LocalBrain` answers every route on this Mac, on his own keys).
/// All three run the whole app — goal understanding, screenshots, ticks, block scoring, suggestions, the
/// score reveal — only the routes differ (`FocusRoute`: `/admin/focus/...` behind the owner's secret prefix, or
/// `/lb/focus/...` with an `X-LB-Token` header, or `hermes-local://` answered in-process). Before anything is
/// chosen there is nowhere to send anything and the timer runs alone.
final class FocusController {
    private(set) var machine: PhaseMachine
    /// Durations from launch arguments / defaults (honours --test).
    private let standardDurations: Durations
    /// Durations this session started with (standard, or test via Option-click). The goal screen's length
    /// picker and the long-break rule scale with `baseDurations.work / 25 min`.
    private var baseDurations: Durations
    private let defaults = UserDefaults.standard

    let overlay = OverlayManager()
    private let corner = CornerTimer()
    private let edge = EdgeGlow()
    let toast = NudgeToast()
    private let blips = Blips()
    let controls = ControlWindowController()
    private let activity = ActivityMonitor()
    private let announcer = Announcer()
    /// Clean focus mode: the Dock, the menu bar and the desktop icons out of the way
    /// while a block runs, and his own settings back at the break (see CleanFocus).
    private var chrome: CleanFocusChrome!
    let brain: BrainClient

    private(set) var mode: AppMode
    /// Owner, friend or local; nil until he picks on the first-launch screen (`BrainMode.resolve`).
    private(set) var brainMode: BrainMode?
    private let friendURL: URL
    /// The first-launch choice and the key steps in the control window.
    private var setup = SetupFlow()
    /// Local mode: the keys the local brain reads (from the Keychain, cached), and where it keeps its files.
    private let localKeys = LocalKeys()
    private let localStoreURL: URL
    /// Local mode: this Mac's Keychain holds an Anthropic key.
    private var anthropicStored = false

    private var loopTimer: Timer?
    private var retryTimer: Timer?

    // Goal understanding (only while the goal prompt is up).
    var goalFlow: GoalFlow?
    private var goalFlowToken = UUID()
    /// The rubric the running block was started with (goal screen, after any "Fix…"); fills in the Now tab's
    /// milestones when `/now` only sends the balance.
    private var blockRubric: Rubric?

    // The settled goal for the current block, progress toward it and the latest tip.
    var plan = GoalPlan(goal: "")
    var goalProgress: Double?
    var latestTip = ""

    // Nudges, long break, today.
    var nudges = NudgeQueue()
    /// The brain's `next_work_s`, shown as a chip on the next goal screen (never applied by itself).
    private var suggestion: StoredSuggestion?
    private var longBreak = LongBreak()
    private var nextAwayCheckAt: TimeInterval = 0
    private var lastLoopAt: TimeInterval = 0
    private var sleptAt: TimeInterval?
    private var dayStats: DayStats
    private var dayFocus: DayFocus
    /// Unpaused work seconds in the running block (so an ended-early block counts what was worked).
    private var runningWorked: TimeInterval = 0
    private var goalHours: Double

    // Distractions.
    private var distraction = DistractionTracker()
    private var gate = DistractionGate()
    private var nextDistractionAt: TimeInterval = .infinity
    private var minuteDistraction = 0.0
    private var blockDistraction = 0.0

    // Measurement windows.
    private var minute = MeasureWindow()
    private var block = MeasureWindow()
    private var frames: [JSONValue] = []
    private var nextTickAt: TimeInterval = .infinity
    private var nextShotAt: TimeInterval = .infinity
    /// When the last screenshot went out in this block (nil = none yet), and how many there have been.
    private var lastShotAt: TimeInterval?
    private var shotsThisBlock = 0
    // Jev (FocusCore/Sense.swift): once a second during work, what is on the screen as text.
    private var nextSenseAt: TimeInterval = .infinity
    private var senseInFlight = false
    private var senseHealth = SenseHealth()
    /// A friend's own TypeSafe key (FocusCore/TypeSafe.swift): without one the brain answers 402 and the app
    /// probes once a minute instead of every second. Owner mode never touches it.
    private var typesafe = TypeSafeState()
    /// This Mac's Keychain holds a key (read once at launch, then kept in step with Save / Remove).
    private var keyStored = false
    private var lastSenseText = ""
    private var lastSenseDigest = ""
    private var lastSenseApp = ""
    /// Screenshots on the sense post (`ImageGate`): one capture at a time, handed to the next post for that screen.
    private var imageGate = ImageGate()
    private var senseCaptureInFlight = false
    private var readyImage: (key: String, b64: String, at: TimeInterval)?
    private var nextActivityAt: TimeInterval = .infinity
    private var lastActivityAt: TimeInterval = 0
    private var nextInputAt: TimeInterval = .infinity
    private var lastInputAt: TimeInterval = 0
    /// Focus returning from the overlay to his own app is not a real switch.
    private var ignoreSwitchesUntil: TimeInterval = 0

    // Score shown on the break screen.
    private var scoreBlockId: String?
    private var pending: PendingBlocks
    private var inFlight = Set<String>()
    private let pendingURL: URL

    // Break-screen score reveal.
    private struct RevealContext { var blockId: String; var worked: Double; var before: Double; var after: Double; var avgBefore: Int? }
    private var revealContext: RevealContext?
    private var revealedBlockId: String?
    private var revealFallback: DispatchWorkItem?
    private var revealFade: DispatchWorkItem?
    private var revealSounds: [DispatchWorkItem] = []
    /// Clears the "+25 min" once it has been counted into the hours label.
    private var hoursAddClear: DispatchWorkItem?
    /// While a finished block's "+N min" is still to come, the hours label shows the total BEFORE that
    /// block, so it can be seen being added. Without this the label jumped to the new total when the
    /// break opened, fell back to the old one when the count-up started, then climbed again.
    private var hoursHold: Double?

    // Live control window data.
    private var snapshot: NowSnapshot?
    private var snapshotDay: String?
    /// This Mac's own total for today when `snapshot` arrived (blocks finished since then are added on top).
    private var snapshotLocalBase: Double?
    private var online: Bool?
    private var liveTimer: Timer?
    private var liveTicks = 0
    private var settingsWork: DispatchWorkItem?

    // Suggested blocks (owner): the goal screen's cards and the idle window's "Up next".
    private var upNext: [BlockSuggestion] = []
    private var pendingPick: BlockSuggestion?
    private var suggestionsToken = UUID()

    // Friend leaderboard reports.
    private var nextReportAt: TimeInterval = .infinity

    /// Called whenever the menus / Dock icon should refresh.
    var onStateChange: (() -> Void)?

    init(durations: Durations, envPath: String) {
        standardDurations = durations
        baseDurations = durations
        machine = PhaseMachine(durations: durations,
                               lastGoal: UserDefaults.standard.string(forKey: "lastGoal") ?? "",
                               lastUnderstood: UserDefaults.standard.string(forKey: "lastUnderstood") ?? "")
        brain = BrainClient(envPath: envPath)
        suggestion = Self.load(StoredSuggestion.self, key: "suggestedLength")
        dayStats = Self.load(DayStats.self, key: "dayStats") ?? DayStats()
        dayFocus = Self.load(DayFocus.self, key: "dayFocus") ?? DayFocus()
        let storedGoal = UserDefaults.standard.double(forKey: "dailyHoursGoal")
        goalHours = storedGoal > 0 ? HoursMath.clampGoal(storedGoal) : HoursMath.defaultGoalHours

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HermesFocus", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        pendingURL = support.appendingPathComponent("pending-blocks.json")
        pending = PendingBlocks.decode(try? Data(contentsOf: pendingURL))
        friendURL = support.appendingPathComponent("friend.json")
        chrome = CleanFocusChrome(supportDirectory: support, prefs: Self.cleanFocusPrefs())
        let ownerEnv = FileManager.default.fileExists(atPath: envPath)
        mode = AppMode.resolve(ownerEnvExists: ownerEnv, friend: FriendConfig.load(from: friendURL))
        brainMode = BrainMode.resolve(ownerEnvExists: ownerEnv, friendJoined: mode.friend != nil,
                                      stored: UserDefaults.standard.string(forKey: BrainMode.defaultsKey))
        localStoreURL = LocalData.directory(support: support)
        // Own keys chosen: no server at all, even if an old friend.json is still on disk.
        if brainMode == .local { mode = .needsJoin }
        log.info("mode: \(self.brainMode?.rawValue ?? "not chosen", privacy: .public)")

        overlay.model.onSubmit = { [weak self] text in self?.submitGoalText(text) }
        overlay.model.onRubricFix = { [weak self] in self?.openRubricFix() }
        overlay.model.onRubricNote = { [weak self] note in self?.sendRubricNote(note) }
        overlay.model.onRubricEscape = { [weak self] in self?.closeRubricFix() }
        overlay.model.onSkipBreak = { [weak self] in self?.apply { $0.skipBreak(now: Self.now) } }
        overlay.model.onEndSession = { [weak self] in self?.stop() }
        overlay.model.screenWarning = isScoring
        overlay.model.isOwner = mode.isOwner
        overlay.model.brainMode = brainMode
        overlay.model.localDataPath = LocalData.displayPath(localStoreURL)
        overlay.model.onSaveAnthropicKey = { [weak self] k in self?.saveAnthropicKey(k) }
        overlay.model.onRemoveAnthropicKey = { [weak self] in self?.removeAnthropicKey() }
        overlay.model.onShowLocalData = { [weak self] in self?.showLocalData() }
        overlay.model.onLocalSettingsAppear = { [weak self] in self?.refreshLocalHealth() }
        controls.model.onPickOwnKeys = { [weak self] in self?.chooseOwnKeys() }
        controls.model.onPickJoin = { [weak self] in self?.updateSetup { $0.pickJoin() } }
        controls.model.onSetupBack = { [weak self] in self?.setupBack() }
        controls.model.onSetupNext = { [weak self] in
            guard let self else { return }
            let works = self.typesafe.keyIsSet(storedLocally: self.keyStored)
            self.clearKeyResult()
            self.updateSetup { $0.next(typesafeWorks: works) }
        }
        controls.model.onOpenSetup = { [weak self] in self?.showJoin() }
        controls.model.onAddKey = { [weak self] in self?.openKeyScreen() }
        controls.model.onSaveAnthropicKey = { [weak self] k in self?.saveAnthropicKey(k) }
        controls.model.onCloseSetup = { [weak self] in
            self?.clearKeyResult()
            self?.updateSetup { $0.close() }
        }
        overlay.model.onFriendsOpened = { [weak self] in self?.refreshBoard() }
        overlay.model.onHistoryOpened = { [weak self] in self?.refreshHistory() }
        overlay.model.onSetGoalHours = { [weak self] h in self?.setGoalHours(h) }
        overlay.model.cleanFocus = Self.cleanFocusPrefs()
        overlay.model.onSetCleanFocus = { [weak self] p in self?.setCleanFocus(p) }
        controls.model.onStart = { [weak self] test in self?.start(testDurations: test) }
        controls.model.onTogglePause = { [weak self] in self?.togglePause() }
        controls.model.onEnd = { [weak self] in self?.stop() }
        controls.model.onGoalHours = { [weak self] h in self?.setGoalHours(h) }
        controls.model.onTab = { [weak self] t in
            if t == .board { self?.refreshBoard() }
            if t == .history { self?.refreshHistory() }
        }
        controls.model.onRefreshBoard = { [weak self] in self?.refreshBoard() }
        controls.model.onRefreshHistory = { [weak self] in self?.refreshHistory() }
        controls.model.onJoin = { [weak self] server, code, name in self?.join(server: server, code: code, name: name) }
        controls.model.onPickUpNext = { [weak self] s in self?.startWith(s) }
        controls.model.boardSort = LeaderboardSort(stored: defaults.string(forKey: "boardSort"))
        controls.model.onBoardSort = { [weak self] sort in self?.defaults.set(sort.rawValue, forKey: "boardSort") }
        controls.model.onSaveKey = { [weak self] k in self?.saveTypeSafeKey(k) }
        controls.model.onRemoveKey = { [weak self] in self?.removeTypeSafeKey() }
        controls.model.onCloseKey = { [weak self] in
            self?.controls.model.showKey = false
            self?.clearKeyResult()
        }
        overlay.model.onSaveKey = { [weak self] k in self?.saveTypeSafeKey(k) }
        overlay.model.onRemoveKey = { [weak self] in self?.removeTypeSafeKey() }
        controls.model.onSkipJoin = { [weak self] in
            self?.defaults.set(true, forKey: "joinSkipped")
            self?.updateSetup { $0.close() }
        }
        controls.onVisibilityChange = { [weak self] visible in
            if visible { self?.startLive() } else { self?.stopLive() }
        }
        controls.model.goalHours = goalHours
        syncModeToControls()
        // The sharpened goal used to be saved on its own ("lastSpecificGoal") and could ride along with a
        // different goal; it is saved with its goal now ("lastPlan").
        defaults.removeObject(forKey: "lastSpecificGoal")
        activity.onSwitch = { [weak self] in self?.recordSwitch() }
        // 25+ minutes asleep counts as his long break.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleptAt = Self.now
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let t = self.sleptAt else { return }
            self.sleptAt = nil
            self.noteAway(seconds: Self.now - t)
        }

        if brainMode == .local { startLocalBrain() }
        if isScoring { startRetrying() }
        if judgesOnOwnKey {
            keyStored = TypeSafeKeychain.hasKey
            if brainMode == .local {
                anthropicStored = AnthropicKeychain.hasKey
                // No TypeSafe key yet: say so on the first goal screen without waiting for a reply.
                if brain.local?.ready == false { typesafe.observe(.missing, now: Self.now) }
            }
            refreshKeyUI()
            // Is he being judged? The goal screen says so before the first block, not after it.
            refreshNow()
        }
        refreshControls()
    }

    /// The owner, a joined friend and own-keys all run the full app; only where the calls go differs. Before a
    /// choice there is nowhere to send anything (the timer still works).
    var isScoring: Bool { brainMode != nil }

    /// Judged on his own TypeSafe key (friend, local): a missing key answers 402 and shows "Add key".
    private var judgesOnOwnKey: Bool { brainMode?.judgesOnOwnKey ?? false }

    /// Where a focus call goes for this app: the owner's secret prefix, the friend's `/lb/focus/...`, or the
    /// local brain (`hermes-local://focus/...`, answered by `BrainClient` without the network).
    func target(_ route: FocusRoute, query: String = "") -> FocusRoute.Target? {
        BrainDispatch.select(route, mode: brainMode, owner: brain.config, friend: mode.friend, query: query).target
    }

    static var now: TimeInterval { Date().timeIntervalSince1970 }
    private static var today: String { DayKey.string(Date()) }

    var phase: Phase { machine.phase }
    var isPaused: Bool { machine.isPaused }
    var isTestMode: Bool { machine.durations.isTestMode }
    var overlayIsUp: Bool { overlay.isVisible }
    var canPause: Bool { machine.phase == .work || machine.phase == .onBreak }
    /// This session's block scale: 1 normally, 60 s / 25 min in test mode.
    private var scale: Double { max(0.001, baseDurations.work / Durations.standard.work) }
    /// Nothing chosen yet (no `.env`, not joined, not on own keys) and he hasn't said "Not now".
    var shouldOfferJoin: Bool { brainMode == nil && !defaults.bool(forKey: "joinSkipped") }

    var statusText: String {
        let now = Self.now
        switch machine.phase {
        case .idle: return "Not running"
        case .goal: return "Waiting for goal"
        case .countdown: return "Starting…"
        case .work: return (machine.isPaused ? "Paused — work " : "Work ") + FocusText.clock(machine.remaining(now: now))
        case .onBreak: return (machine.isPaused ? "Paused — break " : "Break ") + FocusText.clock(machine.remaining(now: now))
        }
    }

    // MARK: - Actions (menus, Dock, control window, black screens)

    func start(testDurations: Bool) {
        guard machine.phase == .idle else { return }
        // `standardDurations` already honours --test / defaults; the Option items force test.
        baseDurations = testDurations ? .test : standardDurations
        machine.durations = baseDurations
        longBreak.reset()
        controls.model.testMode = baseDurations.isTestMode
        apply { $0.start(now: Self.now) }
    }

    /// "Up next" clicked: start a session whose goal screen opens with it filled in.
    func startWith(_ s: BlockSuggestion) {
        guard machine.phase == .idle else { return }
        pendingPick = s
        start(testDurations: NSEvent.modifierFlags.contains(.option))
    }

    func stop() {
        goalFlow = nil
        apply { $0.stop(now: Self.now) }
    }

    func togglePause() {
        if machine.isPaused { apply { $0.resume(now: Self.now) } } else { apply { $0.pause(now: Self.now) } }
    }

    func showControls() {
        refreshControls()
        controls.show()
    }

    /// First launch (or Board → "Choose"): "Run on my own keys" or "Join a friend's leaderboard".
    /// First launch (or Board → "Choose"). The owner's build offers the two cards; the standalone build has
    /// no leaderboard to join, so it goes straight to the own-keys key steps.
    func showJoin() {
        chooseOwnKeys()
        showControls()
    }

    func bringOverlayForward() { overlay.bringForward() }

    // MARK: - Engine


    private func apply(_ f: (inout PhaseMachine) -> [FocusEffect]) {
        let effects = f(&machine)
        effects.forEach(handle)
        refreshUI()
        if !effects.isEmpty {
            onStateChange?()
        }
    }

    private func handle(_ effect: FocusEffect) {
        let now = Self.now
        switch effect {
        case .sessionStarted:
            startLoop()
            sendEvent(.sessionStarted, blockId: "", goal: machine.lastGoal)

        case .showGoalPrompt(let prefill):
            hideWorkChrome()
            nextTickAt = .infinity
            // "Same as before" carries the last plan's sharpened goal only when that plan was for this very goal.
            let previous = GoalPlan.carried(Self.load(GoalPlan.self, key: "lastPlan"), to: machine.lastGoal)
            goalFlow = GoalFlow(previousGoal: machine.lastGoal, previousUnderstood: machine.lastUnderstood,
                                previousSpecific: previous.specificGoal)
            goalFlowToken = UUID()
            let choice = BlockLengthChoice(suggestion: suggestion?.suggestion(today: Self.today))
            overlay.showGoal(prefill: prefill, length: choice, scale: scale)
            if let pick = pendingPick {
                pendingPick = nil
                overlay.model.pick(pick)
            }
            fetchSuggestions(forGoalScreen: true)
            // Nothing from the last block is left beside the hours label on the goal screen.
            hoursHold = nil
            clearHoursAdd()
            refreshNow()

        case .countdownStarted:
            defaults.set(machine.lastGoal, forKey: "lastGoal")
            defaults.set(machine.lastUnderstood, forKey: "lastUnderstood")
            let n = machine.countdownNumber(now: now)
            overlay.showCountdown(n, goalLabel: machine.goal)
            blips.tick()

        case .workStarted(let id, let goal, _):
            defaults.set(machine.lastGoal, forKey: "lastGoal")
            defaults.set(machine.lastUnderstood, forKey: "lastUnderstood")
            blips.go()
            overlay.showGoThenHide()
            corner.show(FocusText.clock(machine.currentWorkLength), delay: 0.9)
            nudges.clear()
            minute = MeasureWindow()
            block = MeasureWindow()
            frames = []
            runningWorked = 0
            latestTip = ""
            distraction.reset()
            gate.reset()
            minuteDistraction = 0
            blockDistraction = 0
            revealContext = nil
            chrome.engage()
            nextTickAt = now + machine.durations.tickInterval
            nextActivityAt = now + machine.durations.activitySampleInterval
            nextDistractionAt = now + DistractionTracker.sampleInterval
            lastActivityAt = now
            nextInputAt = now + 1
            lastInputAt = now
            if mode.friend != nil { nextReportAt = now + LBReportSchedule.interval }
            machine.nextBreakIsLong = longBreak.wouldBeDue(afterBlock: machine.currentWorkLength, scale: scale)
            ignoreSwitchesUntil = now + 2
            lastShotAt = now
            shotsThisBlock = 0
            scheduleNextShot(from: now)
            senseHealth.reset()
            lastSenseText = ""; lastSenseDigest = ""; lastSenseApp = ""
            imageGate.reset()
            readyImage = nil
            if isScoring, !ScreenText.hasPermission {
                log.info("accessibility not granted — screen text only from Chrome/Safari tabs")
            }
            nextSenseAt = now + 2
            sendEvent(.blockStarted, blockId: id, goal: goal)

        case .workEnded(let timing):
            hideWorkChrome()
            nextShotAt = .infinity
            nextSenseAt = .infinity
            nextDistractionAt = .infinity
            nextReportAt = .infinity
            let endDay = DayKey.string(Date(timeIntervalSince1970: timing.endedAt))
            let worked = HoursMath.workedSeconds(completed: timing.completed, planned: timing.plannedSeconds,
                                                 lastKnownWorked: runningWorked)
            let before = loggedSeconds(running: 0)
            dayFocus.record(seconds: worked, completed: timing.completed, day: endDay)
            save(dayFocus, key: "dayFocus")
            runningWorked = 0
            if timing.completed {
                longBreak.recordBlock(worked: worked)
                scoreBlockId = timing.blockId
                let avgBefore = dayStats.day == endDay ? dayStats.averageScore : nil
                dayStats.recordBlock(day: endDay)
                save(dayStats, key: "dayStats")
                revealContext = RevealContext(blockId: timing.blockId, worked: worked, before: before,
                                              after: before + worked, avgBefore: avgBefore)
                hoursHold = before
            }
            if let friend = mode.friend { report(friend) }
            if isScoring {
                var scored = timing
                // The block is scored against whatever he ended up working on (the brain may have moved it).
                scored.goal = plan.goal.isEmpty ? timing.goal : plan.goal
                scored.understood = plan.understood
                let payload = BlockPayload(timing: scored, window: block, frames: frames,
                                           distractionS: Int(blockDistraction.rounded()), specificGoal: plan.specificGoal)
                pending.enqueue(payload)
                savePending()
                submit(payload)
            }

        case .breakStarted:
            chrome.restore(why: "break")
            announcer.breakTime()
            overlay.model.reveal = nil
            clearHoursAdd()
            overlay.model.revealFaded = false
            overlay.model.breakClock = FocusText.clock(machine.breakLength)
            if machine.breakIsLong {
                // Taking it: the count starts again.
                longBreak.reset()
                overlay.model.breakTitle = "LONG BREAK"
                overlay.model.longBreakProgress = 1
                overlay.model.longBreakLine = "Long break — you earned it"
            } else {
                overlay.model.breakTitle = "BREAK"
                overlay.model.longBreakProgress = longBreak.progress(scale: scale)
                overlay.model.longBreakLine = longBreak.progressText(scale: scale)
            }
            refreshOverlayHours()
            overlay.showBreak()
            refreshNow()
            minute = MeasureWindow()
            nextTickAt = now + machine.durations.tickInterval
            nextActivityAt = now + machine.durations.activitySampleInterval
            lastActivityAt = now
            nextInputAt = now + 1
            lastInputAt = now
            // Owner: reveal when the score lands (or after 9 s without it). Friend: right after the fade-in.
            revealFallback?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.startReveal(result: nil) }
            revealFallback = w
            DispatchQueue.main.asyncAfter(deadline: .now() + (isScoring ? 9 : 0.9), execute: w)
            // The break is rest: the corner card fades away 30 s in and the screen is empty after that.
            revealFade?.cancel()
            let fade = DispatchWorkItem { [weak self] in self?.overlay.model.revealFaded = true }
            revealFade = fade
            DispatchQueue.main.asyncAfter(deadline: .now() + BreakReveal.fadeStartsAt, execute: fade)

        case .breakSkipped(let id):
            cancelReveal()
            sendEvent(.breakSkipped, blockId: id, goal: machine.goal)

        case .breakEnded:
            cancelReveal()

        case .sessionStopped:
            chrome.restore(why: "session ended")
            goalFlow = nil
            longBreak.reset()
            cancelReveal()
            hideWorkChrome()
            overlay.hide()
            stopLoop()
            sendEvent(.sessionStopped, blockId: machine.blockId ?? "", goal: machine.goal)

        case .paused:
            edge.hide()
            distraction.reset()
            gate.reset()

        case .resumed:
            nextTickAt = now + machine.durations.tickInterval
            nextActivityAt = now + machine.durations.activitySampleInterval
            nextDistractionAt = now + DistractionTracker.sampleInterval
            lastActivityAt = now
            nextInputAt = now + 1
            lastInputAt = now
            if machine.phase == .work { scheduleNextShot(from: now) }
        }
    }

    private func noteAway(seconds: TimeInterval) {
        guard machine.phase != .idle, longBreak.noteAway(seconds: seconds, scale: scale) else { return }
        log.info("away \(Int(seconds)) s: long-break count reset")
        if machine.phase == .work {
            machine.nextBreakIsLong = longBreak.wouldBeDue(afterBlock: machine.currentWorkLength, scale: scale)
        }
    }

    private func hideWorkChrome() {
        corner.hide()
        edge.hide()
        nudges.clear()
        toast.hide()
    }

    private func startLoop() {
        loopTimer?.invalidate()
        // 10×/s: smooth enough for the half-second edge pulse and the countdown punches.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.loop() }
        RunLoop.main.add(t, forMode: .common)
        loopTimer = t
    }

    private func stopLoop() {
        loopTimer?.invalidate()
        loopTimer = nil
        nextTickAt = .infinity
        nextShotAt = .infinity
        nextSenseAt = .infinity
        nextActivityAt = .infinity
        nextDistractionAt = .infinity
        nextInputAt = .infinity
        nextReportAt = .infinity
    }

    private func loop() {
        if overlay.model.rubricFix.holdsStart, machine.phase == .goal {
            // He is fixing the rubric: the goal screen waits; a rewrite that never comes back is given up.
            if overlay.model.rubricFix.tick(now: Self.now) { rubricFixClosed() }
        } else if var flow = goalFlow, machine.phase == .goal {
            let fx = flow.tick(now: Self.now)
            goalFlow = flow
            handleGoal(fx)
        }
        apply { $0.tick(now: Self.now) }
        let now = Self.now
        let phase = machine.phase
        // Away from the Mac 25+ min (no input, or the loop stalled while asleep) = his long break.
        if lastLoopAt > 0, now - lastLoopAt > 60 { noteAway(seconds: now - lastLoopAt) }
        lastLoopAt = now
        if now >= nextAwayCheckAt {
            nextAwayCheckAt = now + 5
            noteAway(seconds: activity.secondsSinceLastInput())
        }
        guard !machine.isPaused, phase == .work || phase == .onBreak else { return }

        if phase == .work, let change = nudges.tick(now: now) {
            switch change {
            case .show(let text): toast.show(text)
            case .hide: toast.hide()
            }
        }
        if now >= nextInputAt {
            // Scroll / keystroke seconds, sampled once a second (no permission needed).
            let interval = min(now - lastInputAt, 3)
            lastInputAt = now
            nextInputAt = now + 1
            let scroll = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)
            let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            minute.addInput(interval: interval, sinceScroll: scroll, sinceKey: key)
            if phase == .work { block.addInput(interval: interval, sinceScroll: scroll, sinceKey: key) }
        }
        if now >= nextActivityAt {
            let interval = min(now - lastActivityAt, machine.durations.activitySampleInterval * 3)
            lastActivityAt = now
            nextActivityAt = now + machine.durations.activitySampleInterval
            let ctx = activity.currentContext()
            let idle = activity.secondsSinceLastInput()
            minute.addActivity(context: ctx, interval: interval, sinceLastEvent: idle)
            if phase == .work { block.addActivity(context: ctx, interval: interval, sinceLastEvent: idle) }
        }
        if phase == .work, now >= nextDistractionAt {
            nextDistractionAt = now + DistractionTracker.sampleInterval
            checkDistraction(now: now)
        }
        if now >= nextTickAt {
            nextTickAt = now + machine.durations.tickInterval
            sendTick(now: now)
        }
        if phase == .work, now >= nextShotAt {
            scheduleNextShot(from: now)
            // While Jev is judging the sense posts carry their own screenshots; this schedule is the fallback.
            if senseHealth.screenshotsOnSchedule { captureFrame() }
        }
        if phase == .work, now >= nextSenseAt {
            nextSenseAt = now + SenseHealth.interval
            sense(now: now)
        }
        if phase == .work, now >= nextReportAt, let friend = mode.friend {
            nextReportAt = now + LBReportSchedule.interval
            report(friend)
        }
    }

    private func refreshUI() {
        let now = Self.now
        switch machine.phase {
        case .countdown:
            let n = machine.countdownNumber(now: now)
            if overlay.model.countdown != n, n > 0 {
                overlay.model.countdown = n
                blips.tick()
            }
        case .work:
            let remaining = machine.remaining(now: now)
            runningWorked = max(0, machine.currentWorkLength - remaining)
            let pulsing = EdgePulse.isActive(phase: .work, paused: machine.isPaused, remaining: remaining,
                                             work: machine.currentWorkLength)
            let lit = pulsing && EdgePulse.isLit(remaining: remaining)
            if pulsing { edge.show(); edge.setLit(lit) } else if edge.isShown { edge.hide() }
            corner.update(FocusText.clock(remaining), paused: machine.isPaused, lit: lit)
            // What the hover box shows if he rests the pointer on the pill.
            corner.setGoal(plan.goal, specific: plan.specificGoal, progress: goalProgress)
        case .onBreak:
            let c = FocusText.clock(machine.remaining(now: now))
            if overlay.model.breakClock != c { overlay.model.breakClock = c }
        case .idle, .goal:
            break
        }
        refreshControls()
    }

    /// Hours logged today: the server's figure when fresh, never less than this Mac's, plus the running block.
    private func loggedSeconds(running: TimeInterval) -> Double {
        HoursMath.loggedSeconds(serverFocusS: snapshot?.today.focusS, serverDay: snapshotDay, local: dayFocus,
                                today: Self.today, running: running, localAtServer: snapshotLocalBase)
    }

    /// A daily hours goal counts as set once he (or the server) chose one; otherwise the label shows hours only.
    private var hoursGoalSet: Bool { defaults.double(forKey: "dailyHoursGoal") > 0 || snapshot?.today.goalHours != nil }

    /// The top-left hours label on the black screens (main display): same figure as the control window.
    private func refreshOverlayHours() {
        let h = OverlayHours.make(serverFocusS: snapshot?.today.focusS, serverDay: snapshotDay,
                                  localAtServer: snapshotLocalBase, local: dayFocus, today: Self.today,
                                  running: machine.phase == .work ? runningWorked : 0,
                                  goalHours: hoursGoalSet ? goalHours : nil)
        var shown = h
        if let hold = hoursHold { shown.seconds = min(hold, h.seconds) }
        if overlay.model.hours != shown { overlay.model.hours = shown }
    }

    func refreshControls() {
        let now = Self.now
        let today = Self.today
        let nextWork: TimeInterval
        switch machine.phase {
        case .idle: nextWork = standardDurations.work
        case .goal: nextWork = overlay.model.length.seconds(scale: scale)
        default: nextWork = machine.durations.work
        }
        // The block's goal can move mid-block (the brain spotted he switched), so the window shows `plan`.
        let goal = machine.phase == .goal ? machine.lastGoal : (plan.goal.isEmpty ? machine.goal : plan.goal)
        let understood = machine.phase == .goal ? machine.lastUnderstood
                                                : (plan.goal.isEmpty ? machine.understood : plan.understood)
        var s = ControlState.make(phase: machine.phase, isPaused: machine.isPaused, remaining: machine.remaining(now: now),
                                  nextWork: nextWork, goal: goal, understood: understood,
                                  todayLine: dayStats.line(today: today))
        if machine.phase == .onBreak && machine.breakIsLong {
            s.phaseLabel = machine.isPaused ? "Long break paused" : "Long break"
        }
        if controls.model.state != s { controls.model.state = s }

        let logged = loggedSeconds(running: machine.phase == .work ? runningWorked : 0)
        var live = LiveInfo()
        live.loggedText = HoursMath.loggedText(logged)
        live.goalText = HoursMath.goalText(goalHours)
        live.dayProgress = HoursMath.progress(seconds: logged, goalHours: goalHours)
        let showPlan = machine.phase != .idle
        live.specificGoal = showPlan ? (machine.phase == .goal ? "" : plan.specificGoal) : ""
        live.goalProgress = showPlan ? goalProgress : nil
        live.tip = machine.phase == .work ? latestTip : ""
        live.online = isScoring ? online : nil
        live.upNext = machine.phase == .idle && isScoring ? Array(upNext.prefix(2)) : []
        live.canChangeGoal = machine.phase == .work
        let blockRunning = machine.phase == .work || machine.phase == .onBreak
        live.rubricLine = blockRunning && (snapshot?.active ?? false)
            ? Rubric.nowLine(now: snapshot?.rubric, local: blockRubric, reached: snapshot?.milestonesReached) : ""
        live.note = ""
        if machine.phase != .idle {
            let longNow = machine.phase == .onBreak && machine.breakIsLong
            live.longBreakProgress = longNow ? 1 : longBreak.progress(scale: scale)
            live.longBreakText = longNow ? "Long break — you earned it" : longBreak.progressText(scale: scale)
        }
        if controls.model.live != live { controls.model.live = live }
        refreshOverlayHours()
    }

    private func syncModeToControls() {
        if brainMode == .local {
            controls.model.mode = .local
            if controls.model.tab == .board { controls.model.tab = .now }
            return
        }
        switch mode {
        case .owner: controls.model.mode = .owner
        case .friend(let f): controls.model.mode = .friend; controls.model.joinedName = f.name
        case .needsJoin: controls.model.mode = .notJoined
        }
    }

    // MARK: - Goal understanding

    private func submitGoalText(_ text: String) {
        guard machine.phase == .goal, var flow = goalFlow else { return }
        let fx = flow.submit(text, now: Self.now)
        goalFlow = flow
        handleGoal(fx)
    }

    private func handleGoal(_ effects: [GoalFlow.Effect]) {
        for e in effects {
            switch e {
            case .showUnderstanding:
                overlay.model.goalStatus = .understanding
            case .post(let req, let requestId):
                let token = goalFlowToken
                guard let route = target(.goal) else {
                    // Nowhere to ask (no config, or a friend who hasn't joined): go with the text as typed.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.goalFlowToken == token, var flow = self.goalFlow else { return }
                        let fx = flow.receive(nil, requestId: requestId, now: Self.now)
                        self.goalFlow = flow
                        self.handleGoal(fx)
                    }
                    continue
                }
                Task { @MainActor [weak self, brain] in
                    // Slightly past the flow's own 6 s timeout so the flow decides, not the socket.
                    let resp = await brain.send(url: route.url, label: route.label, body: req,
                                                headers: route.headers, timeout: GoalFlow.timeout + 1)
                    guard let self, self.goalFlowToken == token, var flow = self.goalFlow,
                          self.machine.phase == .goal else { return }
                    let fx = flow.receive(resp.flatMap(GoalReply.parse), requestId: requestId, now: Self.now)
                    self.goalFlow = flow
                    self.handleGoal(fx)
                }
            case .showQuestion(let q):
                overlay.model.goalText = ""
                overlay.model.goalStatus = .question(q)
                overlay.model.focusToken += 1
            case .showUnderstood(let u):
                overlay.model.goalStatus = .understood(u)
            case .showRubric(let r):
                overlay.model.rubricNote = ""
                overlay.model.rubricFix = RubricFix(rubric: r)
            case .proceed(let goal, let understood, let specific):
                goalFlow = nil
                // The latest rubric (after any "Fix…") rides with the block for the Now tab.
                blockRubric = overlay.model.rubricFix.rubric
                overlay.model.rubricFix = RubricFix()
                // The length chosen on this goal screen drives this block (timer, pulse, planned_s, long break).
                machine.durations.work = overlay.model.length.seconds(scale: scale)
                let sameAsBefore = goal == plan.goal && specific == plan.specificGoal
                plan = GoalPlan(goal: goal, understood: understood, specificGoal: specific)
                if !sameAsBefore { goalProgress = nil }
                // Saved WITH its goal: the next "same" only reuses the sharpened goal for this same goal.
                save(plan, key: "lastPlan")
                apply { $0.submitGoal(goal, understood: understood, now: Self.now) }
            }
        }
    }

    // MARK: - Rubric "Fix…" (goal screen)

    private func openRubricFix() {
        guard machine.phase == .goal, goalFlow != nil else { return }
        overlay.model.rubricNote = ""
        overlay.model.rubricFix.open()
    }

    /// Return in the "Fix…" field: the same goal goes back to `/goal` (or `/lb/focus/goal`) with `rubric_note`.
    private func sendRubricNote(_ raw: String) {
        guard machine.phase == .goal, let flow = goalFlow else { return }
        guard let note = overlay.model.rubricFix.submit(raw, now: Self.now) else { rubricFixClosed(); return }
        let requestId = overlay.model.rubricFix.requestId
        let req = GoalRequest(text: flow.text, previousGoal: flow.previousGoal,
                              previousUnderstood: flow.previousUnderstood, rubricNote: note, at: Int(Self.now))
        guard let route = target(.goal) else {
            overlay.model.rubricFix.receive(nil, requestId: requestId)
            rubricFixClosed()
            return
        }
        let token = goalFlowToken
        Task { @MainActor [weak self, brain] in
            let resp = await brain.send(url: route.url, label: route.label, body: req,
                                        headers: route.headers, timeout: RubricFix.timeout)
            guard let self, self.goalFlowToken == token, self.machine.phase == .goal else { return }
            if self.overlay.model.rubricFix.receive(Rubric.parse(resp?["rubric"]), requestId: requestId) {
                self.rubricFixClosed()
            }
        }
    }

    private func closeRubricFix() {
        if overlay.model.rubricFix.escape() { rubricFixClosed() }
    }

    /// The field closed (new summary, Esc, empty, or given up): a moment to read it, then Start as usual.
    private func rubricFixClosed() {
        overlay.model.rubricNote = ""
        guard var flow = goalFlow else { return }
        flow.holdUntil(Self.now + GoalFlow.afterFixHold)
        goalFlow = flow
    }

    // MARK: - Distractions

    private func checkDistraction(now: TimeInterval) {
        let ctx = activity.currentContext()
        let about = [plan.goal, plan.specificGoal, plan.understood].joined(separator: " ")
        let label = Distraction.classify(ctx, goal: about)
        let before = distraction.seconds
        let hit = distraction.observe(label, now: now)
        let added = distraction.seconds - before
        // Relevance before the note: everything but Instagram/TikTok waits for the next
        // frame verdict, which says whether the site is actually serving the goal.
        apply(gate: gate.sample(label: label, toastNow: hit, seconds: added, now: now), now: now)
        apply(gate: gate.expire(now: now), now: now)
    }

    /// Count, drop, or toast what the gate decided. While Jev is judging the brain decides every nudge (after
    /// ~20 s of confident off-task), so a toast here only counts its seconds and shows nothing.
    private func apply(gate outcome: DistractionGate.Outcome, now: TimeInterval) {
        var outcome = outcome
        if senseHealth.isJudging, case .toast(let label, let seconds) = outcome {
            log.info("distraction: \(label, privacy: .public) (counted; Jev decides the nudge)")
            outcome = .counted(seconds)
        }
        switch outcome {
        case .none, .held:
            return
        case .dropped(let seconds):
            if seconds > 0 { log.info("distraction serves the goal — \(Int(seconds)) s not counted") }
        case .counted(let seconds):
            minuteDistraction += seconds
            blockDistraction += seconds
        case .toast(let label, let seconds):
            minuteDistraction += seconds
            blockDistraction += seconds
            let text = Distraction.toastText(label: label, goal: machine.goal)
            log.info("distraction: \(label, privacy: .public)")
            if case .show(let t)? = nudges.interrupt(text, now: now) { toast.show(t) }
        }
    }

    // MARK: - Measurements

    private func recordSwitch() {
        guard !machine.isPaused, Self.now >= ignoreSwitchesUntil else { return }
        switch machine.phase {
        case .work:
            minute.addSwitch(); block.addSwitch()
            // Check the new front app soon rather than waiting for the next sample.
            nextDistractionAt = min(nextDistractionAt, Self.now + 0.5)
            // And take a shot of whatever he just switched to, unless one went out in the last 20 s
            // (Jev sees the switch itself within a second; the shot is for the screenshot schedule).
            if senseHealth.screenshotsOnSchedule,
               let at = ScreenshotSchedule.shotAfterSwitch(now: Self.now, lastShotAt: lastShotAt,
                                                           nextShotAt: nextShotAt) {
                nextShotAt = at
            }
        case .onBreak: minute.addSwitch()
        default: break
        }
    }

    private func scheduleNextShot(from now: TimeInterval) {
        nextShotAt = now + ScreenshotSchedule.nextDelay(interval: machine.durations.screenshotInterval,
                                                        jitter: machine.durations.screenshotJitter,
                                                        unitRandom: Double.random(in: 0...1))
    }

    private func captureFrame() {
        guard ScreenshotSchedule.shouldCapture(phase: machine.phase, paused: machine.isPaused,
                                               screenLocked: ScreenCapturer.isScreenLocked,
                                               displayAsleep: ScreenCapturer.isDisplayAsleep),
              ScreenCapturer.hasPermission, let route = target(.frame),
              let blockId = machine.blockId else { return }
        // The app's own ceiling for the block (the server has one too).
        guard shotsThisBlock < ScreenshotSchedule.maxPerBlock(workSeconds: machine.currentWorkLength,
                                                             interval: machine.durations.screenshotInterval) else { return }
        let friend = judgesOnOwnKey
        if friend, !typesafe.canJudge(now: Self.now) { return }
        if friend { typesafe.sent(now: Self.now) }
        shotsThisBlock += 1
        lastShotAt = Self.now
        let goal = plan.goal.isEmpty ? machine.goal : plan.goal
        let understood = plan.understood
        let specific = plan.specificGoal
        let ctx = activity.currentContext()
        Task { @MainActor [weak self] in
            guard let jpeg = await ScreenCapturer.captureMainDisplayJPEG() else { return }
            let payload = FramePayload(blockId: blockId, goal: goal, understood: understood, at: Int(Self.now),
                                       imageJpegB64: jpeg.base64EncodedString(), context: ctx, specificGoal: specific)
            guard let self else { return }
            let reply = await self.brain.sendWithStatus(url: route.url, label: route.label, body: payload,
                                                        headers: route.headers)
            if friend, self.noteJudged(reply) { return }
            guard (200..<300).contains(reply.status), let resp = reply.json else { return }
            // Only keep it if we're still in the same block.
            guard self.machine.phase == .work, self.machine.blockId == blockId else { return }
            self.frames.append(resp)
            let result = FrameResult.parse(resp)
            // The verdict that a held distraction toast was waiting for.
            self.apply(gate: self.gate.frameVerdict(servesGoal: result.servesGoal), now: Self.now)
            if !result.nudge.isEmpty { self.nudges.push(result.nudge) }
            self.goalProgress = GoalProgress.merge(self.goalProgress, result.goalProgress)
            if let tip = result.tip, !tip.isEmpty { self.latestTip = tip }
            self.apply(goalChange: result.goalChanged)
            self.refreshControls()
        }
    }

    /// Once a second: the front window's text and what changed, to the brain for Jev, with a screenshot on the
    /// seconds `ImageGate` picks. Never two in flight; a locked or sleeping screen sends nothing. The reply may
    /// carry a verdict (whose `serves_goal` settles a held distraction site), a nudge, a minute frame,
    /// progress and a goal change.
    private func sense(now: TimeInterval) {
        guard !senseInFlight, isScoring, machine.phase == .work, !machine.isPaused,
              !ScreenCapturer.isScreenLocked, !ScreenCapturer.isDisplayAsleep,
              let route = target(.sense), let blockId = machine.blockId else { return }
        let friend = judgesOnOwnKey
        // No TypeSafe key: one probe a minute, not one a second (the rest of the block runs as normal).
        if friend, !typesafe.canJudge(now: now) { return }
        if friend { typesafe.sent(now: now) }
        senseInFlight = true
        let ctx = activity.currentContext()
        let sinceScroll = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let idle = activity.secondsSinceLastInput()
        let switched = ctx.app != lastSenseApp
        lastSenseApp = ctx.app
        let goal = plan.goal.isEmpty ? machine.goal : plan.goal
        let understood = plan.understood
        let specific = plan.specificGoal
        // The distraction site this screen is (if any): the reply's serves_goal settles it only if it is still held.
        let siteLabel = Distraction.classify(ctx, goal: [plan.goal, plan.specificGoal, plan.understood].joined(separator: " "))
        ScreenText.read { [weak self] text in
            guard let self else { return }
            guard self.machine.phase == .work, self.machine.blockId == blockId else {
                self.senseInFlight = false
                return
            }
            let digest = TextChange.digest(text)
            let changed = digest != self.lastSenseDigest
            let share = changed ? TextChange.share(old: self.lastSenseText, new: text) : 0
            if changed { self.lastSenseText = text; self.lastSenseDigest = digest }
            let image = self.senseImage(for: ctx, text: text, now: now)
            let payload = SensePayload(blockId: blockId, goal: goal, understood: understood, specificGoal: specific,
                                       at: Int(now), context: ctx, text: changed ? text : nil, textDigest: digest,
                                       textChangedShare: share, typed: sinceKey <= 1.5, scrolled: sinceScroll <= 1.5,
                                       idleS: Self.wholeSeconds(idle), appSwitched: switched,
                                       axTrusted: ScreenText.hasPermission, imageJpegB64: image)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.senseInFlight = false }
                let reply = await self.brain.sendWithStatus(url: route.url, label: route.label, body: payload,
                                                            headers: route.headers, timeout: image == nil ? 8 : 12)
                if friend, self.noteJudged(reply) { return }
                let resp = (200..<300).contains(reply.status) ? reply.json : nil
                guard self.machine.phase == .work, self.machine.blockId == blockId else { return }
                guard let resp else {
                    self.senseHealth.failed()
                    if self.senseHealth.screenshotsOnSchedule, self.senseHealth.failures == SenseHealth.failuresBeforeFallback {
                        log.info("jev unreachable — screenshots back on schedule")
                    }
                    return
                }
                let wasJudging = self.senseHealth.isJudging
                self.senseHealth.succeeded()
                if !wasJudging { log.info("jev judging — screenshots ride on the sense posts") }
                let r = SenseResult.parse(resp)
                // The held distraction site is settled by Jev's verdict on that same site.
                if let serves = r.servesGoal, let held = self.gate.heldLabel, held == siteLabel {
                    self.apply(gate: self.gate.frameVerdict(servesGoal: serves), now: Self.now)
                }
                if !r.nudge.isEmpty, case .show(let t)? = self.nudges.interrupt(r.nudge, now: Self.now) {
                    let shown = ShownNudge(blockId: blockId, nudgeId: r.nudgeId, context: ctx, at: Int(Self.now))
                    self.toast.show(t, button: (ExceptionReply.buttonTitle, { [weak self] in self?.markForWork(shown) }))
                }
                if let frame = r.frame { self.frames.append(frame) }
                self.goalProgress = GoalProgress.merge(self.goalProgress, r.goalProgress)
                self.apply(goalChange: r.goalChanged)
                if r.frame != nil { self.refreshControls() }
            }
        }
    }

    /// The screenshot for this second's sense post, base64, or nil. A capture that finished for this same screen
    /// goes out now (and only then does the gate count it as sent); otherwise, when the gate wants a picture, a
    /// capture starts in the background for the next post — the 1-second cadence never waits for it.
    private func senseImage(for ctx: AppContext, text: String, now: TimeInterval) -> String? {
        let key = ImageGate.screenKey(ctx)
        if let ready = readyImage {
            readyImage = nil
            if ready.key == key, Self.now - ready.at <= ImageGate.repeatEvery {
                imageGate.sent(context: ctx, now: now)
                return ready.b64
            }
        }
        if imageGate.wants(context: ctx, text: text, now: now) { startSenseCapture(key: key) }
        return nil
    }

    private func startSenseCapture(key: String) {
        guard !senseCaptureInFlight, ScreenCapturer.hasPermission, !ScreenCapturer.isScreenLocked,
              !ScreenCapturer.isDisplayAsleep, let blockId = machine.blockId else { return }
        senseCaptureInFlight = true
        Task { @MainActor [weak self] in
            let jpeg = await ScreenCapturer.captureSenseJPEG()
            guard let self else { return }
            self.senseCaptureInFlight = false
            guard let jpeg, self.machine.phase == .work, !self.machine.isPaused, self.machine.blockId == blockId else { return }
            self.readyImage = (key, jpeg.base64EncodedString(), Self.now)
            // Send it with the next post right away rather than up to a second later.
            if !self.senseInFlight { self.nextSenseAt = min(self.nextSenseAt, Self.now) }
        }
    }

    /// A sense nudge on screen, and the screen it was about (for "I'm on task").
    private struct ShownNudge {
        var blockId: String
        var nudgeId: String
        var context: AppContext
        var at: Int
    }

    /// "I'm on task" clicked: tell the brain this screen counts as work for the rest of the block.
    private func markForWork(_ n: ShownNudge) {
        guard machine.phase == .work, machine.blockId == n.blockId, let route = target(.exception) else { return }
        toast.setButtonBusy(true)
        let payload = ExceptionPayload(blockId: n.blockId, nudgeId: n.nudgeId, context: n.context, at: n.at)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resp = await self.brain.send(url: route.url, label: route.label, body: payload,
                                             headers: route.headers, timeout: 10)
            guard self.machine.phase == .work, self.machine.blockId == n.blockId else { return }
            let reply = resp.map(ExceptionReply.parse)
            guard reply?.ok == true else {
                log.info("on task: not saved")
                self.toast.buttonFailed(text: ExceptionReply.failure)
                return
            }
            log.info("on task: \(reply?.rule ?? "", privacy: .public)")
            if case .show(let t)? = self.nudges.interrupt(ExceptionReply.confirmation, now: Self.now, for: 4) {
                self.toast.show(t)
            }
        }
    }

    /// A seconds count for the wire (never negative, never a crash on a nonsense clock).
    private static func wholeSeconds(_ t: TimeInterval) -> Int {
        guard t.isFinite, t > 0 else { return 0 }
        return Int(min(t, 7 * 86_400).rounded(.down))
    }

    // MARK: - Brain

    private func sendTick(now: TimeInterval) {
        let distractionS = Int(minuteDistraction.rounded())
        minuteDistraction = 0
        guard let route = target(.tick) else { minute = MeasureWindow(); return }
        let payload = TickPayload(blockId: machine.blockId ?? "", goal: plan.goal.isEmpty ? machine.goal : plan.goal,
                                  understood: plan.understood,
                                  at: Int(now), phase: machine.phase, window: minute, context: activity.currentContext(),
                                  distractionS: distractionS, idleS: Self.wholeSeconds(activity.secondsSinceLastInput()))
        minute = MeasureWindow()
        let blockId = machine.blockId
        Task { @MainActor [weak self] in
            guard let self, let resp = await self.brain.send(url: route.url, label: route.label, body: payload,
                                                            headers: route.headers) else { return }
            // The brain answers a tick with a nudge when his eyes have been
            // blank for a few minutes ("stand up, then re-read the last paragraph").
            guard self.machine.phase == .work, self.machine.blockId == blockId else { return }
            let result = FrameResult.parse(resp)
            if !result.nudge.isEmpty { self.nudges.push(result.nudge) }
            self.goalProgress = GoalProgress.merge(self.goalProgress, result.goalProgress)
            if let tip = result.tip, !tip.isEmpty { self.latestTip = tip }
            self.apply(goalChange: result.goalChanged)
        }
    }

    /// The brain spotted that he moved to another goal: replace the block's goal (later frames, ticks and the
    /// block summary carry the new one), tell him in a blue toast, and start the progress bar again.
    private func apply(goalChange change: GoalChange?) {
        guard let change, machine.phase == .work, change.changes(plan) else { return }
        plan = change.applied(to: plan)
        goalProgress = nil
        log.info("goal changed by the brain")
        if case .show(let t)? = nudges.interrupt(change.toastText, now: Self.now) { toast.show(t) }
        refreshControls()
    }

    private func sendEvent(_ kind: EventKind, blockId: String, goal: String) {
        guard let route = target(.event) else { return }
        let payload = EventPayload(kind: kind, blockId: blockId, goal: goal, at: Int(Self.now))
        Task { [brain] in
            _ = await brain.send(url: route.url, label: route.label, body: payload, headers: route.headers)
        }
    }

    private func submit(_ payload: BlockPayload) {
        guard !inFlight.contains(payload.blockId), let route = target(.block) else { return }
        inFlight.insert(payload.blockId)
        Task { @MainActor [weak self, brain] in
            let resp = await brain.send(url: route.url, label: route.label, body: payload, headers: route.headers)
            guard let self else { return }
            self.inFlight.remove(payload.blockId)
            let result = resp.flatMap(BlockResult.parse)
            if resp != nil {
                // Delivered (even if the reply was odd) — don't resend.
                self.pending.remove(blockId: payload.blockId)
                self.savePending()
            }
            let isLatest = self.scoreBlockId == payload.blockId
            if let result, payload.completed {
                let day = DayKey.string(Date(timeIntervalSince1970: TimeInterval(payload.endedAt)))
                if day == Self.today {
                    self.dayStats.recordScore(result.score, day: day)
                    self.save(self.dayStats, key: "dayStats")
                }
            }
            // The brain's next length is a suggestion only: a chip on the next goal screen (newest block wins).
            if isLatest, let json = resp, let advice = NextBlockAdvice.parse(json) {
                let sug = BlockLengthChoice.suggestion(from: advice, scale: self.scale)
                if sug.minutes == BlockLengthChoice.defaultMinutes {
                    self.suggestion = nil
                    UserDefaults.standard.removeObject(forKey: "suggestedLength")
                } else {
                    let stored = StoredSuggestion(minutes: sug.minutes, reason: sug.reason, day: Self.today)
                    self.suggestion = stored
                    self.save(stored, key: "suggestedLength")
                }
            }
            self.refreshControls()
            guard isLatest, self.machine.phase == .onBreak else { return }
            // The break screen is rest: no advice, no "suggested next block" line — the score reveal only.
            self.startReveal(result: result)
        }
    }

    private func retryPending() {
        pending.items.forEach(submit)
    }

    private func savePending() {
        try? pending.encoded().write(to: pendingURL, options: .atomic)
    }

    // MARK: - Break-screen score reveal

    /// Starts the count-up / bars / "+25 min" → hours animation once per block, with its sounds.
    private func startReveal(result: BlockResult?) {
        guard machine.phase == .onBreak, let ctx = revealContext, revealedBlockId != ctx.blockId else { return }
        revealedBlockId = ctx.blockId
        revealFallback?.cancel()
        revealFallback = nil

        let goalSecs = goalHours * 3600
        let hitGoal = ctx.before < goalSecs && ctx.after >= goalSecs
        let beatAvg = result.map { r in ctx.avgBefore.map { r.score > $0 } ?? false } ?? false
        var line = ""
        if hitGoal { line = "Daily goal hit — \(HoursMath.hoursText(goalHours)) done!" }
        else if beatAvg, let avg = ctx.avgBefore { line = "Above your average today (\(avg))" }
        let note = isScoring ? "Score pending" : "No brain to score this one"
        overlay.model.reveal = OverlayModel.Reveal(
            score: result?.score, focus: result?.focusScore, output: result?.outputScore,
            workedMinutes: max(1, Int((ctx.worked / 60).rounded())),
            celebrate: hitGoal || beatAvg, celebrateLine: line, note: note, startedAt: Date())
        scheduleRevealSounds(hasScore: result != nil, celebrate: hitGoal || beatAvg, ctx: ctx)
    }

    private func scheduleRevealSounds(hasScore: Bool, celebrate: Bool, ctx: RevealContext) {
        revealSounds.forEach { $0.cancel() }
        revealSounds = []
        func at(_ t: Double, _ f: @escaping () -> Void) {
            let w = DispatchWorkItem { [weak self] in
                guard self?.machine.phase == .onBreak else { return }
                f()
            }
            revealSounds.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, t), execute: w)
        }
        let shift = hasScore ? 0 : -ScoreRevealTiming.chipAppear + 0.3
        if hasScore {
            // A rising tick in step with the count-up (ease-out-expo: fast then slowing), then a chime as it lands.
            let n = Blips.riseSteps
            for i in 0..<n {
                let p = Double(i + 1) / Double(n + 1)
                let t = -log2(1 - p) / 10 * ScoreRevealTiming.countUp
                at(t) { [blips] in blips.rise(i) }
            }
            at(ScoreRevealTiming.countUp) { [blips] in blips.chime() }
        }
        // The chip lands on the top-left hours label: it sits there for a moment, then the digits count up to
        // the new total and the chip is absorbed into them (`HoursAddition`).
        at(ScoreRevealTiming.hoursTick + shift) { [weak self, blips] in
            blips.tick()
            self?.startHoursAdd(ctx: ctx)
        }
        if celebrate { at(ScoreRevealTiming.burstAt + shift) { [blips] in blips.celebrate() } }
    }

    /// The "+25 min" is handed to the hours label: chip, then the digits climb to today's new total, then gone.
    private func startHoursAdd(ctx: RevealContext) {
        // The count-up takes over from here: it starts at the held figure and climbs to the new total.
        hoursHold = nil
        refreshOverlayHours()
        var add = HoursAddition.make(before: ctx.before, worked: ctx.worked,
                                     serverFocusS: snapshot?.today.focusS, serverDay: snapshotDay,
                                     today: Self.today, startedAt: Date())
        // Never land below what the label would show anyway (another launch's hours), never add the block twice.
        add.to = max(add.to, loggedSeconds(running: 0))
        overlay.model.hoursAdd = add
        hoursAddClear?.cancel()
        // Runs whatever happens next (break skipped, session ended): the chip never outlives its own animation.
        let done = DispatchWorkItem { [weak self] in self?.overlay.model.hoursAdd = nil }
        hoursAddClear = done
        DispatchQueue.main.asyncAfter(deadline: .now() + add.duration, execute: done)
    }

    /// Cut the "+25 min" cleanly: the label goes straight to today's total with no chip beside it.
    private func clearHoursAdd() {
        hoursAddClear?.cancel()
        hoursAddClear = nil
        overlay.model.hoursAdd = nil
    }

    private func cancelReveal() {
        // Break skipped or ended before the count-up: go straight to the true total.
        hoursHold = nil
        clearHoursAdd()
        refreshOverlayHours()
        revealFallback?.cancel()
        revealFallback = nil
        revealFade?.cancel()
        revealFade = nil
        revealSounds.forEach { $0.cancel() }
        revealSounds = []
    }

    // MARK: - Live control window

    private func startLive() {
        liveTimer?.invalidate()
        liveTicks = 0
        refreshNow()
        if machine.phase == .idle { fetchSuggestions(forGoalScreen: false) }
        if controls.model.tab == .board { refreshBoard() }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.controls.isVisible else { self.stopLive(); return }
            self.liveTicks += 1
            self.refreshNow()
            if self.controls.model.tab == .board, self.liveTicks % 3 == 0 { self.refreshBoard() }
        }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    private func stopLive() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    /// `GET /admin/focus/now` (owner). Falls back to local state when unreachable.
    private func refreshNow() {
        guard let route = target(.now) else { refreshControls(); return }
        Task { @MainActor [weak self, brain] in
            let resp = await brain.send(url: route.url, label: route.label, body: Optional<JSONValue>.none,
                                        headers: route.headers, timeout: 12)
            guard let self else { return }
            if self.judgesOnOwnKey, let json = resp { self.noteKeyStatus(TypeSafeStatus.parse(json)) }
            guard let json = resp, let s = NowSnapshot.parse(json) else {
                self.online = false
                self.refreshControls()
                return
            }
            self.online = true
            self.snapshot = s
            self.snapshotDay = Self.today
            self.snapshotLocalBase = self.dayFocus.seconds(today: Self.today)
            if let g = s.today.goalHours, self.settingsWork == nil, g != self.goalHours {
                self.goalHours = g
                self.defaults.set(g, forKey: "dailyHoursGoal")
                self.controls.model.goalHours = g
            }
            let running = self.machine.phase == .work || self.machine.phase == .onBreak
            let sameGoal = GoalProgress.sameGoal(s.specificGoal, self.plan.specificGoal)
                || (s.specificGoal.isEmpty && GoalProgress.sameGoal(s.goal, self.plan.goal))
            if running, sameGoal {
                self.goalProgress = GoalProgress.merge(self.goalProgress, s.goalProgress)
                if self.latestTip.isEmpty, !s.tip.isEmpty { self.latestTip = s.tip }
            }
            self.refreshControls()
        }
    }

    /// `GET /admin/focus/suggestions` (owner). Never blocks typing: the cards fade in when they arrive and
    /// stay hidden on failure. Friends get none.
    func fetchSuggestions(forGoalScreen: Bool) {
        guard let route = target(.suggestions) else { return }
        let token = UUID()
        suggestionsToken = token
        Task { @MainActor [weak self, brain] in
            let resp = await brain.send(url: route.url, label: route.label, body: Optional<JSONValue>.none,
                                        headers: route.headers, timeout: 8)
            guard let self, self.suggestionsToken == token else { return }
            let items = resp.map(BlockSuggestion.parse) ?? []
            if resp != nil { self.upNext = items }
            if forGoalScreen, self.machine.phase == .goal, self.overlay.model.goalStatus == .idle,
               self.overlay.model.suggestions.isEmpty {
                self.overlay.model.suggestions = SuggestionPicker(items: items)
            }
            self.refreshControls()
        }
    }

    // MARK: - Clean focus mode

    /// The two Settings toggles, off until he turns them on. Stored in the
    /// app's own defaults, so they survive a restart like every other setting.
    static func cleanFocusPrefs() -> CleanFocusPrefs {
        let d = UserDefaults.standard
        return CleanFocusPrefs(hideDockAndMenuBar: d.bool(forKey: "hideDockAndMenuBar"),
                               hideDesktopIcons: d.bool(forKey: "hideDesktopIcons"))
    }

    /// A toggle was flipped on the goal screen. Turning one OFF mid-session
    /// puts that part of the screen back straight away rather than waiting for
    /// the break — a setting he just turned off should be off now.
    private func setCleanFocus(_ prefs: CleanFocusPrefs) {
        defaults.set(prefs.hideDockAndMenuBar, forKey: "hideDockAndMenuBar")
        defaults.set(prefs.hideDesktopIcons, forKey: "hideDesktopIcons")
        overlay.model.cleanFocus = prefs
        chrome.update(prefs: prefs)
        // Put everything back first, then hide whatever the new settings still
        // ask for. Going through his own values is what makes turning ONE of
        // the two toggles off give that one back straight away; it costs a
        // second Dock flicker, and only when he is flipping switches mid-block.
        chrome.restore(why: "setting changed")
        if machine.phase == .work { chrome.engage() }
    }

    /// Quitting: put his Dock and menu bar back before the app goes.
    func restoreChrome() { chrome.restore(why: "quit") }

    /// Launch: if the last run died mid-block, the restore file is still there.
    func recoverChrome() { chrome.recoverFromCrash() }

    private func setGoalHours(_ h: Double) {
        goalHours = HoursMath.clampGoal(h)
        defaults.set(goalHours, forKey: "dailyHoursGoal")
        controls.model.goalHours = goalHours
        if !overlay.model.hoursEditing { overlay.model.hoursEditor = HoursGoalEditor(hours: goalHours) }
        refreshControls()
        guard let route = target(.settings) else { return }
        // Debounced: dragging the slider (or holding the stepper) sends one POST.
        settingsWork?.cancel()
        let value = goalHours
        let w = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let resp = await self.brain.send(url: route.url, label: route.label,
                                                 body: FocusSettings(dailyHoursGoal: value), headers: route.headers)
                self.settingsWork = nil
                if let g = resp?["daily_hours_goal"]?.doubleValue, g > 0 {
                    let c = HoursMath.clampGoal(g)
                    if c != self.goalHours { self.goalHours = c; self.controls.model.goalHours = c; self.refreshControls() }
                }
            }
        }
        settingsWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    // MARK: - History

    /// The last 30 days, for the goal screen's History panel and the control window's History tab.
    private func refreshHistory() {
        let m = controls.model
        guard let route = target(.history) else {
            m.history = []
            m.historyStatus = ModeText.historyNeedsChoice
            overlay.model.history = []
            overlay.model.historyStatus = m.historyStatus
            return
        }
        m.historyLoading = true
        overlay.model.historyLoading = true
        Task { @MainActor [weak self, brain] in
            let resp = await brain.send(url: route.url, label: route.label, body: Optional<JSONValue>.none,
                                        headers: route.headers, timeout: 15)
            guard let self else { return }
            m.historyLoading = false
            let local = self.brainMode == .local
            if let resp {
                // Local: the day's report is a Markdown file on this Mac (`report_path`), not a Google Doc.
                m.history = local ? LocalHistory.parse(resp, store: self.localStoreURL) : FocusHistory.parse(resp)
                m.historyStatus = m.history.isEmpty ? ModeText.historyNoDays : ""
            } else if local {
                m.historyStatus = ModeText.historyLocalFailed
            } else {
                m.historyStatus = m.history.isEmpty ? "Couldn't reach your history — try again soon."
                                                    : "Offline — showing the last days fetched"
            }
            self.overlay.model.history = m.history
            self.overlay.model.historyStatus = m.historyStatus
            self.overlay.model.historyLoading = false
        }
    }

    // MARK: - Leaderboard

    private func refreshBoard() {
        let m = controls.model
        switch mode {
        case .needsJoin:
            // Not chosen yet, or own keys (no board at all).
            m.board = []
            m.boardStatus = ""
            overlay.model.board = []
            overlay.model.boardStatus = "Join a friend's leaderboard first (Dock icon → Board → Join)."
            return
        case .owner, .friend:
            break
        }
        m.boardLoading = true
        Task { @MainActor [weak self, brain, mode] in
            var resp: JSONValue?
            switch mode {
            case .owner:
                resp = await brain.get("/admin/focus/leaderboard")
            case .friend(let f):
                if let url = BrainConfig.plainURL(base: f.baseURL, path: "/lb/board") {
                    resp = await brain.send(url: url, label: "/lb/board", body: Optional<JSONValue>.none,
                                            headers: ["X-LB-Token": f.token], timeout: 12)
                }
            case .needsJoin:
                break
            }
            guard let self else { return }
            m.boardLoading = false
            if let resp {
                m.board = Leaderboard.parse(resp)
                let f = DateFormatter(); f.timeStyle = .short
                m.boardStatus = "Updated \(f.string(from: Date()))"
            } else {
                m.boardStatus = m.board.isEmpty ? "Couldn't reach the board — try again soon." : "Offline — showing the last board"
            }
            // The goal screen's Friends panel shows the same rows.
            self.overlay.model.board = m.board
            self.overlay.model.boardStatus = m.boardStatus
        }
    }

    // MARK: - Friend mode

    private func join(server: String, code: String, name: String) {
        let m = controls.model
        let req = LBJoinRequest(code: code, name: name)
        guard !req.code.isEmpty, !req.name.isEmpty, let url = BrainConfig.plainURL(base: server, path: "/lb/join") else {
            m.joinError = "Enter the code and your name."
            return
        }
        m.joinBusy = true
        m.joinError = ""
        Task { @MainActor [weak self, brain, friendURL] in
            let resp = await brain.send(url: url, label: "/lb/join", body: req, timeout: 15)
            guard let self else { return }
            m.joinBusy = false
            guard let json = resp, let cfg = LBJoinRequest.config(from: json, baseURL: server, fallbackName: req.name) else {
                m.joinError = "That didn't work — check the code (they expire) and the server address."
                return
            }
            do { try cfg.save(to: friendURL) } catch {
                m.joinError = "Joined, but couldn't save the settings file."
                log.error("friend.json save failed: \(error.localizedDescription, privacy: .public)")
            }
            self.mode = .friend(cfg)
            self.brainMode = .friend
            self.defaults.set(BrainMode.friend.storedValue, forKey: BrainMode.defaultsKey)
            self.overlay.model.brainMode = .friend
            self.overlay.model.isOwner = false
            self.syncModeToControls()
            // A joined friend runs the full app now, so it needs the same screen permission the owner's does.
            self.overlay.model.screenWarning = true
            ScreenCapturer.requestAccessIfNeeded()
            self.startRetrying()
            self.updateSetup { $0.close() }
            m.tab = .board
            // Next step: his own TypeSafe key (Jev judges on it, so the cost is his). "Later" skips it.
            self.keyStored = TypeSafeKeychain.hasKey
            self.clearKeyResult()
            m.showKey = true
            self.refreshNow()
            self.report(cfg)
            self.refreshBoard()
            self.refreshControls()
        }
    }

    /// `POST /lb/report` with today's worked seconds (including the running block) and completed blocks.
    private func report(_ f: FriendConfig) {
        guard let url = BrainConfig.plainURL(base: f.baseURL, path: "/lb/report") else { return }
        let today = Self.today
        let running = machine.phase == .work ? runningWorked : 0
        let body = LBReport(token: f.token, day: today, focusS: Int((dayFocus.seconds(today: today) + running).rounded()),
                            blocks: dayFocus.blocks(today: today))
        Task { [brain] in _ = await brain.send(url: url, label: "/lb/report", body: body) }
    }

    // MARK: - A friend's TypeSafe key

    /// A friend's sense / frame reply: true when it was "no key" (402) — the caller drops it quietly, it is
    /// neither a verdict nor the brain being down. A success while the key was missing turns judging back on.
    private func noteJudged(_ reply: (status: Int, json: JSONValue?)) -> Bool {
        let wasMissing = typesafe.missing
        let noKey = typesafe.judged(httpStatus: reply.status, body: reply.json, now: Self.now)
        if noKey, !wasMissing { log.info("typesafe: no key — judging paused, one try a minute") }
        if !noKey, wasMissing, !typesafe.missing { log.info("typesafe: key works — judging again") }
        if wasMissing != typesafe.missing { refreshKeyUI() }
        if noKey { resendStoredKeyIfNeeded() }
        return noKey
    }

    /// What `now` (or a settings reply) said about the key.
    private func noteKeyStatus(_ status: TypeSafeStatus?) {
        let wasMissing = typesafe.missing
        typesafe.observe(status, now: Self.now)
        if wasMissing, !typesafe.missing { resumeJudging() }
        resendStoredKeyIfNeeded()
        refreshKeyUI()
    }

    /// The brain lost the key this Mac still holds: send it again, once per launch, silently.
    private func resendStoredKeyIfNeeded() {
        guard mode.friend != nil, typesafe.takeResend(storedLocally: keyStored), let key = TypeSafeKeychain.read() else { return }
        log.info("typesafe: server has no key, resending the one in the Keychain")
        postTypeSafeKey(key, quiet: true)
    }

    /// "Save key" in the step after Join or in Settings.
    private func saveTypeSafeKey(_ raw: String) {
        guard judgesOnOwnKey else { return }
        guard let key = TypeSafeKeyField.clean(raw) else {
            setKeyResult(TypeSafeText.badFormat, ok: false)
            return
        }
        postTypeSafeKey(key, quiet: false)
    }

    private func postTypeSafeKey(_ key: String, quiet: Bool) {
        guard let route = target(.settings) else { return }
        if !quiet { setKeyBusy(true) }
        // Local: the local brain reads its key from the Keychain, so the new key goes in first; a refused one
        // comes back out and the earlier key (if any) is put back (`LocalKeyCommit`).
        let local = brainMode == .local
        let previous = local ? TypeSafeKeychain.read() : nil
        if local {
            TypeSafeKeychain.save(key)
            localKeys.invalidate()
        }
        Task { @MainActor [weak self, brain] in
            let reply = await brain.sendWithStatus(url: route.url, label: route.label,
                                                   body: TypeSafeKeyRequest(typesafeKey: key), headers: route.headers,
                                                   timeout: 20)
            guard let self else { return }
            let status = (200..<300).contains(reply.status) ? TypeSafeStatus.parse(reply.json) : nil
            log.info("typesafe: key saved -> \(status?.rawValue ?? "no answer", privacy: .public)")
            if local, LocalKeyCommit.decide(status) == .restore {
                if let previous { TypeSafeKeychain.save(previous) } else { TypeSafeKeychain.remove() }
                self.localKeys.invalidate()
            }
            let wasMissing = self.typesafe.missing
            self.typesafe.saved(status, now: Self.now)
            if status == .ok {
                self.keyStored = TypeSafeKeychain.save(key) || self.keyStored
                if wasMissing { self.resumeJudging() }
            }
            if local { self.keyStored = TypeSafeKeychain.hasKey }
            if !quiet {
                let r = ModeText.typesafeResult(status, mode: self.brainMode)
                self.setKeyBusy(false)
                self.setKeyResult(r.text, ok: r.ok)
            }
            self.refreshKeyUI()
        }
    }

    /// "Remove" in Settings: `""` to the brain, then out of the Keychain.
    private func removeTypeSafeKey() {
        guard judgesOnOwnKey, let route = target(.settings) else { return }
        if brainMode == .local {
            // Nothing to ask anyone: out of the Keychain, and the local brain is told so it stops judging.
            TypeSafeKeychain.remove()
            localKeys.invalidate()
            keyStored = false
            typesafe.removed(now: Self.now)
            log.info("typesafe: key removed (local)")
            setKeyResult(TypeSafeText.removed, ok: false)
            refreshKeyUI()
            Task { [brain] in
                _ = await brain.sendWithStatus(url: route.url, label: route.label, body: TypeSafeKeyRequest.remove,
                                               headers: route.headers, timeout: 20)
            }
            return
        }
        setKeyBusy(true)
        Task { @MainActor [weak self, brain] in
            let reply = await brain.sendWithStatus(url: route.url, label: route.label, body: TypeSafeKeyRequest.remove,
                                                   headers: route.headers, timeout: 20)
            guard let self else { return }
            self.setKeyBusy(false)
            guard (200..<300).contains(reply.status) else {
                self.setKeyResult(TypeSafeText.unreachable, ok: false)
                return
            }
            TypeSafeKeychain.remove()
            self.keyStored = false
            self.typesafe.removed(now: Self.now)
            log.info("typesafe: key removed")
            self.setKeyResult(TypeSafeText.removed, ok: false)
            self.refreshKeyUI()
        }
    }

    /// A key works again mid-block: the next sense post goes now, not in a minute.
    private func resumeJudging() {
        if machine.phase == .work, nextSenseAt.isFinite { nextSenseAt = min(nextSenseAt, Self.now) }
    }

    /// Both screens: "set / not set" and the reminder line.
    private func refreshKeyUI() {
        let ownKey = judgesOnOwnKey
        let set = ownKey && typesafe.keyIsSet(storedLocally: keyStored)
        let missing = ownKey && typesafe.showsReminder
        let anthropic = brainMode == .local && anthropicStored
        updateKeyUI { $0.set = set; $0.missing = missing; $0.anthropicSet = anthropic }
    }

    private func setKeyBusy(_ busy: Bool) {
        updateKeyUI { k in
            k.busy = busy
            if busy { k.result = ""; k.resultOK = false }
        }
    }

    private func setKeyResult(_ text: String, ok: Bool) { updateKeyUI { $0.result = text; $0.resultOK = ok } }
    private func clearKeyResult() { setKeyResult("", ok: false) }

    private func updateKeyUI(_ change: (inout TypeSafeKeyUI) -> Void) {
        var c = controls.model.key
        change(&c)
        if controls.model.key != c { controls.model.key = c }
        var o = overlay.model.key
        change(&o)
        if overlay.model.key != o { overlay.model.key = o }
    }

    // MARK: - Own keys (local mode)

    /// One place that moves the setup screens, so the control window always shows what `SetupFlow` says.
    private func updateSetup(_ change: (inout SetupFlow) -> Void) {
        change(&setup)
        if controls.model.setup != setup.screen { controls.model.setup = setup.screen }
    }

    private func setupBack() {
        clearKeyResult()
        updateSetup { $0.back() }
    }

    /// "Run on my own keys": local mode from now on (remembered), the same screen permissions the owner's app
    /// asks for, then the TypeSafe key step.
    private func chooseOwnKeys() {
        let first = brainMode != .local
        brainMode = .local
        defaults.set(BrainMode.local.storedValue, forKey: BrainMode.defaultsKey)
        mode = .needsJoin
        startLocalBrain()
        overlay.model.brainMode = .local
        overlay.model.isOwner = false
        overlay.model.screenWarning = true
        syncModeToControls()
        if first {
            ScreenCapturer.requestAccessIfNeeded()
            ScreenText.requestAccessIfNeeded()
        }
        startRetrying()
        keyStored = TypeSafeKeychain.hasKey
        anthropicStored = AnthropicKeychain.hasKey
        if brain.local?.ready == false { typesafe.observe(.missing, now: Self.now) }
        clearKeyResult()
        refreshKeyUI()
        updateSetup { $0.pickOwnKeys() }
        refreshNow()
        refreshControls()
    }

    /// The one shared local brain: files in ~/Library/Application Support/HermesFocus/local, keys from the
    /// Keychain (cached until a key changes), the real network for TypeSafe and Anthropic.
    private func startLocalBrain() {
        guard brain.local == nil else { return }
        try? FileManager.default.createDirectory(at: localStoreURL, withIntermediateDirectories: true)
        let keys = localKeys
        brain.local = LocalBrain(storeURL: localStoreURL, keys: { keys.current() }, transport: URLSessionTransport())
        log.info("local brain on")
    }

    /// Owner/friend retries of unsent blocks, once a minute (started once).
    private func startRetrying() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.retryPending() }
        retryPending()
    }

    /// "Add key" beside "Add your TypeSafe key in Settings to be judged" in the control window.
    private func openKeyScreen() {
        clearKeyResult()
        if brainMode == .local {
            updateSetup { $0.openKey() }
        } else {
            controls.model.showKey = true
        }
        showControls()
    }

    /// The optional Anthropic key: into the Keychain; the local brain picks it up on its next call.
    private func saveAnthropicKey(_ raw: String) {
        guard brainMode == .local else { return }
        guard let key = AnthropicKeyField.clean(raw) else {
            setKeyResult(TypeSafeText.badFormat, ok: false)
            return
        }
        let saved = AnthropicKeychain.save(key)
        localKeys.invalidate()
        anthropicStored = AnthropicKeychain.hasKey
        log.info("anthropic key: \(saved ? "saved" : "save failed", privacy: .public)")
        setKeyResult(saved ? ModeText.anthropicSaved : ModeText.anthropicSaveFailed, ok: saved)
        refreshKeyUI()
    }

    private func removeAnthropicKey() {
        guard brainMode == .local else { return }
        AnthropicKeychain.remove()
        localKeys.invalidate()
        anthropicStored = false
        log.info("anthropic key removed")
        setKeyResult(TypeSafeText.removed, ok: false)
        refreshKeyUI()
    }

    /// "Show in Finder" beside "Your data: ~/Library/Application Support/HermesFocus/local".
    private func showLocalData() {
        try? FileManager.default.createDirectory(at: localStoreURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(localStoreURL)
    }

    /// The Health line in local Settings (calls today, cost estimate).
    private func refreshLocalHealth() {
        guard brainMode == .local else { return }
        overlay.model.localHealth = LocalHealth.line(brain.local?.health)
    }

    // MARK: - Small persisted state (defaults, JSON)

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
