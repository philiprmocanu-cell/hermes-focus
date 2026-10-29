import XCTest
@testable import FocusCore

private func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
private func object<T: Encodable>(_ v: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as! [String: Any]
}

// MARK: - The break screen is rest

final class BreakRevealTests: XCTestCase {
    func testTheCornerCardFadesOutThirtySecondsIn() {
        XCTAssertEqual(BreakReveal.opacity(since: 0), 1)
        XCTAssertEqual(BreakReveal.opacity(since: 29.9), 1)
        XCTAssertTrue(BreakReveal.isVisible(since: 29.9))
        // It fades over `fadeDuration`, then it's gone for the rest of the break.
        XCTAssertEqual(BreakReveal.opacity(since: 30 + BreakReveal.fadeDuration / 2), 0.5, accuracy: 0.01)
        XCTAssertEqual(BreakReveal.opacity(since: 30 + BreakReveal.fadeDuration), 0)
        XCTAssertFalse(BreakReveal.isVisible(since: 60))
        XCTAssertFalse(BreakReveal.isVisible(since: 5 * 60))
    }

    func testOneGreyLinePointsAtTheDoc() {
        XCTAssertEqual(BreakReveal.footnote, "Review it later in History")
    }
}

// MARK: - Countdown

final class CountdownLengthTests: XCTestCase {
    func testThreeSecondsAndTestModeIsShorter() {
        XCTAssertEqual(Durations.standard.countdown, 3, "3, 2, 1 — three seconds")
        XCTAssertLessThanOrEqual(Durations.test.countdown, Durations.standard.countdown)
        XCTAssertGreaterThan(Durations.test.countdown, 0)

        var m = PhaseMachine(durations: .standard, makeId: { "b" })
        _ = m.start(now: 0)
        XCTAssertEqual(m.submitGoal("write", now: 100), [.countdownStarted])
        XCTAssertEqual(m.countdownNumber(now: 100), 3)
        XCTAssertEqual(m.countdownNumber(now: 101), 2)
        XCTAssertEqual(m.countdownNumber(now: 102), 1)
        XCTAssertEqual(m.tick(now: 102.9), [])
        XCTAssertEqual(m.tick(now: 103), [.workStarted(blockId: "b", goal: "write", startedAt: 103)])
    }
}

// MARK: - The daily hours goal, edited from the black screen

final class HoursGoalEditorTests: XCTestCase {
    func testStepperStaysInsideHalfAndSixteenHours() {
        var e = HoursGoalEditor(hours: 4)
        XCTAssertEqual(e.text, "4")
        XCTAssertEqual(e.caption, "of 4 h")
        e.bump(1)
        XCTAssertEqual(e.hours, 4.5)
        XCTAssertEqual(e.text, "4.5")
        XCTAssertEqual(e.caption, "of 4.5 h")

        var low = HoursGoalEditor(hours: 0.5)
        XCTAssertFalse(low.canDecrease)
        low.bump(-1)
        XCTAssertEqual(low.hours, HoursMath.minGoalHours)

        var high = HoursGoalEditor(hours: 16)
        XCTAssertFalse(high.canIncrease)
        high.bump(1)
        XCTAssertEqual(high.hours, HoursMath.maxGoalHours)
        XCTAssertEqual(HoursGoalEditor(hours: 99).hours, 16)
        XCTAssertEqual(HoursGoalEditor(hours: 0).hours, 0.5)
    }

    func testTypingIsClampedAndNonsenseKeepsTheGoal() {
        var e = HoursGoalEditor(hours: 4)
        XCTAssertTrue(e.type("6.5"))
        XCTAssertEqual(e.hours, 6.5)
        XCTAssertTrue(e.type("3,5"), "a comma is a decimal point too")
        XCTAssertEqual(e.hours, 3.5)
        XCTAssertTrue(e.type("40"))
        XCTAssertEqual(e.hours, 16, "clamped, not refused")
        XCTAssertFalse(e.type("soon"))
        XCTAssertEqual(e.hours, 16, "nonsense leaves the goal alone")
        XCTAssertEqual(e.text, "soon", "…but he can still see what he typed")
        XCTAssertEqual(e.commit(), 16)
        XCTAssertEqual(e.text, "16", "Enter tidies the field up")
        // It edits the goal, never the hours logged.
        XCTAssertEqual(HoursMath.loggedSeconds(serverFocusS: 7200, serverDay: "D", local: DayFocus(), today: "D",
                                               running: 0), 7200)
    }
}

