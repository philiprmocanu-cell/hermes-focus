import AppKit
import SwiftUI
import FocusCore

// Everything drawn over his work while a block runs: the corner timer (every display),
// the final-20-second edge pulse (every display) and the nudge toast (main display).
// All of it is click-through, never takes focus, and fades in and out.

private let chromeLevel = NSWindow.Level.statusBar

// MARK: - Corner timer

final class CornerModel: ObservableObject {
    @Published var text = "25:00"
    @Published var paused = false
    @Published var shown = false
    /// In step with the edge pulse during the final seconds.
    @Published var lit = false
}

struct CornerView: View {
    @ObservedObject var model: CornerModel

    var body: some View {
        HStack(spacing: 6) {
            if model.paused {
                Image(systemName: "pause.fill").font(.system(size: 11, weight: .bold))
            }
            Text(model.text)
                .font(Theme.font(18, .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.blue.opacity(model.paused ? 0.6 : 1))
        .shadow(color: Theme.blue.opacity(0.6), radius: 4)
        .padding(.horizontal, 13).padding(.vertical, 7)
        // Fully opaque: nothing behind the pill shows through.
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(white: 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Theme.blue.opacity(model.lit ? 1 : 0.8), lineWidth: model.lit ? 2 : 1.5))
        .shadow(color: Theme.blue.opacity(model.lit ? 0.9 : 0.45), radius: model.lit ? 12 : 7)
        .animation(.easeInOut(duration: 0.3), value: model.lit)
        .opacity(model.shown ? 1 : 0)
        .offset(y: model.shown ? 0 : -14)
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: model.shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 8).padding(.trailing, 12)
    }
}

/// Lightning-blue timer box in the top-right corner of every display.
final class CornerTimer {
    let model = CornerModel()
    private var panels: [NSPanel] = []
    private var hideWork: DispatchWorkItem?
    static let panelSize = NSSize(width: 170, height: 64)

