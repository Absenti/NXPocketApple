import NXPocketKit
import NXShellUI
import SwiftUI

/// The variables the detail screen puts first, as two switches under Play: the console mode, shown as Handheld mode, and the
/// frame-rate counter. The other rows follow in the game's own sections.
enum QuickSetting {
    static let opMode = "DM_OPMODE"
    static let handheldValue = "0", dockedValue = "1"
    static let fpsCounter = "DM_SHOW_FPS"

    /// Handheld mode is a switch only when the game offers exactly the two console modes.
    static func offersHandheld(_ settings: GameSettings) -> Bool {
        guard let s = settings.setting(opMode), s.kind == "choice" else { return false }
        return Set(s.options?.compactMap(\.first) ?? []) == [handheldValue, dockedValue]
    }

    static func shown(_ settings: GameSettings) -> Set<String> {
        var shown: Set<String> = []
        if offersHandheld(settings) { shown.insert(opMode) }
        if settings.setting(fpsCounter)?.kind == "toggle" { shown.insert(fpsCounter) }
        return shown
    }
}

/// Handheld mode and the frame-rate counter, right under Play.
struct QuickSettingsCard: View {
    @EnvironmentObject private var model: ShellHostModel
    let settings: GameSettings
    let choose: (String, String) -> Void

    var body: some View {
        let shown = QuickSetting.shown(settings)
        if !shown.isEmpty {
            ShellCard {
                VStack(alignment: .leading, spacing: 12) {
                    if shown.contains(QuickSetting.opMode), let s = settings.setting(QuickSetting.opMode) {
                        SettingSwitch(title: model.text(.handheldMode), note: model.text(.handheldModeNote),
                                      isOn: settings.value(of: s) == QuickSetting.handheldValue, lock: settings.lock(of: s)) {
                            choose(s.env, $0 ? QuickSetting.handheldValue : QuickSetting.dockedValue)
                        }
                    }
                    if shown.contains(QuickSetting.fpsCounter), let s = settings.setting(QuickSetting.fpsCounter) {
                        SettingSwitch(title: model.text(.fpsCounter), note: nil,
                                      isOn: settings.value(of: s) == s.onValue, lock: settings.lock(of: s)) {
                            choose(s.env, $0 ? s.onValue : s.offValue)
                        }
                    }
                }
            }
        }
    }
}

/// The rest of the game's `launcher.json`, one card per section, in the list's order. Sub-settings appear while the
/// setting they depend on has the value they need. The Controls card also leads to the touch controls, shared by all games.
struct GameSettingsCards: View {
    @EnvironmentObject private var model: ShellHostModel
    let settings: GameSettings
    let choose: (String, String) -> Void
    let reset: () -> Void
    let openTouchControls: () -> Void

    var body: some View {
        let sections = settings.sections(excluding: QuickSetting.shown(settings))
        VStack(alignment: .leading, spacing: 16) {
            if settings.list.isEmpty {
                ShellCard {
                    VStack(alignment: .leading, spacing: 8) {
                        ShellSectionLabel(model.text(.gameSettings))
                        Text(model.text(.noSettings)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                    }
                }
            }
            ForEach(sections, id: \.title) { section in
                ShellCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ShellSectionLabel(section.title)
                        ForEach(section.rows) { row($0) }
                        if section.title == "Controls" { touchControlsRow }
                    }
                }
            }
            if !sections.contains(where: { $0.title == "Controls" }) {
                ShellCard { touchControlsRow }
            }
            if !settings.list.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button(model.text(.resetSettings), action: reset)
                        .buttonStyle(ShellButtonStyle())
                        .disabled(!settings.hasChoices)
                    Text(model.text(.settingsAtPlay)).font(.system(size: 11)).foregroundStyle(ShellInk.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ s: LauncherSetting) -> some View {
        let label = s.label
        let note = s.note.isEmpty ? nil : s.note
        let value = settings.value(of: s)
        switch s.kind {
        case "toggle":
            SettingSwitch(title: label, note: note, isOn: value == s.onValue, lock: settings.lock(of: s)) {
                choose(s.env, $0 ? s.onValue : s.offValue)
            }
        case "range":
            SettingSlider(setting: s, title: label, note: note, value: value, lock: settings.lock(of: s)) {
                choose(s.env, $0)
            }
        default:
            SettingChoice(setting: s, title: label, note: note, value: value, lock: settings.lock(of: s)) {
                choose(s.env, $0)
            }
        }
    }

    private var touchControlsRow: some View {
        Button(action: openTouchControls) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text(.touchControls)).font(.system(size: 14)).foregroundStyle(ShellInk.primary)
                    Text(model.text(.allGames)).font(.system(size: 11)).foregroundStyle(ShellInk.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What a fixed row says instead of letting itself be changed.
@MainActor
private func lockText(_ lock: SettingLock?, _ model: ShellHostModel) -> String? {
    switch lock {
    case .envFile(let name): return "\(model.text(.setIn)) \(name)"
    case .launch: return model.text(.setAtLaunch)
    case nil: return nil
    }
}

private struct SettingCaption: View {
    let note: String?
    let lock: String?

    var body: some View {
        if let lock { Text(lock).font(.system(size: 11)).foregroundStyle(ShellInk.accent) }
        if let note { Text(note).font(.system(size: 11)).foregroundStyle(ShellInk.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}

struct SettingSwitch: View {
    @EnvironmentObject private var model: ShellHostModel
    let title: String
    let note: String?
    let isOn: Bool
    let lock: SettingLock?
    let set: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(get: { isOn }, set: set)) {
                Text(title).font(.system(size: 14)).foregroundStyle(ShellInk.primary)
            }
            .tint(ShellInk.accent)
            .disabled(lock != nil)
            SettingCaption(note: note, lock: lockText(lock, model))
        }
    }
}

struct SettingChoice: View {
    @EnvironmentObject private var model: ShellHostModel
    let setting: LauncherSetting
    let title: String
    let note: String?
    let value: String
    let lock: SettingLock?
    let set: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 14)).foregroundStyle(ShellInk.primary)
                Spacer(minLength: 8)
                Picker(title, selection: Binding(get: { value }, set: set)) {
                    ForEach(setting.options ?? [], id: \.self) { option in
                        Text(option[1])
                            .tag(option[0])
                    }
                }
                .pickerStyle(.menu)
                .tint(ShellInk.accent)
                .disabled(lock != nil)
            }
            SettingCaption(note: note, lock: lockText(lock, model))
        }
    }
}

