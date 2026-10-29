import AppKit
import SwiftUI
import FocusCore

// MARK: - Model

final class OverlayModel: ObservableObject {
    enum Mode: Equatable { case goal, countdown, go, rest }
    enum GoalStatus: Equatable { case idle, understanding, question(String), understood(String) }

    /// Everything the break screen's score reveal animates, fixed when the reveal starts.
    struct Reveal: Equatable {
        var score: Int?
        var focus: Int?
        var output: Int?
        /// "+25 min" — minutes actually worked in the block.
        var workedMinutes: Int
        /// Beat the day's average, or passed the daily hours goal.
        var celebrate: Bool
        var celebrateLine: String
        /// Shown instead of the score (no score yet).
        var note: String
        var startedAt: Date
    }

    @Published var mode: Mode = .goal
    /// Drives the content's entrance / exit (scale + blur + fade).
    @Published var visible = false
    @Published var goalText = ""
    @Published var goalStatus: GoalStatus = .idle {
        // Once he has pressed Enter the bottom disclosures fold away again.
        didSet { if goalStatus != .idle, disclosure.anyOpen { _ = disclosure.escape(&suggestions) } }
    }
    @Published var workPhrase = "25 minutes"
    /// Short goal label shown under the countdown.
    @Published var goalLabel = ""
    @Published var countdown = 6
    @Published var breakClock = "5:00"
    @Published var reveal: Reveal?
    /// Top-left "2 h 35 m logged today" on the main display (goal, countdown, break). Same figure as the control window.
    @Published var hours = OverlayHours(seconds: 0, goalHours: nil)
    /// Set when the reveal's "+25 min" chip lands on the hours label: the chip shows for a moment, the digits
    /// count up to the new total, then it is cleared — nothing is left beside the label.
    @Published var hoursAdd: HoursAddition?
    /// Block length for the next block (goal screen). `lengthScale` = base block / 25 min (test mode 0.04).
    @Published var length = BlockLengthChoice()
    @Published var lengthScale = 1.0
    /// Suggested blocks (owner only; empty = no "Suggestions" disclosure) and the text the screen opened with.
    @Published var suggestions = SuggestionPicker()
    /// The two small grey disclosures at the bottom of the goal screen; both closed every time it appears.
    @Published var disclosure = GoalScreenDisclosure()
    /// The reveal card in the top-right corner has faded away (30 s after the break started).
    @Published var revealFaded = false
    /// Owner: the Friends panel may offer more than the board; friends only see the board.
    @Published var isOwner = true
    /// A friend's TypeSafe key (friend mode only): the Settings row and the "Add your key" line.
    @Published var key = TypeSafeKeyUI()
    /// The key's secure field is open in Settings.
    @Published var keyEditing = false
    var onSaveKey: (String) -> Void = { _ in }
    var onRemoveKey: () -> Void = {}
    /// Owner, friend or own keys (nil = not chosen yet). Own keys hides Friends, sharing and the voice links,
    /// and Settings shows both keys, where the data lives and the Health line.
    @Published var brainMode: BrainMode? = .owner
    /// Own keys: "~/Library/Application Support/HermesFocus/local" and the Health line.
    @Published var localDataPath = ""
    @Published var localHealth = ""
    /// Own keys: the Anthropic key's secure field is open in Settings.
    @Published var anthropicEditing = false
    var onSaveAnthropicKey: (String) -> Void = { _ in }
    var onRemoveAnthropicKey: () -> Void = {}
    var onShowLocalData: () -> Void = {}
    /// Settings opened in own-keys mode: refresh the Health line.
    var onLocalSettingsAppear: () -> Void = {}
    // Friends panel (goal screen).
    @Published var board: [LeaderboardRow] = []
    @Published var boardStatus = ""
    // History panel (goal screen): the last 30 days, newest first.
    @Published var history: [HistoryDay] = []
    @Published var historyStatus = ""
    @Published var historyLoading = false
    /// Clean focus mode: hide the Dock and menu bar (and, optionally, the desktop
    /// icons) while a block runs. Both off until he turns them on.
    @Published var cleanFocus = CleanFocusPrefs()
    // The daily hours goal, edited by clicking the top-left hours label.
    @Published var hoursEditing = false
    @Published var hoursEditor = HoursGoalEditor(hours: HoursMath.defaultGoalHours)
    var prefill = ""
    /// "BREAK" or "LONG BREAK", and the 4 dots toward the long break.
    @Published var breakTitle = "BREAK"
    @Published var longBreakProgress: Double = 0
    @Published var longBreakLine = ""
    /// Bumped each time the field should re-focus and select its text.
    @Published var focusToken = 0
    /// Owner mode only: warn when screen reading is off. Friends never send screenshots.
    @Published var screenWarning = true

    var onSubmit: (String) -> Void = { _ in }
    /// The rubric summary under "Got it — …" and its "Fix…" field (see `RubricFix`); closed and empty by default.
    @Published var rubricFix = RubricFix()
    @Published var rubricNote = ""
    /// "Fix…" clicked / Return in its field / Esc while it is open.
    var onRubricFix: () -> Void = {}
    var onRubricNote: (String) -> Void = { _ in }
    var onRubricEscape: () -> Void = {}

    /// A suggestion was clicked (or picked with ↓ + Enter): fill the field and the length (he can still edit
    /// both) and close the list.
    func pick(_ s: BlockSuggestion) {
        goalText = disclosure.pick(s, picker: &suggestions, length: &length)
        focusToken += 1
    }
    var onSkipBreak: () -> Void = {}
    var onEndSession: () -> Void = {}
    /// The Friends panel was opened: refresh the board.
    var onFriendsOpened: () -> Void = {}
    /// The History panel was opened: fetch the last 30 days.
    var onHistoryOpened: () -> Void = {}
    /// The daily hours goal was changed in the top-left editor.
    var onSetGoalHours: (Double) -> Void = { _ in }
    /// A clean focus toggle was flipped in Settings.
    var onSetCleanFocus: (CleanFocusPrefs) -> Void = { _ in }
}

