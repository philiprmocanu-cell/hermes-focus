import XCTest
@testable import FocusCore

private func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
private func object<T: Encodable>(_ v: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as! [String: Any]
}

// MARK: - Hours logged + daily goal

final class HoursTests: XCTestCase {
    func testWorkedSecondsForCompletedAndEndedEarlyBlocks() {
        XCTAssertEqual(HoursMath.workedSeconds(completed: true, planned: 1500, lastKnownWorked: 1480), 1500)
        XCTAssertEqual(HoursMath.workedSeconds(completed: false, planned: 1500, lastKnownWorked: 600), 600)
        XCTAssertEqual(HoursMath.workedSeconds(completed: false, planned: 1500, lastKnownWorked: 9999), 1500)
        XCTAssertEqual(HoursMath.workedSeconds(completed: false, planned: 1500, lastKnownWorked: -3), 0)
    }

    func testLocalFallbackAndDayRollover() {
        var d = DayFocus()
        d.record(seconds: 1500, completed: true, day: "2026-09-21")
        d.record(seconds: 600, completed: false, day: "2026-09-21")
        XCTAssertEqual(d.seconds(today: "2026-09-21"), 2100)
        XCTAssertEqual(d.blocks(today: "2026-09-21"), 1, "ended-early blocks count time, not blocks")
        XCTAssertEqual(d.seconds(today: "2026-09-22"), 0, "yesterday's total isn't today's")
        d.record(seconds: 300, completed: true, day: "2026-09-22")
        XCTAssertEqual(d.seconds(today: "2026-09-22"), 300)
        XCTAssertEqual(d.blocks(today: "2026-09-22"), 1)
    }

    func testLoggedPrefersServerButNeverLessThanLocalPlusRunning() {
        var local = DayFocus()
        local.record(seconds: 3000, completed: true, day: "D")
        // Server knows more (another launch today).
        XCTAssertEqual(HoursMath.loggedSeconds(serverFocusS: 5000, serverDay: "D", local: local, today: "D", running: 100), 5100)
        // Server behind this Mac (block not reported yet) → local.
        XCTAssertEqual(HoursMath.loggedSeconds(serverFocusS: 1000, serverDay: "D", local: local, today: "D", running: 0), 3000)
        // Unreachable → local.
        XCTAssertEqual(HoursMath.loggedSeconds(serverFocusS: nil, serverDay: nil, local: local, today: "D", running: 60), 3060)
        // Yesterday's server figure after midnight is ignored.
        XCTAssertEqual(HoursMath.loggedSeconds(serverFocusS: 9000, serverDay: "C", local: DayFocus(), today: "D", running: 0), 0)
    }

    func testLoggedAddsBlocksFinishedSinceTheServerFigure() {
        var local = DayFocus()
        local.record(seconds: 3600, completed: true, day: "D")
        // Server was fetched when this Mac had 1 h; it knows about another launch too (3 h).
        let base = 3600.0
        XCTAssertEqual(HoursMath.loggedSeconds(serverFocusS: 10_800, serverDay: "D", local: local, today: "D",
                                               running: 0, localAtServer: base), 10_800)
        // A 25-minute block just ended here: it counts straight away, even though the server is ahead.
        local.record(seconds: 1500, completed: true, day: "D")
        XCTAssertEqual(HoursMath.loggedSeconds(serverFocusS: 10_800, serverDay: "D", local: local, today: "D",
                                               running: 0, localAtServer: base), 12_300)
        // Never less than this Mac's own total, and an unreachable server adds nothing.
        XCTAssertEqual(HoursMath.loggedSeconds(serverFocusS: 60, serverDay: "D", local: local, today: "D",
                                               running: 0, localAtServer: base), 5100)
        XCTAssertEqual(HoursMath.loggedSeconds(serverFocusS: nil, serverDay: nil, local: local, today: "D",
                                               running: 30, localAtServer: base), 5130)
    }

    func testOverlayHoursLabel() {
        var local = DayFocus()
        local.record(seconds: 3600, completed: true, day: "D")
        // Server ahead of this Mac → the server's figure, plus the running block.
        let h = OverlayHours.make(serverFocusS: 9000, serverDay: "D", localAtServer: 3600, local: local, today: "D",
                                  running: 300, goalHours: 4)
        XCTAssertEqual(h.seconds, 9300)
        XCTAssertEqual(h.text, "2 h 35 m")
        XCTAssertEqual(h.caption, "logged today")
        XCTAssertEqual(h.goalText, "of 4 h")
        XCTAssertEqual(h.progress ?? -1, 9300 / (4 * 3600), accuracy: 1e-9)

        // Break screen: the block that just ended is in the number even while the server figure is stale.
        local.record(seconds: 1500, completed: true, day: "D")
        let after = OverlayHours.make(serverFocusS: 9000, serverDay: "D", localAtServer: 3600, local: local,
                                      today: "D", running: 0, goalHours: 4)
        XCTAssertEqual(after.seconds, h.seconds - 300 + 1500, "the just-finished block lands in the same number")
        XCTAssertEqual(after.text, "2 h 55 m")

        // Friend mode (no server figure): local hours, and no goal set → no "of 4 h", no progress line.
        let friend = OverlayHours.make(serverFocusS: nil, serverDay: nil, localAtServer: nil, local: local,
                                       today: "D", running: 60, goalHours: nil)
        XCTAssertEqual(friend.seconds, 5160)
        XCTAssertEqual(friend.text, "1 h 26 m")
        XCTAssertNil(friend.goalText)
        XCTAssertNil(friend.progress)

        // Yesterday's figures after midnight, and a nonsense goal.
        let fresh = OverlayHours.make(serverFocusS: 9000, serverDay: "C", localAtServer: 9000, local: local,
                                      today: "E", running: 0, goalHours: 0)
        XCTAssertEqual(fresh.seconds, 0)
        XCTAssertEqual(fresh.text, "0 m")
        XCTAssertNil(fresh.goalHours)
        XCTAssertEqual(OverlayHours(seconds: -5, goalHours: 20).seconds, 0)
        XCTAssertEqual(OverlayHours(seconds: 60, goalHours: 20).goalText, "of 16 h")
    }

    // MARK: - "+N min" landing in the hours label

    private func addition(before: Double = 4740, worked: Double = 1200, server: Double? = nil,
                          serverDay: String? = "D") -> HoursAddition {
        HoursAddition.make(before: before, worked: worked, serverFocusS: server, serverDay: serverDay,
                           today: "D", startedAt: Date(timeIntervalSince1970: 0))
    }

