import XCTest
@testable import FocusCore

final class GoalFlowTests: XCTestCase {
    private func req(_ text: String, answer: String? = nil, at: Int, prev: String = "essay", prevU: String = "Writing the history essay.") -> GoalRequest {
        GoalRequest(text: text, previousGoal: prev, previousUnderstood: prevU, clarifyAnswer: answer, at: at)
    }

    func testOkPathShowsUnderstoodThenProceeds() {
        var f = GoalFlow(previousGoal: "essay", previousUnderstood: "Writing the history essay.")
        XCTAssertEqual(f.stage, .typing)
        XCTAssertEqual(f.submit("  maths sheet 4 ", now: 100), [.showUnderstanding, .post(req("maths sheet 4", at: 100), requestId: 1)])
        XCTAssertEqual(f.stage, .understanding)
        XCTAssertTrue(f.isBusy)
        XCTAssertEqual(f.submit("again", now: 101), [], "Enter while understanding is ignored")

        let reply = GoalReply(status: .ok, goal: "Maths sheet 4", understood: "Doing maths problem sheet 4.")
        XCTAssertEqual(f.receive(reply, requestId: 1, now: 102), [.showUnderstood("Doing maths problem sheet 4.")])
        XCTAssertEqual(f.tick(now: 103.4), [])
        XCTAssertEqual(f.tick(now: 103.5), [.proceed(goal: "Maths sheet 4", understood: "Doing maths problem sheet 4.")])
        XCTAssertEqual(f.stage, .done)
        XCTAssertEqual(f.tick(now: 200), [])
    }

    func testClarifyThenAnswer() {
        var f = GoalFlow(previousGoal: "essay", previousUnderstood: "Writing the history essay.")
        _ = f.submit("stuff", now: 0)
        XCTAssertEqual(f.receive(GoalReply(status: .clarify, question: "Which subject?"), requestId: 1, now: 1),
                       [.showQuestion("Which subject?")])
        XCTAssertEqual(f.stage, .clarifying(question: "Which subject?"))
        XCTAssertFalse(f.isBusy)
        // Clarify stage never times out: he is typing.
        XCTAssertEqual(f.tick(now: 60), [])
        XCTAssertEqual(f.submit("biology notes", now: 61),
                       [.showUnderstanding, .post(req("stuff", answer: "biology notes", at: 61), requestId: 2)])
        // A late reply to the first request is ignored.
        XCTAssertEqual(f.receive(GoalReply(status: .ok, goal: "x", understood: "y"), requestId: 1, now: 62), [])
        XCTAssertEqual(f.receive(GoalReply(status: .ok, goal: "Biology notes", understood: "Revising biology notes."),
                                 requestId: 2, now: 62), [.showUnderstood("Revising biology notes.")])
        XCTAssertEqual(f.tick(now: 63.5), [.proceed(goal: "Biology notes", understood: "Revising biology notes.")])
    }

    func testEmptyClarifyAnswerProceedsWithTextAsTyped() {
        var f = GoalFlow(previousGoal: "", previousUnderstood: "")
        _ = f.submit("stuff", now: 0)
        _ = f.receive(GoalReply(status: .clarify, question: "Which?"), requestId: 1, now: 1)
        XCTAssertEqual(f.submit("  ", now: 2), [.proceed(goal: "stuff", understood: "")])
    }

    func testTooManyQuestionsFallsBack() {
        var f = GoalFlow(previousGoal: "", previousUnderstood: "")
        _ = f.submit("stuff", now: 0)
        _ = f.receive(GoalReply(status: .clarify, question: "Q1"), requestId: 1, now: 1)
        _ = f.submit("a", now: 2)
        _ = f.receive(GoalReply(status: .clarify, question: "Q2"), requestId: 2, now: 3)
        _ = f.submit("b", now: 4)
        XCTAssertEqual(f.receive(GoalReply(status: .clarify, question: "Q3"), requestId: 3, now: 5),
                       [.proceed(goal: "stuff", understood: "")])
    }

    func testTimeoutProceedsWithTextAsTyped() {
        var f = GoalFlow(previousGoal: "essay", previousUnderstood: "u")
        _ = f.submit("physics", now: 10)
        XCTAssertEqual(f.tick(now: 15.9), [])
        XCTAssertEqual(f.tick(now: 16), [.proceed(goal: "physics", understood: "")])
        XCTAssertEqual(f.receive(GoalReply(status: .ok, goal: "late", understood: "late"), requestId: 1, now: 17), [])
    }