// MARK: - Root

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    let isPrimary: Bool
    /// The notch (0 on displays without one); the overlay sits above the menu bar, so only the notch matters.
    var notchInset: CGFloat = 0

    /// Top-left corner of the hours label, in the overlay's own coordinates (the reveal's chip flies here).
    private var hoursOrigin: CGPoint { CGPoint(x: HoursCorner.edge, y: max(HoursCorner.edge, notchInset + 14)) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isPrimary {
                ZStack {
                    switch model.mode {
                    case .goal: GoalView(model: model).transition(.opacity.combined(with: .scale(scale: 0.97)))
                    case .countdown, .go: CountdownView(model: model).transition(.opacity)
                    case .rest: BreakView(model: model).transition(.opacity.combined(with: .scale(scale: 1.03)))
                    }
                }
                .animation(.easeInOut(duration: 0.55), value: model.mode)
                .scaleEffect(model.visible ? 1 : 1.05)
                .blur(radius: model.visible ? 0 : 16)
                .opacity(model.visible ? 1 : 0)
                .animation(.easeInOut(duration: Theme.fadeDuration), value: model.visible)

                // Hours logged today — main display only, stays put across goal / countdown / break.
                HoursCorner(model: model)
                    .padding(.leading, hoursOrigin.x)
                    .padding(.top, hoursOrigin.y)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea()
                    .opacity(model.visible ? 1 : 0)
                    .animation(.easeInOut(duration: Theme.fadeDuration), value: model.visible)
                    // Clickable (it opens the daily hours goal editor) except mid-countdown.
                    .allowsHitTesting(model.mode != .countdown && model.mode != .go)
            }
        }
        .coordinateSpace(name: HoursCorner.space)
        .environment(\.hoursTarget, CGPoint(x: hoursOrigin.x + 44, y: hoursOrigin.y + 16))
        .preferredColorScheme(.dark)
    }
}

/// Where the reveal's "+25 min" chip flies to (the number in the top-left hours label), in `HoursCorner.space`.
private struct HoursTargetKey: EnvironmentKey { static let defaultValue: CGPoint? = nil }
extension EnvironmentValues {
    var hoursTarget: CGPoint? {
        get { self[HoursTargetKey.self] }
        set { self[HoursTargetKey.self] = newValue }
    }
}

/// Top-left of the main display on every black screen: "2 h 35 m", "logged today · of 4 h" and a slim blue line
/// toward the daily goal. The one hours display on the black screens: the reveal's "+25 min" lands here, sits
/// beside the number for a moment, and is then counted into it (`HoursAddition`) and gone.
struct HoursCorner: View {
    static let edge: CGFloat = 32
    static let space = "overlayRoot"
    @ObservedObject var model: OverlayModel
    @State private var pulse = false
    @State private var hover = false

    var body: some View {
        // While a block is being added the label redraws every frame (digits climbing, chip shrinking in);
        // the rest of the time it is a plain static label.
        if let add = model.hoursAdd {
            TimelineView(.animation) { ctx in label(add: add, now: ctx.date) }
        } else {
            label(add: nil, now: Date())
        }
    }

    /// What the label shows right now: mid-addition the climbing figure, otherwise today's total.
    private func shown(_ add: HoursAddition?, _ now: Date) -> (text: String, progress: Double?) {
        let h = model.hours
        guard let add else { return (h.text, h.progress) }
        return (add.text(at: now), add.progress(at: now, goalHours: h.goalHours) ?? h.progress)
    }

    @ViewBuilder
    private func label(add: HoursAddition?, now: Date) -> some View {
        let h = model.hours
        let live = shown(add, now)
        let counting = add.map { $0.stage(at: now) == .countUp } ?? false
        VStack(alignment: .leading, spacing: 5) {
            Button {
                model.hoursEditor = HoursGoalEditor(hours: h.goalHours ?? HoursMath.defaultGoalHours)
                model.hoursEditing.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(live.text)
                            .font(Theme.font(22, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(pulse ? 0.95 : 0.7))
                            .shadow(color: Theme.blue.opacity(pulse ? 0.9 : 0), radius: 10)
                            .contentTransition(.numericText())
                            // Each minute ticks past quickly while counting up; a normal change still eases.
                            .animation(.easeOut(duration: counting ? 0.12 : 0.5), value: live.text)
                            .scaleEffect(pulse ? 1.08 : 1, anchor: .leading)
                        if let add, add.chipOpacity(at: now) > 0.001 {
                            Text("+\(add.addedMinutes) min")
                                .font(Theme.font(12, .semibold))
                                .foregroundStyle(Theme.blue)
                                .opacity(add.chipOpacity(at: now))
                                .scaleEffect(add.chipScale(at: now), anchor: .leading)
                        }
                    }
                    HStack(spacing: 5) {
                        Text(h.caption)
                        if let g = h.goalText { Text("·"); Text(g) }
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 8, weight: .semibold))
                            .opacity(hover || model.hoursEditing ? 1 : 0)
                    }
                    .font(Theme.font(11, .medium))
                    .foregroundStyle(Color.white.opacity(hover || model.hoursEditing ? 0.65 : 0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("Set your daily hours goal")
            if let p = live.progress {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(Theme.blue)
                            .frame(width: max(p > 0 ? 2 : 0, g.size.width * p))
                            .shadow(color: Theme.blue.opacity(0.6), radius: 3)
                    }
                }
                .frame(width: 120, height: 2)
                // The line grows with the digits, so it follows them frame by frame while counting.
                .animation(counting ? nil : .easeOut(duration: 0.6), value: p)
            }
            if model.hoursEditing {
                HoursGoalEditorView(model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .fixedSize()
        .animation(.easeOut(duration: 0.2), value: model.hoursEditing)
        .onChange(of: model.hoursAdd) { _, v in
            guard v != nil else { pulse = false; return }
            withAnimation(.easeOut(duration: 0.18)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeInOut(duration: 0.6)) { pulse = false }
            }
        }
    }
}

/// The tiny editor behind the hours label: how many hours he is aiming for today (0.5–16), stepped or typed.
/// It changes the GOAL, never the hours already logged.
struct HoursGoalEditorView: View {
    @ObservedObject var model: OverlayModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DAILY HOURS GOAL")
                .font(Theme.font(9, .semibold)).tracking(1.6)
                .foregroundStyle(Theme.blue.opacity(0.9))
            HStack(spacing: 6) {
                step("minus", enabled: model.hoursEditor.canDecrease) { bump(-1) }
                TextField("", text: Binding(get: { model.hoursEditor.text },
                                            set: { v in
                                                var e = model.hoursEditor
                                                if e.type(v) { model.onSetGoalHours(e.hours) }
                                                model.hoursEditor = e
                                            }))
                    .textFieldStyle(.plain)
                    .font(Theme.font(15, .semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .frame(width: 44)
                    .focused($focused)
                    .onSubmit { commit() }
                Text("h").font(Theme.font(12)).foregroundStyle(Color(white: 0.5))
                step("plus", enabled: model.hoursEditor.canIncrease) { bump(1) }
                Button("Done") { commit() }
                    .buttonStyle(.plain)
                    .font(Theme.font(11, .medium))
                    .foregroundStyle(Color(white: 0.55))
                    .padding(.leading, 4)
            }
            Text("Hours of focused work you're aiming for today.")
                .font(Theme.font(10)).foregroundStyle(Color(white: 0.38))
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .frame(width: 240, alignment: .leading)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
    }

    private func bump(_ d: Int) {
        var e = model.hoursEditor
        e.bump(d)
        model.hoursEditor = e
        model.onSetGoalHours(e.hours)
    }

    private func commit() {
        var e = model.hoursEditor
        let h = e.commit()
        model.hoursEditor = e
        model.onSetGoalHours(h)
        model.hoursEditing = false
    }

    private func step(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(white: enabled ? 0.8 : 0.3))
                .frame(width: 20, height: 18)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// "End session  ⌘⇧E" — on every black screen.
struct EndSessionButton: View {
    let action: () -> Void
    var escapes = false
    @State private var hover = false

    var body: some View {
        let b = Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill").font(.system(size: 10))
                Text("End session")
                Text(escapes ? "Esc" : "⌘⇧E").foregroundStyle(Color(white: 0.4))
            }
            .font(Theme.font(13, .medium))
            .foregroundStyle(Color(white: hover ? 0.9 : 0.62))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.08 : 0.03)))
            .overlay(Capsule().stroke(Color(white: hover ? 0.5 : 0.28), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .padding(.bottom, 30)
        if escapes { b.keyboardShortcut(.cancelAction) } else { b }
    }
}

// MARK: - Goal prompt

/// The original minimal goal screen: the question and the field ("the bar") in the middle of the black, nothing
/// else. Suggestions and block length live in two small grey disclosures at the very bottom, closed every time.
struct GoalView: View {
    @ObservedObject var model: OverlayModel
    @FocusState private var focused: Bool

