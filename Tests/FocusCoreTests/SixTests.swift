import XCTest
@testable import FocusCore

// MARK: - Breaks scale with the block that just finished

final class BreakLengthTests: XCTestCase {
    func testTheTable() {
        // work minutes → short break minutes
        let table: [(Double, Double)] = [
            (5, 3),      // 1 min → the 3 min floor
            (12.5, 3),   // 2.5 min → rounds to 3, and the floor agrees
            (15, 3),
            (20, 4),
            (25, 5),
            (30, 6),
            (45, 9),
            (50, 10),
            (60, 12),
        ]
        for (work, expected) in table {
            XCTAssertEqual(BreakLength.shortMinutes(workMinutes: work), expected, "\(work) min block")
            XCTAssertEqual(BreakLength.short(work: work * 60), expected * 60, accuracy: 0.5)
        }
    }

    func testRoundsToTheNearestMinuteAndNeverUnderThree() {
        XCTAssertEqual(BreakLength.shortMinutes(workMinutes: 17), 3, "3.4 → 3")
        XCTAssertEqual(BreakLength.shortMinutes(workMinutes: 18), 4, "3.6 → 4")
        XCTAssertEqual(BreakLength.shortMinutes(workMinutes: 22), 4, "4.4 → 4")
        XCTAssertEqual(BreakLength.shortMinutes(workMinutes: 23), 5, "4.6 → 5")
        // The floor.
        XCTAssertEqual(BreakLength.shortMinutes(workMinutes: 5), 3)
        XCTAssertEqual(BreakLength.shortMinutes(workMinutes: 1), 3)
        XCTAssertEqual(BreakLength.shortMinutes(workMinutes: 0), 3)
        XCTAssertEqual(BreakLength.short(work: 0), 180)
    }

    func testTheLongBreakIsFourOfThemWithAFifteenMinuteFloor() {
        XCTAssertEqual(BreakLength.longMinutes(workMinutes: 25), 20, "25-min blocks → 20 min")
        XCTAssertEqual(BreakLength.longMinutes(workMinutes: 50), 40)
        XCTAssertEqual(BreakLength.longMinutes(workMinutes: 60), 48)
        XCTAssertEqual(BreakLength.longMinutes(workMinutes: 45), 36)
        // 4 × 3 = 12, under the 15-minute floor.
        XCTAssertEqual(BreakLength.longMinutes(workMinutes: 12.5), 15)
        XCTAssertEqual(BreakLength.longMinutes(workMinutes: 15), 15)
        XCTAssertEqual(BreakLength.longMinutes(workMinutes: 20), 16)
        XCTAssertEqual(BreakLength.long(work: 25 * 60), 20 * 60)
    }

    func testTestModeScalesProportionally() {
        let scale = Durations.test.work / Durations.standard.work   // 60 s / 25 min
        // A 60 s test block stands for 25 real minutes: a 5 min break, scaled → 12 s.
        XCTAssertEqual(BreakLength.short(work: 60, scale: scale), 12)
        XCTAssertEqual(BreakLength.long(work: 60, scale: scale), 48)
        // A test block that stands for 50 real minutes (120 s).
        XCTAssertEqual(BreakLength.short(work: 120, scale: scale), 24)
        XCTAssertEqual(BreakLength.long(work: 120, scale: scale), 96)
        // Same ratios as real time.
        XCTAssertEqual(BreakLength.short(work: 60, scale: scale) / 60, BreakLength.short(work: 1500) / 1500,
                       accuracy: 1e-9)
    }

    func testTheMachineUsesTheBlockThatJustFinished() {
        var m = PhaseMachine(durations: .standard)
        _ = m.start(now: 0)
        m.durations.work = 50 * 60
        _ = m.submitGoal("g", now: 0)
        _ = m.tick(now: 3)                     // countdown → work
        XCTAssertEqual(m.currentWorkLength, 3000)
        _ = m.tick(now: 3 + 3000)              // work → break
        XCTAssertEqual(m.phase, .onBreak)
        XCTAssertEqual(m.breakLength, 600, "50 min of work → a 10 min break")

        // The next block is shorter, so its break is shorter — even though nothing else changed.
        _ = m.tick(now: 3 + 3000 + 600)
        m.durations.work = 15 * 60
        _ = m.submitGoal("g", now: 4000)
        _ = m.tick(now: 4003)
        _ = m.tick(now: 4003 + 900)
        XCTAssertEqual(m.breakLength, 180, "15 min of work → the 3 min floor")

        // And the long break after that same block.
        var n = PhaseMachine(durations: .standard)
        _ = n.start(now: 0)
        n.durations.work = 50 * 60
        _ = n.submitGoal("g", now: 0)
        _ = n.tick(now: 3)
        n.nextBreakIsLong = true
        _ = n.tick(now: 3 + 3000)
        XCTAssertTrue(n.breakIsLong)
        XCTAssertEqual(n.breakLength, 2400, "4 × 10 min")
    }

