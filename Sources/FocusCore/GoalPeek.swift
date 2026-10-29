import Foundation

// Hovering the corner timer reminds him what he said he'd do.
//
// The pill stays click-through and non-activating, so nothing here is a mouse-tracking area: the shell
// only reports where the pointer is (over the pill or not) and lets time pass. This type holds all the
// timing so it can be tested without a screen.

/// The little goal box that slides out under the corner timer while the pointer rests on the pill.
///
/// Pointer onto the pill → it waits `showDelay` before showing anything (a pointer crossing the corner on
/// its way somewhere else never flashes the box). Pointer away → it stays up for `hideGrace` and then
/// fades, and coming back inside that grace simply keeps it up.
public struct GoalPeek: Equatable, Sendable {
    /// How long the pointer has to rest on the pill before the box slides out.
    public static let showDelay: TimeInterval = 0.4
    /// How long the box stays up after the pointer leaves.
    public static let hideGrace: TimeInterval = 0.5

    public enum State: Equatable, Sendable {
        /// Nothing on screen.
        case hidden
        /// Pointer is on the pill; the box appears once `showDelay` has passed since this moment.
        case waiting(since: TimeInterval)
        /// Box is out, pointer still on the pill.
        case shown
        /// Pointer has left; the box goes at `hideGrace` after this moment unless he comes back.
        case leaving(since: TimeInterval)
    }

    public private(set) var state: State = .hidden

    /// A millisecond of slack, so a deadline landing exactly on the delay isn't lost to floating-point dust.
    private static let slack: TimeInterval = 0.001

    public init() {}

    /// Is the box on screen right now (out, or in its grace period)?
    public var isShown: Bool {
        switch state {
        case .shown, .leaving: return true
        case .hidden, .waiting: return false
        }
    }

    /// Is the pointer counted as being on the pill?
    public var isInside: Bool {
        switch state {
        case .waiting, .shown: return true
        case .hidden, .leaving: return false
        }
    }

    /// True while something still has to happen on a timer (the shell only needs to tick then).
    public var isSettling: Bool {
        switch state {
        case .waiting, .leaving: return true
        case .hidden, .shown: return false
        }
    }

    /// Where the pointer is now. `inside` = over the pill's frame. Returns whether the box appeared or
    /// disappeared because of it.
    @discardableResult
    public mutating func pointer(inside: Bool, now: TimeInterval) -> Bool {
        let was = isShown
        switch (state, inside) {
        case (.hidden, true):
            state = .waiting(since: stamp(now))
        case (.waiting, true), (.shown, true):
            break                                   // already counting, or already out
        case (.leaving, true):
            state = .shown                          // came back inside the grace: the hide is off
        case (.waiting, false):
            state = .hidden                         // left before the delay was up: nothing was shown
        case (.shown, false):
            state = .leaving(since: stamp(now))
        case (.hidden, false), (.leaving, false):
            break
        }
        return was != isShown
    }

    /// Time passing with the pointer wherever it was. Returns whether the box appeared or disappeared.
    @discardableResult
    public mutating func tick(now: TimeInterval) -> Bool {
        let was = isShown
        switch state {
        case .waiting(let since) where stamp(now) - since >= Self.showDelay - Self.slack:
            state = .shown
        case .leaving(let since) where stamp(now) - since >= Self.hideGrace - Self.slack:
            state = .hidden
        default:
            break
        }
        return was != isShown
    }

    /// The pill itself went away (block ended, session ended, paused out of work): everything drops at once.
    public mutating func reset() { state = .hidden }

    /// Guards against a nonsense clock; a time that runs backwards simply doesn't advance anything.
    private func stamp(_ now: TimeInterval) -> TimeInterval { now.isFinite ? now : 0 }
}