    private var busy: Bool {
        switch model.goalStatus {
        case .understanding, .understood: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 34) {
                Spacer()
                Text("What are you working on for the next \(FocusText.lengthPhrase(model.length.seconds(scale: model.lengthScale)))?")
                    .font(Theme.font(34, .light))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: model.length)
                if model.screenWarning && !ScreenCapturer.hasPermission {
                    // Without it every screenshot is skipped and the score is a guess —
                    // say so where he will see it, not in a log.
                    Text("Screen reading is off, so your score can't see your work. Turn on Hermes Focus in System Settings → Privacy & Security → Screen & System Audio Recording.")
                        .font(Theme.font(15, .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.35))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 640)
                }
                if !model.isOwner && model.key.missing {
                    // No key = no judging; everything else keeps working. One calm line, one link.
                    HStack(spacing: 10) {
                        Text(TypeSafeText.reminder)
                            .font(Theme.font(14))
                            .foregroundStyle(Color(white: 0.5))
                        PlainLink(title: TypeSafeText.reminderLink, brightness: 0.62) {
                            if !model.disclosure.settingsOpen { model.disclosure.toggleSettings(&model.suggestions) }
                            model.keyEditing = true
                        }
                    }
                    .transition(.opacity)
                }
                VStack(spacing: 10) {
                    TextField("", text: $model.goalText,
                              prompt: Text(placeholder).foregroundStyle(Color(white: 0.3)))
                        .textFieldStyle(.plain)
                        .font(Theme.font(28, .regular))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        // Room at both ends so centred text never runs under anything at the end of the field.
                        .padding(.horizontal, 44)
                        .frame(maxWidth: 760)
                        .focused($focused)
                        .disabled(busy)
                        .opacity(busy ? 0.55 : 1)
                        .onSubmit { model.onSubmit(model.goalText) }
                    Rectangle()
                        .fill(busy ? Theme.blue : Color(white: 0.3))
                        .frame(maxWidth: 760, maxHeight: busy ? 2 : 1)
                        .shadow(color: busy ? Theme.blue.opacity(0.8) : .clear, radius: 6)
                }
                .animation(.easeInOut(duration: 0.35), value: busy)
                GoalStatusLine(status: model.goalStatus)
                    .frame(minHeight: 60, alignment: .top)
                    // The rubric hangs below the status line as an overlay, so nothing else on the screen moves.
                    .overlay(alignment: .bottom) {
                        if case .understood = model.goalStatus, !model.rubricFix.lines.isEmpty {
                            RubricSummary(model: model)
                                .alignmentGuide(.bottom) { $0[.top] }
                                .transition(.opacity)
                        }
                    }
                Spacer()
            }
            .padding(.horizontal, 40)
            VStack {
                Spacer()
                GoalFooter(model: model, refocus: { focusSoon() })
            }
        }
        .onAppear { focusSoon() }
        .onChange(of: model.focusToken) { _, _ in focusSoon() }
    }

    private var placeholder: String {
        if case .question = model.goalStatus { return "Your answer" }
        return "e.g. maths sheet 4"
    }

    private func focusSoon(selectAll: Bool = true) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focused = true
            // Select the pre-filled goal so typing replaces it and Enter alone keeps it.
            if selectAll { NSApp.keyWindow?.firstResponder.flatMap { $0 as? NSTextView }?.selectAll(nil) }
        }
    }
}

/// Under the bar: nothing while typing; "Understanding your goal…", a clarifying question as one small blue line,
/// or "Got it — <sharpened goal>" for a moment.
struct GoalStatusLine: View {
    let status: OverlayModel.GoalStatus

    var body: some View {
        ZStack {
            switch status {
            case .idle:
                EmptyView()
            case .understanding:
                UnderstandingLine().transition(.opacity)
            case .question(let q):
                Text(q)
                    .font(Theme.font(16, .medium))
                    .foregroundStyle(Theme.blue)
                    .shadow(color: Theme.blue.opacity(0.4), radius: 8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 720)
                    .transition(.opacity)
            case .understood(let u):
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "bolt.fill")
                    Text("Got it — \(u)")
                        .multilineTextAlignment(.center)
                }
                .font(Theme.font(20, .medium))
                .foregroundStyle(Theme.blue)
                .shadow(color: Theme.blue.opacity(0.6), radius: 12)
                .frame(maxWidth: 760)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: status)
    }
}