    func testTimeoutAfterClarifyAnswer() {
        var f = GoalFlow(previousGoal: "", previousUnderstood: "")
        _ = f.submit("stuff", now: 0)
        _ = f.receive(GoalReply(status: .clarify, question: "Which?"), requestId: 1, now: 1)
        _ = f.submit("bio", now: 30)
        XCTAssertEqual(f.tick(now: 35), [])
        XCTAssertEqual(f.tick(now: 36), [.proceed(goal: "stuff", understood: "")])
    }

    func testFailedRequestProceedsImmediately() {
        var f = GoalFlow(previousGoal: "", previousUnderstood: "")
        _ = f.submit("physics", now: 0)
        XCTAssertEqual(f.receive(nil, requestId: 1, now: 0.2), [.proceed(goal: "physics", understood: "")])
    }

    func testANewGoalNeverCarriesTheOldGoalsSpecificGoal() {
        // Oct 15 2026: "Make the Website" went out with "DO the Geo reading" as its specific goal for four
        // blocks. The saved plan only travels with its own goal.
        let geo = GoalPlan(goal: "DO the Geo reading", understood: "Reading for Geology.",
                            specificGoal: "DO the Geo reading")
        XCTAssertEqual(GoalPlan.carried(geo, to: "Make the Website"), GoalPlan(goal: "Make the Website"))
        XCTAssertEqual(GoalPlan.carried(nil, to: "Make the Website"), GoalPlan(goal: "Make the Website"))
        XCTAssertEqual(GoalPlan.carried(geo, to: " do the geo reading "),
                       GoalPlan(goal: "do the geo reading", understood: "Reading for Geology.",
                                specificGoal: "DO the Geo reading"), "the same goal keeps its own")

        // "Same" on the website goal while the saved plan is the Geo one: the website goes out alone.
        let previous = GoalPlan.carried(geo, to: "Make the Website")
        var f = GoalFlow(previousGoal: "Make the Website", previousUnderstood: "",
                         previousSpecific: previous.specificGoal)
        XCTAssertEqual(f.submit("Make the Website", now: 0).last,
                       .proceed(goal: "Make the Website", understood: "", specificGoal: ""))

        // A reply for a new goal that echoes the old goal's sentence / sharpened goal: both dropped.
        var g = GoalFlow(previousGoal: "DO the Geo reading", previousUnderstood: "Reading for Geology.",
                         previousSpecific: "DO the Geo reading")
        _ = g.submit("Make the Website", now: 0)
        let echo = GoalReply(status: .ok, goal: "Make the Website", understood: "Reading for Geology.",
                             specificGoal: "DO the Geo reading")
        XCTAssertEqual(g.receive(echo, requestId: 1, now: 1), [.proceed(goal: "Make the Website", understood: "",
                                                                         specificGoal: "")])
        // …while a real sharpened goal for the new one is kept.
        var h = GoalFlow(previousGoal: "DO the Geo reading", previousUnderstood: "", previousSpecific: "DO the Geo reading")
        _ = h.submit("Make the Website", now: 0)
        XCTAssertEqual(h.receive(GoalReply(status: .ok, goal: "Make the Website", specificGoal: "Ship the landing page"),
                                 requestId: 1, now: 1), [.showUnderstood("Ship the landing page")])

        // The brain moving the goal mid-block never keeps the old sharpened goal either.
        let moved = GoalChange(goal: "Make the Website").applied(to: geo)
        XCTAssertEqual(moved, GoalPlan(goal: "Make the Website", understood: "", specificGoal: ""))
    }