    private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    func testHoursAdditionSequence() {
        // 1 h 19 m on the label, a 20-minute block just ended.
        let add = addition()
        XCTAssertEqual(add.addedMinutes, 20)
        XCTAssertEqual(HoursMath.duration(add.from), "1 h 19 m")
        XCTAssertEqual(HoursMath.duration(add.to), "1 h 39 m")

        // 1. The chip sits beside the untouched number.
        XCTAssertEqual(add.stage(at: at(0)), .chip)
        XCTAssertEqual(add.stage(at: at(0.59)), .chip)
        XCTAssertEqual(add.text(at: at(0)), "1 h 19 m")
        XCTAssertEqual(add.text(at: at(0.5)), "1 h 19 m", "the digits wait for the chip")
        XCTAssertEqual(add.chipOpacity(at: at(0.5)), 1)
        XCTAssertEqual(add.chipScale(at: at(0.5)), 1)

        // 2. The digits climb while the chip shrinks and fades into them.
        XCTAssertEqual(add.stage(at: at(0.7)), .countUp)
        XCTAssertEqual(add.stage(at: at(1.7)), .countUp)
        let mid = add.seconds(at: at(1.2))
        XCTAssertGreaterThan(mid, add.from)
        XCTAssertLessThan(mid, add.to)
        XCTAssertLessThan(add.chipOpacity(at: at(1.2)), 1)
        XCTAssertLessThan(add.chipScale(at: at(1.2)), 1)
        XCTAssertEqual(add.chipOpacity(at: at(1.4)), 0, "gone well before the digits settle")

        // The number only ever climbs, minute by minute, and ends on the new total.
        var last = -1.0
        var seen: Set<String> = []
        for step in stride(from: 0.0, through: 1.8, by: 0.02) {
            let v = add.seconds(at: at(step))
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
            seen.insert(add.text(at: at(step)))
        }
        XCTAssertGreaterThan(seen.count, 10, "the minute values tick past, not one jump")

        // 3. Done: the new total, no chip.
        XCTAssertEqual(add.stage(at: at(1.81)), .done)
        XCTAssertTrue(add.isDone(at: at(add.duration + 0.01)))
        XCTAssertEqual(add.text(at: at(add.duration + 0.01)), "1 h 39 m")
        XCTAssertEqual(add.seconds(at: at(30)), add.to)
        XCTAssertEqual(add.chipOpacity(at: at(30)), 0)
        XCTAssertEqual(add.duration, HoursAddition.chipHold + HoursAddition.countUpDuration)
    }

    func testHoursAdditionProgressLineGrowsWithTheDigits() {
        let add = addition()
        XCTAssertNil(add.progress(at: at(0), goalHours: nil))
        let start = add.progress(at: at(0), goalHours: 4) ?? -1
        let mid = add.progress(at: at(1.2), goalHours: 4) ?? -1
        let end = add.progress(at: at(5), goalHours: 4) ?? -1
        XCTAssertEqual(start, HoursMath.progress(seconds: add.from, goalHours: 4), accuracy: 1e-9)
        XCTAssertGreaterThan(mid, start)
        XCTAssertGreaterThan(end, mid)
        XCTAssertEqual(end, HoursMath.progress(seconds: add.to, goalHours: 4), accuracy: 1e-9)
    }

    func testHoursAdditionNeverDoubleAddsTheFinishedBlock() {
        // The server already counted the block: count up to its figure, not to its figure plus the block again.
        let counted = addition(before: 4740, worked: 1200, server: 5940)
        XCTAssertEqual(counted.to, 5940)
        // A stale server figure (older than the block): this Mac's total including it wins.
        let stale = addition(before: 4740, worked: 1200, server: 4740)
        XCTAssertEqual(stale.to, 5940)
        // Another launch is ahead: land on the larger figure.
        let ahead = addition(before: 4740, worked: 1200, server: 9000)
        XCTAssertEqual(ahead.to, 9000)
        // Yesterday's server figure after midnight, and friend mode (no server figure at all).
        XCTAssertEqual(addition(before: 4740, worked: 1200, server: 9000, serverDay: "C").to, 5940)
        XCTAssertEqual(addition(before: 4740, worked: 1200, server: nil).to, 5940)
        // The number never goes backwards, whatever the server says.
        let odd = HoursAddition(addedMinutes: 20, from: 5940, to: 100, startedAt: at(0))
        XCTAssertEqual(odd.to, 5940)
        XCTAssertEqual(odd.seconds(at: at(5)), 5940)
    }

    func testHoursAdditionForABlockStoppedEarly() {
        // He stopped a 25-minute block after 8 minutes: "+8 min", and 8 minutes is what is added.
        let worked = HoursMath.workedSeconds(completed: false, planned: 1500, lastKnownWorked: 480)
        let add = addition(before: 4740, worked: worked)
        XCTAssertEqual(add.addedMinutes, 8)
        XCTAssertEqual(add.to, 4740 + 480)
        XCTAssertEqual(add.text(at: at(add.duration)), "1 h 27 m")
        // A block barely under a minute still says "+1 min" and never subtracts.
        let tiny = addition(before: 4740, worked: 20)
        XCTAssertEqual(tiny.addedMinutes, 1)
        XCTAssertEqual(tiny.to, 4760)
        XCTAssertEqual(addition(before: 4740, worked: -5).to, 4740)
    }

    func testHoursAdditionIsCutCleanlyWhenTheBreakIsSkipped() {
        // Skipping the break part-way through: whatever the moment, the figure shown is on the way to the new
        // total and never past it — so dropping the addition leaves the label on the real number.
        let add = addition()
        for t in [0.0, 0.3, 0.6, 0.9, 1.5, 1.8, 4.0] {
            let v = add.seconds(at: at(t))
            XCTAssertGreaterThanOrEqual(v, add.from)
            XCTAssertLessThanOrEqual(v, add.to)
        }
        // And left alone it finishes on its own: done after 1.8 s, with the chip already gone.
        XCTAssertFalse(add.isDone(at: at(1.7)))
        XCTAssertTrue(add.isDone(at: at(1.85)))
        XCTAssertEqual(add.chipOpacity(at: at(1.85)), 0)
    }

    func testTextAndProgress() {
        XCTAssertEqual(HoursMath.loggedText(2 * 3600 + 35 * 60 + 59), "2 h 35 m logged")
        XCTAssertEqual(HoursMath.duration(35 * 60), "35 m")
        XCTAssertEqual(HoursMath.duration(0), "0 m")
        XCTAssertEqual(HoursMath.duration(3 * 3600), "3 h")
        XCTAssertEqual(HoursMath.goalText(4), "of 4 h goal")
        XCTAssertEqual(HoursMath.goalText(4.5), "of 4.5 h goal")
        XCTAssertEqual(HoursMath.progress(seconds: 3600, goalHours: 4), 0.25, accuracy: 1e-9)
        XCTAssertEqual(HoursMath.progress(seconds: 99_999, goalHours: 4), 1)
        XCTAssertEqual(HoursMath.clampGoal(0.1), 0.5)
        XCTAssertEqual(HoursMath.clampGoal(20), 16)
        XCTAssertEqual(HoursMath.clampGoal(3.3), 3.5)
        XCTAssertEqual(HoursMath.clampGoal(.nan), HoursMath.defaultGoalHours)
    }

