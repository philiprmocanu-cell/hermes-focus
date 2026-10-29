import AppKit
import AVFoundation
import SwiftUI
import FocusCore

/// Lightning blue from the app icon (#2E96FF) and the few other colours the app uses.
enum Theme {
    static let blue = Color(red: 0x2E / 255, green: 0x96 / 255, blue: 0xFF / 255)
    static let blueSoft = Color(red: 0x7F / 255, green: 0xC0 / 255, blue: 0xFF / 255)
    static let nsBlue = NSColor(srgbRed: 0x2E / 255, green: 0x96 / 255, blue: 0xFF / 255, alpha: 1)
    static let grey = Color(white: 0.55)
    static let dimGrey = Color(white: 0.38)
    /// "Under" days on the History list.
    static let orange = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x3C / 255)

    /// Proud is blue, Solid grey, Under orange; nothing judged yet is grey too.
    static func verdictColor(_ v: HistoryDay.Verdict?) -> Color {
        switch v {
        case .proud: return blue
        case .under: return orange
        case .solid, .none: return grey
        }
    }

    /// Standard show / hide feel for anything big.
    static let fadeDuration: TimeInterval = 0.8

    // MARK: Type — Space Grotesk everywhere (system font if it couldn't be registered)

    /// Set once at launch by `registerFonts()`.
    private(set) static var spaceGrotesk = false
    private static var cache: [String: NSFont] = [:]

    /// Registers the bundled Space Grotesk for this process (Contents/Resources/Fonts).
    static func registerFonts() {
        let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
        let r = AppFont.register(directory: dir)
        spaceGrotesk = r.choice == .spaceGrotesk
        if !spaceGrotesk { log.info("Space Grotesk not available (\(r.registered) files); using the system font") }
    }

    /// The app's font at `size` / `weight`. `design` only matters for the system fallback.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        guard spaceGrotesk, let ns = nsFont(size, weight) else { return .system(size: size, weight: weight, design: design) }
        return Font(ns)
    }

    static func nsFont(_ size: CGFloat, _ weight: Font.Weight) -> NSFont? {
        let w = AppFont.axisWeight(level(weight))
        let key = "\(size)-\(w)"
        if let f = cache[key] { return f }
        let desc = NSFontDescriptor(fontAttributes: [
            .family: AppFont.family,
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [AppFont.weightAxis: w],
        ])
        guard let f = NSFont(descriptor: desc, size: size), f.familyName == AppFont.family else { return nil }
        cache[key] = f
        return f
    }

    private static func level(_ w: Font.Weight) -> Int {
        switch w {
        case .ultraLight: return 0
        case .thin: return 1
        case .light: return 2
        case .medium: return 4
        case .semibold: return 5
        case .bold: return 6
        case .heavy: return 7
        case .black: return 8
        default: return 3
        }
    }
}

/// Floating panels that never take focus or clicks and follow him onto every Space.
func makeClickThroughPanel(frame: NSRect, level: NSWindow.Level) -> NSPanel {
    let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = level
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.ignoresMouseEvents = true
    p.hidesOnDeactivate = false
    p.becomesKeyOnlyIfNeeded = true
    p.isReleasedWhenClosed = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return p
}

/// Fade a set of windows' alpha with the standard ease.
func fade(_ windows: [NSWindow], to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = duration
        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        windows.forEach { $0.animator().alphaValue = alpha }
    }, completionHandler: completion)
}

/// Crisp synthesized countdown sounds: a short click-beep per number and a brighter "GO".
/// (Race-start style: same pitch for each number, an octave up for GO.)
final class Blips {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private lazy var tickBuffer = tone([880, 1760], weights: [1, 0.25], duration: 0.11, decay: 0.035, click: true)
    private lazy var goBuffer = tone([1760, 2637, 3520], weights: [1, 0.45, 0.2], duration: 0.42, decay: 0.14, click: true)
    private var ready = false
    private var idleStop: DispatchWorkItem?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.32
        ready = true
    }

    func tick() { play(tickBuffer, fallback: "Tink") }
    func go() { play(goBuffer, fallback: "Hero") }

    // Score reveal: a rising tick while the number counts up, a finishing chime, and a brighter
    // arpeggio when he beats his average or passes his daily hours goal.
    private lazy var riseBuffers: [AVAudioPCMBuffer?] = (0..<Self.riseSteps).map { i in
        let f = 620 * pow(2, Double(i) / Double(Self.riseSteps - 1) * 1.25)   // up ~1¼ octaves
        return tone([f, f * 2], weights: [1, 0.2], duration: 0.06, decay: 0.018, click: true)
    }
    private lazy var chimeBuffer = tone([1318.5, 1975.5, 2637], weights: [1, 0.55, 0.3], duration: 0.7, decay: 0.22, click: false)
    private lazy var celebrateBuffer = arpeggio([1046.5, 1318.5, 1568, 2093], step: 0.07, tail: 0.5)
    static let riseSteps = 14

    func rise(_ step: Int) {
        let i = min(Self.riseSteps - 1, max(0, step))
        play(riseBuffers[i], fallback: "Tink")
    }
    func chime() { play(chimeBuffer, fallback: "Glass") }
    func celebrate() { play(celebrateBuffer, fallback: "Hero") }

    /// Notes one after another in one buffer, each ringing out.
    private func arpeggio(_ freqs: [Double], step: Double, tail: Double) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let duration = step * Double(freqs.count) + tail
        let n = AVAudioFrameCount(sr * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n), let data = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = n
        for i in 0..<Int(n) {
            let t = Double(i) / sr
            var v = 0.0
            for (k, f) in freqs.enumerated() {
                let t0 = Double(k) * step
                guard t >= t0 else { continue }
                let u = t - t0
                v += min(1, u / 0.003) * exp(-u / 0.18) * (sin(2 * .pi * f * u) + 0.3 * sin(4 * .pi * f * u))
            }
            data[i] = Float(v * 0.28)
        }
        return buf
    }

    private func play(_ buffer: AVAudioPCMBuffer?, fallback: String) {
        guard ready, let buffer else { NSSound(named: fallback)?.play(); return }
        do {
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            if !player.isPlaying { player.play() }
        } catch {
            NSSound(named: fallback)?.play()
        }
        // Don't keep the audio hardware awake between countdowns.
        idleStop?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.player.stop()
            self.engine.stop()
        }
        idleStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    private func tone(_ freqs: [Double], weights: [Double], duration: Double, decay: Double, click: Bool) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let n = AVAudioFrameCount(sr * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n), let data = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = n
        let total = weights.reduce(0, +)
        for i in 0..<Int(n) {
            let t = Double(i) / sr
            let attack = min(1, t / 0.002)
            let env = attack * exp(-t / decay)
            var v = 0.0
            for (f, w) in zip(freqs, weights) { v += w * sin(2 * .pi * f * t) }
            v /= total
            // A tiny noise transient makes it "click" rather than "beep".
            if click && t < 0.004 { v += Double.random(in: -0.5...0.5) * (1 - t / 0.004) }
            data[i] = Float(v * env * 0.9)
        }
        return buf
    }
}
