import XCTest
@testable import FocusCore

final class PhaseMachineTests: XCTestCase {
    private func machine(_ d: Durations = .standard, lastGoal: String = "") -> PhaseMachine {
        var n = 0
        return PhaseMachine(durations: d, lastGoal: lastGoal, makeId: { n += 1; return "block-\(n)" })
    }

    func testFullCycle() {
        var m = machine()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.start(now: 0), [.sessionStarted, .showGoalPrompt(prefill: "")])
        XCTAssertEqual(m.phase, .goal)

        XCTAssertEqual(m.submitGoal("  write chapter 3 ", now: 10), [.countdownStarted])
        XCTAssertEqual(m.phase, .countdown)
        XCTAssertEqual(m.goal, "write chapter 3")
        // 3, 2, 1 — three seconds.
        XCTAssertEqual(m.countdownNumber(now: 10), 3)
        XCTAssertEqual(m.countdownNumber(now: 10.5), 3)
        XCTAssertEqual(m.countdownNumber(now: 11), 2)
        XCTAssertEqual(m.countdownNumber(now: 12.2), 1)
        XCTAssertEqual(m.tick(now: 12.9), [])

        XCTAssertEqual(m.tick(now: 13), [.workStarted(blockId: "block-1", goal: "write chapter 3", startedAt: 13)])
        XCTAssertEqual(m.phase, .work)
        XCTAssertEqual(m.remaining(now: 13), 1500)
        XCTAssertEqual(m.tick(now: 1512), [])

        let fx = m.tick(now: 1513.2)
        let timing = BlockTiming(blockId: "block-1", goal: "write chapter 3", startedAt: 13, endedAt: 1513,
                                 plannedSeconds: 1500, completed: true)
        XCTAssertEqual(fx, [.workEnded(timing), .breakStarted(blockId: "block-1")])
        XCTAssertEqual(m.phase, .onBreak)
        XCTAssertEqual(m.remaining(now: 1513), 300)

        XCTAssertEqual(m.tick(now: 1813), [.breakEnded, .showGoalPrompt(prefill: "write chapter 3")])
        XCTAssertEqual(m.phase, .goal)

        // Enter alone continues with the pre-filled (last) goal.
        XCTAssertEqual(m.submitGoal("", now: 1820), [.countdownStarted])
        XCTAssertEqual(m.goal, "write chapter 3")
        XCTAssertEqual(m.tick(now: 1823), [.workStarted(blockId: "block-2", goal: "write chapter 3", startedAt: 1823)])
    }

    func testEmptyGoalWithoutHistoryIsIgnored() {
        var m = machine()
        _ = m.start(now: 0)
        XCTAssertEqual(m.submitGoal("   ", now: 1), [])
        XCTAssertEqual(m.phase, .goal)
    }

    func testPrefillUsesStoredLastGoal() {
        var m = machine(lastGoal: "inbox zero")
        XCTAssertEqual(m.start(now: 0), [.sessionStarted, .showGoalPrompt(prefill: "inbox zero")])
    }

    func testSkipBreak() {
        var m = machine(.test)
        _ = m.start(now: 0)
        _ = m.submitGoal("x", now: 0)
        _ = m.tick(now: 2)
        _ = m.tick(now: 62)
        XCTAssertEqual(m.phase, .onBreak)
        XCTAssertEqual(m.skipBreak(now: 65), [.breakSkipped(blockId: "block-1"), .showGoalPrompt(prefill: "x")])
        XCTAssertEqual(m.phase, .goal)
        XCTAssertEqual(m.skipBreak(now: 66), [])
    }

    func testStopDuringWorkReportsIncompleteBlock() {
        var m = machine(.test)
        _ = m.start(now: 0)
        _ = m.submitGoal("x", now: 0)
        _ = m.tick(now: 2)
        let fx = m.stop(now: 30)
        XCTAssertEqual(fx, [.workEnded(BlockTiming(blockId: "block-1", goal: "x", startedAt: 2, endedAt: 30,
                                                   plannedSeconds: 60, completed: false)),
                            .sessionStopped])
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.tick(now: 1000), [])
        XCTAssertEqual(m.stop(now: 1001), [])
    }

    func testStopOutsideWorkHasNoBlock() {
        var m = machine()
        _ = m.start(now: 0)
        XCTAssertEqual(m.stop(now: 1), [.sessionStopped])
        // Restart works and keeps last goal.
        _ = m.start(now: 2)
        XCTAssertEqual(m.phase, .goal)
    }

    func testPauseFreezesTimer() {
        var m = machine(.test)
        _ = m.start(now: 0)
        XCTAssertEqual(m.pause(now: 0), [], "cannot pause on the goal prompt")
        _ = m.submitGoal("x", now: 0)
        _ = m.tick(now: 2)
        XCTAssertEqual(m.pause(now: 12), [.paused])
        XCTAssertEqual(m.remaining(now: 500), 50)
        XCTAssertEqual(m.tick(now: 500), [])
        XCTAssertEqual(m.resume(now: 600), [.resumed])
        XCTAssertEqual(m.remaining(now: 600), 50)
        XCTAssertEqual(m.tick(now: 649), [])
        XCTAssertEqual(m.tick(now: 650).count, 2)
        XCTAssertEqual(m.phase, .onBreak)
    }

    func testZeroCountdownGoesStraightToWork() {
        var d = Durations.test
        d.countdown = 0
        var m = machine(d)
        _ = m.start(now: 0)
        XCTAssertEqual(m.submitGoal("x", now: 5), [.workStarted(blockId: "block-1", goal: "x", startedAt: 5)])
    }

    func testLongSleepDuringWorkStillGivesFullBreak() {
        var m = machine(.test)
        _ = m.start(now: 0)
        _ = m.submitGoal("x", now: 0)
        _ = m.tick(now: 2)
        _ = m.tick(now: 10_000)
        XCTAssertEqual(m.phase, .onBreak)
        XCTAssertEqual(m.remaining(now: 10_000), 12, "a 60 s test block earns a 12 s break")
    }

    func testInputsIgnoredInWrongPhase() {
        var m = machine()
        XCTAssertEqual(m.submitGoal("x", now: 0), [])
        XCTAssertEqual(m.skipBreak(now: 0), [])
        XCTAssertEqual(m.resume(now: 0), [])
        _ = m.start(now: 0)
        XCTAssertEqual(m.start(now: 1), [])
    }
}

