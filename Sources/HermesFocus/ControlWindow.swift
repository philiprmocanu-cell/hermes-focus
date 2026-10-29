import AppKit
import SwiftUI
import FocusCore

/// What the live control window shows beyond the phase machine (hours, sharpened goal, tip, board…).
struct LiveInfo: Equatable {
    var loggedText = "0 m logged"
    var goalText = "of 4 h goal"
    var dayProgress = 0.0
    var specificGoal = ""
    /// 0..1 toward the sharpened goal; nil = nothing yet.
    var goalProgress: Double?
    var tip = ""
    /// Last `/now` refresh: true = live, false = offline (showing local), nil = not asked (friend mode).
    var online: Bool?
    /// One extra line under the footer ("" = none).
    var note = ""
    /// Toward the long break: filled dots of 4 and "2 of 4 until your long break" ("" = hide).
    var longBreakProgress: Double = 0
    var longBreakText = ""
    /// Idle only: the top 2 suggested blocks ("Up next").
    var upNext: [BlockSuggestion] = []
    /// A work block is running: the goal can be changed (the owner's build offers "Change goal" by voice).
    var canChangeGoal = false
    /// While a block runs: "Judged 90% on focus, 10% on output · 1. … · ✓ 2. …" from `/now` ("" = hide).
    var rubricLine = ""
}

final class ControlModel: ObservableObject {
    enum Tab: String, CaseIterable { case now = "Now", board = "Board", history = "History" }
    enum Mode: Equatable { case owner, friend, local, notJoined }

    @Published var state = ControlState.make(phase: .idle, isPaused: false, remaining: 0, nextWork: 1500,
                                             goal: "", understood: "", todayLine: "")
    @Published var testMode = false
    @Published var live = LiveInfo()
    @Published var tab: Tab = .now
    @Published var goalHours = HoursMath.defaultGoalHours
    @Published var mode: Mode = .owner
    /// The first-launch choice, Join, and the own-keys key steps (`SetupFlow`); nil = the normal tabs.
    @Published var setup: SetupScreen?
    /// After Join (and from "Add key"): the "Your TypeSafe key" step, in the join screen's style.
    @Published var showKey = false
    /// The friend's TypeSafe key: set or not, the save in flight, the line under the field.
    @Published var key = TypeSafeKeyUI()

    // Board
    @Published var board: [LeaderboardRow] = []
    /// "Hardest working" (hours) or "Most output" (output score); remembered across launches.
    @Published var boardSort = LeaderboardSort.hours
    @Published var boardStatus = ""
    @Published var boardLoading = false

    // History — the last 30 days, newest first.
    @Published var history: [HistoryDay] = []
    @Published var historyStatus = ""
    @Published var historyLoading = false

    // Join
    @Published var joinBusy = false
    @Published var joinError = ""
    @Published var joinedName = ""

    var onStart: (_ testDurations: Bool) -> Void = { _ in }
    var onTogglePause: () -> Void = {}
    var onEnd: () -> Void = {}
    var onGoalHours: (Double) -> Void = { _ in }
    var onTab: (Tab) -> Void = { _ in }
    var onRefreshBoard: () -> Void = {}
    var onRefreshHistory: () -> Void = {}
    var onJoin: (_ server: String, _ code: String, _ name: String) -> Void = { _, _, _ in }
    var onSkipJoin: () -> Void = {}
    /// The choice screen's two cards, "Back", "Next" (after "Key works"), and "Later" / "Skip" / "Done".
    var onPickOwnKeys: () -> Void = {}
    var onPickJoin: () -> Void = {}
    var onSetupBack: () -> Void = {}
    var onSetupNext: () -> Void = {}
    var onCloseSetup: () -> Void = {}
    /// Board tab before anything is chosen: back to the choice screen.
    var onOpenSetup: () -> Void = {}
    /// "Add key" beside the reminder line: the friend's key step, or (own keys) the TypeSafe step.
    var onAddKey: () -> Void = {}
    /// Own keys: "Save key" on the Anthropic step.
    var onSaveAnthropicKey: (String) -> Void = { _ in }

