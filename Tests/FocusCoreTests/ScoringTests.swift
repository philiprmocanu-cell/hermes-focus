import XCTest
@testable import FocusCore

// Parity between the Swift port (`Scoring`, `FocusDay`) and the Python source of truth
// (brain/focus.py, brain/focus_day.py). The fixtures in Tests/Fixtures/scoring are written by
// scripts/fixtures_scoring.py; regenerate them after changing either side:
//
//     python3 scripts/fixtures_scoring.py
//
// Numbers match to 1e-6 (integers therefore exactly), strings exactly.

private func scoringFixture(_ name: String) throws -> JSONValue {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/scoring/\(name)")
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

/// Every difference between two JSON values, as "path: actual vs expected".
private func scoringDiff(_ a: JSONValue?, _ e: JSONValue?, _ path: String = "$") -> [String] {
    switch (a ?? .null, e ?? .null) {
    case (.number(let x), .number(let y)):
        return abs(x - y) <= 1e-6 ? [] : ["\(path): \(x) vs \(y)"]
    case (.object(let x), .object(let y)):
        var out: [String] = []
        for k in Set(x.keys).union(y.keys).sorted() {
            if x[k] == nil { out.append("\(path).\(k): missing"); continue }
            if y[k] == nil { out.append("\(path).\(k): unexpected"); continue }
            out += scoringDiff(x[k], y[k], "\(path).\(k)")
        }
        return out
    case (.array(let x), .array(let y)):
        if x.count != y.count { return ["\(path): \(x.count) items vs \(y.count)"] }
        return zip(x, y).enumerated().flatMap { scoringDiff($0.element.0, $0.element.1, "\(path)[\($0.offset)]") }
    case (let x, let y):
        return x == y ? [] : ["\(path): \(x) vs \(y)"]
    }
}

private func assertSame(_ a: JSONValue?, _ e: JSONValue?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    let d = scoringDiff(a, e)
    XCTAssertTrue(d.isEmpty, "\(what):\n" + d.prefix(12).joined(separator: "\n"), file: file, line: line)
}

private func jarr(_ v: JSONValue?) -> [JSONValue] { v?.arrayValue ?? [] }
private func jstr(_ v: JSONValue?) -> String { v?.stringValue ?? "" }
private func jnum(_ v: JSONValue?) -> Double? { if case .number(let n)? = v { return n }; return nil }
private func jopt(_ v: JSONValue?) -> JSONValue? { (v == nil || v == .null) ? nil : v }
private func jbool(_ b: Bool) -> JSONValue { .bool(b) }
private func jn(_ d: Double?) -> JSONValue { d.map { .number($0) } ?? .null }

final class ScoringParityTests: XCTestCase {
    func testEveryBlockScoresExactlyAsThePythonDoes() throws {
        let cases = jarr(try scoringFixture("blocks.json"))
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        for c in cases {
            let out = Scoring.scoreBlock(c["block"]!, rubric: jopt(c["rubric"]))
            assertSame(out, c["expected"], jstr(c["name"]))
        }
    }

    func testGoalChangeRescoreAndTheWordsAroundTheGoal() throws {
        let g = try scoringFixture("goal.json")
        for c in jarr(g["goal_change"]) {
            let n = Int(jnum(c["n"]) ?? 3)
            assertSame(Scoring.goalChange(c["frames"], n: n).map { .string($0) } ?? .null, c["expected"], jstr(c["name"]))
        }
        for c in jarr(g["rescore_on_goal"]) {
            var frames = jarr(c["frames"])
            let changed = Scoring.rescoreOnGoal(jstr(c["goal"]), frames: &frames)
            XCTAssertEqual(Double(changed), jnum(c["changed"]), jstr(c["goal"]))
            assertSame(.array(frames), c["after"], "rescore \(jstr(c["goal"]))")
        }
        for c in jarr(g["name_new_goal"]) {
            let (label, specific) = Scoring.nameNewGoal(jstr(c["actual"]), recent: c["recent"])
            assertSame(.array([.string(label), .string(specific)]), c["expected"], "name_new_goal \(jstr(c["actual"]))")
        }
        for c in jarr(g["frame_real_work"]) {
            assertSame(jbool(Scoring.frameRealWork(c["row"])), c["expected"], "frame_real_work \(String(describing: c["row"]))")
        }
        for c in jarr(g["tips"]) {
            let t = jstr(c["text"])
            assertSame(jbool(Scoring.switchesTool(t)), c["switches_tool"], "switches_tool \(t)")
            assertSame(.string(Scoring.tipText(t)), c["tip_text"], "tip_text \(t)")
        }
        for c in jarr(g["goal_vagueness"]) {
            assertSame(.string(Scoring.goalVagueness(jstr(c["text"]), context: jstr(c["context"]))), c["expected"],
                       "goal_vagueness \(jstr(c["text"]))")
        }
        for c in jarr(g["is_same_goal"]) {
            assertSame(jbool(Scoring.isSameGoal(jstr(c["text"]), previousGoal: jstr(c["previous"]))), c["expected"],
                       "is_same_goal \(jstr(c["text"]))")
        }
        for c in jarr(g["needs_inferred_goal"]) {
            assertSame(jbool(Scoring.needsInferredGoal(jstr(c["goal"]), specificGoal: c["specific"])), c["expected"],
                       "needs_inferred_goal \(jstr(c["goal"]))")
        }
        for c in jarr(g["goal_label"]) {
            assertSame(.string(Scoring.goalLabel(jstr(c["text"]))), c["expected"], "goal_label")
        }
    }

    func testTheFrameAndMinuteHelpersOfTheSensePath() throws {
        let f = try scoringFixture("frames.json")
        for c in jarr(f["distracted_run"]) {
            let r = Scoring.distractedRun(c["ticks"], frames: c["frames"], now: jnum(c["now"])!)
            assertSame(.array([.number(Double(r.seconds)), .string(r.why)]), c["expected"], jstr(c["name"]))
        }
        for c in jarr(f["mark_detours"]) {
            var frames = jarr(c["frames"])
            let n = Scoring.markDetours(&frames)
            XCTAssertEqual(Double(n), jnum(c["marked"]), jstr(c["name"]))
            assertSame(.array(frames), c["after"], "detours \(jstr(c["name"]))")
        }
        for (i, c) in jarr(f["retro_credit"]).enumerated() {
            var frames = jarr(c["frames"])
            let n = Scoring.retroCredit(&frames, row: c["row"]!)
            XCTAssertEqual(Double(n), jnum(c["credited"]), "retro \(i)")
            assertSame(.array(frames), c["after"], "retro \(i)")
        }
        for c in jarr(f["pending"]) {
            let row = c["row"]!
            assertSame(jbool(Scoring.looksAmbiguous(row)), c["looks_ambiguous"], "looks_ambiguous \(row)")
            assertSame(jbool(Scoring.framePending(row, said: jopt(c["said"]))), c["frame_pending"], "frame_pending \(row)")
            assertSame(Scoring.provisional(row), c["provisional"], "provisional \(row)")
        }
        for c in jarr(f["break_point_s"]) {
            let out = Scoring.breakPointS(ticks: c["ticks"], frames: c["frames"], startedAt: c["started_at"],
                                          endedAt: jopt(c["ended_at"]))
            assertSame(jn(out), c["expected"], jstr(c["name"]))
        }
        for c in jarr(f["next_block_length"]) {
            let out = Scoring.nextBlockLength(breakS: jnum(c["break_s"]), todayBreaksScaled: jarr(c["today"]).compactMap(jnum),
                                              currentS: jnum(c["current_s"]), capS: jnum(c["cap_s"]),
                                              scale: jnum(c["scale"]) ?? 1)
            assertSame(.object(["next_work_s": .number(Double(out.nextWorkS)), "next_reason": .string(out.nextReason)]),
                       c["expected"], "next_block_length \(String(describing: c["break_s"]))")
        }
        for c in jarr(f["to_ts"]) {
            assertSame(.number(Scoring.toTs(c["value"])), c["expected"], "to_ts \(String(describing: c["value"]))")
        }
        for c in jarr(f["site_key"]) {
            assertSame(.string(Scoring.siteKey(c["row"]!)), c["expected"], "site_key")
        }
        for c in jarr(f["eyes"]) {
            assertSame(Scoring.eyeClean(c["eye"]) ?? .null, c["clean"], "eye_clean")
            assertSame(Scoring.eyeGood(c["eye"]).map { .object($0) } ?? .null, c["good"], "eye_good")
        }
        for c in jarr(f["input_minutes"]) {
            assertSame(jn(Scoring.inputMinutes(c["ticks"])), c["expected"], "input_minutes")
        }
        for c in jarr(f["nudge_text"]) {
            assertSame(.string(Scoring.nudgeText(jstr(c["model"]), goal: jstr(c["goal"]), frame: c["frame"])),
                       c["expected"], "nudge_text")
        }
        for c in jarr(f["on_task_share"]) {
            assertSame(jn(Scoring.onTaskShare(c["frames"])), c["expected"], "on_task_share")
        }
        for c in jarr(f["call_sentence"]) {
            let s = Scoring.callSentence(goal: jstr(c["goal"]), why: jstr(c["why"]), minutes: Int(jnum(c["minutes"])!),
                                         doing: jstr(c["doing"]), app: jstr(c["app"]))
            assertSame(.string(s), c["expected"], "call_sentence")
        }
        for c in jarr(f["day_stats"]) {
            let st = Scoring.dayStats(c["blocks"])
            assertSame(st, c["stats"], "day_stats")
            assertSame(.string(Scoring.speakDay(st)), c["speak"], "speak_day")
            assertSame(.string(Scoring.reportLines(st)), c["report"], "report_lines")
        }
    }

    func testTheDaySummariesAndTheirPages() throws {
        let days = jarr(try scoringFixture("days.json"))
        XCTAssertEqual(days.count, 3)
        for c in days {
            let name = jstr(c["name"])
            let kw = c["kwargs"] ?? .object([:])
            let report = FocusDay.report(
                day: jstr(c["day"]), blocks: c["blocks"], startedIds: jarr(kw["started_ids"]),
                history: kw["history"], judge: kw["judge"], final: kw["final"] == .bool(true),
                goalHours: kw["goal_hours"], projects: jarr(kw["projects"]), events: jarr(kw["events"]),
                claude: jarr(kw["claude"]), coach: kw["coach"], weekly: kw["weekly"], modes: jarr(kw["modes"]),
                board: kw["board"])
            assertSame(report, c["report"], "\(name) report")
            let tz = TimeZone(identifier: jstr(c["tz"]))!
            let paras = FocusDay.docParagraphs(report, tz: tz, updatedAt: jnum(c["updated_at"]))
            assertSame(.array(paras.map(\.json)), c["paragraphs"], "\(name) paragraphs")
            XCTAssertEqual(FocusDay.docText(paras), jstr(c["text"]), name)
            XCTAssertEqual(FocusDay.docHTML(paras), jstr(c["html"]), name)
            XCTAssertEqual(FocusDay.verdictLine(report), jstr(c["verdict_line"]), name)
            XCTAssertEqual(FocusDay.hoursSentence(report["hours"]), jstr(c["hours_sentence"]), name)
        }
        let x = try scoringFixture("day_parts.json")
        assertSame(FocusDay.weeklyFallback(x["weekly_fallback"]?["days"]), x["weekly_fallback"]?["expected"], "weekly_fallback")
        assertSame(FocusDay.weeklyClean(x["weekly_clean"]?["raw"]) ?? .null, x["weekly_clean"]?["expected"], "weekly_clean")
        for c in jarr(x["rank_among"]) {
            assertSame(FocusDay.rankAmong(Int(jnum(c["score"])!), day: jstr(c["day"]), history: c["history"]),
                       c["expected"], "rank_among")
        }
        for c in jarr(x["time_range"]) {
            XCTAssertEqual(FocusDay.timeRange(jnum(c["start"])!, jnum(c["end"])!, TimeZone(identifier: "UTC")),
                           jstr(c["expected"]))
        }
        for c in jarr(x["doc_title"]) { XCTAssertEqual(FocusDay.docTitle(jstr(c["day"])), jstr(c["expected"])) }
        for c in jarr(x["hm"]) { XCTAssertEqual(FocusDay.hm(jnum(c["seconds"])), jstr(c["expected"])) }
    }
}

/// Assertions ported from tests/test_focus.py and tests/test_focus_day.py (the pure functions).
final class ScoringPortedTests: XCTestCase {
    let t0 = 1_790_000_000.0


    func block(_ over: [String: JSONValue] = [:]) -> JSONValue {
        var b: [String: JSONValue] = [
            "block_id": "b1".sj, "goal": "Acme onboarding screen".sj, "started_at": .number(t0),
            "ended_at": .number(t0 + 1500), "planned_s": .number(1500), "completed": .bool(true),
            "active_s": .number(1200), "switches": .number(4),
            "apps": .array([.object(["app": "Xcode".sj, "title": "OnboardingView.swift — Acme".sj, "url": "".sj, "seconds": .number(1400)]),
                            .object(["app": "Google Chrome".sj, "title": "SwiftUI docs".sj,
                                     "url": "https://developer.apple.com/x".sj, "seconds": .number(100)])]),
            "frames": .array([.object(["on_goal": .number(0.9), "working": .number(0.9), "doing": "editing SwiftUI view".sj]),
                              .object(["on_goal": .number(1.0), "working": .number(0.8), "doing": "writing code".sj])]),
        ]
        for (k, v) in over { b[k] = v }
        return .object(b)
    }

    func score(_ b: JSONValue, _ rubric: JSONValue? = nil) -> JSONValue { Scoring.scoreBlock(b, rubric: rubric) }
    func int(_ v: JSONValue?) -> Int { Int(jnum(v) ?? -1) }

    func testWeightsSumToOneAndMatchTheDocumentedSplit() {
        XCTAssertEqual(Scoring.focusWeights.map(\.1).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(Scoring.outputWeights.map(\.1).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(Scoring.focusWeights.map(\.0), ["on_goal", "mono"])
        XCTAssertEqual(Scoring.outputWeights.map(\.1), [0.35, 0.25, 0.15, 0.25])
    }

    func testAGoodBlockScoresHighAndTheScoreIsTheMeanOfTheSides() {
        let out = score(block())
        XCTAssertGreaterThan(int(out["score"]), 800)
        XCTAssertEqual(int(out["score"]), Int((Double(int(out["focus_score"]) + int(out["output_score"])) / 2).rounded(.toNearestOrEven)))
        XCTAssertEqual(Set(out["parts"].flatMap { if case .object(let o) = $0 { return Array(o.keys) } else { return nil } } ?? []),
                       ["mono", "on_goal", "progress", "quality", "smart", "engaged", "output"])
        XCTAssertTrue(jstr(out["why"]).contains("on your goal"))
        XCTAssertEqual(score(block()), score(block()))
    }

    func testAlwaysBetween1And1000() {
        let worst = score(block(["active_s": .number(0), "switches": .number(500), "frames": .array([.object(["on_goal": .number(0), "working": .number(0)])]),
                                 "completed": .bool(false), "ended_at": .number(t0 + 1), "apps": .array([])]))
        XCTAssertEqual(int(worst["score"]), 1)
        let best = score(block(["active_s": .number(1500), "switches": .number(0), "apps": .array([.object(["app": "Xcode".sj, "seconds": .number(1500)])]),
                                "frames": .array([.object(["on_goal": .number(1), "working": .number(1)])])]))
        XCTAssertEqual(int(best["score"]), 1000)
        XCTAssertTrue(jstr(best["advice"]).contains("do the next one exactly the same way"))
    }

    func testCameraFieldsChangeNothing() {
        let plain = score(block())
        let old = score(block(["attention": .number(0), "face_present": .number(0),
                               "eye": .object(["on_screen": .number(0.1), "blank": .number(0.9), "samples": .number(1500), "quality": "good".sj])]))
        XCTAssertEqual(plain, old)
        XCTAssertNil(plain["parts"]?["attention"])
    }

    func testWorkedExampleNumberForNumber() {
        let frames: [JSONValue] = [0.3, 0.6, 0.8, 0.8].map {
            .object(["on_goal": .number(0.9), "working": .number(0.8), "quality": .number(0.75), "smart": .number(0.7), "progress": .number($0), "mode": "making".sj])
        }
        let out = score(block(["goal": "Acme rulings".sj, "switches": .number(3), "active_s": .number(900), "frames": .array(frames),
                               "apps": .array([.object(["app": "Google Docs".sj, "title": "Acme rulings".sj, "seconds": .number(1425)]),
                                               .object(["app": "Claude".sj, "seconds": .number(75)])])]))
        XCTAssertEqual(int(out["focus_score"]), 861)
        XCTAssertEqual(int(out["output_score"]), 661)
        XCTAssertEqual(int(out["score"]), 761)
        XCTAssertEqual(jnum(out["parts"]?["mono"]?["value"])!, 0.927, accuracy: 1e-9)
        XCTAssertEqual(jnum(out["parts"]?["output"]?["value"])!, 0.772, accuracy: 1e-9)
        XCTAssertTrue(jstr(out["why"]).contains("80% of the way to the goal"))
    }

    func testOnGoalFromScreensOrOnlyFromPlainlyDistractingSites() {
        let apps: JSONValue = .array([.object(["app": "Xcode".sj, "title": "Acme".sj, "seconds": .number(900)]),
                                      .object(["app": "Google Chrome".sj, "url": "https://www.instagram.com/".sj, "seconds": .number(600)])])
        let g = score(block(["frames": .array([]), "apps": apps]))["parts"]?["on_goal"]
        XCTAssertEqual(jstr(g?["from"]), "apps")
        XCTAssertEqual(jnum(g?["value"])!, 0.6, accuracy: 1e-9)
        let unseen = score(block(["goal": "Finish Acme app rulings".sj, "frames": .array([]),
                                  "apps": .array([.object(["app": "Claude".sj, "seconds": .number(1500)])])]))
        XCTAssertEqual(unseen["parts"]?["on_goal"], .null)
        XCTAssertTrue(jstr(unseen["why"]).contains("screen wasn't read"))
    }

    func testAnIncompleteBlockIsNamedInTheAdvice() {
        let half = score(block(["completed": .bool(false), "ended_at": .number(t0 + 750)]))
        XCTAssertEqual(jnum(half["completion"])!, 0.5, accuracy: 1e-9)
        XCTAssertTrue(jstr(half["advice"]).contains("stopped after 12"))
    }

    func testTheRubricBalanceMilestonesAndHyperfocusCeiling() {
        let rubric: JSONValue = .object(["kind": "building".sj, "balance": .object(["focus": .number(0.35), "output": .number(0.65)]),
                                         "milestones": .array([.object(["id": "a".sj, "text": "A".sj]),
                                                               .object(["id": "b".sj, "text": "B.".sj]),
                                                               .object(["id": "c".sj, "text": "C".sj])])])
        let out = score(block(["milestones_reached": .array(["a".sj, "b".sj])]), rubric)
        XCTAssertLessThanOrEqual(int(out["output_score"]), 667)
        XCTAssertEqual(jstr(out["balance_line"]), "Judged 35% on focus, 65% on output: a building block")
        XCTAssertEqual(out["milestones"]?["missed"], .array(["C".sj]))
        XCTAssertTrue(jstr(out["why"]).contains("Milestones: 2 of 3 reached (A; B). Missed: C."))
        let perfect: [JSONValue] = (1...10).map { i in
            .object(["at": .number(t0 + 60 * Double(i)), "seconds": .number(60), "on_goal": .number(1), "working": .number(1), "quality": .number(1),
                     "smart": .number(1), "progress": .number(1), "away_s": .number(6)])
        }
        let capped = score(block(["active_s": .number(1500), "switches": .number(0), "frames": .array(perfect),
                                  "apps": .array([.object(["app": "Xcode".sj, "seconds": .number(1500)])])]),
                           .object(["kind": "writing".sj, "balance": .object(["focus": .number(0.4), "output": .number(0.6)])]))
        XCTAssertEqual(int(capped["score"]), Scoring.hyperfocusCap)
        XCTAssertTrue(jstr(capped["why"]).contains("on task 90% of the time; 1,000 needs 95% and no distraction site"))
        XCTAssertEqual(Scoring.balanceLine(.object(["focus": .number(0.9)]), kind: "reading"),
                       "Judged 90% on focus, 10% on output: a reading block")
        XCTAssertEqual(Scoring.balanceLine(nil), "")
    }

    func testTimestamps() {
        XCTAssertEqual(Scoring.toTs(.number(t0)), t0)
        XCTAssertEqual(Scoring.toTs(.number(t0 * 1000)), t0)
        XCTAssertEqual(Scoring.toTs(.string(String(Int(t0)))), t0)
        XCTAssertEqual(Scoring.toTs(.string("2026-09-21T09:00:00Z")), 1_789_981_200)
        XCTAssertEqual(Scoring.toTs(.string("nonsense")), 0)
        XCTAssertEqual(Scoring.toTs(nil), 0)
    }

    func testDetoursAndTheSequence() {
        let on: [String: JSONValue] = ["on_goal": .number(0.9), "working": .number(0.8), "quality": .number(0.8), "mode": "making".sj, "app": "Claude".sj]
        let off: [String: JSONValue] = ["on_goal": .number(0.05), "working": .number(0.1), "quality": .number(0.1), "mode": "other".sj, "app": "Calendar".sj]
        func at(_ o: [String: JSONValue], _ t: Double) -> JSONValue { var x = o; x["at"] = .number(t); return .object(x) }
        var frames = [at(on, t0), at(off, t0 + 60), at(on, t0 + 120)]
        XCTAssertEqual(Scoring.markDetours(&frames), 1)
        XCTAssertEqual(Scoring.markDetours(&frames), 0)
        XCTAssertEqual(Scoring.tickDistracted(.object(["phase": "work".sj, "at": .number(t0 + 70)]), frames: .array(frames)), "")
        XCTAssertTrue(Scoring.framePending(.object(["app": "Xcode".sj]), said: .bool(true)))
        XCTAssertFalse(Scoring.framePending(.object(["app": "Messages".sj]), said: .bool(true)))
        XCTAssertTrue(Scoring.looksAmbiguous(.object(["app": "Google Chrome".sj, "url": "https://mail.google.com/u/0".sj])))
    }

    func testNudges() {
        let offF: JSONValue = .object(["on_goal": .number(0.1), "quality": .number(0.2), "url": "https://www.youtube.com/watch?v=1".sj, "app": "Chrome".sj])
        let ramble: JSONValue = .object(["on_goal": .number(0.8), "quality": .number(0.1), "app": "ChatGPT".sj])
        let onF: JSONValue = .object(["on_goal": .number(0.9), "quality": .number(0.8)])
        XCTAssertFalse(Scoring.frameOffTask(.object(["on_goal": .number(0.3), "quality": .number(0.25)])))
        XCTAssertTrue(Scoring.nudgeAllowed(offF, previous: ramble, lastNudgeAt: 0, now: t0))
        XCTAssertFalse(Scoring.nudgeAllowed(offF, previous: onF, lastNudgeAt: 0, now: t0))
        XCTAssertFalse(Scoring.nudgeAllowed(offF, previous: offF, lastNudgeAt: t0 - 239, now: t0))
        XCTAssertTrue(Scoring.nudgeAllowed(offF, previous: offF, lastNudgeAt: t0 - 240, now: t0))
        XCTAssertEqual(Scoring.nudgeText("", goal: "the HIST 2 intro", frame: offF), "Close youtube.com — back to the HIST 2 intro.")
    }

    func testNextBlockLength() {
        XCTAssertEqual(Scoring.nextBlockLength(breakS: 18 * 60, todayBreaksScaled: [], currentS: 1500).nextWorkS, 900)
        XCTAssertEqual(Scoring.nextBlockLength(breakS: 18 * 60, todayBreaksScaled: [], currentS: 1500).nextReason,
                       "Your focus slipped around minute 18, so the next block is 15 minutes.")
        XCTAssertEqual(Scoring.nextBlockLength(breakS: nil, todayBreaksScaled: [], currentS: 9000).nextWorkS, 7200)
        XCTAssertEqual(Scoring.lengthScale(60), 0.04, accuracy: 1e-12)
        let out = Scoring.nextBlockLength(breakS: 30, todayBreaksScaled: [], currentS: 60, scale: Scoring.lengthScale(60))
        XCTAssertEqual(out.nextWorkS, 24)
        XCTAssertEqual(out.nextReason, "Your focus slipped around second 30, so the next block is 24 seconds.")
    }

    func testGoalWords() {
        XCTAssertEqual(Scoring.goalLabel("write the intro of the HIST 2 reaction paper today"), "write the intro of the HIST")
        XCTAssertEqual(Scoring.goalVagueness("essays", context: "Open Canvas work: HIST 2 Reaction paper essay"), "")
        XCTAssertEqual(Scoring.goalVagueness("banana", context: "essay"), "unknown")
        XCTAssertTrue(Scoring.needsInferredGoal("stuff"))
        XCTAssertFalse(Scoring.needsInferredGoal("stuff", specificGoal: "Draft rulings 1-5".sj))
        XCTAssertEqual(Scoring.tipText("Draft the ruling table first, then write the reasoning. Also X."),
                       "Draft the ruling table first, then write the reasoning.")
        XCTAssertLessThanOrEqual(Scoring.tipText(String(repeating: "word ", count: 80)).count, 140)
    }

    // ---------------------------------------------------------------- the day

    func day(_ i: Int, _ score: Int, completed: Bool = true, completion: Double? = nil) -> JSONValue {
        let d0 = 1_789_981_200.0
        return .object([
            "block_id": .string("b\(i)"), "score": .number(Double(score)), "completed": .bool(completed), "planned_s": .number(1500),
            "completion": .number(completed ? 1.0 : (completion ?? 0.4)),
            "started_at": .number(d0 + Double(i) * 1800), "ended_at": .number(d0 + Double(i) * 1800 + 1500),
            "goal": "HIST 2 intro".sj, "understood": "Write the intro section of the HIST 2 report.".sj,
            "parts": .object(["on_goal": .object(["value": .number(0.9)]), "output": .object(["value": .number(0.7)])]),
            "frames": .array([.object(["on_goal": .number(0.9), "doing": "writing HIST 2 intro".sj]),
                              .object(["on_goal": .number(0.9), "doing": "Writing HIST 2 intro".sj]),
                              .object(["on_goal": .number(0.8), "doing": "reading control list".sj]),
                              .object(["on_goal": .number(0.1), "doing": "scrolling reddit".sj, "url": "https://reddit.com/r/x".sj])]),
            "apps": .array([.object(["app": "Google Docs".sj, "title": "HIST 2 intro".sj, "seconds": .number(1300)]),
                            .object(["app": "Google Chrome".sj, "url": "https://www.reddit.com/r/x".sj, "seconds": .number(200)])]),
            "advice": "Close reddit.com before the next block starts.".sj,
        ])
    }

    var worked: [JSONValue] { [day(0, 795), day(1, 700), day(2, 650), day(3, 600), day(4, 400, completed: false)] }

    func testTheDocumentedWorkedDay() {
        let t = FocusDay.dayTotals(.array(worked))
        XCTAssertEqual([t["blocks"], t["done"], t["started"], t["avg"], t["best"]].map { int($0) }, [5, 4, 5, 629, 795])
        XCTAssertEqual(jnum(t["focused_s"])! / 60, 100.4, accuracy: 0.05)
        let parts = FocusDay.dayParts(t, substance: 0.6)
        XCTAssertEqual(parts, .object(["volume": .number(0.418), "substance": .number(0.6), "quality": .number(0.696)]))
        XCTAssertEqual(FocusDay.dayScore(parts), 526)
        let r = FocusDay.report(day: "2026-09-21", blocks: .array(worked), judge: .object(["substance": .number(0.6), "why": "x".sj]))
        XCTAssertEqual(int(r["score"]), 526)
        XCTAssertEqual(jstr(r["verdict"]), "Solid")
        XCTAssertEqual(FocusDay.dayScore(.object(["volume": .number(0), "substance": .number(0), "quality": .number(0)])), 21)
        XCTAssertEqual(FocusDay.dayScore(.object(["volume": .number(1), "substance": .number(1), "quality": .number(1)])), 1000)
        let screens = FocusDay.report(day: "2026-09-21", blocks: .array(worked))
        XCTAssertEqual(jstr(screens["judged_by"]), "screens")
        XCTAssertTrue(jstr(screens["why"]).hasPrefix("1 h 40 min of focused work across 4 finished blocks"))
    }

    func testRankAndVerdict() {
        let hist: JSONValue = .object(["2026-09-10": .number(800), "2026-09-15": .number(400), "2026-09-18": .number(650), "2026-09-19": .number(300),
                                       "2026-09-20": .number(550), "2026-09-01": .number(999), "2026-09-22": .number(999)])
        XCTAssertEqual(jstr(FocusDay.rankAmong(600, day: "2026-09-21", history: hist)["line"]), "your 3rd best day of the last 6")
        XCTAssertEqual(jstr(FocusDay.rankAmong(900, day: "2026-09-21", history: hist)["line"]), "your best day of the last 6")
        XCTAssertEqual(jstr(FocusDay.rankAmong(100, day: "2026-09-21", history: hist)["line"]), "your weakest day of the last 6")
        XCTAssertEqual(FocusDay.verdictFor(700, rank: .object(["rank": .number(3), "earlier": .number(9)])), "Proud")
        XCTAssertEqual(FocusDay.verdictFor(699, rank: .object(["rank": .number(3), "earlier": .number(9)])), "Solid")
        XCTAssertEqual(FocusDay.verdictFor(449, rank: .object(["rank": .number(3), "earlier": .number(9)])), "Under")
        XCTAssertEqual(FocusDay.verdictFor(610, rank: .object(["rank": .number(1), "earlier": .number(5)])), "Proud")
        XCTAssertEqual(FocusDay.verdictFor(610, rank: .object(["rank": .number(1), "earlier": .number(4)])), "Solid")
    }

    func testBulletsLeaksAndThePage() {
        XCTAssertEqual(FocusDay.fallbackBullets(day(0, 700)), ["Writing HIST 2 intro", "Reading control list"])
        XCTAssertEqual(FocusDay.cleanBullets(.array(["  drafted the intro. ".sj, "".sj, "- read the control list".sj, "a".sj, "b".sj])),
                       ["Drafted the intro", "Read the control list", "A"])
        XCTAssertEqual(FocusDay.leaks(.array([day(0, 700)])).first?.0, "reddit.com")
        XCTAssertEqual(FocusDay.docTitle("2026-09-21"), "2026-09-21 — Monday")
        let utc = TimeZone(identifier: "UTC")
        XCTAssertEqual(FocusDay.timeRange(1_789_981_500, 1_789_983_000, utc), "9:05–9:30 am")
        let report = FocusDay.report(day: "2026-09-21", blocks: .array(worked),
                                     judge: .object(["substance": .number(0.6), "tomorrow": "start before 9".sj]))
        let paras = FocusDay.docParagraphs(report, tz: utc)
        let text = FocusDay.docText(paras)
        XCTAssertTrue(text.hasPrefix("Solid — 526 out of 1000"))
        XCTAssertEqual(paras[0].style, "TITLE")
        XCTAssertEqual(paras[0].bold, 5)
        XCTAssertTrue(text.contains("9:00–9:25 am · 795 / 1000"))
        XCTAssertTrue(text.contains("(stopped early)"))
        XCTAssertTrue(text.contains("Goal: Write the intro section of the HIST 2 report."))
        XCTAssertTrue(text.contains("Blocks: 4 finished of 5 started"))
        XCTAssertTrue(text.contains("Tomorrow: Start before 9."))
        XCTAssertTrue(text.contains("So far"))
        for jargon in ["on_goal", "parts", "substance", "0."] { XCTAssertFalse(text.contains(jargon), jargon) }
        let html = FocusDay.docHTML(paras)
        XCTAssertTrue(html.contains("<h1><b>Solid</b> — 526"))
        XCTAssertTrue(html.contains("<h2>What you got done</h2>"))
        XCTAssertEqual(html.components(separatedBy: "<ul>").count, html.components(separatedBy: "</ul>").count)
        XCTAssertTrue(FocusDay.docHTML([DayParagraph("a <b> tag")]).contains("&lt;"))
        XCTAssertTrue(FocusDay.verdictLine(report).hasPrefix("Today so far: Solid, 526 out of 1000"))
        XCTAssertEqual(FocusDay.hoursGoalLine(5400, goalHours: .number(1.5)), "1 h 30 min of your 1.5-hour goal (100%)")
        XCTAssertEqual(FocusDay.hoursGoalLine(100, goalHours: nil), "")
    }

    func testAnEmptyDayHasNoHoursSection() {
        let rep = FocusDay.report(day: "2026-09-21", blocks: .array([]))
        XCTAssertEqual(FocusDay.hoursParagraphs(rep["hours"]), [])
        XCTAssertEqual(FocusDay.hoursSentence(rep["hours"]), "")
        XCTAssertEqual(FocusDay.goalsParagraphs(.array([])), [])
        XCTAssertTrue(FocusDay.docText(FocusDay.docParagraphs(rep, tz: TimeZone(identifier: "UTC"))).contains("No focus blocks were finished today."))
    }

    func testTheMarkdownPage() {
        let paras = [DayParagraph("Solid — 526 out of 1000", style: "TITLE", bold: 5), DayParagraph("Why it went *well*."),
                     DayParagraph("Hours", style: "HEADING_1"), DayParagraph("one", bullet: true), DayParagraph("two", bullet: true),
                     DayParagraph("Tomorrow: start early", bold: 9)]
        XCTAssertEqual(FocusDay.markdown(paras),
                       "# **Solid** — 526 out of 1000\n\nWhy it went \\*well\\*.\n\n## Hours\n\n- one\n- two\n\n**Tomorrow:** start early\n")
    }
}

private extension String {
    var sj: JSONValue { .string(self) }
}
