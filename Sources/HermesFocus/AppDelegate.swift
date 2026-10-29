import AppKit
import FocusCore

/// A normal Dock app plus a menu-bar item. Everything that controls a session is reachable from:
/// the Dock icon (click → control window; right-click → menu), the menu bar, the app's own menus
/// (End session ⌘⇧E), the control window, and buttons on every black screen.
///
/// Launch arguments:
///   --test    use test durations (60 s work / 20 s break / 2 s countdown) for every session
///   --start   start a session immediately at launch
///   --login   launched by the LaunchAgent at login: stay quiet (no goal prompt)
/// Defaults (domain app.hermesfocus.mac): testMode, workSeconds, breakSeconds, countdownSeconds,
/// screenshotSeconds, tickSeconds, envPath, brainMode, anthropicModel.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var controller: FocusController!
    private let statusMenu = NSMenu()
    private var terminating = false

    func applicationDidFinishLaunching(_ note: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            log.info("another HermesFocus is running; exiting")
            NSApp.terminate(nil)
            return
        }

        Theme.registerFonts()
        let args = ProcessInfo.processInfo.arguments
        let defaults = UserDefaults.standard
        let durations = Durations.resolve(arguments: args, lookup: { defaults.object(forKey: $0) })
        // No default server: owner mode only when `defaults write … envPath /path/to/.env` points at one.
        let envPath = defaults.string(forKey: "envPath") ?? ""
        controller = FocusController(durations: durations, envPath: envPath)
        // Before any window: if the last run died with the Dock hidden, the
        // restore file is still on disk and his settings go back now.
        controller.recoverChrome()
        controller.onStateChange = { [weak self] in self?.updateIcon() }

        NSApp.mainMenu = buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        updateIcon()

        // Ask for screen recording once, at launch (never mid-session, where the
        // black overlay could hide the system prompt). A joined friend and own keys run the same measurements.
        if controller.isScoring {
            ScreenCapturer.requestAccessIfNeeded()
            ScreenText.requestAccessIfNeeded()
        }

        // First launch without the owner's .env: "Run on my own keys" or "Join a friend's leaderboard"
        // instead of the goal prompt.
        if controller.shouldOfferJoin && !args.contains("--start") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.controller.showJoin() }
        } else if !args.contains("--login") || args.contains("--start") {
            // Opening the app IS the start button. Only the login launch (LaunchAgent passes
            // --login) stays quiet in the Dock and menu bar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startIfIdle()
            }
        }
    }

    /// A hidden Dock left behind would outlive the app entirely.
    func applicationWillTerminate(_ note: Notification) {
        controller?.restoreChrome()
    }

    /// Quit (⌘Q, Dock, menus) ends the session properly and gives its last POSTs a moment to leave.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.phase != .idle, !terminating else { return .terminateNow }
        terminating = true
        controller.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Closing the control window never quits; only Quit does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon clicked (or the app opened again while running).
    /// Idle → start a session (goal prompt). Black screen up → bring it forward. Otherwise → the live
    /// control window. Before own keys or a friend's leaderboard is chosen, the choice screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let controller else { return false }
        if controller.phase == .idle && controller.shouldOfferJoin {
            controller.showJoin()
        } else if controller.phase == .idle {
            startIfIdle()
        } else if controller.overlayIsUp {
            controller.bringOverlayForward()
        } else {
            controller.showControls()
        }
        return false
    }

    /// Right-click on the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        m.autoenablesItems = false
        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        m.addItem(status)
        m.addItem(.separator())
        m.addItem(item("Show Controls", #selector(showControls)))
        if controller.phase == .idle {
            m.addItem(item("Start Focus Session", #selector(startSession)))
            m.addItem(item("Start Focus Session (test durations)", #selector(startTestSession)))
        } else {
            if controller.canPause {
                m.addItem(item(controller.isPaused ? "Resume" : "Pause", #selector(togglePause)))
            }
            m.addItem(item("End Session", #selector(endSession)))
        }
        return m
    }

    private func startIfIdle() {
        guard controller.phase == .idle else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.start(testDurations: false)
    }

    private func updateIcon() {
        let name: String
        switch controller.phase {
        case .idle: name = "bolt"
        case .onBreak: name = "cup.and.saucer"
        default: name = controller.isPaused ? "pause.circle" : "bolt.fill"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Hermes Focus")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    // MARK: - Menus

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Hermes Focus", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Show Controls", #selector(showControls), key: "0"))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Hermes Focus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Hermes Focus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Hermes Focus"))

        // Standard edit actions so ⌘V / ⌘A / ⌘Z work in the goal field.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let session = NSMenu(title: "Session")
        session.addItem(item("Start Focus Session", #selector(startSession), key: "n", mods: [.command, .shift]))
        let startTest = item("Start Focus Session (test durations)", #selector(startTestSession), key: "n", mods: [.command, .shift, .option])
        startTest.isAlternate = true
        session.addItem(startTest)
        session.addItem(item("Pause", #selector(togglePause), key: "p", mods: [.command, .shift]))
        session.addItem(item("End Session", #selector(endSession), key: "e", mods: [.command, .shift]))
        main.addItem(submenu(session, title: "Session"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(item("Show Controls", #selector(showControls)))
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window
        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        i.submenu = menu
        return i
    }

    private func item(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if !key.isEmpty { i.keyEquivalentModifierMask = mods }
        return i
    }

    /// Enables / retitles our items in the main and menu-bar menus (auto-enabling).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller else { return false }
        let running = controller.phase != .idle
        switch menuItem.action {
        case #selector(startSession), #selector(startTestSession):
            return !running
        case #selector(togglePause):
            menuItem.title = controller.isPaused ? "Resume" : "Pause"
            return controller.canPause
        case #selector(endSession):
            return running
        default:
            return true
        }
    }

    // Menu-bar menu, rebuilt every time it opens so titles are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: controller.statusText + (controller.isTestMode && controller.phase != .idle ? "  (test)" : ""),
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item("Show Controls", #selector(showControls)))
        menu.addItem(item("Start Focus Session", #selector(startSession)))
        let startTest = item("Start Focus Session (test durations)", #selector(startTestSession))
        startTest.isAlternate = true
        startTest.keyEquivalentModifierMask = .option
        menu.addItem(startTest)
        menu.addItem(item(controller.isPaused ? "Resume" : "Pause", #selector(togglePause)))
        menu.addItem(item("End Session", #selector(endSession)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Hermes Focus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
    }

    @objc private func showControls() { controller.showControls() }
    @objc private func startSession() { controller.start(testDurations: false) }
    @objc private func startTestSession() { controller.start(testDurations: true) }
    @objc private func togglePause() { controller.togglePause() }
    @objc private func endSession() { controller.stop() }
}