/// Under "Got it — …": how the block will be judged, small and grey (balance line first, then the numbered
/// milestones, then what it watches for), with a "Fix…" link beside the balance line. "Fix…" opens one line:
/// Return sends it ("Rewriting…", then the new summary), Esc or an empty Return closes it.
struct RubricSummary: View {
    @ObservedObject var model: OverlayModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let fix = model.rubricFix
        VStack(spacing: 5) {
            ForEach(Array(fix.lines.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line)
                        .font(Theme.font(13))
                        .foregroundStyle(Color(white: 0.42))
                        .lineLimit(1)
                    if i == 0 && fix.canFix {
                        PlainLink(title: RubricFix.linkTitle, brightness: 0.5) { model.onRubricFix() }
                    }
                }
            }
            if fix.isEditing {
                VStack(spacing: 4) {
                    TextField("", text: $model.rubricNote,
                              prompt: Text(RubricFix.placeholder).foregroundStyle(Color(white: 0.3)))
                        .textFieldStyle(.plain)
                        .font(Theme.font(14))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .focused($fieldFocused)
                        .onSubmit { model.onRubricNote(model.rubricNote) }
                    Rectangle().fill(Color(white: 0.25)).frame(height: 1)
                }
                .frame(maxWidth: 520)
                .padding(.top, 4)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { fieldFocused = true } }
                .transition(.opacity)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 720)
        .padding(.top, 4)
        .animation(.easeOut(duration: 0.2), value: fix)
    }
}

/// Very bottom of the goal screen, barely visible: Suggestions · Settings · Friends · History · … ·
/// End session.
/// An open panel shows its small grey card just above the row; the middle of the screen never moves.
struct GoalFooter: View {
    @ObservedObject var model: OverlayModel
    let refocus: () -> Void

    var body: some View {
        let d = model.disclosure
        VStack(spacing: 14) {
            ZStack {
                if d.suggestionsOpen {
                    SuggestionList(model: model)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if d.settingsOpen {
                    LengthSettings(model: model, onDone: refocus)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if d.friendsOpen {
                    FriendsPanel(model: model)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if d.historyOpen {
                    HistoryPanel(model: model)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            HStack(spacing: 22) {
                ForEach(BrainMode.goalScreenLinks(model.brainMode, hasSuggestions: !model.suggestions.isEmpty),
                        id: \.self) { link in
                    switch link {
                    case .endSession:
                        SubtleEndSession(action: model.onEndSession)
                    default:
                        DisclosureLabel(title: link.title, open: model.disclosure.open == link) {
                            model.disclosure.toggle(link, &model.suggestions)
                            if model.disclosure.open == .friends { model.onFriendsOpened() }
                            if model.disclosure.open == .history { model.onHistoryOpened() }
                            if model.disclosure.open == nil { refocus() }
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        .padding(.bottom, 26)
        .animation(.easeOut(duration: 0.22), value: model.disclosure)
        .animation(.easeOut(duration: 0.4), value: model.suggestions.isEmpty)
    }
}

/// The History panel: one quiet row per day, newest first — date, hours, blocks, score, verdict and the
/// day's Google Doc when the server sent a link.
struct HistoryPanel: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.history.isEmpty {
                Text(model.historyStatus.isEmpty ? "Loading your days…" : model.historyStatus)
                    .font(Theme.font(12)).foregroundStyle(Color(white: 0.4))
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(model.history) { d in HistoryLine(day: d) }
                    }
                }
                .frame(maxHeight: 190)
                if !model.historyStatus.isEmpty {
                    Text(model.historyStatus)
                        .font(Theme.font(10.5)).foregroundStyle(Color(white: 0.3))
                }
            }
        }
        .frame(width: 520, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.16), lineWidth: 1))
    }
}

/// One day on the goal screen's History panel.
struct HistoryLine: View {
    let day: HistoryDay

    var body: some View {
        HStack(spacing: 10) {
            Text(day.dateText)
                .font(Theme.font(12, .medium))
                .foregroundStyle(Color(white: 0.62))
                .frame(width: 84, alignment: .leading)
                .lineLimit(1)
            Text(day.hoursText)
                .font(Theme.font(12, .medium)).monospacedDigit()
                .foregroundStyle(Color(white: 0.75))
                .frame(width: 72, alignment: .trailing)
            Text(day.blocksText)
                .font(Theme.font(11)).monospacedDigit()
                .foregroundStyle(Color(white: 0.35))
                .frame(width: 62, alignment: .trailing)
            Text(day.scoreText)
                .font(Theme.font(12, .medium)).monospacedDigit()
                .foregroundStyle(Color(white: 0.55))
                .frame(width: 42, alignment: .trailing)
            Text(day.verdictText)
                .font(Theme.font(11, .semibold))
                .foregroundStyle(Theme.verdictColor(day.verdict))
                .frame(width: 46, alignment: .leading)
            Spacer(minLength: 0)
            if let url = day.docURL, let u = URL(string: url) {
                Link("Open doc", destination: u)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.blue.opacity(0.8))
            }
        }
    }
}

/// A bottom link with no chevron.
struct PlainLink: View {
    let title: String
    /// Resting grey (hover always brightens to 0.6, or a little above a brighter rest).
    var brightness: Double = 0.3
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(12, .medium))
                .foregroundStyle(Color(white: hover ? max(0.6, brightness + 0.2) : brightness))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// The Friends panel: the board (and, for the owner, an invite code and a link to the app itself).
struct FriendsPanel: View {
    @ObservedObject var model: OverlayModel
    @State private var copiedCode = false
    @State private var copiedLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.board.isEmpty {
                Text(model.boardStatus.isEmpty ? "Loading the board…" : model.boardStatus)
                    .font(Theme.font(12)).foregroundStyle(Color(white: 0.4))
            } else {
                VStack(spacing: 3) {
                    ForEach(model.board) { r in
                        HStack(spacing: 10) {
                            Text("\(r.rank)")
                                .font(Theme.font(11, .semibold)).monospacedDigit()
                                .foregroundStyle(r.rank <= 3 ? Theme.blue : Color(white: 0.4))
                                .frame(width: 18, alignment: .leading)
                            Text(r.name)
                                .font(Theme.font(12.5, r.me ? .semibold : .regular))
                                .foregroundStyle(Color(white: r.me ? 0.9 : 0.6))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(HoursMath.duration(r.todayS))
                                .font(Theme.font(12, .medium)).monospacedDigit()
                                .foregroundStyle(Color(white: 0.6))
                            Text(HoursMath.duration(r.weekS))
                                .font(Theme.font(11)).monospacedDigit()
                                .foregroundStyle(Color(white: 0.4))
                                .frame(width: 58, alignment: .trailing)
                            // OUTPUT: today's average output score ("—" when none).
                            Text(r.outputText)
                                .font(Theme.font(11)).monospacedDigit()
                                .foregroundStyle(Color(white: 0.4))
                                .frame(width: 34, alignment: .trailing)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(r.me ? Theme.blue.opacity(0.14) : Color.white.opacity(0.03)))
                    }
                }
            }

        }
        .frame(width: 560, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.035)))
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func smallButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(12, .medium))
                .foregroundStyle(Color(white: enabled ? 0.7 : 0.35))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().stroke(Color(white: 0.22), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func copyButton(copied: Bool, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(Theme.font(11, .medium))
                .foregroundStyle(Color(white: 0.65))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Suggestions ▾" — small low-contrast grey text that lightens on hover.
struct DisclosureLabel: View {
    let title: String
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(Theme.font(12, .medium))
            .foregroundStyle(Color(white: open || hover ? 0.6 : 0.3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// "End session  Esc" in the same quiet grey as the disclosures (Esc still ends it when nothing is open).
struct SubtleEndSession: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("End session")
                Text("Esc").foregroundStyle(Color(white: hover ? 0.4 : 0.22))
            }
            .font(Theme.font(12, .medium))
            .foregroundStyle(Color(white: hover ? 0.6 : 0.3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// The 3–5 suggested blocks as small grey rows: goal · why · minutes. Click (or ↓ / ↑ then Enter) fills the field
/// and the length, then the list closes.
struct SuggestionList: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.suggestions.items.enumerated()), id: \.element.id) { i, s in
                SuggestionRow(s: s, highlighted: model.suggestions.highlighted == i) { model.pick(s) }
            }
        }
        .frame(width: 560)
    }
}

struct SuggestionRow: View {
    let s: BlockSuggestion
    let highlighted: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let lit = highlighted || hover
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(s.goal)
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(Color(white: lit ? 0.85 : 0.55))
                    .lineLimit(1)
                    .layoutPriority(1)
                if !s.why.isEmpty {
                    Text(s.why)
                        .font(Theme.font(12))
                        .foregroundStyle(Color(white: lit ? 0.5 : 0.32))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(s.minutes) min")
                    .font(Theme.font(12))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: lit ? 0.6 : 0.35))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(lit ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: lit)
    }
}

