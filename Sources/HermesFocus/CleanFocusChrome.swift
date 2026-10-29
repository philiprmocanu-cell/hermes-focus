import Foundation
import FocusCore

/// The side of clean focus mode that actually touches the machine: reads the
/// three `defaults` keys, writes them, restarts the Dock or Finder, and keeps
/// the restore file. All the deciding is in `FocusCore/CleanFocus.swift`.
///
/// Nothing here throws or blocks the session: a `defaults` binary that will not
/// run leaves the screen as it was and logs why. Hiding the Dock is a comfort,
/// never a precondition for working.
final class CleanFocusChrome {
    /// `~/Library/Application Support/HermesFocus/clean-focus-restore.json`.
    /// Written before the first change of a session and deleted once his
    /// settings are back — so its mere existence at launch means the last run
    /// died with the Dock still hidden.
    private let restoreURL: URL
    private let defaultsBin = "/usr/bin/defaults"
    private let killallBin = "/usr/bin/killall"
    /// Reading `defaults` is a subprocess per key; the values only change when
    /// we change them or he does, so a block's start reads them fresh and the
    /// break reuses nothing.
    private var prefs: CleanFocusPrefs

    init(supportDirectory: URL, prefs: CleanFocusPrefs) {
        self.restoreURL = supportDirectory.appendingPathComponent("clean-focus-restore.json")
        self.prefs = prefs
    }

    func update(prefs: CleanFocusPrefs) { self.prefs = prefs }

    // MARK: - The three moments

    /// A work block started.
    func engage() {
        apply(CleanFocus.engage(prefs: prefs, current: readChrome(), saved: readSaved()),
              why: "work block")
    }

    /// The break, the end of the session, or quitting.
    func restore(why: String) {
        apply(CleanFocus.restore(saved: readSaved(), current: readChrome()), why: why)
    }

    /// Called once at launch, before anything is shown. A restore file here is
    /// the last run's crash: put his Dock and menu bar back before he notices
    /// they are missing.
    func recoverFromCrash() {
        guard let saved = readSaved() else { return }
        log.info("clean focus: a restore file was left behind — putting the Dock and menu bar back")
        apply(CleanFocus.recover(saved: saved, current: readChrome()), why: "crash recovery")
    }

    // MARK: - Doing it

    private func apply(_ plan: ChromePlan, why: String) {
        guard !plan.isEmpty else { return }
        // The save comes FIRST and is the only thing that survives a crash: if
        // the process dies between here and the writes, the worst case is a
        // restore file describing a screen nobody changed, which restores to
        // itself and is then deleted.
        if let save = plan.save, !writeSaved(save) {
            log.error("clean focus: could not write the restore file — leaving the screen alone")
            return
        }
        for write in plan.writes {
            let (domain, key, value) = write.command
            _ = run(defaultsBin, ["write", domain, key, "-bool", value ? "true" : "false"])
        }
        // Half a second of Dock flicker: `killall Dock` is the only way these
        // take effect, and the Dock has to come back up. Expected, documented,
        // and the reason nothing is written when nothing differs.
        if plan.killDock { _ = run(killallBin, ["Dock"]) }
        if plan.killFinder { _ = run(killallBin, ["Finder"]) }
        if plan.clearSaved { try? FileManager.default.removeItem(at: restoreURL) }
        log.info("clean focus (\(why, privacy: .public)): \(plan.writes.count, privacy: .public) setting(s) changed")
    }

    // MARK: - Reading and writing the machine

    private func readChrome() -> SystemChrome {
        SystemChrome(dockAutohide: readBool("com.apple.dock", "autohide") ?? false,
                     menuBarHidden: readBool("NSGlobalDomain", "_HIHideMenuBar") ?? false,
                     // An unset CreateDesktop means Finder DOES draw the desktop.
                     desktopIcons: readBool("com.apple.finder", "CreateDesktop") ?? true)
    }

    /// `defaults read <domain> <key>` — nil when the key is not set at all,
    /// which is the usual state of all three on a machine nobody has touched.
    private func readBool(_ domain: String, _ key: String) -> Bool? {
        guard let out = run(defaultsBin, ["read", domain, key]) else { return nil }
        switch out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    private func readSaved() -> SystemChrome? {
        guard let data = try? Data(contentsOf: restoreURL) else { return nil }
        return try? JSONDecoder().decode(SystemChrome.self, from: data)
    }

    private func writeSaved(_ chrome: SystemChrome) -> Bool {
        guard let data = try? JSONEncoder().encode(chrome) else { return false }
        do {
            try data.write(to: restoreURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            log.error("clean focus: \(path, privacy: .public) would not run")
            return nil
        }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out, encoding: .utf8)
    }
}