    // Hover-to-see-your-goal (see `GoalPeek`). The pill stays click-through and non-activating, so the
    // pointer is read from events, never from a tracking area.
    private let peekModel = PeekModel()
    private var peek = GoalPeek()
    private var peekPanel: NSPanel?
    private var peekScreen: NSScreen?
    private var peekTimer: Timer?
    private var monitors: [Any] = []
    private var peekHideWork: DispatchWorkItem?

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.model.shown else { return }
            self.rebuild()
            self.dropPeek()
        }
    }

    func show(_ text: String, delay: TimeInterval = 0) {
        hideWork?.cancel()
        model.text = text
        if panels.isEmpty { rebuild() }
        panels.forEach { $0.orderFrontRegardless() }
        startWatchingPointer()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.panels.isEmpty else { return }
            self.model.shown = true
        }
    }

    func update(_ text: String, paused: Bool, lit: Bool) {
        if model.text != text { model.text = text }
        if model.paused != paused { model.paused = paused }
        if model.lit != lit { model.lit = lit }
    }

    /// What the hover box says: his goal as typed, the sharpened one under it, and the progress bar.
    func setGoal(_ goal: String, specific: String, progress: Double?) {
        if peekModel.goal != goal { peekModel.goal = goal }
        if peekModel.specific != specific { peekModel.specific = specific }
        if peekModel.progress != progress { peekModel.progress = progress }
    }

    func hide() {
        stopWatchingPointer()
        dropPeek()
        guard !panels.isEmpty else { return }
        model.shown = false
        model.lit = false
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.panels.forEach { $0.orderOut(nil) }
            self?.panels.removeAll()
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    /// Where the main display's box sits (the nudge toast goes to its left).
    static func boxLeftEdge(on screen: NSScreen) -> CGFloat {
        screen.visibleFrame.maxX - 12 - 110
    }

    /// The pill itself, in screen coordinates — what the pointer has to be over. A little slop around it so
    /// the edge isn't fussy.
    static func pillFrame(on screen: NSScreen, slop: CGFloat = 4) -> NSRect {
        let vf = screen.visibleFrame
        let width: CGFloat = 110, height: CGFloat = 36
        return NSRect(x: boxLeftEdge(on: screen) - slop, y: vf.maxY - 8 - height - slop,
                      width: width + 2 * slop, height: height + 2 * slop)
    }

    private func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let vf = screen.visibleFrame
            let s = Self.panelSize
            let p = makeClickThroughPanel(frame: NSRect(x: vf.maxX - s.width, y: vf.maxY - s.height,
                                                        width: s.width, height: s.height), level: chromeLevel)
            p.contentView = NSHostingView(rootView: CornerView(model: model))
            p.orderFrontRegardless()
            return p
        }
    }

    // MARK: Hover

    /// Mouse position needs no permission — a global monitor for `.mouseMoved` is enough, and a local one
    /// covers the moments Hermes Focus itself is frontmost.
    private func startWatchingPointer() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.pointerMoved()
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            self?.pointerMoved(); return e
        }) { monitors.append(l) }
        pointerMoved()
    }

    private func stopWatchingPointer() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        peekTimer?.invalidate()
        peekTimer = nil
        peek.reset()
    }

    private func pointerMoved() {
        let loc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
        let inside = model.shown && !peekModel.goal.isEmpty
            && screen.map { NSMouseInRect(loc, Self.pillFrame(on: $0), false) } == true
        if inside { peekScreen = screen }
        if peek.pointer(inside: inside, now: Date().timeIntervalSince1970) { applyPeek() }
        armPeekTimer()
    }

    /// Only runs while the delay or the grace is counting down — the pointer can sit still through both.
    private func armPeekTimer() {
        guard peek.isSettling else {
            peekTimer?.invalidate()
            peekTimer = nil
            return
        }
        guard peekTimer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.peek.tick(now: Date().timeIntervalSince1970) { self.applyPeek() }
            if !self.peek.isSettling { self.armPeekTimer() }
        }
        RunLoop.main.add(t, forMode: .common)
        peekTimer = t
    }

    private func applyPeek() {
        if peek.isShown { showPeek() } else { hidePeek() }
    }

    private func showPeek() {
        guard let screen = peekScreen ?? NSScreen.main else { return }
        peekHideWork?.cancel()
        let size = NSSize(width: 320, height: 190)
        let pill = Self.pillFrame(on: screen, slop: 0)
        // Below the pill and tucked to its left, right edges lined up.
        let frame = NSRect(x: pill.maxX - size.width, y: pill.minY - 6 - size.height,
                           width: size.width, height: size.height)
        if peekPanel == nil {
            let p = makeClickThroughPanel(frame: frame, level: chromeLevel)
            p.contentView = NSHostingView(rootView: PeekView(model: peekModel))
            peekPanel = p
        }
        peekPanel?.setFrame(frame, display: false)
        peekPanel?.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.peekModel.shown = true }
    }

    private func hidePeek() {
        guard let panel = peekPanel else { return }
        peekModel.shown = false
        peekHideWork?.cancel()
        let w = DispatchWorkItem { panel.orderOut(nil) }
        peekHideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// Straight off the screen, no fade (the displays changed, or work ended).
    private func dropPeek() {
        peekHideWork?.cancel()
        peekModel.shown = false
        peekPanel?.orderOut(nil)
        peekPanel = nil
        peekScreen = nil
        peek.reset()
    }
}

// MARK: - Hover box: what he said he'd do

final class PeekModel: ObservableObject {
    @Published var goal = ""
    @Published var specific = ""
    @Published var progress: Double?
    @Published var shown = false
}

/// Small dark box that slides out below the corner timer while the pointer rests on it.
struct PeekView: View {
    @ObservedObject var model: PeekModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").font(.system(size: 8.5, weight: .bold))
                Text("YOUR GOAL").font(Theme.font(9.5, .semibold)).tracking(2)
            }
            .foregroundStyle(Theme.blue)
            Text(model.goal)
                .font(Theme.font(14.5, .semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !model.specific.isEmpty {
                Text(model.specific)
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.grey)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressTrack(progress: progress, height: 5)
                        .animation(.spring(response: 0.7, dampingFraction: 0.8), value: progress)
                    Text(GoalProgress.text(progress))
                        .font(Theme.font(10))
                        .foregroundStyle(Theme.dimGrey)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: 300, alignment: .leading)
        // Fully opaque, like the pill: nothing behind it shows through.
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(white: 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Theme.blue.opacity(0.5), lineWidth: 1))
        .shadow(color: Theme.blue.opacity(0.35), radius: 10)
        .opacity(model.shown ? 1 : 0)
        .offset(y: model.shown ? 0 : -10)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: model.shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }
}

// MARK: - Edge pulse

final class EdgeModel: ObservableObject {
    @Published var lit = false
    @Published var shown = false
}