/// Block length, small and grey: 15 / 25 / 45 / 60, a custom 5–60 field and the brain's suggestion chip.
/// Every goal screen starts at 25; the suggestion only applies when clicked.
struct LengthSettings: View {
    @ObservedObject var model: OverlayModel
    var onDone: () -> Void
    @State private var custom = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("Block").font(Theme.font(12)).foregroundStyle(Color(white: 0.3)).padding(.trailing, 4)
                ForEach(BlockLengthChoice.presets, id: \.self) { m in
                    LengthPill(title: "\(m) min", selected: !model.length.isCustom && model.length.minutes == m) {
                        model.length.select(m)
                        custom = ""
                        onDone()
                    }
                }
                HStack(spacing: 3) {
                    TextField("", text: $custom, prompt: Text("custom").foregroundStyle(Color(white: 0.28)))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .frame(width: 46)
                        .onChange(of: custom) { _, v in
                            let digits = v.filter(\.isNumber)
                            if digits != v { custom = digits; return }
                            model.length.setCustom(digits)
                        }
                        .onSubmit {
                            if model.length.isCustom { custom = "\(model.length.minutes)" }
                            onDone()
                        }
                    Text("min").foregroundStyle(Color(white: 0.3))
                }
                .font(Theme.font(12, .medium))
                .foregroundStyle(Color(white: model.length.isCustom ? 0.85 : 0.55))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(model.length.isCustom ? 0.09 : 0.02)))
                .overlay(Capsule().stroke(Color(white: 0.18), lineWidth: 1))
                .help("Any length from 5 to 60 minutes")
            }
            if let chip = model.length.chipText {
                Button {
                    model.length.applySuggestion()
                    custom = model.length.isCustom ? "\(model.length.minutes)" : ""
                    onDone()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
                        Text(chip).font(Theme.font(11.5)).lineLimit(1)
                    }
                    .foregroundStyle(Color(white: 0.42))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 560)
                .help("Use the suggested length for this block")
            }
            CleanFocusSettings(model: model)
            if model.brainMode == .local {
                LocalSettings(model: model)
            } else if !model.isOwner {
                TypeSafeKeySettings(model: model)
            }
        }
    }
}

/// Friend mode only, under the clean focus switches: "TypeSafe key: set / not set" · Change · Remove.
/// Change opens the same secure field as the step after Join; Remove clears it on the brain and here.
struct TypeSafeKeySettings: View {
    @ObservedObject var model: OverlayModel
    @State private var key = ""
    @FocusState private var focused: Bool

    private var k: TypeSafeKeyUI { model.key }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 14) {
                Text(TypeSafeText.row(set: k.set))
                    .font(Theme.font(11.5))
                    .foregroundStyle(Color(white: k.set ? 0.55 : 0.42))
                PlainLink(title: TypeSafeText.change) {
                    model.keyEditing.toggle()
                    key = ""
                }
                if k.set {
                    PlainLink(title: TypeSafeText.remove) {
                        model.keyEditing = false
                        key = ""
                        model.onRemoveKey()
                    }
                    .disabled(k.busy)
                }
            }
            if model.keyEditing {
                HStack(spacing: 8) {
                    SecureField("", text: $key, prompt: Text("Paste your TypeSafe key").foregroundStyle(Color(white: 0.28)))
                        .textFieldStyle(.plain)
                        .font(Theme.font(12.5))
                        .foregroundStyle(Color(white: 0.85))
                        .frame(width: 260)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.04)))
                        .overlay(Capsule().stroke(Color(white: 0.18), lineWidth: 1))
                        .focused($focused)
                        .disabled(k.busy)
                        .onSubmit(save)
                    PlainLink(title: k.busy ? TypeSafeText.saving : TypeSafeText.save, brightness: 0.5, action: save)
                        .disabled(k.busy || !TypeSafeKeyField.isValid(key))
                }
                .transition(.opacity)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
            }
            if !k.result.isEmpty {
                Text(k.result)
                    .font(Theme.font(11.5))
                    .foregroundStyle(k.resultOK ? Color.green.opacity(0.7) : Color.orange.opacity(0.8))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.keyEditing)
        .onChange(of: k.resultOK) { _, ok in
            if ok { key = ""; model.keyEditing = false }
        }
    }

    private func save() {
        guard !k.busy, TypeSafeKeyField.isValid(key) else { return }
        model.onSaveKey(key)
    }
}

