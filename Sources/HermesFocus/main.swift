import AppKit

// Normal Dock app (icon in the Dock, plus a menu-bar item). See AppDelegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
