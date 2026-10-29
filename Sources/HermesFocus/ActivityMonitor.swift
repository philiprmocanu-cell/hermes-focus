import AppKit
import FocusCore

/// Frontmost app, window title, Chrome / Safari tab URL, input idle time and app switches.
final class ActivityMonitor {
    /// Called on the main queue for every activation of another app.
    var onSwitch: (() -> Void)?

    /// Last known tab URL per browser bundle id (refreshed in the background, may lag one sample).
    private var browserURL: [String: String] = [:]
    private var queryRunning = Set<String>()
    private var observer: NSObjectProtocol?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    static let chromeBundleID = "com.google.Chrome"
    static let safariBundleID = "com.apple.Safari"
    /// AppleScript that returns the active tab's URL, per browser.
    private static let urlScripts: [String: String] = [
        chromeBundleID: "tell application \"Google Chrome\" to get URL of active tab of front window",
        safariBundleID: "tell application \"Safari\" to get URL of front document",
    ]

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier == self.ownPID { return }
            self.onSwitch?()
        }
    }

    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    /// Seconds since the last keyboard/mouse event (no special permission needed).
    func secondsSinceLastInput() -> TimeInterval {
        let any = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// Current app/title/url. The Chrome URL is refreshed in the background and may lag a sample.
    func currentContext() -> AppContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return AppContext() }
        let name = app.localizedName ?? app.bundleIdentifier ?? ""
        let title = Self.frontWindowTitle(pid: app.processIdentifier)
        var url = ""
        if let id = app.bundleIdentifier, Self.urlScripts[id] != nil {
            url = browserURL[id] ?? ""
            refreshURL(bundleID: id)
        }
        return AppContext(app: name, title: title, url: url)
    }

    /// Title of the app's frontmost normal window. Needs Screen Recording permission; "" otherwise.
    static func frontWindowTitle(pid: pid_t) -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return "" }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty { return name }
        }
        return ""
    }

    /// Runs osascript off the main thread; one query per browser at a time. First run triggers the
    /// macOS "HermesFocus wants to control Google Chrome / Safari" prompt.
    private func refreshURL(bundleID: String) {
        guard !queryRunning.contains(bundleID), let script = Self.urlScripts[bundleID] else { return }
        queryRunning.insert(bundleID)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var result = ""
            do {
                try p.run()
                // Safety net: never let a stuck query live longer than 90 s (long enough for the
                // one-time permission prompt to be answered).
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                if p.terminationStatus == 0 {
                    result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {}
            DispatchQueue.main.async {
                self?.browserURL[bundleID] = result
                self?.queryRunning.remove(bundleID)
            }
        }
    }
}
