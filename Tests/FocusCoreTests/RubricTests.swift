import XCTest
@testable import FocusCore

// MARK: - The block's rubric: parsing, the goal screen's lines, the Now tab's line, and "Fix…"

final class RubricTests: XCTestCase {
    private func json(_ s: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    private let readingReply = """
    {"status":"ok","goal":"Geo reading","understood":"Reading the geology chapters.",
     "specific_goal":"Read chapters 3 and 4 of the geology reader",
     "rubric":{"kind":"reading","balance":{"focus":0.9,"output":0.1},
       "milestones":[{"id":"m1","text":"Finish chapter 3"},{"id":"m2","text":"Finish chapter 4"}],
       "on_tells":[{"id":"t1","text":"the reader PDF open"},{"id":"t2","text":"steady scrolling"},
                   {"id":"t3","text":"notes in the margin"},{"id":"t4","text":"a dictionary lookup"}],
       "off_tells":[{"id":"o1","text":"YouTube"}],"smart":["Read 2 chapters in 50 min"],"md":"# Reading"}}
    """

    // MARK: Parsing

    func testFullReplyParses() throws {
        let reply = try XCTUnwrap(GoalReply.parse(json(readingReply)))
        let r = try XCTUnwrap(reply.rubric)
        XCTAssertEqual(r.kind, .reading)
        XCTAssertEqual(r.balance, Rubric.Balance(focus: 0.9, output: 0.1))
        XCTAssertEqual(r.milestones.map(\.id), ["m1", "m2"])
        XCTAssertEqual(r.onTells.count, 4)
        XCTAssertEqual(r.offTells.map(\.text), ["YouTube"])
        XCTAssertEqual(r.smart, ["Read 2 chapters in 50 min"])
        XCTAssertEqual(r.md, "# Reading")
    }

    func testMissingOrJunkRubricIsNil() {
        XCTAssertNil(GoalReply.parse(json(#"{"status":"ok","goal":"x"}"#))?.rubric)
        XCTAssertNil(Rubric.parse(json(#""text""#)))
        XCTAssertNil(Rubric.parse(json(#"{}"#)))
        XCTAssertNil(Rubric.parse(json(#"{"kind":"knitting","milestones":[],"balance":{}}"#)))
        XCTAssertNil(Rubric.parse(nil))
        // The goal itself still goes through.
        XCTAssertEqual(GoalReply.parse(json(#"{"status":"ok","goal":"x","rubric":7}"#))?.goal, "x")
    }

    func testLenientFields() throws {
        let r = try XCTUnwrap(Rubric.parse(json("""
        {"kind":"Writing","balance":{"focus":30,"output":70},
         "milestones":["Outline", {"text":"  Draft intro "}, {"id":3,"text":"Edit"}, {"text":""}, 5,
                       "a","b","c"],
         "on_tells":"nope"}
        """)))
        XCTAssertEqual(r.kind, .writing)
        XCTAssertEqual(r.balance?.focus ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(r.milestones.map(\.text), ["Outline", "Draft intro", "Edit", "a", "b"])  // max 5
        XCTAssertEqual(r.milestones.map(\.id), ["m1", "m2", "3", "m6", "m7"])
        XCTAssertTrue(r.onTells.isEmpty)
    }

    func testBalanceShapes() {
        XCTAssertEqual(Rubric.parseBalance(json(#"{"focus":0.6}"#))?.output ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(Rubric.parseBalance(json(#"{"output":"0.25"}"#))?.focus ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(Rubric.parseBalance(json(#"{"focus":3,"output":1}"#))?.focus ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertNil(Rubric.parseBalance(json(#"{"focus":0,"output":0}"#)))
        XCTAssertNil(Rubric.parseBalance(json(#"{"focus":-1}"#)))
        XCTAssertNil(Rubric.parseBalance(nil))
    }

    // MARK: Lines

    func testBalanceLine() {
        func line(_ f: Double, _ o: Double) -> String? { Rubric(balance: .init(focus: f, output: o)).balanceLine }
        XCTAssertEqual(line(0.9, 0.1), "Judged 90% on focus, 10% on output")
        XCTAssertEqual(line(0.5, 0.5), "Judged half on focus, half on output")
        XCTAssertEqual(line(0.666, 0.334), "Judged 67% on focus, 33% on output")
        XCTAssertEqual(line(1, 0), "Judged 100% on focus, 0% on output")
        XCTAssertEqual(line(0.505, 0.495), "Judged 51% on focus, 49% on output")
        XCTAssertNil(Rubric(md: "x").balanceLine)
    }

    func testSummaryForAReadingGoalWithTwoMilestones() throws {
        let r = try XCTUnwrap(GoalReply.parse(json(readingReply))?.rubric)
        XCTAssertEqual(r.summaryLines, [
            "Judged 90% on focus, 10% on output",
            "1. Finish chapter 3",
            "2. Finish chapter 4",
            "Watching for: the reader PDF open · steady scrolling · notes in the margin",
        ])
    }

    func testSummaryIsAtMostSixLines() {
        let ms = (1...5).map { Rubric.Item(id: "m\($0)", text: "Step \($0)") }
        let r = Rubric(balance: .init(focus: 0.5, output: 0.5), milestones: ms,
                       onTells: [.init(id: "t", text: "typing")])
        XCTAssertEqual(r.summaryLines.count, 6)
        XCTAssertEqual(r.summaryLines.last, "5. Step 5")
        // No balance, no tells: just the milestones; nothing at all = no lines.
        XCTAssertEqual(Rubric(milestones: [ms[0]]).summaryLines, ["1. Step 1"])
        XCTAssertEqual(Rubric(md: "only md").summaryLines, [])
    }

    func testLongLinesAreClipped() {
        let r = Rubric(milestones: [.init(id: "m1", text: String(repeating: "a", count: 200))])
        XCTAssertEqual(r.summaryLines[0].count, 3 + Rubric.maxLineLength)
        XCTAssertTrue(r.summaryLines[0].hasSuffix("…"))
    }

    // MARK: Now tab

    func testNowSnapshotRubric() throws {
        let s = try XCTUnwrap(NowSnapshot.parse(json(##"{"active":true,"rubric":{"md":"# R","balance":{"focus":0.9,"output":0.1}}}"##)))
        XCTAssertEqual(s.rubric?.balanceLine, "Judged 90% on focus, 10% on output")
        XCTAssertNil(s.milestonesReached)
        XCTAssertNil(NowSnapshot.parse(json(#"{"active":true}"#))?.rubric)
        let t = try XCTUnwrap(NowSnapshot.parse(json(#"{"rubric":{"md":"x","milestones_reached":["m1",2]}}"#)))
        XCTAssertEqual(t.milestonesReached, ["m1", "2"])
        XCTAssertEqual(NowSnapshot.parse(json(#"{"milestones_reached":[]}"#))?.milestonesReached, [])
    }

    func testNowLine() throws {
        let local = try XCTUnwrap(GoalReply.parse(json(readingReply))?.rubric)
        let now = Rubric(balance: .init(focus: 0.9, output: 0.1), md: "# R")
        XCTAssertEqual(Rubric.nowLine(now: now, local: local, reached: nil),
                       "Judged 90% on focus, 10% on output · 1. Finish chapter 3 · 2. Finish chapter 4")
        XCTAssertEqual(Rubric.nowLine(now: now, local: local, reached: ["m1"]),
                       "Judged 90% on focus, 10% on output · ✓ 1. Finish chapter 3 · 2. Finish chapter 4")
        XCTAssertEqual(Rubric.nowLine(now: now, local: local, reached: ["2", "finish chapter 3"]),
                       "Judged 90% on focus, 10% on output · ✓ 1. Finish chapter 3 · ✓ 2. Finish chapter 4")
        XCTAssertEqual(Rubric.nowLine(now: now, local: nil, reached: nil), "Judged 90% on focus, 10% on output")
        XCTAssertEqual(Rubric.nowLine(now: nil, local: local, reached: nil), "")
    }

    // MARK: Fix…

    func testFixRoundTrip() throws {
        let r = try XCTUnwrap(GoalReply.parse(json(readingReply))?.rubric)
        var fix = RubricFix(rubric: r)
        XCTAssertTrue(fix.canFix)
        XCTAssertFalse(fix.holdsStart)
        XCTAssertEqual(fix.lines, r.summaryLines)

        XCTAssertTrue(fix.open())
        XCTAssertTrue(fix.isEditing)
        XCTAssertTrue(fix.holdsStart)
        XCTAssertFalse(fix.canFix)

        XCTAssertEqual(fix.submit("  this is mostly\nreading ", now: 10), "this is mostly reading")
        XCTAssertEqual(fix.stage, .rewriting)
        XCTAssertEqual(fix.lines, ["Rewriting…"])

        let new = Rubric(balance: .init(focus: 1, output: 0))
        XCTAssertFalse(fix.receive(new, requestId: fix.requestId - 1))   // stale
        XCTAssertTrue(fix.receive(new, requestId: fix.requestId))
        XCTAssertEqual(fix.stage, .closed)
        XCTAssertEqual(fix.lines, ["Judged 100% on focus, 0% on output"])
        XCTAssertFalse(fix.holdsStart)
    }

    func testFixEmptyAndEscapeClose() {
        var fix = RubricFix(rubric: Rubric(balance: .init(focus: 0.5, output: 0.5)))
        fix.open()
        XCTAssertNil(fix.submit("   ", now: 0))
        XCTAssertEqual(fix.stage, .closed)
        XCTAssertFalse(fix.escape())          // nothing open: Esc goes on to the screen
        fix.open()
        XCTAssertTrue(fix.escape())
        XCTAssertEqual(fix.stage, .closed)
        // Esc while rewriting gives up; the late reply is ignored and the old summary stays.
        fix.open()
        _ = fix.submit("more output", now: 0)
        XCTAssertTrue(fix.escape())
        XCTAssertFalse(fix.receive(Rubric(md: "late"), requestId: fix.requestId))
        XCTAssertEqual(fix.lines, ["Judged half on focus, half on output"])
    }

    func testFixFailureAndTimeoutKeepTheOldSummary() {
        let old = Rubric(balance: .init(focus: 0.9, output: 0.1))
        var fix = RubricFix(rubric: old)
        fix.open()
        _ = fix.submit("x", now: 0)
        XCTAssertTrue(fix.receive(nil, requestId: fix.requestId))
        XCTAssertEqual(fix.rubric, old)

        fix.open()
        _ = fix.submit("y", now: 100)
        XCTAssertFalse(fix.tick(now: 100 + RubricFix.timeout - 0.1))
        XCTAssertTrue(fix.tick(now: 100 + RubricFix.timeout))
        XCTAssertEqual(fix.stage, .closed)
        XCTAssertEqual(fix.rubric, old)
    }

    func testNoteIsCappedAndNoRubricMeansNoFix() {
        var fix = RubricFix(rubric: Rubric(milestones: [.init(id: "m1", text: "a")]))
        fix.open()
        XCTAssertEqual(fix.submit(String(repeating: "z", count: 500), now: 0)?.count, RubricFix.maxNote)
        var none = RubricFix()
        XCTAssertFalse(none.canFix)
        XCTAssertFalse(none.open())
        XCTAssertEqual(none.lines, [])
        XCTAssertFalse(none.holdsStart)
        var mdOnly = RubricFix(rubric: Rubric(md: "x"))
        XCTAssertFalse(mdOnly.open())
    }

    func testRubricNoteIsSentOnlyWhenSet() throws {
        let plain = String(decoding: try JSONEncoder().encode(GoalRequest(text: "a", previousGoal: "", previousUnderstood: "", at: 1)), as: UTF8.self)
        XCTAssertFalse(plain.contains("rubric_note"))
        let fix = try JSONEncoder().encode(GoalRequest(text: "a", previousGoal: "", previousUnderstood: "",
                                                       rubricNote: "mostly reading", at: 1))
        XCTAssertEqual(json(String(decoding: fix, as: UTF8.self)).str("rubric_note"), "mostly reading")
    }

    // MARK: The goal screen's timing

    func testRubricHoldsTheGotItScreenLongerAndFixExtendsIt() throws {
        var f = GoalFlow(previousGoal: "", previousUnderstood: "")
        _ = f.submit("Geo reading", now: 0)
        let reply = try XCTUnwrap(GoalReply.parse(json(readingReply)))
        let fx = f.receive(reply, requestId: 1, now: 1)
        XCTAssertEqual(fx, [.showUnderstood("Read chapters 3 and 4 of the geology reader"),
                            .showRubric(reply.rubric!)])
        XCTAssertEqual(f.tick(now: 1 + GoalFlow.understoodHold), [])
        XCTAssertEqual(f.tick(now: 1 + GoalFlow.rubricHold - 0.01), [])
        f.holdUntil(10)
        XCTAssertEqual(f.tick(now: 1 + GoalFlow.rubricHold), [])
        XCTAssertEqual(f.tick(now: 10).count, 1)
        XCTAssertEqual(f.stage, .done)
    }

    func testNoRubricKeepsTheOldTiming() throws {
        var f = GoalFlow(previousGoal: "", previousUnderstood: "")
        _ = f.submit("x", now: 0)
        _ = f.receive(GoalReply(status: .ok, goal: "x", understood: "Doing x."), requestId: 1, now: 1)
        XCTAssertEqual(f.tick(now: 1 + GoalFlow.understoodHold).count, 1)
        // holdUntil outside the "Got it" screen does nothing.
        f.holdUntil(100)
        XCTAssertEqual(f.stage, .done)
    }
}