    func testEnterOnPrefillOrSameContinuesPreviousGoal() {
        // Unchanged pre-fill / "same": skips straight through with the previous plan (the brain is still told,
        // but nobody waits for it and there is no "Got it" line).
        var f = GoalFlow(previousGoal: "essay", previousUnderstood: "Writing the history essay.",
                         previousSpecific: "Draft the intro and two body paragraphs")
        XCTAssertEqual(f.submit("essay", now: 0),
                       [.post(req("essay", at: 0), requestId: 1),
                        .proceed(goal: "essay", understood: "Writing the history essay.",
                                 specificGoal: "Draft the intro and two body paragraphs")])
        XCTAssertEqual(f.stage, .done)
        XCTAssertEqual(f.receive(GoalReply(status: .ok, goal: "x", specificGoal: "y"), requestId: 1, now: 1), [],
                       "the late reply changes nothing")

        var g = GoalFlow(previousGoal: "essay", previousUnderstood: "Writing the history essay.")
        XCTAssertEqual(g.submit("Same thing.", now: 0),
                       [.post(req("Same thing.", at: 0), requestId: 1),
                        .proceed(goal: "essay", understood: "Writing the history essay.")])

        // Empty field = pre-fill.
        var h = GoalFlow(previousGoal: "essay", previousUnderstood: "")
        XCTAssertEqual(h.submit("", now: 0), [.post(req("essay", at: 0, prevU: ""), requestId: 1),
                                              .proceed(goal: "essay", understood: "")])
    }

    func testSharpenedGoalShowsOneLineThenStarts() {
        // No review card: the sharpened goal is one "Got it" line for 1.5 s, then the block starts with it.
        var f = GoalFlow(previousGoal: "essay", previousUnderstood: "")
        _ = f.submit("physics", now: 0)
        let reply = GoalReply(status: .ok, goal: "Physics", understood: "Doing physics.",
                              specificGoal: "Finish questions 1–6 of the kinematics sheet", specificity: 0.4,
                              specificityHint: "Next time name the sheet and how many questions.")
        XCTAssertEqual(f.receive(reply, requestId: 1, now: 1),
                       [.showUnderstood("Finish questions 1–6 of the kinematics sheet")])
        XCTAssertTrue(f.isBusy)
        XCTAssertEqual(f.submit("", now: 1.2), [], "Enter does nothing while the line shows")
        XCTAssertEqual(f.tick(now: 2.4), [])
        XCTAssertEqual(f.tick(now: 2.5),
                       [.proceed(goal: "Physics", understood: "Doing physics.",
                                 specificGoal: "Finish questions 1–6 of the kinematics sheet")])
        XCTAssertEqual(f.stage, .done)
    }

    func testEmptyWithoutHistoryDoesNothing() {
        var f = GoalFlow(previousGoal: "", previousUnderstood: "")
        XCTAssertEqual(f.submit("   ", now: 0), [])
        XCTAssertEqual(f.stage, .typing)
    }

    func testOkWithoutUnderstoodProceedsAtOnce() {
        var f = GoalFlow(previousGoal: "", previousUnderstood: "")
        _ = f.submit("physics", now: 0)
        XCTAssertEqual(f.receive(GoalReply(status: .ok, goal: "Physics"), requestId: 1, now: 1),
                       [.proceed(goal: "Physics", understood: "")])
        var g = GoalFlow(previousGoal: "", previousUnderstood: "")
        _ = g.submit("physics", now: 0)
        XCTAssertEqual(g.receive(GoalReply(status: .ok, understood: "Doing physics."), requestId: 1, now: 1),
                       [.showUnderstood("Doing physics.")])
        XCTAssertEqual(g.tick(now: 2.5), [.proceed(goal: "physics", understood: "Doing physics.")])
    }