    func testTheBreakScreenShowsTheRealLength() {
        XCTAssertEqual(FocusText.clock(BreakLength.short(work: 25 * 60)), "5:00")
        XCTAssertEqual(FocusText.clock(BreakLength.short(work: 50 * 60)), "10:00")
        XCTAssertEqual(FocusText.clock(BreakLength.short(work: 60 * 60)), "12:00")
        XCTAssertEqual(FocusText.clock(BreakLength.long(work: 25 * 60)), "20:00")
        // The "… until your long break" line is untouched by any of this.
        var lb = LongBreak()
        lb.recordBlock(worked: 1500)
        XCTAssertEqual(lb.progressText(scale: 1), "25 m of 2 h until your long break")
    }
}

// MARK: - Block length limits

final class BlockLengthLimitsTests: XCTestCase {
    func testCustomFieldIsFiveToSixty() {
        XCTAssertEqual(BlockLengthChoice.customRange, 5...60)
        XCTAssertEqual(BlockLengthChoice.presets, [15, 25, 45, 60])
        XCTAssertEqual(BlockLengthChoice.defaultMinutes, 25)
        var c = BlockLengthChoice()
        c.setCustom("61"); XCTAssertEqual(c.minutes, 60)
        c.setCustom("120"); XCTAssertEqual(c.minutes, 60)
        c.setCustom("4"); XCTAssertEqual(c.minutes, 5)
        c.setCustom("40"); XCTAssertEqual(c.minutes, 40)
        XCTAssertTrue(c.isCustom)
        c.select(200); XCTAssertEqual(c.minutes, 60)
        XCTAssertEqual(BlockLengthChoice.clamp(1000), 60)
        XCTAssertEqual(BlockLengthChoice.clamp(0), 5)
    }

    func testTheServerChipStillOnlySuggests() {
        let big = BlockLengthChoice.suggestion(from: NextBlockAdvice(workSeconds: 90 * 60, reason: "r"), scale: 1)
        XCTAssertEqual(big.minutes, 60, "clamped to the new ceiling")
        var c = BlockLengthChoice(suggestion: big)
        XCTAssertEqual(c.minutes, 25, "the chip never changes the default by itself")
        c.applySuggestion()
        XCTAssertEqual(c.minutes, 60)
        // A suggestion parsed off the wire is clamped too.
        let s = BlockSuggestion.parse(.object(["suggestions": .array([
            .object(["goal": .string("essay"), "minutes": .number(240)]),
        ])]))
        XCTAssertEqual(s.first?.minutes, 60)
    }
}

// MARK: - History

final class HistoryTests: XCTestCase {
    private func sample() -> JSONValue {
        .object(["days": .array([
            .object(["day": .string("2026-09-19"), "weekday": .string("Saturday"), "focus_s": .number(4500),
                     "blocks": .number(3), "avg_score": .number(612), "verdict": .string("Solid"),
                     "day_score": .number(640), "doc_url": .string("https://docs.google.com/d/abc")]),
            .object(["day": .string("2026-09-21"), "weekday": .string("Monday"), "focus_s": .number(9300),
                     "blocks": .number(6), "avg_score": .number(812), "verdict": .string("Proud"),
                     "day_score": .number(830), "doc_url": .string("https://docs.google.com/d/xyz")]),
            .object(["day": .string("2026-09-20"), "weekday": .string("Sunday"), "focus_s": .number(1200),
                     "blocks": .number(1), "verdict": .string("under")]),
        ])])
    }