final class DurationsTests: XCTestCase {
    func testStandard() {
        let d = Durations.resolve(arguments: [], lookup: { _ in nil })
        XCTAssertEqual(d, .standard)
        XCTAssertEqual(d.work, 1500); XCTAssertNil(d.breakOverride); XCTAssertEqual(d.countdown, 3)
        XCTAssertEqual(d.shortBreak(work: 1500), 300); XCTAssertEqual(d.blockScale, 1)
        XCTAssertEqual(d.screenshotInterval, 60); XCTAssertEqual(d.screenshotJitter, 10)
    }

    func testTestFlag() {
        let d = Durations.resolve(arguments: ["HermesFocus", "--test"], lookup: { _ in nil })
        XCTAssertEqual(d.work, 60); XCTAssertNil(d.breakOverride); XCTAssertEqual(d.countdown, 2)
        XCTAssertEqual(d.blockScale, 0.04, accuracy: 1e-9)
        XCTAssertEqual(d.shortBreak(work: 60), 12, "60 s test block → a 12 s break (5 real min × 0.04)")
        XCTAssertEqual(d.longBreak(work: 60), 48)
        XCTAssertTrue(d.isTestMode)
        XCTAssertTrue(Durations.resolve(arguments: [], lookup: { $0 == "testMode" ? true : nil }).isTestMode)
        XCTAssertTrue(Durations.resolve(arguments: [], forceTest: true, lookup: { _ in nil }).isTestMode)
    }

    func testDefaultsOverrides() {
        let values: [String: Any] = ["workSeconds": 90, "breakSeconds": "30", "countdownSeconds": 0,
                                     "screenshotSeconds": 40.0, "tickSeconds": NSNumber(value: 10)]
        let d = Durations.resolve(arguments: [], lookup: { values[$0] })
        XCTAssertEqual(d.work, 90); XCTAssertEqual(d.breakOverride, 30); XCTAssertEqual(d.countdown, 0)
        XCTAssertEqual(d.shortBreak(work: 90), 30, "breakSeconds overrides the block-scaled rule")
        XCTAssertEqual(d.longBreak(work: 90), 120)
        XCTAssertEqual(d.screenshotInterval, 40); XCTAssertEqual(d.screenshotJitter, 10); XCTAssertEqual(d.tickInterval, 10)
    }

    func testBadOverridesIgnored() {
        let values: [String: Any] = ["workSeconds": -5, "breakSeconds": "abc"]
        XCTAssertEqual(Durations.resolve(arguments: [], lookup: { values[$0] }), .standard)
    }
}