    /// The tabs this mode shows: own keys has no board.
    var tabs: [Tab] { mode == .local ? [.now, .history] : Tab.allCases }
    /// "Save key" (the raw text from the secure field), "Remove", and "Later" / "Done".
    var onSaveKey: (String) -> Void = { _ in }
    var onRemoveKey: () -> Void = {}
    var onCloseKey: () -> Void = {}
    /// "Up next" row clicked: start a session with that goal and length filled in.
    var onPickUpNext: (BlockSuggestion) -> Void = { _ in }
    /// The board's sort toggle was flipped.
    var onBoardSort: (LeaderboardSort) -> Void = { _ in }
}

// MARK: - Root

struct ControlView: View {
    @ObservedObject var model: ControlModel
    private var s: ControlState { model.state }

    var body: some View {
        ZStack {
            background
            if let screen = model.setup {
                Group {
                    switch screen {
                    case .choose: ModeChoiceView(model: model)
                    case .join: JoinView(model: model)
                    case .typesafeKey: LocalTypeSafeStep(model: model)
                    case .anthropicKey: AnthropicKeyStep(model: model)
                    }
                }
                .id(screen)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if model.showKey {
                TypeSafeKeyStep(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                VStack(spacing: 0) {
                    HeaderBar(model: model)
                        .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 14)
                    ZStack {
                        switch model.tab {
                        case .now: NowTab(model: model).transition(.opacity.combined(with: .move(edge: .leading)))
                        case .board: BoardTab(model: model).transition(.opacity.combined(with: .move(edge: .trailing)))
                        case .history: HistoryTab(model: model).transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.86), value: model.tab)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.setup)
        .animation(.easeInOut(duration: 0.35), value: model.showKey)
        .frame(width: 400, height: 600)
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        ZStack {
            Color(white: 0.06)
            RadialGradient(colors: [Theme.blue.opacity(s.isLive ? 0.24 : 0.09), .clear],
                           center: .top, startRadius: 0, endRadius: 380)
                .animation(.easeInOut(duration: 0.8), value: s.isLive)
            // Faint lightning-blue floor glow so the window never feels flat.
            RadialGradient(colors: [Theme.blue.opacity(0.06), .clear], center: .bottom, startRadius: 0, endRadius: 300)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Header: hours logged + daily goal, tabs, settings

struct HeaderBar: View {
    @ObservedObject var model: ControlModel
    @State private var settings = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ProgressRing(progress: model.live.dayProgress, lineWidth: 4)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.blue)
                    .shadow(color: Theme.blue.opacity(model.state.isLive ? 0.9 : 0.3), radius: 5)
            }
            .frame(width: 38, height: 38)
            .animation(.easeOut(duration: 0.6), value: model.live.dayProgress)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.live.loggedText)
                    .font(Theme.font(15, .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: model.live.loggedText)
                Button { settings.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(model.live.goalText)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(Theme.font(11.5))
                    .foregroundStyle(Color(white: 0.52))
                    .lineLimit(1)
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Set your daily hours goal")
                .popover(isPresented: $settings, arrowEdge: .bottom) { GoalHoursPopover(model: model) }
            }
            Spacer(minLength: 8)
            TabPills(model: model)
        }
    }
}

struct TabPills: View {
    @ObservedObject var model: ControlModel
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.tabs, id: \.self) { t in
                let on = model.tab == t
                Button {
                    model.tab = t
                    model.onTab(t)
                } label: {
                    Text(t.rawValue)
                        .font(Theme.font(12, .semibold))
                        .foregroundStyle(on ? .white : Color(white: 0.55))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background {
                            if on {
                                Capsule().fill(Theme.blue.opacity(0.9))
                                    .shadow(color: Theme.blue.opacity(0.6), radius: 6)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.tab)
    }
}

struct GoalHoursPopover: View {
    @ObservedObject var model: ControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DAILY HOURS GOAL")
                .font(Theme.font(10.5, .semibold)).tracking(2)
                .foregroundStyle(Theme.blue)
            HStack(alignment: .firstTextBaseline) {
                Text(HoursMath.hoursText(model.goalHours))
                    .font(Theme.font(30, .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.2), value: model.goalHours)
                Text("a day").foregroundStyle(Color(white: 0.5))
                Spacer()
                Stepper("", value: binding, in: HoursMath.minGoalHours...HoursMath.maxGoalHours, step: 0.5)
                    .labelsHidden()
            }
            Slider(value: binding, in: HoursMath.minGoalHours...HoursMath.maxGoalHours, step: 0.5)
                .tint(Theme.blue)
            Text("Hours of focused work you're aiming for each day.")
                .font(Theme.font(11)).foregroundStyle(Color(white: 0.45))
        }
        .padding(16)
        .frame(width: 260)
        .preferredColorScheme(.dark)
    }

    private var binding: Binding<Double> {
        Binding(get: { model.goalHours }, set: { v in
            let h = HoursMath.clampGoal(v)
            guard h != model.goalHours else { return }
            model.goalHours = h
            model.onGoalHours(h)
        })
    }
}

// MARK: - Now tab

struct NowTab: View {
    @ObservedObject var model: ControlModel
    private var s: ControlState { model.state }
    private var l: LiveInfo { model.live }