    func testParsesAndSortsNewestFirst() {
        let days = FocusHistory.parse(sample())
        XCTAssertEqual(days.map(\.day), ["2026-09-21", "2026-09-20", "2026-09-19"])
        let monday = days[0]
        XCTAssertEqual(monday.weekday, "Monday")
        XCTAssertEqual(monday.hoursText, "2 h 35 m")
        XCTAssertEqual(monday.blocks, 6)
        XCTAssertEqual(monday.blocksText, "6 blocks")
        XCTAssertEqual(monday.avgScore, 812)
        XCTAssertEqual(monday.dayScore, 830)
        XCTAssertEqual(monday.scoreShown, 830, "the day score wins over the block average")
        XCTAssertEqual(monday.verdict, .proud)
        XCTAssertEqual(monday.verdictText, "Proud")
        XCTAssertEqual(monday.docURL, "https://docs.google.com/d/xyz")
        XCTAssertTrue(monday.hasDoc)
        XCTAssertEqual(monday.dateText, "Mon 21 Sep")

        let sunday = days[1]
        XCTAssertEqual(sunday.verdict, .under, "lowercase verdicts are read too")
        XCTAssertNil(sunday.dayScore)
        XCTAssertNil(sunday.avgScore)
        XCTAssertEqual(sunday.scoreText, "—")
        XCTAssertFalse(sunday.hasDoc, "friend mode sends no doc_url")
        XCTAssertEqual(sunday.blocksText, "1 block")
    }

    func testEveryFieldIsOptional() {
        let days = FocusHistory.parse(.object(["days": .array([
            .object(["day": .string("2026-09-18")]),
            .object(["weekday": .string("Friday")]),            // no day → dropped
            .object(["day": .string("  ")]),                    // blank day → dropped
            .object(["day": .string("2026-09-18"), "blocks": .number(9)]),   // repeat → first wins
            .object(["day": .string("2026-09-17"), "focus_s": .string("nonsense"),
                     "verdict": .string("Brilliant"), "doc_url": .string("javascript:alert(1)"),
                     "avg_score": .number(4000), "blocks": .number(-3)]),
        ])]))
        XCTAssertEqual(days.map(\.day), ["2026-09-18", "2026-09-17"])
        XCTAssertEqual(days[0].focusS, 0)
        XCTAssertEqual(days[0].hoursText, "0 m")
        XCTAssertEqual(days[0].blocks, 0)
        XCTAssertEqual(days[0].blocksText, "")
        XCTAssertNil(days[0].verdict)
        XCTAssertEqual(days[0].verdictText, "")
        XCTAssertEqual(days[0].dateText, "18 Sep", "no weekday from the server, just the date")
        XCTAssertNil(days[1].verdict, "an unknown verdict is nothing, never a guess")
        XCTAssertNil(days[1].docURL, "only http(s) links become an Open doc link")
        XCTAssertEqual(days[1].avgScore, 1000, "scores are clamped to 1..1000")
        XCTAssertEqual(days[1].blocks, 0)
    }

    func testEmptyAndOddShapes() {
        XCTAssertTrue(FocusHistory.parse(.object([:])).isEmpty)
        XCTAssertTrue(FocusHistory.parse(.object(["days": .array([])])).isEmpty)
        XCTAssertTrue(FocusHistory.parse(.string("nope")).isEmpty)
        // A bare array works too.
        XCTAssertEqual(FocusHistory.parse(.array([.object(["day": .string("2026-01-02")])])).count, 1)
        // A day that can't be read still shows something.
        XCTAssertEqual(HistoryDay(day: "not-a-date").dateText, "not-a-date")
        XCTAssertEqual(HistoryDay(day: "2026-13-40").dateText, "2026-13-40")
    }

    func testTheRoutes() {
        let owner = BrainConfig(baseURL: "https://brain.example", token: "SECRET")
        let friend = FriendConfig(baseURL: "https://brain.example", token: "LBTOKEN", name: "Bro")
        let o = FocusRoute.target(.history, owner: owner, friend: nil)
        XCTAssertEqual(o?.url.absoluteString, "https://brain.example/t/SECRET/admin/focus/history?days=30")
        XCTAssertEqual(o?.label, "/admin/focus/history")
        let f = FocusRoute.target(.history, owner: nil, friend: friend)
        XCTAssertEqual(f?.url.absoluteString, "https://brain.example/lb/focus/history")
        XCTAssertEqual(f?.headers["X-LB-Token"], "LBTOKEN")
        XCTAssertTrue(FocusRoute.history.friendCanCall)
        XCTAssertNil(FocusRoute.target(.history, owner: nil, friend: nil))
    }
}

// MARK: - Screenshots: every 60 s, plus one after an app switch

