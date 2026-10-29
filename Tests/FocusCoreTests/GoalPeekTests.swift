import XCTest
@testable import FocusCore

// MARK: - Hovering the corner timer shows the goal

final class GoalPeekTests: XCTestCase {
    func testNothingIsShownUntilHeRests() {
        var p = GoalPeek()
        XCTAssertFalse(p.isShown)
        XCTAssertEqual(p.state, .hidden)

        // Pointer arrives: still nothing.
        XCTAssertFalse(p.pointer(inside: true, now: 10))
        XCTAssertEqual(p.state, .waiting(since: 10))
        XCTAssertFalse(p.isShown)

        // Just short of the delay.
        XCTAssertFalse(p.tick(now: 10 + GoalPeek.showDelay - 0.01))
        XCTAssertFalse(p.isShown)

        // And there it is.
        XCTAssertTrue(p.tick(now: 10 + GoalPeek.showDelay))
        XCTAssertEqual(p.state, .shown)
        XCTAssertTrue(p.isShown)
    }

    func testCrossingTheCornerNeverFlashesTheBox() {
        var p = GoalPeek()
        p.pointer(inside: true, now: 0)
        XCTAssertFalse(p.tick(now: 0.2))
        // Gone again before the delay was up.
        XCTAssertFalse(p.pointer(inside: false, now: 0.25))
        XCTAssertEqual(p.state, .hidden)
        // Time passing afterwards changes nothing.
        XCTAssertFalse(p.tick(now: 60))
        XCTAssertFalse(p.isShown)
    }

    func testLeavingGivesItAGraceThenHides() {
        var p = shownPeek(at: 0)

        // He moves off: still up.
        XCTAssertFalse(p.pointer(inside: false, now: 5))
        XCTAssertEqual(p.state, .leaving(since: 5))
        XCTAssertTrue(p.isShown)

        XCTAssertFalse(p.tick(now: 5 + GoalPeek.hideGrace - 0.01))
        XCTAssertTrue(p.isShown)

        XCTAssertTrue(p.tick(now: 5 + GoalPeek.hideGrace))
        XCTAssertEqual(p.state, .hidden)
        XCTAssertFalse(p.isShown)
    }

    func testComingBackCancelsTheHide() {
        var p = shownPeek(at: 0)
        p.pointer(inside: false, now: 5)
        XCTAssertEqual(p.state, .leaving(since: 5))

        // Back on the pill well inside the grace.
        XCTAssertFalse(p.pointer(inside: true, now: 5.2))   // it never went away, so nothing "changed"
        XCTAssertEqual(p.state, .shown)
        XCTAssertTrue(p.isShown)

        // The old hide deadline passes and it is still up — no second delay either.
        XCTAssertFalse(p.tick(now: 5 + GoalPeek.hideGrace + 1))
        XCTAssertTrue(p.isShown)
    }

    func testLeavingAndReturningAfterTheGraceStartsOver() {
        var p = shownPeek(at: 0)
        p.pointer(inside: false, now: 1)
        XCTAssertTrue(p.tick(now: 1 + GoalPeek.hideGrace))
        XCTAssertFalse(p.isShown)

        // A fresh hover waits the full delay again.
        p.pointer(inside: true, now: 9)
        XCTAssertFalse(p.isShown)
        XCTAssertFalse(p.tick(now: 9 + GoalPeek.showDelay - 0.01))
        XCTAssertTrue(p.tick(now: 9 + GoalPeek.showDelay))
    }

    func testRepeatedReportsOfTheSamePlaceDoNothing() {
        var p = GoalPeek()
        p.pointer(inside: true, now: 3)
        // Every mouse-moved event inside the pill keeps the ORIGINAL moment, so the delay still lands on time.
        for t in stride(from: 3.05, through: 3.3, by: 0.05) { XCTAssertFalse(p.pointer(inside: true, now: t)) }
        XCTAssertEqual(p.state, .waiting(since: 3))
        XCTAssertTrue(p.tick(now: 3 + GoalPeek.showDelay))

        // Same while it is out: staying inside changes nothing.
        for t in stride(from: 4.0, through: 5.0, by: 0.1) {
            XCTAssertFalse(p.pointer(inside: true, now: t))
            XCTAssertFalse(p.tick(now: t))
        }
        XCTAssertEqual(p.state, .shown)

        // And outside, after it is hidden.
        p.pointer(inside: false, now: 6)
        p.tick(now: 6 + GoalPeek.hideGrace)
        for t in stride(from: 7.0, through: 8.0, by: 0.1) { XCTAssertFalse(p.pointer(inside: false, now: t)) }
        XCTAssertEqual(p.state, .hidden)
    }

    func testTheShellOnlyHasToTickWhileSomethingIsPending() {
        var p = GoalPeek()
        XCTAssertFalse(p.isSettling)            // hidden: nothing to do
        p.pointer(inside: true, now: 0)
        XCTAssertTrue(p.isSettling)             // waiting on the delay
        p.tick(now: GoalPeek.showDelay)
        XCTAssertFalse(p.isSettling)            // out and staying out
        p.pointer(inside: false, now: 2)
        XCTAssertTrue(p.isSettling)             // waiting on the grace
        p.tick(now: 2 + GoalPeek.hideGrace)
        XCTAssertFalse(p.isSettling)
    }

    func testResetDropsItFromAnyState() {
        for build in [{ GoalPeek() },
                      { var p = GoalPeek(); p.pointer(inside: true, now: 0); return p },
                      { shownPeek(at: 0) },
                      { var p = shownPeek(at: 0); p.pointer(inside: false, now: 1); return p }] {
            var p = build()
            p.reset()
            XCTAssertEqual(p.state, .hidden)
            XCTAssertFalse(p.isShown)
            XCTAssertFalse(p.isInside)
        }
    }

    func testInsideTracksThePointerNotTheBox() {
        var p = GoalPeek()
        XCTAssertFalse(p.isInside)
        p.pointer(inside: true, now: 0)
        XCTAssertTrue(p.isInside)               // counting, box not out yet
        p.tick(now: GoalPeek.showDelay)
        XCTAssertTrue(p.isInside)
        p.pointer(inside: false, now: 1)
        XCTAssertFalse(p.isInside)              // pointer gone, box still up for the grace
        XCTAssertTrue(p.isShown)
    }

    func testANonsenseClockNeverShowsOrHidesAnything() {
        var p = GoalPeek()
        p.pointer(inside: true, now: 100)
        // A clock that jumps backwards just doesn't advance the delay.
        XCTAssertFalse(p.tick(now: 50))
        XCTAssertFalse(p.isShown)
        XCTAssertFalse(p.tick(now: .nan))
        XCTAssertFalse(p.isShown)
        XCTAssertTrue(p.tick(now: 100 + GoalPeek.showDelay))
    }

    func testTheDelaysAreTheOnesAskedFor() {
        XCTAssertEqual(GoalPeek.showDelay, 0.4, accuracy: 0.0001)
        XCTAssertEqual(GoalPeek.hideGrace, 0.5, accuracy: 0.0001)
    }
}

/// A peek that is already out, having been hovered at `at`.
private func shownPeek(at t: TimeInterval) -> GoalPeek {
    var p = GoalPeek()
    p.pointer(inside: true, now: t)
    p.tick(now: t + GoalPeek.showDelay)
    return p
}