struct EdgeGlowView: View {
    @ObservedObject var model: EdgeModel
    private let r: CGFloat = 12

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(Theme.blue.opacity(0.35), lineWidth: 28).blur(radius: 22)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(Theme.blue.opacity(0.8), lineWidth: 8).blur(radius: 7)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(Theme.blueSoft, lineWidth: 2.5).blur(radius: 0.8)
        }
        .drawingGroup()   // rasterize the blurred strokes once; the pulse only animates opacity
        .ignoresSafeArea()
        // Heartbeat: quick on, slower fade off.
        .opacity(model.shown ? (model.lit ? 1 : 0.1) : 0)
        .animation(model.lit ? .easeOut(duration: 0.14) : .easeInOut(duration: 0.4), value: model.lit)
        .animation(.easeInOut(duration: 0.5), value: model.shown)
        .allowsHitTesting(false)
    }
}

/// Glowing lightning-blue outline around every display for the final seconds of a block.
final class EdgeGlow {
    private let model = EdgeModel()
    private var panels: [NSPanel] = []
    private var hideWork: DispatchWorkItem?

    var isShown: Bool { model.shown }

    func show() {
        hideWork?.cancel()
        if panels.isEmpty {
            panels = NSScreen.screens.map { screen in
                let p = makeClickThroughPanel(frame: screen.frame, level: chromeLevel)
                p.contentView = NSHostingView(rootView: EdgeGlowView(model: model))
                p.setFrame(screen.frame, display: true)
                return p
            }
        }
        panels.forEach { $0.orderFrontRegardless() }
        if !model.shown { DispatchQueue.main.async { [weak self] in self?.model.shown = true } }
    }

    func setLit(_ lit: Bool) {
        if model.lit != lit { model.lit = lit }
    }

    func hide() {
        guard !panels.isEmpty else { return }
        model.shown = false
        model.lit = false
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.panels.forEach { $0.orderOut(nil) }
            self?.panels.removeAll()
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }
}

// MARK: - Nudge toast

final class ToastModel: ObservableObject {
    @Published var text = ""
    @Published var shown = false
    /// The small button under a sense nudge ("I'm on task"); nil = no button, the toast is click-through.
    @Published var buttonTitle: String?
    @Published var buttonBusy = false
    var onButton: () -> Void = {}
}

struct ToastView: View {
    @ObservedObject var model: ToastModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).padding(.top, 2)
                Text(model.text)
                    .font(Theme.font(13.5, .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let title = model.buttonTitle {
                Button(action: { if !model.buttonBusy { model.onButton() } }) {
                    Text(model.buttonBusy ? "Saving…" : title)
                        .font(Theme.font(11.5, .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(model.buttonBusy ? 0.12 : 0.2)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.buttonBusy)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13).padding(.vertical, 9)
        .frame(maxWidth: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.blue.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .shadow(color: Theme.blue.opacity(0.55), radius: 10)
        .opacity(model.shown ? 1 : 0)
        .offset(x: model.shown ? 0 : 16)
        .animation(.easeInOut(duration: 0.6), value: model.shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 8).padding(.trailing, 10)
    }
}

/// The toast's host view: a click on the button works on the first click, without the app coming forward.
private final class ToastHostingView: NSHostingView<ToastView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One small blue toast next to the corner timer on the main display. Silent and click-through, except
/// while it carries a button (a sense nudge's "I'm on task"): then that one click goes to it, and the
/// app still never comes forward (non-activating panel).
final class NudgeToast {
    private let model = ToastModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 380, height: 130)

    /// `button`: title and action of the small button under the text; nil for every other toast.
    func show(_ text: String, button: (title: String, action: () -> Void)? = nil) {
        hideWork?.cancel()
        guard let screen = NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let right = CornerTimer.boxLeftEdge(on: screen)
        let frame = NSRect(x: right - Self.size.width, y: vf.maxY - Self.size.height,
                           width: Self.size.width, height: Self.size.height)
        if panel == nil {
            let p = makeClickThroughPanel(frame: frame, level: chromeLevel)
            p.contentView = ToastHostingView(rootView: ToastView(model: model))
            panel = p
        }
        panel?.setFrame(frame, display: false)
        panel?.ignoresMouseEvents = button == nil
        panel?.orderFrontRegardless()
        model.text = text
        model.buttonTitle = button?.title
        model.buttonBusy = false
        model.onButton = button?.action ?? {}
        DispatchQueue.main.async { [weak self] in self?.model.shown = true }
    }

    /// The button's request is out (it shows "Saving…" and can't be clicked twice).
    func setButtonBusy(_ busy: Bool) { model.buttonBusy = busy }

    /// The button's request failed: say so, keep the button for another try.
    func buttonFailed(text: String) {
        model.buttonBusy = false
        model.text = text
    }

    func hide() {
        guard let panel else { return }
        model.shown = false
        panel.ignoresMouseEvents = true
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            panel.orderOut(nil)
            self?.model.buttonTitle = nil
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }
}
