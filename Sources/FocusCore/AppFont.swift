import CoreText
import Foundation

/// Space Grotesk (OFL, bundled in Contents/Resources/Fonts), registered for this process at launch.
/// If registration fails the app falls back to the system font.
public enum AppFont {
    public static let family = "Space Grotesk"
    /// The variable font's weight axis runs 300…700.
    public static let minWeight = 300.0
    public static let maxWeight = 700.0
    /// 'wght'
    public static let weightAxis = 0x7767_6874

    public enum Choice: Equatable, Sendable { case spaceGrotesk, system }

    public struct Registration: Equatable, Sendable {
        /// Files registered now (0 when the folder is missing or empty).
        public var registered: Int
        /// The family can be used afterwards (registered now, earlier, or installed).
        public var usable: Bool
        public var choice: Choice { usable ? .spaceGrotesk : .system }
    }

    /// Register every .ttf / .otf in `directory` (process scope).
    public static func register(directory: URL?) -> Registration {
        var count = 0
        if let directory,
           let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    count += 1
                } else if let e = error?.takeRetainedValue(),
                          CFErrorGetCode(e) == CTFontManagerError.alreadyRegistered.rawValue {
                    count += 1
                }
            }
        }
        return Registration(registered: count, usable: count > 0 && isAvailable())
    }

    public static func isAvailable() -> Bool {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names.contains(family)
    }

    /// SwiftUI-ish weights (0 = ultra light … 8 = black) → the font's weight axis.
    public static func axisWeight(_ level: Int) -> Double {
        switch level {
        case ...2: return 300     // ultraLight, thin, light
        case 3: return 400        // regular
        case 4: return 500        // medium
        case 5: return 600        // semibold
        default: return 700       // bold, heavy, black
        }
    }
}