    var body: some View {
        VStack(spacing: 14) {
            PhaseChip(label: s.phaseLabel, live: s.isLive, test: model.testMode && s.canEnd)

            Text(s.timeText)
                .font(Theme.font(76, .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LinearGradient(colors: [.white, s.isLive ? Theme.blueSoft : Color(white: 0.8)],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: Theme.blue.opacity(s.isLive ? 0.6 : 0), radius: 20)
                .contentTransition(.numericText(countsDown: true))
                .animation(.easeOut(duration: 0.25), value: s.timeText)
                .frame(maxWidth: .infinity)
                .padding(.top, -4)

            GoalCard(goal: s.goal, specific: l.specificGoal.isEmpty ? s.understood : l.specificGoal,
                     progress: l.specificGoal.isEmpty ? nil : l.goalProgress, canStart: s.canStart)

            if !l.rubricLine.isEmpty {
                Text(l.rubricLine)
                    .font(Theme.font(11.5))
                    .foregroundStyle(Color(white: 0.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }

            if (model.mode == .friend || model.mode == .local) && model.key.missing {
                TypeSafeReminder { model.onAddKey() }
                    .transition(.opacity)
            }

            if s.canStart && !l.upNext.isEmpty {
                UpNextList(items: l.upNext) { model.onPickUpNext($0) }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }


            if !l.tip.isEmpty && s.phaseLabel == "Focus" {
                TipLine(tip: l.tip)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer(minLength: 0)

            if !l.longBreakText.isEmpty {
                LongBreakLine(progress: l.longBreakProgress, text: l.longBreakText)
                    .scaleEffect(0.92)
            }

            HStack(spacing: 10) {
                if s.canStart {
                    ControlButton(title: "Start", icon: "bolt.fill", style: .primary) {
                        model.onStart(NSEvent.modifierFlags.contains(.option))
                    }
                } else {
                    ControlButton(title: s.pauseTitle, icon: s.pauseTitle == "Resume" ? "play.fill" : "pause.fill",
                                  style: .secondary, enabled: s.canPause) { model.onTogglePause() }
                    ControlButton(title: "End session", icon: "stop.fill", style: .danger, enabled: s.canEnd) {
                        model.onEnd()
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: s.canStart)


            FooterLine(today: s.todayLine, online: l.online, note: l.note)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .animation(.easeInOut(duration: 0.35), value: l.tip)
        .animation(.easeInOut(duration: 0.4), value: l.upNext)
        .animation(.easeInOut(duration: 0.3), value: l.canChangeGoal)
        .animation(.easeInOut(duration: 0.3), value: model.key.missing)
    }
}

/// Idle control window: the top 2 suggested blocks. Clicking one starts a session with it filled in.
struct UpNextList: View {
    let items: [BlockSuggestion]
    let pick: (BlockSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UP NEXT")
                .font(Theme.font(10.5, .semibold)).tracking(2.2)
                .foregroundStyle(Theme.blue)
            ForEach(items) { s in UpNextRow(s: s) { pick(s) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UpNextRow: View {
    let s: BlockSuggestion
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.goal).font(Theme.font(13, .semibold)).foregroundStyle(.white).lineLimit(1)
                    if !s.why.isEmpty {
                        Text(s.why).font(Theme.font(11)).foregroundStyle(Color(white: 0.5)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text("\(s.minutes) min")
                    .font(Theme.font(11, .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.blueSoft)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.blue.opacity(0.18)))
                Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Theme.blue.opacity(hover ? 1 : 0.5))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(hover ? Theme.blue.opacity(0.12) : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(hover ? Theme.blue.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct PhaseChip: View {
    let label: String
    let live: Bool
    let test: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(live ? Theme.blue : Color(white: 0.4))
                .frame(width: 7, height: 7)
                .shadow(color: Theme.blue.opacity(live ? 1 : 0), radius: 5)
            Text(label.uppercased())
                .font(Theme.font(11.5, .semibold))
                .tracking(3)
                .foregroundStyle(live ? Theme.blue : Color(white: 0.6))
                .contentTransition(.opacity)
            if test {
                Text("TEST")
                    .font(Theme.font(9, .bold)).tracking(1.5)
                    .foregroundStyle(Color(white: 0.5))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().stroke(Color(white: 0.3)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Capsule().fill((live ? Theme.blue : Color.white).opacity(live ? 0.12 : 0.05)))
        .animation(.easeInOut(duration: 0.4), value: live)
    }
}

struct GoalCard: View {
    let goal: String
    let specific: String
    let progress: Double?
    let canStart: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR GOAL")
                .font(Theme.font(10.5, .semibold)).tracking(2.2)
                .foregroundStyle(Color(white: 0.45))
            if goal.isEmpty {
                Text(canStart ? "Ready when you are." : "Choosing a goal…")
                    .font(Theme.font(15))
                    .foregroundStyle(Color(white: 0.55))
            } else {
                Text(goal)
                    .font(Theme.font(16, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !specific.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "scope").font(.system(size: 11, weight: .semibold))
                        Text(specific)
                            .font(Theme.font(13))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Theme.blueSoft.opacity(0.92))
                }
                if let progress {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressTrack(progress: progress, height: 6)
                            .animation(.spring(response: 0.7, dampingFraction: 0.8), value: progress)
                        Text(GoalProgress.text(progress) + " · toward your goal")
                            .font(Theme.font(11)).foregroundStyle(Color(white: 0.5))
                            .contentTransition(.numericText())
                    }
                    .padding(.top, 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct TipLine: View {
    let tip: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lightbulb.max.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.blue)
                .shadow(color: Theme.blue.opacity(0.7), radius: 4)
                .padding(.top, 1)
            Text(tip)
                .font(Theme.font(12.5, .medium))
                .foregroundStyle(Color(white: 0.88))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.blue.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.blue.opacity(0.3), lineWidth: 1))
    }
}

struct FooterLine: View {
    let today: String
    let online: Bool?
    let note: String

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(today)
                if let online {
                    Text("·")
                    Circle().fill(online ? Color.green.opacity(0.8) : Color.orange.opacity(0.8)).frame(width: 5, height: 5)
                    Text(online ? "live" : "offline — local")
                }
            }
            if !note.isEmpty { Text(note).foregroundStyle(Color(white: 0.42)) }
        }
        .font(Theme.font(11))
        .foregroundStyle(Color(white: 0.48))
        .multilineTextAlignment(.center)
    }
}

struct ControlButton: View {
    enum Style { case primary, secondary, danger }
    let title: String
    let icon: String
    let style: Style
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(Theme.font(14, .semibold))
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(border, lineWidth: 1))
            .shadow(color: style == .primary ? Theme.blue.opacity(hover ? 0.75 : 0.45) : .clear, radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hover = $0 }
        .scaleEffect(hover && enabled ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    private var fg: Color { style == .primary ? .white : Color(white: 0.9) }
    private var bg: Color {
        switch style {
        case .primary: return Theme.blue.opacity(hover ? 1 : 0.9)
        case .secondary: return Color.white.opacity(hover ? 0.12 : 0.07)
        case .danger: return Color.red.opacity(hover ? 0.28 : 0.16)
        }
    }
    private var border: Color {
        switch style {
        case .primary: return Color.white.opacity(0.2)
        case .secondary: return Color.white.opacity(0.14)
        case .danger: return Color.red.opacity(0.4)
        }
    }
}

// MARK: - History tab

/// Every day the brain remembers, newest first: date, hours, blocks, score, verdict and the day's doc.
struct HistoryTab: View {
    @ObservedObject var model: ControlModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("HISTORY")
                    .font(Theme.font(11, .semibold)).tracking(2.5)
                    .foregroundStyle(Theme.blue)
                Spacer()
                Button { model.onRefreshHistory() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(model.historyLoading ? 360 : 0))
                        .animation(model.historyLoading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                   value: model.historyLoading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(white: 0.6))
                .help("Refresh")
            }

            VStack(spacing: 0) {
                HStack {
                    Text("DAY").frame(width: 76, alignment: .leading)
                    Text("HOURS").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("BLOCKS").frame(width: 54, alignment: .trailing)
                    Text("SCORE").frame(width: 46, alignment: .trailing)
                    Text("").frame(width: 58, alignment: .leading)
                }
                .font(Theme.font(9.5, .semibold)).tracking(1.2)
                .foregroundStyle(Color(white: 0.42))
                .padding(.horizontal, 8).padding(.bottom, 6)

                if model.history.isEmpty {
                    Text(model.historyLoading ? "Loading…" : "No days yet.")
                        .font(Theme.font(13)).foregroundStyle(Color(white: 0.5))
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView {
                        VStack(spacing: 4) { ForEach(model.history) { d in HistoryRow(day: d) } }
                    }
                    .frame(maxHeight: 380)
                }
            }

            Spacer(minLength: 0)

            Text(model.historyStatus)
                .font(Theme.font(11)).foregroundStyle(Color(white: 0.45))
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
    }
}

struct HistoryRow: View {
    let day: HistoryDay

    var body: some View {
        HStack {
            Text(day.dateText)
                .font(Theme.font(12, .medium))
                .foregroundStyle(Color(white: 0.75))
                .frame(width: 76, alignment: .leading)
                .lineLimit(1)
            Text(day.hoursText)
                .font(Theme.font(12.5, .semibold)).monospacedDigit()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(day.blocks > 0 ? "\(day.blocks)" : "—")
                .font(Theme.font(12)).monospacedDigit()
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 54, alignment: .trailing)
            Text(day.scoreText)
                .font(Theme.font(12, .medium)).monospacedDigit()
                .foregroundStyle(Color(white: 0.6))
                .frame(width: 46, alignment: .trailing)
            HStack(spacing: 5) {
                if !day.verdictText.isEmpty {
                    Text(day.verdictText)
                        .font(Theme.font(10, .bold)).tracking(0.6)
                        .foregroundStyle(Theme.verdictColor(day.verdict))
                }
                if let url = day.docURL, let u = URL(string: url) {
                    Link(destination: u) {
                        Image(systemName: "doc.text").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.blue.opacity(0.85))
                    .help("Open doc")
                }
            }
            .frame(width: 58, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }
}

// MARK: - Board tab

struct BoardTab: View {
    @ObservedObject var model: ControlModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("LEADERBOARD")
                    .font(Theme.font(11, .semibold)).tracking(2.5)
                    .foregroundStyle(Theme.blue)
                Spacer()
                Button { model.onRefreshBoard() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(model.boardLoading ? 360 : 0))
                        .animation(model.boardLoading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                   value: model.boardLoading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(white: 0.6))
                .help("Refresh")
            }

            if model.mode == .notJoined {
                notJoined
            } else {
                table
            }

            Spacer(minLength: 0)


            Text(model.boardStatus)
                .font(Theme.font(11)).foregroundStyle(Color(white: 0.45))
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
    }

    private var table: some View {
        VStack(spacing: 0) {
            BoardSortToggle(sort: model.boardSort) { model.boardSort = $0; model.onBoardSort($0) }
                .padding(.bottom, 10)
            HStack {
                Text("#").frame(width: 26, alignment: .leading)
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("TODAY").frame(width: 66, alignment: .trailing)
                Text("WEEK").frame(width: 66, alignment: .trailing)
                Text("OUTPUT").frame(width: 58, alignment: .trailing)
            }
            .font(Theme.font(9.5, .semibold)).tracking(1.2)
            .foregroundStyle(Color(white: 0.42))
            .padding(.horizontal, 10).padding(.bottom, 6)

            if model.board.isEmpty {
                Text(model.boardLoading ? "Loading…" : "Nobody on the board yet.")
                    .font(Theme.font(13)).foregroundStyle(Color(white: 0.5))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Leaderboard.rank(model.board, by: model.boardSort)) { r in
                            BoardRow(row: r, sort: model.boardSort)
                        }
                    }
                }
                .frame(maxHeight: 290)
            }
        }
    }

    private var notJoined: some View {
        VStack(spacing: 12) {
            Image(systemName: "trophy.fill").font(.system(size: 28)).foregroundStyle(Theme.blue)
                .shadow(color: Theme.blue.opacity(0.6), radius: 10)
            Text("Join a friend's leaderboard — your hours, your scores, side by side with theirs.")
                .font(Theme.font(13)).foregroundStyle(Color(white: 0.7))
                .multilineTextAlignment(.center)
            ControlButton(title: "Join with a code", icon: "person.badge.plus", style: .primary) { model.onOpenSetup() }
                .frame(width: 220)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// "Hardest working" (hours) · "Most output" (today's average output score).
struct BoardSortToggle: View {
    let sort: LeaderboardSort
    let pick: (LeaderboardSort) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LeaderboardSort.allCases, id: \.self) { s in
                let on = s == sort
                Button { pick(s) } label: {
                    Text(s.title)
                        .font(Theme.font(11.5, .semibold))
                        .foregroundStyle(on ? .white : Color(white: 0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if on {
                                Capsule().fill(Theme.blue.opacity(0.85))
                                    .matchedGeometryEffect(id: "sort", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: sort)
    }
}

struct BoardRow: View {
    let row: LeaderboardRow
    var sort: LeaderboardSort = .hours

    var body: some View {
        HStack {
            Text("\(row.rank)")
                .font(Theme.font(12, .bold, design: .rounded))
                .foregroundStyle(row.rank <= 3 ? Theme.blue : Color(white: 0.5))
                .frame(width: 26, alignment: .leading)
            HStack(spacing: 5) {
                Text(row.name).lineLimit(1)
                if row.me {
                    Text("you").font(Theme.font(9, .bold)).tracking(1)
                        .foregroundStyle(Theme.blue)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.blue.opacity(0.18)))
                }
            }
            .font(Theme.font(13, row.me ? .semibold : .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
            // The column the board is sorted by is the bold one.
            Text(HoursMath.duration(row.todayS)).frame(width: 66, alignment: .trailing)
                .font(Theme.font(sort == .hours ? 13 : 12, sort == .hours ? .semibold : .regular, design: .rounded))
                .foregroundStyle(sort == .hours ? .white : Color(white: 0.65))
            Text(HoursMath.duration(row.weekS)).frame(width: 66, alignment: .trailing)
                .font(Theme.font(12, .regular, design: .rounded)).foregroundStyle(Color(white: 0.65))
            Text(row.outputText).frame(width: 58, alignment: .trailing)
                .font(Theme.font(sort == .output ? 13 : 12, sort == .output ? .semibold : .regular, design: .rounded))
                .foregroundStyle(sort == .output ? .white : Color(white: 0.65))
        }
        .help("\(row.blocksToday) block\(row.blocksToday == 1 ? "" : "s") today"
              + (row.outputWeek.map { " · output this week \($0)" } ?? ""))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(row.me ? Theme.blue.opacity(0.16) : Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(row.me ? Theme.blue.opacity(0.55) : .clear, lineWidth: 1))
        .shadow(color: row.me ? Theme.blue.opacity(0.25) : .clear, radius: 8)
    }
}

// MARK: - Join (friend mode)

struct JoinView: View {
    @ObservedObject var model: ControlModel
    @State private var server = BrainConfig.defaultBaseURL
    @State private var code = ""
    @State private var name = NSFullUserName().components(separatedBy: " ").first ?? ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "bolt.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.blue)
                .shadow(color: Theme.blue.opacity(0.9), radius: 16)
            Text("Join a friend's leaderboard")
                .font(Theme.font(22, .semibold))
                .foregroundStyle(.white)
            Text("Your focus hours show up next to theirs, and you get the same thing they do: the timer, the goal check, the score at the end of every block.")
                .font(Theme.font(12.5)).foregroundStyle(Color(white: 0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            VStack(spacing: 10) {
                field("Invite code", text: $code, mono: true)
                field("Your name", text: $name)
                field("Server", text: $server, small: true)
            }
            .padding(.top, 4)

            if !model.joinError.isEmpty {
                Text(model.joinError).font(Theme.font(12)).foregroundStyle(Color.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
            }

            ControlButton(title: model.joinBusy ? "Joining…" : "Join", icon: "person.badge.plus", style: .primary,
                          enabled: !model.joinBusy && !code.trimmingCharacters(in: .whitespaces).isEmpty
                            && !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                model.onJoin(server, code, name)
            }
            .keyboardShortcut(.defaultAction)
            .frame(width: 240)

            HStack(spacing: 18) {
                Button(ModeText.back) { model.onSetupBack() }
                Button(ModeText.notNow) { model.onSkipJoin() }
            }
            .buttonStyle(.plain)
            .font(Theme.font(12))
            .foregroundStyle(Color(white: 0.5))
            Spacer()
        }
        .padding(.horizontal, 36)
    }

    private func field(_ label: String, text: Binding<String>, mono: Bool = false, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(Theme.font(9.5, .semibold)).tracking(1.5)
                .foregroundStyle(Color(white: 0.45))
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(mono ? Theme.font(20, .semibold) : Theme.font(small ? 12 : 15))
                .foregroundStyle(small ? Color(white: 0.65) : .white)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
        .frame(width: 300)
    }
}

// MARK: - The friend's TypeSafe key

/// What both screens show about the key. `result` is the line under the field ("" = none).
struct TypeSafeKeyUI: Equatable {
    var set = false
    var missing = false
    var busy = false
    var result = ""
    var resultOK = false
    /// Own keys: the optional Anthropic key is in the Keychain.
    var anthropicSet = false
}

/// One calm line: no key, so no judging (the timer and everything else keep working).
struct TypeSafeReminder: View {
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(white: 0.5))
            Text(TypeSafeText.reminder)
                .font(Theme.font(12)).foregroundStyle(Color(white: 0.62))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(TypeSafeText.reminderLink, action: open)
                .buttonStyle(.plain)
                .font(Theme.font(12, .semibold))
                .foregroundStyle(Theme.blueSoft)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

/// After Join: "Your TypeSafe key" — same look as the join screen. Save → the brain checks it; "Key works"
/// turns the button into Done. "Later" skips (the reminder line stays until a key is set).
struct TypeSafeKeyStep: View {
    @ObservedObject var model: ControlModel
    @State private var key = ""

    private var k: TypeSafeKeyUI { model.key }
    private var accepted: Bool { k.resultOK && !k.busy }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "key.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.blue)
                .shadow(color: Theme.blue.opacity(0.9), radius: 16)
            Text(TypeSafeText.stepTitle)
                .font(Theme.font(22, .semibold))
                .foregroundStyle(.white)
            Text(TypeSafeText.explainer)
                .font(Theme.font(12.5)).foregroundStyle(Color(white: 0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            VStack(alignment: .leading, spacing: 4) {
                Text(TypeSafeText.fieldLabel.uppercased())
                    .font(Theme.font(9.5, .semibold)).tracking(1.5)
                    .foregroundStyle(Color(white: 0.45))
                SecureField("", text: $key)
                    .textFieldStyle(.plain)
                    .font(Theme.font(15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .disabled(k.busy)
                    .onSubmit(save)
            }
            .frame(width: 300)
            .padding(.top, 4)

            if !k.result.isEmpty {
                Text(k.result).font(Theme.font(12))
                    .foregroundStyle(k.resultOK ? Color.green.opacity(0.85) : Color.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
            }

            if accepted {
                ControlButton(title: TypeSafeText.done, icon: "checkmark", style: .primary) { close() }
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 240)
            } else {
                ControlButton(title: k.busy ? TypeSafeText.saving : TypeSafeText.save, icon: "key.fill", style: .primary,
                              enabled: !k.busy && TypeSafeKeyField.isValid(key)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 240)
                Button(TypeSafeText.later) { close() }
                    .buttonStyle(.plain)
                    .font(Theme.font(12))
                    .foregroundStyle(Color(white: 0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 36)
        .onAppear { key = "" }
        // The key never lingers in the field once the brain has it.
        .onChange(of: model.key.resultOK) { _, ok in if ok { key = "" } }
    }

    private func save() {
        guard !k.busy, TypeSafeKeyField.isValid(key) else { return }
        model.onSaveKey(key)
    }

    private func close() {
        key = ""
        model.onCloseKey()
    }
}

// MARK: - Window

/// Small dark window: opened from the Dock icon (or menus). Closing it only hides it.
final class ControlWindowController: NSObject, NSWindowDelegate {
    let model = ControlModel()
    private var window: NSWindow?
    /// Called when the window appears / is closed (the controller refreshes live data only while visible).
    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { (window?.isVisible ?? false) && !(window?.isMiniaturized ?? true) }

    func show() {
        let w = window ?? makeWindow()
        window = w
        let wasVisible = w.isVisible
        if !wasVisible { w.alphaValue = 0 }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        if !wasVisible { fade([w], to: 1, duration: 0.3) }
        onVisibilityChange?(true)
    }

    func windowWillClose(_ notification: Notification) { onVisibilityChange?(false) }
    func windowDidMiniaturize(_ notification: Notification) { onVisibilityChange?(false) }
    func windowDidDeminiaturize(_ notification: Notification) { onVisibilityChange?(true) }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Hermes Focus"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(white: 0.06, alpha: 1)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace]
        w.delegate = self
        let host = NSHostingView(rootView: ControlView(model: model))
        w.contentView = host
        w.setContentSize(NSSize(width: 400, height: 600))
        // New autosave name: the old one remembered the smaller window's frame.
        if !w.setFrameUsingName("HermesFocusControl3") { w.center() }
        w.setFrameAutosaveName("HermesFocusControl3")
        return w
    }
}
