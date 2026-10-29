import Foundation

/// CLEAN FOCUS MODE — the Dock and the menu bar out of the way while he works.
///
/// The user, 2026-09-21: a black screen between blocks is no good if a red badge
/// on the Dock is still sitting there during the block. So, when the setting is
/// on, a work block hides the Dock and the menu bar system-wide (the same two
/// switches System Settings flips) and gives them back at the break, at the end
/// of the session, and on quit. ⌘-Tab is untouched — this changes nothing about
/// how apps are reached, only what is drawn.
///
/// The rule that matters is that HIS settings come back. Whatever the Dock and
/// the menu bar were set to before the first block is written to a file BEFORE
/// anything is changed, and that file is the only thing restore reads. If the
/// app is killed mid-block, the file outlives it: the next launch finds it,
/// puts the values back, and deletes it. That is the whole crash story — no
/// state kept in memory is trusted to survive a crash, because it does not.
///
/// This file is the pure half: what the system looks like, what it should look
/// like, and therefore exactly which `defaults write` calls to make. It runs no
/// processes and touches no files — `CleanFocusChrome` in the app does that.
///
/// THE DOCK FLICKER: `killall Dock` is the only way to make `com.apple.dock
/// autohide` take effect, and it restarts the Dock process. For about half a
/// second the Dock (and Mission Control's window) blink as it comes back. That
/// is expected, it happens at the start of a block and again at the break, and
/// there is no way to avoid it short of leaving the setting off. Hiding the
/// desktop icons restarts Finder the same way; open Finder *windows* survive,
/// but a Finder window being resized or a drag in progress will be interrupted.

/// What the system chrome was set to — read from `defaults`, written to the
/// restore file, and compared against what a block wants.
public struct SystemChrome: Codable, Equatable, Sendable {
    /// `com.apple.dock autohide`.
    public var dockAutohide: Bool
    /// `NSGlobalDomain _HIHideMenuBar`.
    public var menuBarHidden: Bool
    /// `com.apple.finder CreateDesktop` — true means Finder draws the desktop icons.
    public var desktopIcons: Bool

    public init(dockAutohide: Bool = false, menuBarHidden: Bool = false, desktopIcons: Bool = true) {
        self.dockAutohide = dockAutohide
        self.menuBarHidden = menuBarHidden
        self.desktopIcons = desktopIcons
    }
}

/// The two Settings toggles. Both off by default: nothing about his machine
/// changes until he asks for it.
public struct CleanFocusPrefs: Equatable, Sendable {
    public var hideDockAndMenuBar: Bool
    public var hideDesktopIcons: Bool

    public init(hideDockAndMenuBar: Bool = false, hideDesktopIcons: Bool = false) {
        self.hideDockAndMenuBar = hideDockAndMenuBar
        self.hideDesktopIcons = hideDesktopIcons
    }

    public var anyOn: Bool { hideDockAndMenuBar || hideDesktopIcons }
}

/// One `defaults write`.
public enum ChromeWrite: Equatable, Sendable {
    case dockAutohide(Bool)
    case menuBarHidden(Bool)
    case desktopIcons(Bool)

    /// (domain, key, value) — exactly what `defaults write` is given.
    public var command: (domain: String, key: String, value: Bool) {
        switch self {
        case .dockAutohide(let v): return ("com.apple.dock", "autohide", v)
        case .menuBarHidden(let v): return ("NSGlobalDomain", "_HIHideMenuBar", v)
        case .desktopIcons(let v): return ("com.apple.finder", "CreateDesktop", v)
        }
    }
}

/// Everything to do, in order: save the file, write the defaults, restart what
/// has to be restarted, then (on the way back) delete the file.
public struct ChromePlan: Equatable, Sendable {
    public var writes: [ChromeWrite]
    /// Written to the restore file BEFORE any of `writes` is made.
    public var save: SystemChrome?
    /// The restore file is deleted AFTER the writes land.
    public var clearSaved: Bool

    public init(writes: [ChromeWrite] = [], save: SystemChrome? = nil, clearSaved: Bool = false) {
        self.writes = writes
        self.save = save
        self.clearSaved = clearSaved
    }

    /// `killall Dock` — the Dock owns the menu bar's auto-hide too.
    public var killDock: Bool {
        writes.contains { if case .desktopIcons = $0 { return false } else { return true } }
    }

    /// `killall Finder` — only the desktop icons need it.
    public var killFinder: Bool {
        writes.contains { if case .desktopIcons = $0 { return true } else { return false } }
    }

    public var isEmpty: Bool { writes.isEmpty && save == nil && !clearSaved }
}

public enum CleanFocus {
    /// What a work block wants the screen to look like, given his settings.
    public static func wanted(prefs: CleanFocusPrefs, from current: SystemChrome) -> SystemChrome {
        var out = current
        if prefs.hideDockAndMenuBar {
            out.dockAutohide = true
            out.menuBarHidden = true
        }
        if prefs.hideDesktopIcons {
            out.desktopIcons = false
        }
        return out
    }

    /// A work block is starting.
    ///
    /// `saved` is what the restore file already holds: non-nil means a block
    /// earlier in this session already put his values away, and they must NOT
    /// be overwritten with the hidden ones — the file always holds the values
    /// from before the first block.
    ///
    /// When nothing needs changing (the setting is off, or his Dock already
    /// hides itself) the plan is empty and no file is written, so there is
    /// nothing to restore and nothing to clean up after a crash.
    public static func engage(prefs: CleanFocusPrefs,
                              current: SystemChrome,
                              saved: SystemChrome?) -> ChromePlan {
        let writes = changes(from: current, to: wanted(prefs: prefs, from: current))
        if writes.isEmpty { return ChromePlan() }
        return ChromePlan(writes: writes, save: saved == nil ? current : nil)
    }

    /// The break, the end of the session, quitting — and, with the values read
    /// off disk at launch, coming back from a crash. All four are the same
    /// thing: put back exactly what the file says, then throw the file away.
    ///
    /// Anything he changed himself while the block ran is overwritten, because
    /// the file is the only record of what was his; a setting he flipped during
    /// a block he can flip again.
    public static func restore(saved: SystemChrome?, current: SystemChrome) -> ChromePlan {
        guard let saved else { return ChromePlan() }
        return ChromePlan(writes: changes(from: current, to: saved), clearSaved: true)
    }

    /// The app is starting. A restore file left behind means the last run did
    /// not get to put things back (it crashed, or was force-quit), so this is
    /// the first thing that happens, before any window is shown.
    public static func recover(saved: SystemChrome?, current: SystemChrome) -> ChromePlan {
        restore(saved: saved, current: current)
    }

    /// Only what actually differs — a `defaults write` that changes nothing
    /// still costs a `killall`, and the Dock flicker is the one cost worth
    /// never paying twice.
    static func changes(from: SystemChrome, to: SystemChrome) -> [ChromeWrite] {
        var out: [ChromeWrite] = []
        if from.dockAutohide != to.dockAutohide { out.append(.dockAutohide(to.dockAutohide)) }
        if from.menuBarHidden != to.menuBarHidden { out.append(.menuBarHidden(to.menuBarHidden)) }
        if from.desktopIcons != to.desktopIcons { out.append(.desktopIcons(to.desktopIcons)) }
        return out
    }
}