// MARK: - He moved to another goal (the server decides)

final class GoalChangeTests: XCTestCase {
    func testParsedFromAFrameOrTickReply() throws {
        let reply = try json("""
        {"quality": 0.8, "tip": "keep going",
         "goal_changed": {"goal": "reading Kant", "specific_goal": "finish chapter 2 of the Critique"}}
        """)
        let r = FrameResult.parse(reply)
        XCTAssertEqual(r.tip, "keep going")
        let change = try XCTUnwrap(r.goalChanged)
        XCTAssertEqual(change.goal, "reading Kant")
        XCTAssertEqual(change.specificGoal, "finish chapter 2 of the Critique")
        XCTAssertEqual(change.toastText, "Looks like you moved to reading Kant — scoring that now")

        XCTAssertNil(GoalChange.parse(try json("{}")))
        XCTAssertNil(GoalChange.parse(try json(#"{"goal_changed": {}}"#)))
        XCTAssertNil(GoalChange.parse(try json(#"{"goal_changed": {"specific_goal": "x"}}"#)), "a goal is the point")
    }

    func testItReplacesTheBlocksGoalAndOnlyWhenItIsNew() {
        let plan = GoalPlan(goal: "maths sheet 4", understood: "He is doing maths sheet 4.", specificGoal: "questions 1-8")
        let change = GoalChange(goal: "reading Kant", specificGoal: "chapter 2")
        XCTAssertTrue(change.changes(plan))
        let moved = change.applied(to: plan)
        XCTAssertEqual(moved.goal, "reading Kant")
        XCTAssertEqual(moved.specificGoal, "chapter 2")
        XCTAssertEqual(moved.understood, "", "the old sentence described the old goal")

        // The same change again changes nothing (no second toast).
        XCTAssertFalse(change.changes(moved))
        XCTAssertFalse(GoalChange(goal: "Reading  Kant!", specificGoal: "chapter 2").changes(moved))
        // A change to a NEW goal with no sharpened goal of its own never keeps the old goal's one.
        XCTAssertEqual(GoalChange(goal: "essay").applied(to: plan).specificGoal, "")
        // The same goal (another spelling) with no sharpened goal keeps the one we had.
        XCTAssertEqual(GoalChange(goal: "Maths sheet 4").applied(to: plan).specificGoal, "questions 1-8")
    }
}

// MARK: - The links at the bottom of the goal screen

final class GoalScreenLinkTests: XCTestCase {
    func testTheRowAndWhatIsHidden() {
        // No suggestions from the brain: no empty link.
        XCTAssertEqual(GoalScreenLink.row(hasSuggestions: true, isOwner: false),
                       [.suggestions, .settings, .friends, .history, .endSession])
        XCTAssertEqual(GoalScreenLink.row(hasSuggestions: false, isOwner: false),
                       [.settings, .friends, .history, .endSession])
        XCTAssertEqual(GoalScreenLink.friends.title, "Friends")
        XCTAssertEqual(GoalScreenLink.history.title, "History")
        XCTAssertTrue(GoalScreenLink.friends.isPanel)
        XCTAssertTrue(GoalScreenLink.history.isPanel)
        XCTAssertFalse(GoalScreenLink.endSession.isPanel)
        XCTAssertFalse(GoalScreenLink.settings.isVoice)
    }

    func testOnlyOnePanelIsOpenAndEveryScreenStartsClosed() {
        var picker = SuggestionPicker(items: [BlockSuggestion(goal: "maths sheet 4")])
        var d = GoalScreenDisclosure()
        XCTAssertNil(d.open)
        XCTAssertFalse(d.anyOpen)

        d.toggle(.friends, &picker)
        XCTAssertEqual(d.open, .friends)
        d.toggle(.settings, &picker)
        XCTAssertEqual(d.open, .settings, "opening one closes the other")
        XCTAssertFalse(d.friendsOpen)
        d.toggle(.suggestions, &picker)
        XCTAssertEqual(d.open, .suggestions)
        d.toggle(.friends, &picker)
        XCTAssertEqual(d.open, .friends)
        XCTAssertFalse(d.suggestionsOpen)
        d.toggle(.history, &picker)
        XCTAssertEqual(d.open, .history)
        XCTAssertFalse(d.friendsOpen)
        d.toggle(.friends, &picker)
        XCTAssertEqual(d.open, .friends)
        XCTAssertFalse(d.historyOpen, "History closes when another panel opens")
        d.toggle(.friends, &picker)
        XCTAssertNil(d.open, "clicking the open one closes it")

        // Esc closes whatever is open before it ends the session.
        d.toggle(.friends, &picker)
        XCTAssertTrue(d.escape(&picker))
        XCTAssertFalse(d.anyOpen)
        XCTAssertFalse(d.escape(&picker))
        // Esc closes History too.
        d.toggle(.history, &picker)
        XCTAssertTrue(d.escape(&picker))
        XCTAssertFalse(d.anyOpen)
        // ↓ from the field still opens Suggestions, closing History.
        d.toggle(.history, &picker)
        XCTAssertTrue(d.keyDown(&picker))
        XCTAssertEqual(d.open, .suggestions)
        XCTAssertFalse(d.historyOpen)
        _ = d.escape(&picker)
        // …and Friends.
        d.toggle(.friends, &picker)
        XCTAssertTrue(d.keyDown(&picker))
        XCTAssertEqual(d.open, .suggestions)
        // A fresh goal screen: everything closed.
        XCTAssertNil(GoalScreenDisclosure().open)
        // "End session" never opens a panel.
        var e = GoalScreenDisclosure()
        e.toggle(.endSession, &picker)
        XCTAssertFalse(e.anyOpen)
    }
}

// MARK: - Friend mode runs the same app on different routes

final class FocusRouteTests: XCTestCase {
    private let owner = BrainConfig(baseURL: "https://brain.example", token: "SECRET")
    private let friend = FriendConfig(baseURL: "https://brain.example/", token: "LBTOKEN", name: "Bro")

    func testOwnerRoutesKeepTheSecretPrefix() throws {
        for route in FocusRoute.allCases {
            let t = try XCTUnwrap(FocusRoute.target(route, owner: owner, friend: nil))
            XCTAssertTrue(t.url.absoluteString.hasPrefix("https://brain.example/t/SECRET/admin/focus/"),
                          "\(route): \(t.url)")
            XCTAssertTrue(t.headers.isEmpty, "the token is in the path, not a header")
        }
        XCTAssertEqual(FocusRoute.target(.now, owner: owner, friend: nil)?.url.absoluteString,
                       "https://brain.example/t/SECRET/admin/focus/now")
        XCTAssertEqual(FocusRoute.target(.leaderboard, owner: owner, friend: nil)?.url.absoluteString,
                       "https://brain.example/t/SECRET/admin/focus/leaderboard")
    }

    func testFriendRoutesSwapThePrefixAndCarryTheToken() throws {
        // Everything a session does works in friend mode, on /lb/focus/… with X-LB-Token.
        for route in [FocusRoute.goal, .frame, .tick, .block, .event, .now, .suggestions, .settings, .sense] {
            let t = try XCTUnwrap(FocusRoute.target(route, owner: nil, friend: friend), "\(route)")
            XCTAssertEqual(t.url.absoluteString, "https://brain.example/lb/focus/\(route.rawValue)")
            XCTAssertEqual(t.headers, ["X-LB-Token": "LBTOKEN"])
        }
        // The owner's leaderboard route is not a friend's.
        XCTAssertNil(FocusRoute.target(.leaderboard, owner: nil, friend: friend))
        XCTAssertFalse(FocusRoute.leaderboard.friendCanCall)
        // The owner's app never uses the friend routes, and an app with neither has nowhere to send anything.
        XCTAssertEqual(FocusRoute.target(.tick, owner: owner, friend: friend)?.headers, [:])
        XCTAssertNil(FocusRoute.target(.tick, owner: nil, friend: nil))
    }
}