    func testSettingsJSON() throws {
        let o = try object(FocusSettings(dailyHoursGoal: 30))
        XCTAssertEqual(Set(o.keys), ["daily_hours_goal"])
        XCTAssertEqual(o["daily_hours_goal"] as? Double, 16)
    }
}

// MARK: - Goal progress, tips, scores

final class GoalProgressTests: XCTestCase {
    func testMergeOnlyMovesForward() {
        XCTAssertNil(GoalProgress.merge(nil, nil))
        XCTAssertEqual(GoalProgress.merge(nil, 0.3), 0.3)
        XCTAssertEqual(GoalProgress.merge(0.5, 0.3), 0.5, "a later off-goal screenshot doesn't take ground back")
        XCTAssertEqual(GoalProgress.merge(0.5, 0.8), 0.8)
        XCTAssertEqual(GoalProgress.merge(0.5, nil), 0.5, "missing field keeps the value")
        XCTAssertEqual(GoalProgress.merge(0.2, 7), 1)
        XCTAssertEqual(GoalProgress.merge(0.2, .nan), 0.2)
    }

    func testSameGoalAndText() {
        XCTAssertTrue(GoalProgress.sameGoal("Finish Q1–6, sheet 4.", "finish q1 6 sheet 4"))
        XCTAssertFalse(GoalProgress.sameGoal("Essay intro", "Maths sheet"))
        XCTAssertFalse(GoalProgress.sameGoal("", ""))
        XCTAssertEqual(GoalProgress.text(0.4), "40% of the way there")
        XCTAssertEqual(GoalProgress.text(1), "Done — nice.")
    }