/// Under the block lengths: the two clean focus switches. Off until he turns
/// them on, and both take effect at the start of the next block.
struct CleanFocusSettings: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(spacing: 5) {
            CleanFocusToggle(title: "Hide Dock and menu bar during work",
                             help: "While a block runs, the Dock and the menu bar hide themselves. "
                                 + "Your own settings come back at the break. ⌘-Tab still works; "
                                 + "the Dock blinks for about half a second as it restarts.",
                             on: model.cleanFocus.hideDockAndMenuBar) {
                var p = model.cleanFocus
                p.hideDockAndMenuBar = $0
                model.onSetCleanFocus(p)
            }
            if model.cleanFocus.hideDockAndMenuBar {
                CleanFocusToggle(title: "Hide desktop icons too",
                                 help: "Finder stops drawing the desktop while a block runs, and "
                                     + "restarts to do it — open Finder windows stay, a drag in "
                                     + "progress does not.",
                                 on: model.cleanFocus.hideDesktopIcons) {
                    var p = model.cleanFocus
                    p.hideDesktopIcons = $0
                    model.onSetCleanFocus(p)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.cleanFocus)
    }
}

/// One small grey switch, in the same voice as the length pills.
struct CleanFocusToggle: View {
    let title: String
    let help: String
    let on: Bool
    let set: (Bool) -> Void
    @State private var hover = false

    var body: some View {
        Button { set(!on) } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10, weight: .semibold))
                Text(title).font(Theme.font(11.5)).lineLimit(1)
            }
            .foregroundStyle(Color(white: on ? 0.72 : (hover ? 0.55 : 0.36)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct LengthPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(12, .medium))
                .monospacedDigit()
                .foregroundStyle(Color(white: selected ? 0.9 : (hover ? 0.7 : 0.45)))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.1 : (hover ? 0.05 : 0.02))))
                .overlay(Capsule().stroke(Color(white: selected ? 0.35 : 0.18), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// One small line toward the long break — "1 h 20 of 2 h until your long break" — with a thin bar
/// behind it. It replaced four dots on 2026-09-22: the long break is earned by two hours of work,
/// not by a number of blocks, so a count of blocks was the wrong picture.
struct LongBreakLine: View {
    /// 0…1 of the two hours.
    let progress: Double
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: 58, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.blue)
                        .frame(width: 58 * min(1, max(0, progress)), height: 4)
                        .shadow(color: Theme.blue.opacity(0.8), radius: 4)
                }
            if !text.isEmpty {
                Text(text).font(Theme.font(12.5)).foregroundStyle(Color(white: 0.5))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: progress)
    }
}

/// Slim lightning-blue progress bar with a glowing head.
struct ProgressTrack: View {
    var progress: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.blue, Theme.blueSoft], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(progress > 0 ? height : 0, g.size.width * min(1, max(0, progress))))
                    .shadow(color: Theme.blue.opacity(0.8), radius: 6)
            }
        }
        .frame(height: height)
    }
}

/// "Understanding your goal…" with a travelling shimmer and breathing dots.
struct UnderstandingLine: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                Text("Understanding your goal")
                ForEach(0..<3, id: \.self) { i in
                    Text(".").opacity(0.25 + 0.75 * max(0, sin((t * 3.2) - Double(i) * 0.7)))
                }
            }
            .font(Theme.font(18, .medium))
            .foregroundStyle(Theme.blueSoft.opacity(0.65 + 0.35 * sin(t * 2.4)))
            .shadow(color: Theme.blue.opacity(0.45), radius: 10)
        }
    }
}

// MARK: - Countdown

struct CountdownView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        ZStack {
            // Backdrop glow that swells with each tick.
            RadialGradient(colors: [Theme.blue.opacity(model.mode == .go ? 0.55 : 0.22), .clear],
                           center: .center, startRadius: 10, endRadius: model.mode == .go ? 900 : 520)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.4), value: model.mode)

            if model.mode == .go {
                RingBurst(size: 320, delay: 0).id("go-ring-1")
                RingBurst(size: 320, delay: 0.12).id("go-ring-2")
                Text("GO")
                    .font(Theme.font(300, .black, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.blueSoft], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Theme.blue, radius: 30)
                    .shadow(color: Theme.blue.opacity(0.7), radius: 80)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                FlashView().id("flash")
            } else {
                RingBurst(size: 240, delay: 0).id("ring-\(model.countdown)")
                Text("\(model.countdown)")
                    .font(Theme.font(280, .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.blueSoft], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Theme.blue.opacity(0.95), radius: 24)
                    .shadow(color: Theme.blue.opacity(0.55), radius: 70)
                    .id(model.countdown)
                    .transition(.asymmetric(insertion: .scale(scale: 0.35).combined(with: .opacity),
                                            removal: .scale(scale: 1.7).combined(with: .opacity)))
            }

            VStack {
                Text(model.mode == .go ? " " : "GET READY")
                    .font(Theme.font(15, .semibold))
                    .tracking(8)
                    .foregroundStyle(Theme.blue.opacity(0.8))
                    .padding(.top, 90)
                Spacer()
                if !model.goalLabel.isEmpty {
                    Text(model.goalLabel)
                        .font(Theme.font(18, .regular))
                        .foregroundStyle(Color(white: 0.55))
                        .lineLimit(1)
                        .padding(.bottom, 20)
                }
                EndSessionButton(action: model.onEndSession)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.52), value: model.countdown)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: model.mode)
    }
}

/// A blue ring that bursts outward once.
struct RingBurst: View {
    let size: CGFloat
    let delay: Double
    @State private var go = false

