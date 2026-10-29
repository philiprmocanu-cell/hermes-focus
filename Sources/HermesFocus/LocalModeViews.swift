import AppKit
import SwiftUI
import FocusCore

// MARK: - First launch: own keys, or a friend's leaderboard

/// "How do you want to run Hermes Focus?" — two cards. Own keys is first and marked Recommended.
struct ModeChoiceView: View {
    @ObservedObject var model: ControlModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bolt.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.blue)
                .shadow(color: Theme.blue.opacity(0.9), radius: 16)
            Text(ModeText.chooseTitle)
                .font(Theme.font(20, .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(ModeText.chooseSubtitle)
                .font(Theme.font(12.5)).foregroundStyle(Color(white: 0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            VStack(spacing: 10) {
                ModeCard(icon: "lock.laptopcomputer", title: ModeText.ownKeysTitle, badge: ModeText.ownKeysBadge,
                         text: ModeText.ownKeysBody, primary: true) { model.onPickOwnKeys() }
            }
            .padding(.top, 6)

            Button(ModeText.notNow) { model.onSkipJoin() }
                .buttonStyle(.plain)
                .font(Theme.font(12))
                .foregroundStyle(Color(white: 0.5))
            Spacer()
        }
        .padding(.horizontal, 30)
    }
}

struct ModeCard: View {
    let icon: String
    let title: String
    let badge: String?
    let text: String
    let primary: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(primary ? Theme.blue : Color(white: 0.6))
                    .frame(width: 24)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(Theme.font(14.5, .semibold))
                            .foregroundStyle(.white)
                        if let badge {
                            Text(badge.uppercased())
                                .font(Theme.font(9, .bold)).tracking(1)
                                .foregroundStyle(Theme.blueSoft)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.blue.opacity(0.18)))
                        }
                    }
                    Text(text)
                        .font(Theme.font(12)).foregroundStyle(Color(white: 0.6))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 330, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hover ? 0.09 : (primary ? 0.06 : 0.035))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(primary ? Theme.blue.opacity(hover ? 0.8 : 0.5) : Color.white.opacity(hover ? 0.2 : 0.1),
                              lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - The two key steps (own keys)

/// The shared look of both key steps: icon, title, explainer, one secure field and the line under it.
private struct KeyStepFrame<Buttons: View>: View {
    let icon: String
    let title: String
    let explainer: String
    let extra: String?
    let fieldLabel: String
    @Binding var key: String
    let busy: Bool
    let result: String
    let resultOK: Bool
    let onSubmit: () -> Void
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.blue)
                .shadow(color: Theme.blue.opacity(0.9), radius: 16)
            Text(title)
                .font(Theme.font(21, .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(explainer)
                .font(Theme.font(12.5)).foregroundStyle(Color(white: 0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let extra {
                Text(extra)
                    .font(Theme.font(11.5)).foregroundStyle(Color(white: 0.42))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(fieldLabel.uppercased())
                    .font(Theme.font(9.5, .semibold)).tracking(1.5)
                    .foregroundStyle(Color(white: 0.45))
                SecureField("", text: $key)
                    .textFieldStyle(.plain)
                    .font(Theme.font(15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .disabled(busy)
                    .onSubmit(onSubmit)
            }
            .frame(width: 300)
            .padding(.top, 4)

            if !result.isEmpty {
                Text(result).font(Theme.font(12))
                    .foregroundStyle(resultOK ? Color.green.opacity(0.85) : Color.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            buttons()
            Spacer()
        }
        .padding(.horizontal, 36)
    }
}

private struct StepLinks: View {
    let links: [(String, () -> Void)]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(links.enumerated()), id: \.offset) { _, l in
                Button(l.0, action: l.1)
            }
        }
        .buttonStyle(.plain)
        .font(Theme.font(12))
        .foregroundStyle(Color(white: 0.5))
    }
}

/// Own keys, step 1: the TypeSafe key (needed to be judged). Saved → the local brain checks it → "Key works"
/// → Next. "Later" closes the setup (the "Add your TypeSafe key" line stays until a key is set).
struct LocalTypeSafeStep: View {
    @ObservedObject var model: ControlModel
    @State private var key = ""

    private var k: TypeSafeKeyUI { model.key }
    private var accepted: Bool { k.resultOK && !k.busy }

    var body: some View {
        KeyStepFrame(icon: "key.fill", title: TypeSafeText.stepTitle, explainer: ModeText.typesafeExplainer, extra: nil,
                     fieldLabel: TypeSafeText.fieldLabel, key: $key, busy: k.busy, result: k.result,
                     resultOK: k.resultOK, onSubmit: save) {
            if accepted || (k.set && TypeSafeKeyField.clean(key) == nil && !k.busy) {
                ControlButton(title: ModeText.next, icon: "arrow.right", style: .primary) { model.onSetupNext() }
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 240)
                StepLinks(links: [(ModeText.back, { model.onSetupBack() })])
            } else {
                ControlButton(title: k.busy ? TypeSafeText.saving : TypeSafeText.save, icon: "key.fill", style: .primary,
                              enabled: !k.busy && TypeSafeKeyField.isValid(key)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 240)
                StepLinks(links: [(ModeText.back, { model.onSetupBack() }), (TypeSafeText.later, { model.onCloseSetup() })])
            }
        }
        .onAppear { key = "" }
        .onChange(of: model.key.resultOK) { _, ok in if ok { key = "" } }
    }

    private func save() {
        guard !k.busy, TypeSafeKeyField.isValid(key) else { return }
        model.onSaveKey(key)
    }
}

/// Own keys, step 2 (optional): the Anthropic key. Saved straight into the Keychain → "Key saved" → Done.
struct AnthropicKeyStep: View {
    @ObservedObject var model: ControlModel
    @State private var key = ""

    private var k: TypeSafeKeyUI { model.key }

    var body: some View {
        KeyStepFrame(icon: "sparkles", title: ModeText.anthropicTitle, explainer: ModeText.anthropicExplainer,
                     extra: ModeText.anthropicWhere, fieldLabel: ModeText.anthropicField, key: $key, busy: false,
                     result: k.result, resultOK: k.resultOK, onSubmit: save) {
            if k.resultOK {
                ControlButton(title: TypeSafeText.done, icon: "checkmark", style: .primary) { model.onCloseSetup() }
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 240)
            } else {
                ControlButton(title: TypeSafeText.save, icon: "key.fill", style: .primary,
                              enabled: AnthropicKeyField.isValid(key)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 240)
                StepLinks(links: [(ModeText.back, { model.onSetupBack() }), (ModeText.skip, { model.onCloseSetup() })])
            }
        }
        .onAppear { key = "" }
        .onChange(of: model.key.resultOK) { _, ok in if ok { key = "" } }
    }

    private func save() {
        guard AnthropicKeyField.isValid(key) else { return }
        model.onSaveAnthropicKey(key)
    }
}

// MARK: - Settings on the goal screen (own keys)

/// Own keys only, under the clean focus switches: both keys (set / not set · Change · Remove), where the data
/// lives (Show in Finder) and the Health line.
struct LocalSettings: View {
    @ObservedObject var model: OverlayModel

    private var k: TypeSafeKeyUI { model.key }

    var body: some View {
        VStack(spacing: 7) {
            LocalKeyRow(label: TypeSafeText.row(set: k.set), set: k.set, busy: k.busy,
                        prompt: "Paste your TypeSafe key", editing: $model.keyEditing,
                        valid: TypeSafeKeyField.isValid, save: { model.onSaveKey($0) },
                        remove: { model.onRemoveKey() }, onOpen: { model.anthropicEditing = false })
            LocalKeyRow(label: ModeText.anthropicRow(set: k.anthropicSet), set: k.anthropicSet, busy: false,
                        prompt: ModeText.anthropicPrompt, editing: $model.anthropicEditing,
                        valid: AnthropicKeyField.isValid, save: { model.onSaveAnthropicKey($0) },
                        remove: { model.onRemoveAnthropicKey() }, onOpen: { model.keyEditing = false })
            if !k.result.isEmpty {
                Text(k.result)
                    .font(Theme.font(11.5))
                    .foregroundStyle(k.resultOK ? Color.green.opacity(0.7) : Color.orange.opacity(0.8))
            }
            HStack(spacing: 14) {
                Text(ModeText.dataLine(model.localDataPath))
                    .font(Theme.font(11.5))
                    .foregroundStyle(Color(white: 0.42))
                    .lineLimit(1).truncationMode(.middle)
                PlainLink(title: ModeText.showInFinder) { model.onShowLocalData() }
            }
            Text(ModeText.healthTitle + ": " + (model.localHealth.isEmpty ? ModeText.healthUnknown : model.localHealth))
                .font(Theme.font(11.5))
                .foregroundStyle(Color(white: 0.42))
        }
        .animation(.easeOut(duration: 0.18), value: model.keyEditing)
        .animation(.easeOut(duration: 0.18), value: model.anthropicEditing)
        .onAppear { model.onLocalSettingsAppear() }
        .onChange(of: k.resultOK) { _, ok in
            if ok { model.keyEditing = false; model.anthropicEditing = false }
        }
    }
}

/// "TypeSafe key: set" · Change · Remove, and the secure field when Change is open.
struct LocalKeyRow: View {
    let label: String
    let set: Bool
    let busy: Bool
    let prompt: String
    @Binding var editing: Bool
    let valid: (String) -> Bool
    let save: (String) -> Void
    let remove: () -> Void
    let onOpen: () -> Void
    @State private var key = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 14) {
                Text(label)
                    .font(Theme.font(11.5))
                    .foregroundStyle(Color(white: set ? 0.55 : 0.42))
                PlainLink(title: TypeSafeText.change) {
                    editing.toggle()
                    if editing { onOpen() }
                    key = ""
                }
                if set {
                    PlainLink(title: TypeSafeText.remove) {
                        editing = false
                        key = ""
                        remove()
                    }
                    .disabled(busy)
                }
            }
            if editing {
                HStack(spacing: 8) {
                    SecureField("", text: $key, prompt: Text(prompt).foregroundStyle(Color(white: 0.28)))
                        .textFieldStyle(.plain)
                        .font(Theme.font(12.5))
                        .foregroundStyle(Color(white: 0.85))
                        .frame(width: 260)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.04)))
                        .overlay(Capsule().stroke(Color(white: 0.18), lineWidth: 1))
                        .focused($focused)
                        .disabled(busy)
                        .onSubmit(submit)
                    PlainLink(title: busy ? TypeSafeText.saving : TypeSafeText.save, brightness: 0.5, action: submit)
                        .disabled(busy || !valid(key))
                }
                .transition(.opacity)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
            }
        }
    }

    private func submit() {
        guard !busy, valid(key) else { return }
        save(key)
    }
}
