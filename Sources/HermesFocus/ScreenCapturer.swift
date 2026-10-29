import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import FocusCore

/// Silent screenshot of the main display, downscaled and JPEG-encoded in memory only.
enum ScreenCapturer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system Screen Recording prompt if never answered. Only called at app launch.
    static func requestAccessIfNeeded() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    }

    static var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? ((dict["CGSSessionScreenIsLocked"] as? Int) == 1)
    }

    static var isDisplayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    /// JPEG bytes (up to 1920 px wide, quality 0.72 — sharp enough for the judge to READ
    /// the text he is working on, not just see the app) or nil. Never touches disk. The fallback
    /// schedule's shot for `/admin/focus/frame` (only while Jev is not answering).
    static func captureMainDisplayJPEG() async -> Data? {
        await capture(quality: 0.72) { w, h in ScreenshotSchedule.targetSize(width: w, height: h) }
    }

    /// The smaller shot that rides on a sense post (`ImageGate` decides when): longest side at most 1280 px,
    /// each side at least 280 px, JPEG quality ~0.6. Memory only, never written to disk.
    static func captureSenseJPEG() async -> Data? {
        await capture(quality: SenseImage.quality) { w, h in SenseImage.targetSize(width: w, height: h) }
    }

    /// The main display without this app's own windows (corner timer, toast, black screens).
    private static func capture(quality: Double, size: (Int, Int) -> (width: Int, height: Int)) async -> Data? {
        guard hasPermission else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
            else { return nil }
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let out = size(display.width, display.height)
            let cfg = SCStreamConfiguration()
            cfg.width = out.width
            cfg.height = out.height
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return jpeg(image, quality: quality)
        } catch {
            log.error("screenshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