    var body: some View {
        Circle()
            .stroke(Theme.blue, lineWidth: go ? 1 : 12)
            .frame(width: size, height: size)
            .scaleEffect(go ? 3.4 : 0.55)
            .opacity(go ? 0 : 0.95)
            .blur(radius: go ? 8 : 1)
            .shadow(color: Theme.blue, radius: 16)
            .onAppear {
                withAnimation(.easeOut(duration: 0.95).delay(delay)) { go = true }
            }
    }
}

/// Full-screen blue-white flash for GO.
struct FlashView: View {
    @State private var on = true
    var body: some View {
        LinearGradient(colors: [Color.white.opacity(0.55), Theme.blue.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .opacity(on ? 1 : 0)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { on = false } }
    }
}

// MARK: - Break

/// The break is rest: in the middle of the black, and nothing else, BREAK (or LONG BREAK), the big clock and the
/// four dots toward the long break. The small print at the bottom is only "Skip break (Esc)" and "End session".
/// The score lives in a small card in the top-right corner that fades away after 30 s (`ScoreCard`).
struct BreakView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        ZStack {
            VStack(spacing: 22) {
                Text(model.breakTitle)
                    .font(Theme.font(20, .medium))
                    .tracking(10)
                    .foregroundStyle(model.breakTitle == "BREAK" ? Theme.grey : Theme.blue)
                    .shadow(color: Theme.blue.opacity(model.breakTitle == "BREAK" ? 0 : 0.7), radius: 10)
                Text(model.breakClock)
                    .font(Theme.font(110, .ultraLight, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.3), value: model.breakClock)
                LongBreakLine(progress: model.longBreakProgress, text: model.longBreakLine)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // The score, small, in the corner — and gone before the break is over.
            if let r = model.reveal {
                ScoreCard(reveal: r)
                    .id(r.startedAt)
                    .padding(.trailing, 34)
                    .padding(.top, 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .opacity(model.revealFaded ? 0 : 1)
                    .animation(.easeInOut(duration: BreakReveal.fadeDuration), value: model.revealFaded)
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                Spacer()
                Button(action: { model.onSkipBreak() }) {
                    Text("Skip break  (Esc)")
                        .font(Theme.font(13))
                        .foregroundStyle(Color(white: 0.75))
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .overlay(Capsule().stroke(Color(white: 0.35), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                EndSessionButton(action: model.onEndSession)
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 40)
        .animation(.easeInOut(duration: 0.5), value: model.reveal)
    }
}

/// Top-right of the break screen: the score counts up to its number over "/ 1000", two thin FOCUS / OUTPUT bars
/// and one grey line pointing at the day's doc. Same energy as before (count-up, glow, rising ticks) at a
/// quarter of the size, so the middle of the screen stays empty. "+25 min" still flies out of it into the
/// top-left hours label.
struct ScoreCard: View {
    let reveal: OverlayModel.Reveal
    @Environment(\.hoursTarget) private var hoursTarget
    @State private var settled = false

    private var hasScore: Bool { reveal.score != nil }
    /// Without a score the "+25 min" part starts right away.
    private var shift: Double { hasScore ? 0 : -ScoreRevealTiming.chipAppear + 0.3 }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: settled)) { ctx in
            let t = ctx.date.timeIntervalSince(reveal.startedAt)
            VStack(alignment: .leading, spacing: 9) {
                if hasScore { score(t) } else { note }
                GeometryReader { g in
                    chip(t - shift, from: g.frame(in: .named(HoursCorner.space)))
                        .frame(width: g.size.width, height: g.size.height, alignment: .leading)
                }
                .frame(height: 26)
                if reveal.celebrate, t - shift > ScoreRevealTiming.burstAt, !reveal.celebrateLine.isEmpty {
                    Text(reveal.celebrateLine)
                        .font(Theme.font(11, .semibold))
                        .foregroundStyle(Theme.blueSoft)
                        .transition(.opacity)
                }
                Text(BreakReveal.footnote)
                    .font(Theme.font(10.5))
                    .foregroundStyle(Color(white: 0.34))
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .frame(width: 236, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, ScoreRevealTiming.burstAt + shift) + 1.6) {
                settled = true
            }
        }
    }

    private func score(_ t: Double) -> some View {
        let value = Double(reveal.score ?? 0)
        let p = Ease.outExpo(t / ScoreRevealTiming.countUp)
        let shown = Int((value * p).rounded())
        let land = t - ScoreRevealTiming.countUp
        let punch = land > 0 && land < 0.35 ? 1 + 0.06 * sin(land / 0.35 * .pi) : 1
        let glow = 0.5 + 0.5 * p
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(shown)")
                    .font(Theme.font(38, .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.blueSoft], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Theme.blue.opacity(0.8 * glow), radius: 10)
                    .scaleEffect(punch, anchor: .leading)
                Text("/ 1000")
                    .font(Theme.font(12, .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.42))
            }
            VStack(spacing: 6) {
                if let f = reveal.focus {
                    ThinScoreBar(label: "FOCUS", value: f, progress: Ease.outCubic((t - 0.35) / 0.9))
                }
                if let o = reveal.output {
                    ThinScoreBar(label: "OUTPUT", value: o, progress: Ease.outCubic((t - 0.5) / 0.9))
                }
            }
        }
    }

    private var note: some View {
        Text(reveal.note)
            .font(Theme.font(12.5, .medium))
            .foregroundStyle(Color(white: 0.55))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "+25 min" pops out of the card, then flies into the hours label in the top-left corner.
    private func chip(_ t: Double, from frame: CGRect) -> some View {
        let appear = t - ScoreRevealTiming.chipAppear
        let fly = Ease.inOutCubic((t - ScoreRevealTiming.chipFly) / ScoreRevealTiming.flyDuration)
        let pop = appear <= 0 ? 0 : Ease.outBack(appear / 0.3)
        let opacity = appear <= 0 ? 0 : (fly >= 1 ? 0 : 1 - max(0, fly - 0.75) / 0.25)
        let target = hoursTarget ?? CGPoint(x: frame.midX, y: frame.maxY + 40)
        let dx = target.x - frame.midX, dy = target.y - frame.midY
        return Text("+\(reveal.workedMinutes) min")
            .font(Theme.font(14, .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 4)
            .background(Capsule().fill(Theme.blue))
            .shadow(color: Theme.blue.opacity(0.9), radius: 10)
            .scaleEffect((0.4 + 0.6 * pop) * (1 - 0.6 * fly))
            .offset(x: dx * fly, y: dy * fly)
            .opacity(opacity)
    }
}

/// FOCUS / OUTPUT as one thin line with its number.
struct ThinScoreBar: View {
    let label: String
    let value: Int
    let progress: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.font(8.5, .semibold)).tracking(1.4)
                .foregroundStyle(Color(white: 0.45))
                .frame(width: 46, alignment: .leading)
            ProgressTrack(progress: Double(value) / 1000 * progress, height: 3)
            Text("\(Int((Double(value) * progress).rounded()))")
                .font(Theme.font(10.5, .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(white: 0.8))
                .frame(width: 26, alignment: .trailing)
        }
    }
}

