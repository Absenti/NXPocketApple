import SwiftUI
import NXPMacKit
import NXPMacModel

/// The few things a person sets: where the games are, the keys, where packages go, and two switches. The engine, Xcode
/// and Python find themselves; they live in the Advanced sheet.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var advanced = false

    var body: some View {
        RowsPage(maxColumns: 1, singleWidth: 760) {
            PageTitle(title: "Settings", subtitle: "Just what you need to build and send. The rest sets itself up.")
        } content: {
            group("Games") {
                SettingRow(symbol: "folder", title: "Your games folder",
                           detail: model.settings.value.gameFolder.isEmpty ? "not set" : Friendly.path(model.settings.value.gameFolder)) {
                    Button("Change") { model.chooseGameFolder() }.buttonStyle(QuietButtonStyle(large: true))
                }
                SettingRow(symbol: "key", title: "prod.keys", detail: keysDetail) {
                    if !model.settings.value.keysFile.isEmpty, model.keysProblem == nil { Pill(text: "Found", color: Ink.good) }
                    Button("Change") { model.chooseKeysFile() }.buttonStyle(QuietButtonStyle(large: true))
                }
                SettingRow(symbol: "shippingbox", title: "Built games",
                           detail: Friendly.path(model.settings.value.outputURL.path)) {
                    Button("Change") { model.chooseOutputFolder() }.buttonStyle(QuietButtonStyle(large: true))
                }
            }

            group("Sending") {
                SettingRow(symbol: "arrow.up", title: "Send to the iPhone after building",
                           detail: model.selectedDevice.map { "\($0.name) · \($0.transport ?? "usb")" } ?? "No iPhone connected") {
                    Toggle("", isOn: Binding(get: { model.settings.value.sendAfterBuild },
                                             set: { model.settings.value.sendAfterBuild = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingRow(symbol: "arrow.triangle.2.circlepath", title: "Copy the saves by themselves",
                           detail: "When they change on the iPhone. Nothing is written on it.") {
                    Toggle("", isOn: Binding(get: { model.settings.value.autoBackup },
                                             set: { model.settings.value.autoBackup = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }

            EngineGroup()

            SharingGroup()
            group("Application") {
                SettingRow(symbol: "arrow.down.circle",
                           title: "NXPocketApple \(model.runningVersion?.description ?? "(development build)")",
                           detail: "New versions are looked for when the app starts, once a day.") {
                    updatePill
                }
                Button { advanced = true } label: {
                    SettingRow(symbol: "slider.horizontal.3", title: "Advanced",
                               detail: "Xcode, Python, work folder") {
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Note("NXPocketApple never asks for your Apple ID password and never copies prod.keys. Nothing is sent to a server: the engine runs on this Mac, and sharing is off until you turn it on.")
        }
        .sheet(isPresented: $advanced) { AdvancedSettingsView() }
    }

    private var keysDetail: String {
        if model.settings.value.keysFile.isEmpty { return "not set: choose your prod.keys" }
        if let problem = model.keysProblem { return problem }
        return "Stays on this Mac, never copied into a game"
    }

    @ViewBuilder
    private var updatePill: some View {
        switch model.update {
        case .available:
            Button("Update available") { model.showUpdateSheet = true }.buttonStyle(PrimaryButtonStyle())
        case .downloading, .restarting:
            Pill(text: "Updating…", color: Ink.accent)
        case .failed:
            Pill(text: "Not installed", color: Ink.bad)
        case .upToDate:
            Pill(text: "Up to date", color: Ink.good)
        default:
            EmptyView()
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        SettingsGroup(title: title, content: content)
    }
}

/// What the engine runs on, for the rare time it is not found by itself. Everything here has a sensible default.
struct AdvancedSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PageTitle(title: "Advanced", size: 32,
                          subtitle: "You normally never need these: NXPocketApple finds them by itself.")
                VStack(spacing: 0) {
                    SettingRow(symbol: "hammer", title: "Xcode", detail: model.toolchain.xcode.map { Friendly.path($0.path) } ?? "not found") {
                        Button("Change") { model.chooseXcode() }.buttonStyle(QuietButtonStyle(large: true))
                    }
                    SettingRow(symbol: "terminal", title: "Python", detail: Friendly.path(model.toolchain.python.path)) {
                        Button("Change") { model.choosePython() }.buttonStyle(QuietButtonStyle(large: true))
                    }
                    SettingRow(symbol: "internaldrive", title: "Engine work folder",
                               detail: model.settings.value.workFolder.isEmpty ? "Beside each game, in your games folder" : Friendly.path(model.settings.value.workFolder)) {
                        if !model.settings.value.workFolder.isEmpty {
                            Button("Reset") { model.settings.value.workFolder = "" }.buttonStyle(QuietButtonStyle(large: true))
                        }
                        Button("Change") { model.chooseWorkFolder() }.buttonStyle(QuietButtonStyle(large: true))
                    }
                    SettingRow(symbol: "iphone", title: "iPhone app identifier",
                               detail: "Must match the app on the phone, or its games are lost.") {
                        TextField("dev.nxpocketapple.app", text: Binding(get: { model.settings.value.bundleID },
                                                                         set: { model.settings.value.bundleID = $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 200)
                    }
                }
                .background(Ink.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.line))

                HStack(spacing: 14) {
                    Circle().fill(model.pythonProblem == nil ? Ink.good : Ink.bad).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.pythonProblem == nil ? "Engine ready" : "The engine needs attention")
                            .font(.system(size: 13.5, weight: .bold)).foregroundStyle(Ink.primary)
                        Text(Friendly.text(model.pythonProblem ?? model.engineReport))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.secondary)
                            .textSelection(.enabled).lineLimit(3)
                    }
                    Spacer()
                    Button("Check again") { model.refreshToolchain() }.buttonStyle(QuietButtonStyle(large: true))
                        .disabled(model.checkingToolchain)
                }
                .padding(16)
                .background(Ink.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.line))
            }
            .padding(28)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            .overlay(alignment: .top) { Divider().overlay(Ink.line) }
        }
        .frame(width: 720)
        .background(Ink.background)
    }
}