final class ScreenshotScheduleSixTests: XCTestCase {
    func testCadenceIsSixtySecondsPlusMinusTen() {
        XCTAssertEqual(Durations.standard.screenshotInterval, 60)
        XCTAssertEqual(Durations.standard.screenshotJitter, 10)
        XCTAssertEqual(ScreenshotSchedule.nextDelay(interval: 60, jitter: 10, unitRandom: 0.5), 60)
        XCTAssertEqual(ScreenshotSchedule.nextDelay(interval: 60, jitter: 10, unitRandom: 0), 50)
        XCTAssertEqual(ScreenshotSchedule.nextDelay(interval: 60, jitter: 10, unitRandom: 1), 70)
        // Test mode keeps the same shape, scaled down.
        XCTAssertEqual(Durations.test.screenshotInterval, 10)
        XCTAssertEqual(Durations.test.screenshotJitter, 2)
    }

    func testAnAppSwitchEarnsAShotFiveSecondsLater() {
        // Nothing captured yet in this block.
        XCTAssertEqual(ScreenshotSchedule.shotAfterSwitch(now: 100, lastShotAt: nil, nextShotAt: 160), 105)
        // The last shot was 40 s ago: fine.
        XCTAssertEqual(ScreenshotSchedule.shotAfterSwitch(now: 100, lastShotAt: 60, nextShotAt: 160), 105)
        // Exactly 20 s ago: allowed (the guard is "under 20 s").
        XCTAssertEqual(ScreenshotSchedule.shotAfterSwitch(now: 100, lastShotAt: 80, nextShotAt: 160), 105)
    }

    func testTheTwentySecondGuard() {
        XCTAssertNil(ScreenshotSchedule.shotAfterSwitch(now: 100, lastShotAt: 81, nextShotAt: 160),
                     "19 s ago — flicking between apps can't spam the brain")
        XCTAssertNil(ScreenshotSchedule.shotAfterSwitch(now: 100, lastShotAt: 99.5, nextShotAt: 160))
        XCTAssertEqual(ScreenshotSchedule.switchMinGap, 20)
        XCTAssertEqual(ScreenshotSchedule.switchDelay, 5)
    }

    func testItNeverPushesTheScheduledShotLater() {
        // A shot is already due in 2 s: leave it alone.
        XCTAssertNil(ScreenshotSchedule.shotAfterSwitch(now: 100, lastShotAt: 40, nextShotAt: 102))
        XCTAssertNil(ScreenshotSchedule.shotAfterSwitch(now: 100, lastShotAt: 40, nextShotAt: 105))
        XCTAssertEqual(ScreenshotSchedule.shotAfterSwitch(now: 100, lastShotAt: 40, nextShotAt: 105.5), 105)
    }

    func testThePerBlockCapRoseWithTheCadence() {
        // 25 min at 60 s: 25 scheduled + room for the app-switch shots.
        XCTAssertEqual(ScreenshotSchedule.maxPerBlock(workSeconds: 25 * 60, interval: 60), 45)
        XCTAssertEqual(ScreenshotSchedule.maxPerBlock(workSeconds: 60 * 60, interval: 60), 80)
        XCTAssertEqual(ScreenshotSchedule.maxPerBlock(workSeconds: 5 * 60, interval: 60), 25)
        // It really is higher than the old 2-minute cadence would have allowed.
        XCTAssertGreaterThan(ScreenshotSchedule.maxPerBlock(workSeconds: 25 * 60, interval: 60),
                             ScreenshotSchedule.maxPerBlock(workSeconds: 25 * 60, interval: 120))
        // Nonsense in, a sane floor out.
        XCTAssertEqual(ScreenshotSchedule.maxPerBlock(workSeconds: 0, interval: 60), 12)
        XCTAssertEqual(ScreenshotSchedule.maxPerBlock(workSeconds: 1500, interval: 0), 12)
    }

    func testWhenItStillDoesNotCapture() {
        XCTAssertTrue(ScreenshotSchedule.shouldCapture(phase: .work, paused: false, screenLocked: false, displayAsleep: false))
        XCTAssertFalse(ScreenshotSchedule.shouldCapture(phase: .onBreak, paused: false, screenLocked: false, displayAsleep: false))
        XCTAssertFalse(ScreenshotSchedule.shouldCapture(phase: .work, paused: true, screenLocked: false, displayAsleep: false))
        XCTAssertFalse(ScreenshotSchedule.shouldCapture(phase: .work, paused: false, screenLocked: true, displayAsleep: false))
        XCTAssertFalse(ScreenshotSchedule.shouldCapture(phase: .work, paused: false, screenLocked: false, displayAsleep: true))
    }
}