    func testGoalReplyParse() throws {
        func parse(_ s: String) throws -> GoalReply? {
            GoalReply.parse(try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)))
        }
        XCTAssertEqual(try parse(#"{"status":"ok","goal":" G ","understood":"U"}"#), GoalReply(status: .ok, goal: "G", understood: "U"))
        XCTAssertEqual(try parse(#"{"status":"ok","goal":"G","specific_goal":" S ","criteria":["a"],"specificity":1.7,"specificity_hint":"h"}"#),
                       GoalReply(status: .ok, goal: "G", specificGoal: "S", specificity: 1, specificityHint: "h"))
        XCTAssertEqual(try parse(#"{"status":"clarify","question":"Which?"}"#), GoalReply(status: .clarify, question: "Which?"))
        XCTAssertNil(try parse(#"{"status":"clarify"}"#))
        XCTAssertNil(try parse(#"{"error":"nope"}"#))
        XCTAssertNil(try parse(#"[]"#))
    }

    func testGoalRequestJSON() throws {
        let a = GoalRequest(text: "t", previousGoal: "p", previousUnderstood: "pu", at: 5)
        let objA = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        XCTAssertEqual(Set(objA.keys), ["text", "previous_goal", "previous_understood", "at"])
        let b = GoalRequest(text: "t", previousGoal: "p", previousUnderstood: "pu", clarifyAnswer: "ans", at: 5)
        let objB = try JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as! [String: Any]
        XCTAssertEqual(objB["clarify_answer"] as? String, "ans")
        XCTAssertEqual(objB["previous_understood"] as? String, "pu")
    }
}

final class SessionLogicTests: XCTestCase {
    // MARK: End session from every phase

    func testEndSessionFromEveryPhase() {
        func m() -> PhaseMachine { var n = 0; return PhaseMachine(durations: .test, makeId: { n += 1; return "b\(n)" }) }
        // goal
        var a = m(); _ = a.start(now: 0)
        XCTAssertEqual(a.stop(now: 1), [.sessionStopped]); XCTAssertEqual(a.phase, .idle)
        // countdown
        var b = m(); _ = b.start(now: 0); _ = b.submitGoal("x", now: 0)
        XCTAssertEqual(b.phase, .countdown)
        XCTAssertEqual(b.stop(now: 1), [.sessionStopped]); XCTAssertEqual(b.phase, .idle)
        // work (and paused work)
        var c = m(); _ = c.start(now: 0); _ = c.submitGoal("x", understood: "Doing x.", now: 0); _ = c.tick(now: 2)
        _ = c.pause(now: 10)
        let fx = c.stop(now: 20)
        XCTAssertEqual(fx.count, 2)
        guard case .workEnded(let t) = fx[0] else { return XCTFail() }
        XCTAssertFalse(t.completed); XCTAssertEqual(t.understood, "Doing x."); XCTAssertEqual(t.plannedSeconds, 60)
        XCTAssertEqual(fx[1], .sessionStopped); XCTAssertFalse(c.isPaused)
        // break
        var d = m(); _ = d.start(now: 0); _ = d.submitGoal("x", now: 0); _ = d.tick(now: 2); _ = d.tick(now: 62)
        XCTAssertEqual(d.phase, .onBreak)
        XCTAssertEqual(d.stop(now: 63), [.sessionStopped]); XCTAssertEqual(d.phase, .idle)
        // idle
        var e = m()
        XCTAssertEqual(e.stop(now: 0), [])
    }

    func testWorkLengthChangeOnlyAffectsNextBlock() {
        var n = 0
        var m = PhaseMachine(durations: .test, makeId: { n += 1; return "b\(n)" })
        _ = m.start(now: 0); _ = m.submitGoal("x", now: 0); _ = m.tick(now: 2)
        m.durations.work = 30   // adaptive advice arriving mid-block
        XCTAssertEqual(m.remaining(now: 2), 60)
        let fx = m.tick(now: 62)
        guard case .workEnded(let t) = fx.first else { return XCTFail() }
        XCTAssertEqual(t.plannedSeconds, 60)
        _ = m.skipBreak(now: 63); _ = m.submitGoal("", now: 63); _ = m.tick(now: 65)
        XCTAssertEqual(m.remaining(now: 65), 30)
        XCTAssertEqual(m.currentWorkLength, 30)
    }

    func testUnderstoodCarriesOverOnEmptySubmit() {
        var m = PhaseMachine(durations: .test, lastGoal: "essay", lastUnderstood: "Writing the essay.")
        _ = m.start(now: 0)
        _ = m.submitGoal("", now: 0)
        XCTAssertEqual(m.goal, "essay"); XCTAssertEqual(m.understood, "Writing the essay.")
    }

    // MARK: Control state

    func testControlStateMapping() {
        let idle = ControlState.make(phase: .idle, isPaused: false, remaining: 0, nextWork: 1200,
                                     goal: "g", understood: "u", todayLine: "No blocks yet today")
        XCTAssertEqual(idle.phaseLabel, "Ready"); XCTAssertEqual(idle.timeText, "20:00")
        XCTAssertTrue(idle.canStart); XCTAssertFalse(idle.canPause); XCTAssertFalse(idle.canEnd)
        XCTAssertEqual(idle.goal, ""); XCTAssertFalse(idle.isLive)

        let goal = ControlState.make(phase: .goal, isPaused: false, remaining: 0, nextWork: 1500, goal: "g", understood: "", todayLine: "")
        XCTAssertEqual(goal.phaseLabel, "Choosing a goal"); XCTAssertTrue(goal.canEnd); XCTAssertFalse(goal.canPause)
        XCTAssertFalse(goal.canStart)

        let cd = ControlState.make(phase: .countdown, isPaused: false, remaining: 3.2, nextWork: 1500, goal: "g", understood: "", todayLine: "")
        XCTAssertEqual(cd.phaseLabel, "Starting"); XCTAssertEqual(cd.timeText, "0:04"); XCTAssertTrue(cd.canEnd)

        let work = ControlState.make(phase: .work, isPaused: false, remaining: 754, nextWork: 1500, goal: "g", understood: "u", todayLine: "")
        XCTAssertEqual(work.phaseLabel, "Focus"); XCTAssertEqual(work.timeText, "12:34")
        XCTAssertTrue(work.canPause); XCTAssertEqual(work.pauseTitle, "Pause"); XCTAssertTrue(work.isLive)
        XCTAssertEqual(work.goal, "g"); XCTAssertEqual(work.understood, "u")

        let paused = ControlState.make(phase: .work, isPaused: true, remaining: 754, nextWork: 1500, goal: "g", understood: "", todayLine: "")
        XCTAssertEqual(paused.phaseLabel, "Paused"); XCTAssertEqual(paused.pauseTitle, "Resume"); XCTAssertFalse(paused.isLive)

        let brk = ControlState.make(phase: .onBreak, isPaused: false, remaining: 299, nextWork: 1500, goal: "g", understood: "", todayLine: "")
        XCTAssertEqual(brk.phaseLabel, "Break"); XCTAssertTrue(brk.canPause); XCTAssertTrue(brk.canEnd)
    }

    func testDayStats() {
        var s = DayStats()
        XCTAssertEqual(s.line(today: "2026-09-21"), "No blocks yet today")
        s.recordBlock(day: "2026-09-21")
        XCTAssertEqual(s.line(today: "2026-09-21"), "1 block today")
        s.recordScore(700, day: "2026-09-21")
        s.recordBlock(day: "2026-09-21")
        s.recordScore(801, day: "2026-09-21")
        XCTAssertEqual(s.averageScore, 751)
        XCTAssertEqual(s.line(today: "2026-09-21"), "2 blocks today · avg 751 / 1000")
        XCTAssertEqual(s.line(today: "2026-09-22"), "No blocks yet today")
        s.recordBlock(day: "2026-09-22")
        XCTAssertEqual(s, { var x = DayStats(day: "2026-09-22"); x.blocks = 1; return x }())
    }

    func testDayKey() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        // 2026-09-21 23:30 UTC = 2026-09-22 00:30 BST
        XCTAssertEqual(DayKey.string(Date(timeIntervalSince1970: 1_790_033_400), calendar: cal), "2026-09-22")
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(DayKey.string(Date(timeIntervalSince1970: 1_790_033_400), calendar: cal), "2026-09-21")
    }

    // MARK: Edge pulse

    func testEdgePulseSchedule() {
        XCTAssertEqual(EdgePulse.window(work: 1500), 20)
        XCTAssertEqual(EdgePulse.window(work: 60), 20)
        XCTAssertEqual(EdgePulse.window(work: 30), 10)

        XCTAssertFalse(EdgePulse.isActive(phase: .work, paused: false, remaining: 20.1, work: 1500))
        XCTAssertTrue(EdgePulse.isActive(phase: .work, paused: false, remaining: 20, work: 1500))
        XCTAssertTrue(EdgePulse.isActive(phase: .work, paused: false, remaining: 0.3, work: 1500))
        XCTAssertFalse(EdgePulse.isActive(phase: .work, paused: false, remaining: 0, work: 1500))
        XCTAssertFalse(EdgePulse.isActive(phase: .work, paused: true, remaining: 10, work: 1500))
        XCTAssertFalse(EdgePulse.isActive(phase: .onBreak, paused: false, remaining: 10, work: 1500))

        // One beat per second: on for the first half of each second, off for the second half.
        XCTAssertTrue(EdgePulse.isLit(remaining: 20))
        XCTAssertTrue(EdgePulse.isLit(remaining: 19.7))
        XCTAssertFalse(EdgePulse.isLit(remaining: 19.4))
        XCTAssertTrue(EdgePulse.isLit(remaining: 19.0))
        XCTAssertFalse(EdgePulse.isLit(remaining: 0.2))
        XCTAssertFalse(EdgePulse.isLit(remaining: 0))
        // Exactly 20 beats in the window when sampled every 0.1 s.
        var beats = 0; var was = false
        var r = 20.0
        while r > 0 { let lit = EdgePulse.isLit(remaining: r); if lit && !was { beats += 1 }; was = lit; r -= 0.1; r = (r * 10).rounded() / 10 }
        XCTAssertEqual(beats, 20)
    }

    // MARK: Adaptive length

    func testNextBlockClamping() {
        XCTAssertEqual(AdaptiveLength.fraction(nextWorkS: 1200), 0.8)
        XCTAssertEqual(AdaptiveLength.fraction(nextWorkS: 60), 0.4, "never under 10 min")
        XCTAssertEqual(AdaptiveLength.fraction(nextWorkS: 3000), 1.0, "never longer than 25 min")

        var a = AdaptiveLength()
        XCTAssertEqual(a.workSeconds(base: 1500), 1500)
        a.apply(NextBlockAdvice(workSeconds: 1200, reason: "focus slipped"), day: "d1")
        XCTAssertEqual(a.workSeconds(base: 1500), 1200)
        a.apply(NextBlockAdvice(workSeconds: 1130, reason: ""), day: "d1")
        XCTAssertEqual(a.workSeconds(base: 1500), 1140, "whole minutes")
        a.apply(NextBlockAdvice(workSeconds: 100, reason: ""), day: "d1")
        XCTAssertEqual(a.workSeconds(base: 1500), 600)
        a.apply(NextBlockAdvice(workSeconds: 9999, reason: ""), day: "d1")
        XCTAssertEqual(a.workSeconds(base: 1500), 1500)
    }

    func testNextBlockTestModeScaling() {
        var a = AdaptiveLength()
        a.apply(NextBlockAdvice(workSeconds: 1200, reason: ""), day: "d1")
        XCTAssertEqual(a.workSeconds(base: 60), 48)
        a.apply(NextBlockAdvice(workSeconds: 60, reason: ""), day: "d1")
        XCTAssertEqual(a.workSeconds(base: 60), 24)
        // Custom long base (defaults workSeconds) never grows.
        a.apply(NextBlockAdvice(workSeconds: 1500, reason: ""), day: "d1")
        XCTAssertEqual(a.workSeconds(base: 90), 90)
    }

    func testNextBlockDayReset() {
        var a = AdaptiveLength()
        a.apply(NextBlockAdvice(workSeconds: 900, reason: "tired"), day: "2026-09-21")
        a.startSession(day: "2026-09-21")
        XCTAssertEqual(a.workSeconds(base: 1500), 900, "same day keeps the advice")
        a.startSession(day: "2026-09-22")
        XCTAssertEqual(a.workSeconds(base: 1500), 1500)
        XCTAssertEqual(a.reason, "")
    }

    func testNextBlockParseAndText() throws {
        func j(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
        let r = BlockResult.parse(try j(#"{"score": 640, "advice": "a", "next_work_s": 1200, "next_reason": " your focus slipped around minute 18 "}"#))!
        XCTAssertEqual(r.nextWorkS, 1200); XCTAssertEqual(r.nextReason, "your focus slipped around minute 18")
        let old = BlockResult.parse(try j(#"{"score": 640}"#))!
        XCTAssertNil(old.nextWorkS); XCTAssertEqual(old.nextReason, "")
        XCTAssertNil(NextBlockAdvice.parse(try j(#"{"next_work_s": 0}"#)))
        XCTAssertNil(NextBlockAdvice.parse(try j(#"{"next_work_s": "soon"}"#)))
        XCTAssertEqual(NextBlockAdvice.parse(try j(#"{"next_work_s": 900}"#)), NextBlockAdvice(workSeconds: 900, reason: ""))

        XCTAssertEqual(FocusText.nextBlockLine(seconds: 1200, reason: "your focus slipped around minute 18"),
                       "Next block: 20 min — your focus slipped around minute 18")
        XCTAssertEqual(FocusText.nextBlockLine(seconds: 1500, reason: ""), "Next block: 25 min")
        XCTAssertEqual(FocusText.nextBlockLine(seconds: 48, reason: ""), "Next block: 48 s")
        XCTAssertEqual(FocusText.lengthPhrase(1500), "25 minutes")
        XCTAssertEqual(FocusText.lengthPhrase(60), "1 minute")
        XCTAssertEqual(FocusText.lengthPhrase(48), "48 seconds")
    }

    // MARK: Nudges

    func testNudgeQueueOneAtATime() {
        var q = NudgeQueue()
        XCTAssertNil(q.tick(now: 0))
        q.push("  ")
        XCTAssertNil(q.tick(now: 0))
        q.push("Back to the essay?")
        q.push("Back to the essay?")   // duplicate ignored
        q.push("Phone down")
        XCTAssertEqual(q.tick(now: 10), .show("Back to the essay?"))
        XCTAssertEqual(q.current, "Back to the essay?")
        q.push("Back to the essay?")   // same as on screen: ignored
        XCTAssertNil(q.tick(now: 17.9), "second one waits while the first is on screen")
        XCTAssertEqual(q.tick(now: 18), .hide)
        XCTAssertNil(q.tick(now: 18.5), "short gap between toasts")
        XCTAssertEqual(q.tick(now: 19.2), .show("Phone down"))
        XCTAssertEqual(q.tick(now: 27.2), .hide)
        XCTAssertNil(q.tick(now: 100))
    }

    func testNudgeQueueCapAndClear() {
        var q = NudgeQueue()
        for i in 0..<6 { q.push("n\(i)") }
        XCTAssertEqual(q.queue, ["n3", "n4", "n5"])
        _ = q.tick(now: 0)
        XCTAssertTrue(q.clear())
        XCTAssertNil(q.current); XCTAssertTrue(q.queue.isEmpty)
        XCTAssertFalse(q.clear())
    }

    func testAnInterruptCanBeShorter() {
        var q = NudgeQueue()
        XCTAssertEqual(q.interrupt("Close reddit.com", now: 0), .show("Close reddit.com"))
        // "I'm on task" clicked: the confirmation replaces it and goes after 4 s, not 8.
        XCTAssertEqual(q.interrupt("Got it", now: 2, for: 4), .show("Got it"))
        XCTAssertNil(q.tick(now: 5.9))
        XCTAssertEqual(q.tick(now: 6), .hide)
    }

    func testFrameResultParse() throws {
        func j(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
        XCTAssertEqual(FrameResult.parse(try j(#"{"quality": 0.8, "note": "n", "nudge": " Back to it? "}"#)),
                       FrameResult(quality: 0.8, note: "n", nudge: "Back to it?"))
        XCTAssertEqual(FrameResult.parse(try j(#"{"on_goal": true}"#)), FrameResult(quality: nil, note: "", nudge: ""))
        XCTAssertEqual(FrameResult.parse(try j(#"{"quality": 7}"#)).quality, 1)
        XCTAssertEqual(FrameResult.parse(.object([:])).nudge, "")
    }

    // MARK: JSON of new request fields

    func testUnderstoodOnEveryPayload() throws {
        func keys<T: Encodable>(_ v: T) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as! [String: Any]
        }
        let ctx = AppContext(app: "Chrome", title: "t", url: "u")
        XCTAssertEqual(try keys(FramePayload(blockId: "b", goal: "g", understood: "U", at: 1, imageJpegB64: "x", context: ctx))["understood"] as? String, "U")
        XCTAssertEqual(try keys(TickPayload(blockId: "b", goal: "g", understood: "U", at: 1, phase: .work, window: MeasureWindow(), context: ctx))["understood"] as? String, "U")
        let t = BlockTiming(blockId: "b", goal: "g", startedAt: 0, endedAt: 1, plannedSeconds: 1, completed: true, understood: "U")
        XCTAssertEqual(try keys(BlockPayload(timing: t, window: MeasureWindow(), frames: []))["understood"] as? String, "U")
    }

    func testOldPendingFileWithoutUnderstoodStillLoads() {
        let old = #"{"items":[{"block_id":"b1","goal":"g","started_at":0,"ended_at":1,"planned_s":1500,"completed":true,"attention":0.5,"face_present":1,"active_s":10,"switches":2,"apps":[],"frames":[]}]}"#
        let q = PendingBlocks.decode(Data(old.utf8))
        XCTAssertEqual(q.items.count, 1)
        XCTAssertEqual(q.items[0].understood, "")
        // Round-trips with the new field.
        XCTAssertEqual(PendingBlocks.decode(q.encoded()), q)
    }
}