/// When each part of the reveal happens (seconds after it starts). Shared with the sound schedule.
enum ScoreRevealTiming {
    static let countUp = 1.4
    static let chipAppear = 1.7
    static let chipFly = 2.0
    static let flyDuration = 0.7
    /// The chip reaches the top-left hours label.
    static let hoursTick = chipFly + flyDuration
    static let burstAt = 3.3
}

enum Ease {
    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func outExpo(_ x: Double) -> Double { let c = clamp(x); return c >= 1 ? 1 : 1 - pow(2, -10 * c) }
    static func outCubic(_ x: Double) -> Double { let c = clamp(x); return 1 - pow(1 - c, 3) }
    static func inOutCubic(_ x: Double) -> Double {
        let c = clamp(x); return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }
    static func outBack(_ x: Double) -> Double {
        let c = clamp(x), k = 1.70158
        return 1 + (k + 1) * pow(c - 1, 3) + k * pow(c - 1, 2)
    }
}

/// Blue progress ring (hours toward the daily goal).
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.09), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0.0001, progress)))
                .stroke(AngularGradient(colors: [Theme.blue, Theme.blueSoft, Theme.blue], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.blue.opacity(0.7), radius: 4)
        }
    }
}

// MARK: - Windows

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Full-black windows on every display, above full-screen apps, the Dock and the menu bar.
/// Every show and hide is a ~0.8 s fade (window alpha) with a scale + blur on the content.
final class OverlayManager {
    let model = OverlayModel()
    private var windows: [OverlayWindow] = []
    /// True from `show()` until `hide()` (the fade-out may still be running after that).
    private(set) var isVisible = false
    /// App that was in front before the overlay appeared; it gets focus back when we hide.
    private var previousApp: NSRunningApplication?
    private var pendingHide: DispatchWorkItem?

    private var keyMonitor: Any?

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.rebuild(alpha: 1)
        }
        // Goal screen keys (a monitor, because the text field would otherwise eat the arrow keys):
        // ↓ opens Suggestions and walks its rows, ↑ walks back, Enter picks the highlighted row,
        // Esc closes whatever is open before it ends the session.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, self.model.mode == .goal,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            let m = self.model
            if event.keyCode == 53 {   // Esc
                // Then the rubric's "Fix…" field (or a rewrite in flight): close it, keep the summary.
                if m.rubricFix.holdsStart { m.onRubricEscape(); return nil }
                return m.disclosure.escape(&m.suggestions) ? nil : event
            }
            // Typing a TypeSafe key in Settings: the arrows and Enter belong to that field.
            guard m.goalStatus == .idle, !m.keyEditing else { return event }
            switch event.keyCode {
            case 125:   // ↓
                return m.disclosure.keyDown(&m.suggestions) ? nil : event
            case 126:   // ↑
                return m.disclosure.keyUp(&m.suggestions) ? nil : event
            case 36, 76:   // Return / Enter
                guard let s = m.disclosure.enter(m.suggestions) else { return event }
                m.pick(s)
                return nil
            default:
                return event
            }
        }
    }

    func showGoal(prefill: String, length: BlockLengthChoice, scale: Double) {
        model.goalText = prefill
        model.prefill = prefill
        model.suggestions = SuggestionPicker()
        model.disclosure = GoalScreenDisclosure()
        model.keyEditing = false
        model.goalStatus = .idle
        model.rubricFix = RubricFix()
        model.rubricNote = ""
        model.length = length
        model.lengthScale = scale
        model.mode = .goal
        model.focusToken += 1
        show()
    }

    func showCountdown(_ n: Int, goalLabel: String) {
        model.countdown = n
        model.goalLabel = goalLabel
        model.mode = .countdown
        show()
    }

    /// "GO" flash, then dissolve.
    func showGoThenHide() {
        model.mode = .go
        show()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        pendingHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func showBreak() {
        model.mode = .rest
        show()
    }

    /// Bring the overlay back in front (Dock icon clicked while it is up).
    func bringForward() {
        guard isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        windows.dropFirst().forEach { $0.orderFrontRegardless() }
    }

    func hide() {
        pendingHide?.cancel()
        pendingHide = nil
        guard isVisible else { return }
        isVisible = false
        model.visible = false
        windows.forEach { $0.ignoresMouseEvents = true }
        // Hand focus back straight away; the overlay keeps fading on top of it.
        if let app = previousApp, !app.isTerminated { app.activate() }
        previousApp = nil
        let fading = windows
        fade(fading, to: 0, duration: Theme.fadeDuration) { [weak self] in
            guard let self, !self.isVisible else { return }
            fading.forEach { $0.orderOut(nil) }
            self.windows.removeAll { w in fading.contains { $0 === w } }
        }
    }

    private func show() {
        pendingHide?.cancel()
        pendingHide = nil
        if !isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        }
        let wasVisible = isVisible
        isVisible = true
        if windows.isEmpty { rebuild(alpha: 0) }
        windows.forEach { $0.ignoresMouseEvents = false }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        windows.dropFirst().forEach { $0.orderFrontRegardless() }
        if !wasVisible {
            fade(windows, to: 1, duration: Theme.fadeDuration * 0.9)
            DispatchQueue.main.async { [weak self] in self?.model.visible = true }
        }
    }

    private func rebuild(alpha: CGFloat) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = .screenSaver
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.alphaValue = alpha
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.contentView = NSHostingView(rootView: OverlayView(model: model, isPrimary: i == 0,
                                                                notchInset: screen.safeAreaInsets.top))
            w.setFrame(screen.frame, display: true)
            if i == 0 { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
            windows.append(w)
        }
    }
}
