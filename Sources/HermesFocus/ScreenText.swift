import AppKit
import ApplicationServices
import FocusCore

/// The visible text of the front window, read on this Mac for Jev (2026-09-27): the page text of the
/// Chrome / Safari tab through Apple Events, or the accessibility tree of the front window for every
/// other app. Nothing is written to disk; the text goes only to the brain's sense route.
///
/// Needs the Accessibility permission (System Settings → Privacy & Security → Accessibility) for the
/// non-browser path; without it only the app, title and URL are sent. Password fields are never
/// exposed by the accessibility system, so they never appear here.
enum ScreenText {
    /// Shows the system Accessibility prompt once (never mid-session, where the overlay could hide it).
    static func requestAccessIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    private static let queue = DispatchQueue(label: "hermes.screen-text", qos: .utility)
    private static let browserScripts: [String: String] = [
        ActivityMonitor.chromeBundleID:
            "tell application \"Google Chrome\" to execute active tab of front window javascript "
            + "\"(document.body && document.body.innerText || '').slice(0, \(TextChange.maxChars))\"",
        ActivityMonitor.safariBundleID:
            "tell application \"Safari\" to do JavaScript "
            + "\"(document.body && document.body.innerText || '').slice(0, \(TextChange.maxChars))\" in front document",
    ]

    /// Reads off the main thread and calls back on it. `""` when nothing could be read.
    static func read(completion: @escaping (String) -> Void) {
        guard let app = NSWorkspace.shared.frontmostApplication else { completion(""); return }
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? ""
        queue.async {
            var text = ""
            if let script = browserScripts[bundle] {
                text = runScript(script)
            }
            if text.count < 80, hasPermission {
                let ax = accessibilityText(pid: pid)
                if ax.count > text.count { text = ax }
            }
            let out = TextChange.trimmed(text)
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// osascript with a hard stop: a hung browser never stalls the sense loop for long.
    private static func runScript(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static let textRoles: Set<String> = [
        kAXStaticTextRole as String, kAXTextAreaRole as String, kAXTextFieldRole as String,
        "AXLink", kAXButtonRole as String, "AXHeading", kAXCellRole as String,
        kAXMenuItemRole as String, kAXPopUpButtonRole as String, kAXCheckBoxRole as String,
        kAXRadioButtonRole as String, kAXTabGroupRole as String,
    ]
    private static let maxNodes = 1500
    private static let maxDepth = 24

    /// Walks the front window's accessibility tree, collecting the text people can see, top to bottom.
    private static func accessibilityText(pid: pid_t) -> String {
        let appRef = AXUIElementCreateApplication(pid)
        // Chrome and Electron apps (Claude, Discord, VS Code…) only expose their content when an
        // assistive client asks for it: Chromium reads AXEnhancedUserInterface, Electron AXManualAccessibility.
        AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appRef, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let window = win else { return "" }
        var parts: [String] = []
        var seen = Set<String>()
        var nodes = 0
        var length = 0

        func attr(_ el: AXUIElement, _ name: String) -> String? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }

        func walk(_ el: AXUIElement, depth: Int) {
            guard nodes < maxNodes, depth < maxDepth, length < TextChange.maxChars else { return }
            nodes += 1
            let role = attr(el, kAXRoleAttribute as String) ?? ""
            if textRoles.contains(role) {
                for name in [kAXValueAttribute as String, kAXTitleAttribute as String,
                             kAXDescriptionAttribute as String] {
                    guard let s = attr(el, name)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !s.isEmpty, s.count > 1 else { continue }
                    // A password field's value is never exposed by AX; a secure field's role says so.
                    if role == kAXTextFieldRole as String, attr(el, kAXSubroleAttribute as String) == kAXSecureTextFieldSubrole as String { break }
                    if seen.insert(s).inserted {
                        parts.append(s)
                        length += s.count + 1
                    }
                    break
                }
            }
            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
                  let children = kids as? [AXUIElement] else { return }
            for c in children { walk(c, depth: depth + 1) }
        }
        walk(window as! AXUIElement, depth: 0)
        return parts.joined(separator: "\n")
    }
}