    func testFrameResultProgressAndTip() throws {
        let r = FrameResult.parse(try json(#"{"nudge":"n","goal_progress":0.45,"tip":" Close Slack for 20 min. "}"#))
        XCTAssertEqual(r.goalProgress, 0.45)
        XCTAssertEqual(r.tip, "Close Slack for 20 min.")
        let missing = FrameResult.parse(try json(#"{"quality":0.5}"#))
        XCTAssertNil(missing.goalProgress)
        XCTAssertNil(missing.tip, "missing tip keeps the previous one")
        XCTAssertEqual(FrameResult.parse(try json(#"{"goal_progress":-2}"#)).goalProgress, 0)
    }

    func testBlockResultFocusAndOutput() throws {
        let r = try XCTUnwrap(BlockResult.parse(try json(#"{"score":700,"focus_score":820.4,"output_score":5000,"advice":"a"}"#)))
        XCTAssertEqual(r.score, 700)
        XCTAssertEqual(r.focusScore, 820)
        XCTAssertEqual(r.outputScore, 1000)
        let old = try XCTUnwrap(BlockResult.parse(try json(#"{"score":640}"#)))
        XCTAssertNil(old.focusScore)
        XCTAssertNil(old.outputScore)
    }

    func testNowSnapshotParse() throws {
        let s = try XCTUnwrap(NowSnapshot.parse(try json("""
        {"active":true,"phase":"work","goal":"maths","specific_goal":"Q1–6","criteria":[],"goal_progress":0.5,
         "tip":"t","block_ends_at":1758460000,
         "today":{"focus_s":9300,"blocks":6,"avg_score":712.6,"goal_hours":4.5,"progress":0.57}}
        """)))
        XCTAssertTrue(s.active)
        XCTAssertEqual(s.specificGoal, "Q1–6")
        XCTAssertEqual(s.goalProgress, 0.5)
        XCTAssertEqual(s.today.focusS, 9300)
        XCTAssertEqual(s.today.avgScore, 713)
        XCTAssertEqual(s.today.goalHours, 4.5)
        XCTAssertEqual(s.blockEndsAt, 1_758_460_000)
        let empty = try XCTUnwrap(NowSnapshot.parse(try json("{}")))
        XCTAssertFalse(empty.active)
        XCTAssertNil(empty.today.focusS)
        XCTAssertNil(NowSnapshot.parse(try json("[]")))
    }

    func testFrameCarriesSpecificGoalAndNoCriteria() throws {
        let f = FramePayload(blockId: "b", goal: "g", at: 1, imageJpegB64: "x", context: AppContext(), specificGoal: "S")
        let o = try object(f)
        XCTAssertEqual(o["specific_goal"] as? String, "S")
        XCTAssertNil(o["criteria"])
    }

    func testScrollKeysAndDistractionOnTickAndBlock() throws {
        var w = MeasureWindow()
        w.addInput(interval: 1, sinceScroll: 0.3, sinceKey: 5)
        w.addInput(interval: 1, sinceScroll: 0.9, sinceKey: 0.1)
        w.addInput(interval: 1, sinceScroll: 3, sinceKey: 4)
        XCTAssertEqual(w.scrollSeconds, 2)
        XCTAssertEqual(w.keySeconds, 1)
        let tick = try object(TickPayload(blockId: "b", goal: "g", at: 1, phase: .work, window: w, context: AppContext(), distractionS: 17))
        XCTAssertEqual(tick["scroll_s"] as? Int, 2)
        XCTAssertEqual(tick["keys_s"] as? Int, 1)
        XCTAssertEqual(tick["distraction_s"] as? Int, 17)
        let t = BlockTiming(blockId: "b", goal: "g", startedAt: 0, endedAt: 1, plannedSeconds: 1, completed: true)
        let block = BlockPayload(timing: t, window: w, frames: [], distractionS: 90, specificGoal: "S")
        let o = try object(block)
        XCTAssertEqual(o["distraction_s"] as? Int, 90)
        XCTAssertEqual(o["scroll_s"] as? Int, 2)
        XCTAssertEqual(o["specific_goal"] as? String, "S")
        // Round trip through the pending file.
        var q = PendingBlocks(); q.enqueue(block)
        XCTAssertEqual(PendingBlocks.decode(q.encoded()).items.first?.distractionS, 90)
    }
}

// MARK: - Distractions

final class DistractionTests: XCTestCase {
    private func c(_ url: String, app: String = "Google Chrome", title: String = "") -> AppContext {
        AppContext(app: app, title: title, url: url)
    }

    func testClearDistractionsByURL() {
        let goal = "maths sheet 4"
        XCTAssertEqual(Distraction.classify(c("https://www.instagram.com/"), goal: goal), "Instagram")
        XCTAssertEqual(Distraction.classify(c("https://www.tiktok.com/@x/video/1"), goal: goal), "TikTok")
        XCTAssertEqual(Distraction.classify(c("https://m.facebook.com/home"), goal: goal), "Facebook")
        XCTAssertEqual(Distraction.classify(c("https://x.com/home"), goal: goal), "X")
        XCTAssertEqual(Distraction.classify(c("https://twitter.com/foo"), goal: goal), "X")
        XCTAssertEqual(Distraction.classify(c("https://old.reddit.com/r/all"), goal: goal), "Reddit")
        XCTAssertEqual(Distraction.classify(c("https://www.youtube.com/shorts/abc"), goal: goal), "YouTube Shorts")
        XCTAssertEqual(Distraction.classify(c("https://www.netflix.com/watch/1"), goal: goal), "Netflix")
        XCTAssertEqual(Distraction.classify(c("https://www.twitch.tv/someone"), goal: goal), "Twitch")
        XCTAssertEqual(Distraction.classify(c("https://discord.com/channels/1/2"), goal: goal), "Discord")
        XCTAssertEqual(Distraction.classify(c("web.snapchat.com"), goal: goal), "Snapchat", "no scheme is fine")
    }

    func testNotDistractions() {
        let goal = "maths sheet 4"
        XCTAssertNil(Distraction.classify(c("https://docs.google.com/document/d/1"), goal: goal))
        XCTAssertNil(Distraction.classify(c("https://www.google.com/search?q=instagram"), goal: goal))
        XCTAssertNil(Distraction.classify(c("https://notx.com/"), goal: goal), "only the domain or its subdomains")
        XCTAssertNil(Distraction.classify(c(""), goal: goal))
        XCTAssertNil(Distraction.classify(AppContext(app: "Xcode"), goal: goal))
    }

    func testNativeApps() {
        XCTAssertEqual(Distraction.classify(AppContext(app: "Netflix"), goal: "essay"), "Netflix")
        XCTAssertEqual(Distraction.classify(AppContext(app: "Discord"), goal: "essay"), "Discord")
        XCTAssertNil(Distraction.classify(AppContext(app: "Discord"), goal: "reply to the Discord community mods"))
    }

    func testGoalExemptions() {
        XCTAssertNil(Distraction.classify(c("https://www.instagram.com/"), goal: "Plan this week's Instagram posts"))
        XCTAssertNil(Distraction.classify(c("https://x.com/compose"), goal: "write a tweet thread about the launch"))
        XCTAssertNil(Distraction.classify(c("https://www.reddit.com/r/swift"), goal: "answer Reddit questions"))
        XCTAssertNil(Distraction.classify(c("https://www.instagram.com/"), goal: "schedule social media for Acme"))
        XCTAssertEqual(Distraction.classify(c("https://www.netflix.com/"), goal: "schedule social media for Acme"), "Netflix",
                       "social media doesn't exempt Netflix")
        XCTAssertEqual(Distraction.classify(c("https://www.instagram.com/"), goal: "install the new build"), "Instagram",
                       "'install' isn't 'insta'")
    }

    func testRegularYouTubeDependsOnTheGoal() {
        let watch = c("https://www.youtube.com/watch?v=1", title: "Fourier series explained - YouTube")
        XCTAssertEqual(Distraction.classify(watch, goal: "essay on Macbeth"), "YouTube")
        XCTAssertNil(Distraction.classify(watch, goal: "Fourier transform problems"), "title shares a real word")
        XCTAssertNil(Distraction.classify(watch, goal: "watch the week 3 lecture"), "goal is about video")
        XCTAssertEqual(Distraction.classify(c("https://www.youtube.com/"), goal: "Fourier transform"), "YouTube",
                       "the home feed isn't the video he needs")
        XCTAssertEqual(Distraction.classify(c("https://www.youtube.com/shorts/x"), goal: "lecture notes"), "YouTube Shorts",
                       "a lecture goal doesn't exempt Shorts")
    }

    func testToastText() {
        XCTAssertEqual(Distraction.toastText(label: "Instagram", goal: "maths sheet 4"), "Instagram isn't maths sheet 4 — back to it.")
        XCTAssertEqual(Distraction.toastText(label: "X", goal: " "), "X isn't the plan — back to it.")
    }

    func testTrackerConfirmsThenRepeatsEvery60s() {
        var t = DistractionTracker()
        XCTAssertNil(t.observe("Instagram", now: 0), "one sample could be a stale URL")
        XCTAssertEqual(t.observe("Instagram", now: 3), "Instagram", "second sample in a row → toast (within ~10 s)")
        var toasts: [Double] = []
        var now = 3.0
        while now < 130 { now += 3; if t.observe("Instagram", now: now) != nil { toasts.append(now) } }
        XCTAssertEqual(toasts, [63, 123], "again every 60 s while it stays in front")
        XCTAssertEqual(t.seconds, 132, accuracy: 0.01, "every 3 s gap while it stayed in front")
        XCTAssertNil(t.observe(nil, now: 132))
        XCTAssertNil(t.observe("Instagram", now: 135), "left and came back: confirm again")
        XCTAssertEqual(t.observe("Instagram", now: 138), "Instagram", "…then toast at once, not after 60 s")
    }

    func testTrackerSwitchingSitesAndGaps() {
        var t = DistractionTracker()
        _ = t.observe("Instagram", now: 0)
        _ = t.observe("Instagram", now: 3)
        XCTAssertNil(t.observe("TikTok", now: 6))
        XCTAssertEqual(t.observe("TikTok", now: 9), "TikTok", "a new site toasts once confirmed")
        let before = t.seconds
        _ = t.observe("TikTok", now: 60)   // 51 s gap (asleep / paused) isn't counted
        XCTAssertEqual(t.seconds, before)
        t.reset()
        XCTAssertEqual(t.seconds, 0)
        XCTAssertNil(t.current)
    }

    func testNudgeInterruptShowsAtOnce() {
        var q = NudgeQueue()
        q.push("server nudge")
        XCTAssertEqual(q.tick(now: 0), .show("server nudge"))
        XCTAssertEqual(q.interrupt("Instagram isn't x — back to it.", now: 1), .show("Instagram isn't x — back to it."))
        XCTAssertEqual(q.current, "Instagram isn't x — back to it.")
        XCTAssertNil(q.interrupt("Instagram isn't x — back to it.", now: 2), "same text already showing: just extended")
        XCTAssertNil(q.tick(now: 9.5))
        XCTAssertEqual(q.tick(now: 10), .hide)
        XCTAssertNil(q.interrupt("  ", now: 11))
    }
}

// MARK: - Friend mode + leaderboard

final class LeaderboardTests: XCTestCase {
    func testFriendConfigSaveLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("friend.json")
        XCTAssertNil(FriendConfig.load(from: url))
        let c = FriendConfig(baseURL: "https://example.com", token: "tok", name: "Sam")
        try c.save(to: url)
        XCTAssertEqual(FriendConfig.load(from: url), c)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(Set(o.keys), ["base_url", "token", "name"])
        try Data(#"{"base_url":"x","token":"","name":"n"}"#.utf8).write(to: url)
        XCTAssertNil(FriendConfig.load(from: url), "no token = not joined")
    }

    func testAppMode() {
        let f = FriendConfig(baseURL: "b", token: "t", name: "n")
        XCTAssertEqual(AppMode.resolve(ownerEnvExists: true, friend: f), .owner, "the owner's Mac is always owner")
        XCTAssertEqual(AppMode.resolve(ownerEnvExists: false, friend: f), .friend(f))
        XCTAssertEqual(AppMode.resolve(ownerEnvExists: false, friend: nil), .needsJoin)
    }

    func testJoinAndReport() throws {
        let r = LBJoinRequest(code: " ab12cd ", name: " Sam ")
        XCTAssertEqual(r.code, "AB12CD")
        XCTAssertEqual(r.name, "Sam")
        XCTAssertEqual(Set(try object(r).keys), ["code", "name"])
        let cfg = LBJoinRequest.config(from: try json(#"{"token":"T","name":"Sammy"}"#), baseURL: "https://h.app/", fallbackName: "Sam")
        XCTAssertEqual(cfg, FriendConfig(baseURL: "https://h.app", token: "T", name: "Sammy"))
        XCTAssertEqual(LBJoinRequest.config(from: try json(#"{"token":"T"}"#), baseURL: "", fallbackName: "Sam")?.name, "Sam")
        XCTAssertEqual(LBJoinRequest.config(from: try json(#"{"token":"T"}"#), baseURL: "", fallbackName: "Sam")?.baseURL,
                       BrainConfig.defaultBaseURL)
        XCTAssertNil(LBJoinRequest.config(from: try json(#"{"error":"bad code"}"#), baseURL: "", fallbackName: "Sam"))
        let rep = try object(LBReport(token: "T", day: "2026-09-21", focusS: 5400, blocks: 3))
        XCTAssertEqual(Set(rep.keys), ["token", "day", "focus_s", "blocks"])
        XCTAssertEqual(BrainConfig.plainURL(base: "https://h.app/", path: "lb/board")?.absoluteString, "https://h.app/lb/board")
    }

    func testLeaderboardParseSortRank() throws {
        let rows = Leaderboard.parse(try json("""
        {"rows":[
          {"name":"Sam","today_s":3600,"week_s":9000,"blocks_today":2,"me":false},
          {"name":"Riley","today_s":9300,"week_s":40000,"blocks_today":6,"me":true},
          {"name":"Ana","today_s":3600,"week_s":12000,"blocks_today":2},
          {"name":"Bo","today_s":3600,"week_s":12000,"blocks_today":3},
          {"today_s":99999},
          {"name":"Zed"}
        ],"updated_at":"2026-09-21T10:00:00Z"}
        """))
        XCTAssertEqual(rows.map(\.name), ["Riley", "Ana", "Bo", "Sam", "Zed"])
        XCTAssertEqual(rows.map(\.rank), [1, 2, 2, 4, 5], "ties on today + week share a rank")
        XCTAssertTrue(rows[0].me)
        XCTAssertEqual(rows[0].blocksToday, 6)
        XCTAssertEqual(rows.last?.todayS, 0)
        // Bare array (friend /lb/board may send just rows).
        XCTAssertEqual(Leaderboard.parse(try json(#"[{"name":"A","today_s":1}]"#)).count, 1)
        XCTAssertTrue(Leaderboard.parse(try json(#"{"error":"x"}"#)).isEmpty)
    }

}

// MARK: - Long break

final class LongBreakTests: XCTestCase {
    /// Rulebook 2026-09-22: two hours of work, never a count of blocks.
    func testFourBlocksAloneDoNotMakeTheLongBreak() {
        var lb = LongBreak()
        for i in 1...4 {
            XCTAssertFalse(lb.wouldBeDue(afterBlock: 1500, scale: 1), "block \(i) is only 25 min")
            lb.recordBlock(worked: 1500)
        }
        XCTAssertFalse(lb.isDue(scale: 1), "4 × 25 min = 1 h 40 — not two hours yet")
        XCTAssertEqual(lb.progressText(scale: 1), "1 h 40 m of 2 h until your long break")
        XCTAssertTrue(lb.wouldBeDue(afterBlock: 20 * 60, scale: 1), "the 20 min that makes two hours")
        lb.recordBlock(worked: 20 * 60)
        XCTAssertTrue(lb.isDue(scale: 1))
        XCTAssertEqual(lb.progress(scale: 1), 1, accuracy: 0.001)
    }

    func testTheLineCountsTheHoursNotTheBlocks() {
        var lb = LongBreak()
        XCTAssertEqual(lb.progressText(scale: 1), "0 m of 2 h until your long break")
        XCTAssertEqual(lb.progress(scale: 1), 0, accuracy: 0.001)
        lb.recordBlock(worked: 80 * 60)
        XCTAssertEqual(lb.progressText(scale: 1), "1 h 20 m of 2 h until your long break")
        XCTAssertEqual(lb.progress(scale: 1), 80.0 / 120.0, accuracy: 0.001)
        // Test mode shrinks the clock but the line still reads in real hours.
        let scale = Durations.test.work / Durations.standard.work
        var t = LongBreak()
        t.recordBlock(worked: 80 * 60 * scale)
        XCTAssertEqual(t.progressText(scale: scale), "1 h 20 m of 2 h until your long break")
    }

    func testTwoHoursComesFirstWithLongBlocks() {
        var lb = LongBreak()
        XCTAssertFalse(lb.wouldBeDue(afterBlock: 3600, scale: 1))
        lb.recordBlock(worked: 3600)
        XCTAssertTrue(lb.wouldBeDue(afterBlock: 3600, scale: 1), "2 × 60 min = 2 h before 4 blocks")
        var short = LongBreak()
        short.recordBlock(worked: 45 * 60); short.recordBlock(worked: 45 * 60)
        XCTAssertTrue(short.wouldBeDue(afterBlock: 30 * 60, scale: 1), "45 + 45 + 30 = 2 h")
    }

    func testResetsOnSessionEndAndAway() {
        var lb = LongBreak()
        lb.recordBlock(worked: 1500); lb.recordBlock(worked: 1500)
        XCTAssertFalse(lb.noteAway(seconds: 24 * 60, scale: 1))
        XCTAssertEqual(lb.progress(scale: 1), 50.0 / 120.0, accuracy: 0.001)
        XCTAssertTrue(lb.noteAway(seconds: 25 * 60, scale: 1), "25 min away = his long break")
        XCTAssertEqual(lb, LongBreak())
        lb.recordBlock(worked: 1500)
        lb.reset()   // session ended
        XCTAssertEqual(lb.progress(scale: 1), 0, accuracy: 0.001)
    }

    func testTestModeScales() {
        let scale = Durations.test.work / Durations.standard.work   // 60 s / 25 min
        var lb = LongBreak()
        lb.recordBlock(worked: 60); lb.recordBlock(worked: 60); lb.recordBlock(worked: 60)
        XCTAssertFalse(lb.wouldBeDue(afterBlock: 60, scale: scale), "4 × 60 s = 240 s, short of 288 s")
        lb.recordBlock(worked: 60)
        XCTAssertTrue(lb.wouldBeDue(afterBlock: 60, scale: scale), "the 5th block passes 2 h scaled")
        XCTAssertFalse(lb.noteAway(seconds: 59, scale: scale))
        XCTAssertTrue(lb.noteAway(seconds: 60, scale: scale), "25 min × 0.04 = 60 s")
        var big = LongBreak()
        big.recordBlock(worked: 150); big.recordBlock(worked: 150)
        XCTAssertTrue(big.isDue(scale: scale), "2 h × 0.04 = 288 s")
        XCTAssertEqual(Durations.test.longBreak(work: 60), 48, "20 real min × 0.04")
        XCTAssertEqual(Durations.standard.longBreak(work: 1500), 20 * 60)
    }

    func testMachineRunsTheLongBreakAndSkipDoesNotReset() {
        var n = 0
        var m = PhaseMachine(durations: .standard, makeId: { n += 1; return "b\(n)" })
        var lb = LongBreak()
        _ = m.start(now: 0)
        var now = 0.0
        var breaks: [TimeInterval] = []
        for block in 1...6 {
            _ = m.submitGoal("g", now: now)
            now += 6
            _ = m.tick(now: now)   // countdown → work
            XCTAssertEqual(m.phase, .work)
            m.nextBreakIsLong = lb.wouldBeDue(afterBlock: m.currentWorkLength, scale: 1)
            now += m.currentWorkLength
            _ = m.tick(now: now)   // work → break
            lb.recordBlock(worked: 1500)
            breaks.append(m.breakLength)
            if m.breakIsLong { lb.reset() }
            if block <= 2 {
                _ = m.skipBreak(now: now)   // skipping short breaks keeps the count
            } else {
                now += m.breakLength
                _ = m.tick(now: now)
            }
            XCTAssertEqual(m.phase, .goal)
        }
        // Two hours of work, not four blocks: 5 × 25 min = 2 h 5 min, so the 5th break is the long one.
        XCTAssertEqual(breaks, [300, 300, 300, 300, 1200, 300],
                       "25 min → 5 min; the long one is 4 × 5 = 20 min, earned by the 2 hours")
        _ = m.stop(now: now)
        _ = m.start(now: now)
        XCTAssertFalse(m.nextBreakIsLong)
    }
}

// MARK: - Block length picker

final class BlockLengthTests: XCTestCase {
    func testDefaultIs25EveryTime() {
        var a = BlockLengthChoice()
        XCTAssertEqual(a.minutes, 25)
        a.select(60)
        XCTAssertEqual(a.minutes, 60)
        // The next goal screen starts fresh, not at the last choice.
        XCTAssertEqual(BlockLengthChoice().minutes, 25)
        XCTAssertEqual(BlockLengthChoice(suggestion: .init(minutes: 15, reason: "r")).minutes, 25)
    }

    func testPresetsAndCustomBounds() {
        var c = BlockLengthChoice()
        c.select(45)
        XCTAssertFalse(c.isCustom)
        XCTAssertTrue(c.setCustom("50"))
        XCTAssertEqual(c.minutes, 50)
        XCTAssertTrue(c.isCustom)
        c.setCustom("3"); XCTAssertEqual(c.minutes, 5, "the floor is 5 min")
        c.setCustom("90"); XCTAssertEqual(c.minutes, 60, "the ceiling is 60 min now, not 120")
        c.setCustom("500"); XCTAssertEqual(c.minutes, 60)
        XCTAssertEqual(BlockLengthChoice.customRange, 5...60)
        XCTAssertFalse(c.setCustom("abc"))
        XCTAssertFalse(c.setCustom(""))
        XCTAssertEqual(c.minutes, 60, "junk text changes nothing")
    }

    func testSuggestionOnlyAppliesOnClick() {
        var c = BlockLengthChoice(suggestion: .init(minutes: 15, reason: "your focus slipped around minute 18"))
        XCTAssertEqual(c.chipText, "Suggested: 15 min — your focus slipped around minute 18")
        XCTAssertEqual(c.minutes, 25)
        c.applySuggestion()
        XCTAssertEqual(c.minutes, 15)
        XCTAssertFalse(c.isCustom)
        XCTAssertNil(BlockLengthChoice(suggestion: .init(minutes: 25, reason: "same")).chipText, "no chip for the default")
        var none = BlockLengthChoice()
        none.applySuggestion()
        XCTAssertEqual(none.minutes, 25)
    }

    func testSecondsAndSuggestionScaling() {
        var c = BlockLengthChoice()
        XCTAssertEqual(c.seconds(scale: 1), 1500)
        XCTAssertEqual(c.seconds(scale: 0.04), 60, "test mode: 25 min → 60 s")
        c.select(15)
        XCTAssertEqual(c.seconds(scale: 0.04), 36)
        XCTAssertEqual(BlockLengthChoice.suggestion(from: NextBlockAdvice(workSeconds: 1200, reason: "r"), scale: 1).minutes, 20)
        XCTAssertEqual(BlockLengthChoice.suggestion(from: NextBlockAdvice(workSeconds: 7200, reason: ""), scale: 1).minutes, 60,
                       "a server suggestion above 60 min is still only a suggestion, and clamped")
        XCTAssertEqual(BlockLengthChoice.suggestion(from: NextBlockAdvice(workSeconds: 48, reason: ""), scale: 0.04).minutes, 20)
        XCTAssertEqual(BlockLengthChoice.suggestion(from: NextBlockAdvice(workSeconds: 30, reason: ""), scale: 1).minutes, 5)
        let s = StoredSuggestion(minutes: 20, reason: "r", day: "D")
        XCTAssertEqual(s.suggestion(today: "D")?.minutes, 20)
        XCTAssertNil(s.suggestion(today: "E"), "yesterday's suggestion is dropped")
    }
}

// MARK: - Font

final class AppFontTests: XCTestCase {
    func testMissingFolderFallsBackToSystem() {
        let r = AppFont.register(directory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        XCTAssertEqual(r.registered, 0)
        XCTAssertFalse(r.usable)
        XCTAssertEqual(r.choice, .system)
        XCTAssertEqual(AppFont.register(directory: nil).choice, .system)
    }

    func testBundledSpaceGroteskRegisters() {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Fonts").standardized
        let r = AppFont.register(directory: dir)
        XCTAssertEqual(r.registered, 1)
        XCTAssertTrue(r.usable)
        XCTAssertEqual(r.choice, .spaceGrotesk)
        // Registering twice is fine.
        XCTAssertTrue(AppFont.register(directory: dir).usable)
    }

    func testWeightAxis() {
        XCTAssertEqual(AppFont.axisWeight(0), 300)
        XCTAssertEqual(AppFont.axisWeight(3), 400)
        XCTAssertEqual(AppFont.axisWeight(5), 600)
        XCTAssertEqual(AppFont.axisWeight(8), 700)
    }
}

// MARK: - Suggested blocks

final class SuggestionTests: XCTestCase {
    func testParse() throws {
        let items = BlockSuggestion.parse(try json("""
        {"suggestions":[
          {"goal":" Maths sheet 5 ","specific_goal":"Q1–8","minutes":45,"why":"Sheet 4 is done","source":"history"},
          {"goal":"Essay intro","minutes":300,"why":"Due Friday"},
          {"goal":"","minutes":25},
          {"goal":"maths sheet 5","minutes":15},
          {"goal":"Anki","minutes":"20"},
          {"goal":"Emails"},
          {"goal":"Physics","minutes":2},
          {"goal":"Seventh"}
        ]}
        """))
        XCTAssertEqual(items.map(\.goal), ["Maths sheet 5", "Essay intro", "Anki", "Emails", "Physics"], "max 5, no blanks or repeats")
        XCTAssertEqual(items.map(\.minutes), [45, 60, 20, 25, 5], "clamped 5–60, 25 when missing")
        XCTAssertEqual(items[0].specificGoal, "Q1–8")
        XCTAssertEqual(items[0].why, "Sheet 4 is done")
        XCTAssertEqual(items[0].source, "history")
        XCTAssertTrue(BlockSuggestion.parse(try json(#"{"error":"x"}"#)).isEmpty)
        XCTAssertTrue(BlockSuggestion.parse(.object([:])).isEmpty)
    }

    func testKeyboardHighlight() {
        var p = SuggestionPicker(items: [BlockSuggestion(goal: "A"), BlockSuggestion(goal: "B"), BlockSuggestion(goal: "C")])
        XCTAssertNil(p.highlighted)
        p.moveUp()
        XCTAssertNil(p.highlighted, "↑ with nothing highlighted stays in the field")
        p.moveDown(); XCTAssertEqual(p.highlighted, 0)
        p.moveDown(); p.moveDown(); p.moveDown()
        XCTAssertEqual(p.highlighted, 2, "stops at the last")
        p.moveUp(); XCTAssertEqual(p.highlightedItem?.goal, "B")
        p.moveUp(); p.moveUp()
        XCTAssertNil(p.highlighted, "above the first → back to the field")
        var empty = SuggestionPicker()
        empty.moveDown()
        XCTAssertNil(empty.highlighted)
    }

    private func threeSuggestions() -> SuggestionPicker {
        SuggestionPicker(items: [BlockSuggestion(goal: "Essay intro", minutes: 45),
                                 BlockSuggestion(goal: "Maths sheet 5", minutes: 15),
                                 BlockSuggestion(goal: "Flashcards", minutes: 25)])
    }

    func testDisclosuresClosedOnEveryAppearanceAndLengthBackTo25() {
        var picker = threeSuggestions()
        var d = GoalScreenDisclosure()
        var length = BlockLengthChoice(suggestion: .init(minutes: 15, reason: "slipped"))
        d.toggleSettings(&picker)
        length.select(60)
        XCTAssertTrue(d.settingsOpen)
        // The next goal screen: fresh state, whatever happened on the last one.
        for _ in 0..<3 {
            let fresh = GoalScreenDisclosure()
            XCTAssertFalse(fresh.suggestionsOpen)
            XCTAssertFalse(fresh.settingsOpen)
            XCTAssertFalse(fresh.anyOpen)
            XCTAssertEqual(BlockLengthChoice(suggestion: .init(minutes: 15, reason: "slipped")).minutes, 25)
            XCTAssertEqual(BlockLengthChoice().minutes, 25)
        }
    }

    func testDisclosuresOpenCloseOneAtATime() {
        var picker = threeSuggestions()
        var d = GoalScreenDisclosure()
        d.toggleSuggestions(&picker)
        XCTAssertTrue(d.suggestionsOpen)
        d.toggleSettings(&picker)
        XCTAssertTrue(d.settingsOpen)
        XCTAssertFalse(d.suggestionsOpen, "only one open at a time")
        d.toggleSettings(&picker)
        XCTAssertFalse(d.anyOpen, "click again closes it")
        d.toggleSuggestions(&picker)
        d.toggleSuggestions(&picker)
        XCTAssertFalse(d.suggestionsOpen)

        var empty = SuggestionPicker()
        var e = GoalScreenDisclosure()
        e.toggleSuggestions(&empty)
        XCTAssertFalse(e.suggestionsOpen, "nothing to show (offline / friend mode): stays closed")
        XCTAssertFalse(e.keyDown(&empty))
    }

    func testDisclosureKeyboard() {
        var picker = threeSuggestions()
        var d = GoalScreenDisclosure()
        XCTAssertFalse(d.keyUp(&picker), "↑ in the field does nothing")
        XCTAssertNil(d.enter(picker), "closed: Enter submits the field")
        d.toggleSettings(&picker)
        XCTAssertTrue(d.keyDown(&picker))
        XCTAssertTrue(d.suggestionsOpen, "↓ opens Suggestions")
        XCTAssertFalse(d.settingsOpen)
        XCTAssertEqual(picker.highlighted, 0)
        XCTAssertTrue(d.keyDown(&picker))
        XCTAssertEqual(d.enter(picker)?.goal, "Maths sheet 5")
        XCTAssertTrue(d.keyUp(&picker))
        XCTAssertTrue(d.keyUp(&picker))
        XCTAssertNil(picker.highlighted, "above the first row → back to the field")
        XCTAssertNil(d.enter(picker))
        XCTAssertFalse(d.keyUp(&picker))
        _ = d.keyDown(&picker)
        XCTAssertTrue(d.escape(&picker), "Esc closes the list")
        XCTAssertFalse(d.suggestionsOpen)
        XCTAssertNil(picker.highlighted)
        XCTAssertFalse(d.escape(&picker), "nothing open: Esc ends the session as before")
        d.toggleSettings(&picker)
        XCTAssertTrue(d.escape(&picker))
        XCTAssertFalse(d.settingsOpen)
    }

    func testPickingASuggestionClosesItAndSetsLength() {
        var picker = threeSuggestions()
        var d = GoalScreenDisclosure()
        var length = BlockLengthChoice()
        _ = d.keyDown(&picker)
        let s = d.enter(picker)!
        XCTAssertEqual(d.pick(s, picker: &picker, length: &length), "Essay intro")
        XCTAssertEqual(length.minutes, 45)
        XCTAssertFalse(d.suggestionsOpen, "closes after picking")
        XCTAssertNil(picker.highlighted)
        // Clicking a row works the same way.
        d.toggleSuggestions(&picker)
        XCTAssertEqual(d.pick(picker.items[1], picker: &picker, length: &length), "Maths sheet 5")
        XCTAssertEqual(length.minutes, 15)
        XCTAssertFalse(d.suggestionsOpen)
    }

    func testPickFillsGoalAndLength() {
        var length = BlockLengthChoice()
        let goal = SuggestionPicker.apply(BlockSuggestion(goal: "Essay intro", minutes: 45), to: &length)
        XCTAssertEqual(goal, "Essay intro")
        XCTAssertEqual(length.minutes, 45)
        XCTAssertFalse(length.isCustom)
        _ = SuggestionPicker.apply(BlockSuggestion(goal: "x", minutes: 50), to: &length)
        XCTAssertEqual(length.minutes, 50)
        XCTAssertTrue(length.isCustom, "a non-preset length shows in the custom field")
        length.select(25)
        XCTAssertEqual(length.minutes, 25, "still editable afterwards")
    }
}

// MARK: - Relevance before the note (rulebook 2026-09-22)

final class DistractionGateTests: XCTestCase {
    /// Discord with his teammates about the work: no toast, and the seconds are not distraction.
    func testDiscordThatServesTheGoalIsNeverNoted() {
        var g = DistractionGate()
        XCTAssertEqual(g.sample(label: "Discord", toastNow: nil, seconds: 3, now: 0), .held)
        XCTAssertEqual(g.sample(label: "Discord", toastNow: "Discord", seconds: 3, now: 3), .held,
                       "the toast waits for the screenshot judge, it does not fire")
        XCTAssertEqual(g.heldSeconds, 6)
        XCTAssertEqual(g.frameVerdict(servesGoal: true), .dropped(6))
        // Cleared for the rest of the block: it is not held again, and not counted.
        XCTAssertEqual(g.sample(label: "Discord", toastNow: "Discord", seconds: 3, now: 60), .dropped(3))
    }

    func testDiscordThatDoesNotServeTheGoalToastsOnTheVerdict() {
        var g = DistractionGate()
        _ = g.sample(label: "Discord", toastNow: "Discord", seconds: 3, now: 0)
        _ = g.sample(label: "Discord", toastNow: nil, seconds: 3, now: 3)
        XCTAssertEqual(g.frameVerdict(servesGoal: false), .toast("Discord", 6))
        XCTAssertNil(g.heldLabel)
    }

    /// No verdict at all (the server said nothing) is not a reason to let it pass.
    func testMissingVerdictStillToasts() {
        var g = DistractionGate()
        _ = g.sample(label: "YouTube", toastNow: "YouTube", seconds: 3, now: 0)
        XCTAssertEqual(g.frameVerdict(servesGoal: nil), .toast("YouTube", 3))
    }

    func testInstagramAndTikTokStayInstant() {
        var g = DistractionGate()
        XCTAssertEqual(g.sample(label: "Instagram", toastNow: "Instagram", seconds: 3, now: 0),
                       .toast("Instagram", 3))
        XCTAssertEqual(g.sample(label: "TikTok", toastNow: "TikTok", seconds: 3, now: 6),
                       .toast("TikTok", 3))
        // Before the tracker confirms, the seconds still count — just no toast.
        XCTAssertEqual(g.sample(label: "TikTok", toastNow: nil, seconds: 3, now: 9), .counted(3))
        XCTAssertNil(g.heldLabel, "nothing is ever held for them")
        XCTAssertTrue(DistractionGate.isInstant("Instagram"))
        XCTAssertFalse(DistractionGate.isInstant("Discord"))
    }

    /// The goal literally naming Instagram is `Distraction.classify`'s job — it returns nil, so
    /// the gate never sees a label at all.
    func testAGoalThatNamesInstagramNeverReachesTheGate() {
        let ctx = AppContext(app: "Safari", title: "Instagram", url: "https://instagram.com/x")
        XCTAssertEqual(Distraction.classify(ctx, goal: "post the reels edit"), nil)
        XCTAssertEqual(Distraction.classify(ctx, goal: "maths sheet 4"), "Instagram")
    }

    func testAHeldToastDoesNotWaitForever() {
        var g = DistractionGate()
        _ = g.sample(label: "Reddit", toastNow: "Reddit", seconds: 3, now: 0)
        XCTAssertEqual(g.expire(now: 60), .none, "a frame is still due")
        XCTAssertEqual(g.expire(now: DistractionGate.maxHold + 1), .toast("Reddit", 3))
    }

    func testLeavingTheSiteCountsTheSecondsAndSaysNothing() {
        var g = DistractionGate()
        _ = g.sample(label: "Reddit", toastNow: "Reddit", seconds: 3, now: 0)
        XCTAssertEqual(g.sample(label: nil, toastNow: nil, seconds: 0, now: 3), .counted(3))
        XCTAssertEqual(g.sample(label: nil, toastNow: nil, seconds: 0, now: 6), .none)
    }

    func testResetForgetsWhatTheVerdictCleared() {
        var g = DistractionGate()
        _ = g.sample(label: "Discord", toastNow: "Discord", seconds: 3, now: 0)
        _ = g.frameVerdict(servesGoal: true)
        g.reset()
        XCTAssertEqual(g.sample(label: "Discord", toastNow: "Discord", seconds: 3, now: 0), .held,
                       "a new block asks the judge again")
    }

    func testTheFrameReplyCarriesServesGoal() throws {
        let yes = FrameResult.parse(try json(#"{"quality":0.8,"serves_goal":true}"#))
        XCTAssertEqual(yes.servesGoal, true)
        let no = FrameResult.parse(try json(#"{"quality":0.2,"serves_goal":false}"#))
        XCTAssertEqual(no.servesGoal, false)
        XCTAssertNil(FrameResult.parse(try json(#"{"quality":0.2}"#)).servesGoal,
                     "an older server says nothing and nothing is assumed")
    }
}

// MARK: - The board shows the owner's score and nobody else's

final class BoardScoreTests: XCTestCase {
    func testOnlyTheOwnersRowCarriesAScore() throws {
        let rows = Leaderboard.parse(try json("""
        {"rows":[{"name":"Riley","today_s":7200,"week_s":36000,"blocks_today":4,"me":true,"score_today":742},
                 {"name":"Marius","today_s":3600,"week_s":18000,"blocks_today":2}]}
        """))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].scoreToday, 742)
        XCTAssertNil(rows[1].scoreToday, "a friend's score never leaves his own answers")
    }

    func testAMissingOrNullScoreIsNoScore() throws {
        let rows = Leaderboard.parse(try json(#"{"rows":[{"name":"Riley","score_today":null}]}"#))
        XCTAssertNil(rows[0].scoreToday)
    }
}