/// A slider keeps its value while the finger is on it and keeps the choice when it lets go, so a drag writes the file once.
struct SettingSlider: View {
    @EnvironmentObject private var model: ShellHostModel
    let setting: LauncherSetting
    let title: String
    let note: String?
    let value: String
    let lock: SettingLock?
    let set: (String) -> Void

    @State private var dragging: Double?

    var body: some View {
        let lo = setting.min ?? 0, hi = Swift.max(setting.max ?? 1, lo + 0.000_1)
        let shown = dragging ?? Double(value) ?? Double(setting.def) ?? lo
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 14)).foregroundStyle(ShellInk.primary)
                Spacer(minLength: 8)
                Text(Self.format(shown, step: setting.step)).font(.system(size: 13).monospacedDigit()).foregroundStyle(ShellInk.secondary)
            }
            Slider(value: Binding(get: { Swift.min(Swift.max(shown, lo), hi) }, set: { dragging = $0 }),
                   in: lo...hi, step: setting.step ?? 0.1) { editing in
                if !editing, let dragging {
                    set(Self.format(dragging, step: setting.step))
                    self.dragging = nil
                }
            }
            .tint(ShellInk.accent)
            .disabled(lock != nil)
            SettingCaption(note: note, lock: lockText(lock, model))
        }
    }

    /// As many decimals as the step has: 0.05 gives two, 0.1 one, 1 none.
    static func format(_ value: Double, step: Double?) -> String {
        let decimals = step.map { s -> Int in
            var digits = 0, v = s
            while digits < 4 && abs(v - v.rounded()) > 1e-9 { v *= 10; digits += 1 }
            return digits
        } ?? 2
        return String(format: "%.\(decimals)f", value)
    }
}

/// The touch controls' size, the left stick's place and the way to the layout editor. One set for every game.
struct TouchControlsCard: View {
    @EnvironmentObject private var model: ShellHostModel

    var body: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 12) {
                ShellSectionLabel(model.text(.touchControls))
                Text(model.text(.touchSize)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary)
                Picker(model.text(.touchSize), selection: Binding(get: { model.touch.size }, set: { size in
                    var touch = model.touch
                    touch.size = size
                    model.setTouch(touch)
                })) {
                    Text(model.text(.touchSmall)).tag(TouchControls.Size.small)
                    Text(model.text(.touchMedium)).tag(TouchControls.Size.medium)
                    Text(model.text(.touchLarge)).tag(TouchControls.Size.large)
                }
                .pickerStyle(.segmented)
                Text(model.text(.touchStick)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary)
                Picker(model.text(.touchStick), selection: Binding(get: { model.touch.stick }, set: { stick in
                    var touch = model.touch
                    touch.stick = stick
                    model.setTouch(touch)
                })) {
                    Text(model.text(.stickCorner)).tag(TouchControls.Stick.corner)
                    Text(model.text(.stickHigher)).tag(TouchControls.Stick.higher)
                    Text(model.text(.stickInward)).tag(TouchControls.Stick.inward)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    Button(model.text(.arrangeControls)) { TouchLayoutEditorWindow.present(model) }
                        .buttonStyle(ShellButtonStyle())
                    let moved = TouchLayout.Kind.allCases.reduce(0) { count, kind in
                        count + TouchLayout.Control.allCases.filter { !model.touch.layout[kind, $0].isZero }.count
                    }
                    if moved > 0 { ShellPill("\(model.text(.controlsMoved)) \(moved)") }
                }
                Text(model.text(.touchControlsBody)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            }
        }
    }
}
