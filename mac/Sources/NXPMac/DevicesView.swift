import SwiftUI
import NXPMacKit
import NXPMacModel

/// The iPhone: whether it is connected, what is on it, and the built games ready to send. Built from rows, like Settings.
struct DevicesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        RowsPage {
            header
            linkHero
        } content: {
            if model.devices.count != 1 { devicesGroup }
            if let device = model.selectedDevice { phoneGroup(device) }
            builtGroup
            SavesCard()
            if model.queue.contains(where: \.sends) { QueueView() }
            HelpText(title: "How a game reaches the phone", text: """
                NXPocketApple copies the package into the app's Documents/.incoming folder, over the cable or Wi-Fi, and \
                writes a .complete marker last. The app on the iPhone imports only a transfer that carries that marker, \
                verifies every file, signs the framework with your certificate, and moves it into the library. No reinstall \
                is needed for a new game. A copy that fails or is cancelled is marked, and the iPhone deletes it when the \
                app next opens; one cut off (cable pulled, this app quit) after ten minutes without activity.
                """)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 10) {
            PageTitle(title: model.selectedDevice?.name ?? "iPhone", subtitle: checkedLine)
            Spacer()
            if model.searchingDevices { ProgressView().controlSize(.small) }
            Button {
                model.refreshDevices()
            } label: {
                Label("Find devices", systemImage: "arrow.clockwise")
            }
            .buttonStyle(QuietButtonStyle(large: true))
            .disabled(model.searchingDevices)
        }
    }

    /// The app looks by itself every AppModel.devicePollInterval seconds while it is in front, when it comes to the
    /// front, and before every send.
    private var checkedLine: String {
        if model.searchingDevices { return "Searching…" }
        guard let last = model.lastDeviceSearch else { return "No search yet" }
        return "checked \(last.formatted(date: .omitted, time: .standard)) · again every \(Int(AppModel.devicePollInterval)) s"
    }

    /// The Mac, the cable, the iPhone: what is connected, at a glance.
    private var linkHero: some View {
        let device = model.selectedDevice
        return HStack(spacing: 22) {
            endpoint(title: "This Mac") {
                Image(systemName: "laptopcomputer").font(.system(size: 36, weight: .light)).foregroundStyle(Ink.primary)
            }
            ZStack {
                DashedLine()
                    .stroke(Ink.accent.opacity(device == nil ? 0.2 : 0.5), style: StrokeStyle(lineWidth: 3, dash: [9, 7]))
                    .frame(height: 3)
                Text(device.map { "Connected · \($0.transport ?? "usb")" } ?? "No iPhone")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(device == nil ? Ink.secondary : Ink.accent)
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(Ink.background, in: Capsule())
                    .overlay(Capsule().strokeBorder(Ink.accent.opacity(device == nil ? 0.2 : 0.5)))
            }
            .frame(maxWidth: .infinity)
            endpoint(title: device?.name ?? "iPhone", glow: device != nil) {
                PocketMark(size: 56).opacity(device == nil ? 0.35 : 1)
            }
        }
        .padding(.vertical, 20).padding(.horizontal, 30)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .stitched(radius: 20, color: Ink.accent.opacity(device == nil ? 0.2 : 0.45))
    }

    private func endpoint<Content: View>(title: String, glow: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            content()
                .frame(width: 96, height: 96)
                .background(Ink.raised, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(glow ? Ink.accent.opacity(0.5) : Ink.line))
                .shadow(color: glow ? Ink.accent.opacity(0.14) : .clear, radius: 24)
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.primary).lineLimit(1)
        }
    }

    // MARK: Groups

    /// Which iPhone to use: one line each, or one line saying none was found.
    private var devicesGroup: some View {
        SettingsGroup(title: "Devices") {
            if model.devices.isEmpty {
                SettingRow(symbol: "cable.connector", title: model.searchingDevices && model.lastDeviceSearch == nil ? "Looking for your iPhone…" : "No iPhone found",
                           detail: model.deviceProblem ?? "Connect it by cable, unlock it and trust this Mac.", detailLines: 2) { EmptyView() }
            }
            ForEach(model.devices) { device in
                let selected = model.selectedDevice?.udid == device.udid
                SettingRow(symbol: "iphone", tint: selected ? Ink.accent : Ink.secondary, title: device.name, detail: device.summary) {
                    Pill(text: device.canReceive ? "paired" : "not paired", color: device.canReceive ? Ink.good : Ink.bad)
                    if selected {
                        Pill(text: "selected", color: Ink.accent)
                    } else {
                        Button("Use this one") { model.useDevice(device) }
                            .buttonStyle(QuietButtonStyle(large: true)).disabled(!device.canReceive)
                    }
                }
            }
        }
    }

    /// What the selected iPhone has installed, read from its `Documents/games` (`DeviceLibrary`).
    private func phoneGroup(_ device: Device) -> some View {
        SettingsGroup(title: "On \(device.name)") {
            if model.checkingPhone {
                ProgressView().controlSize(.small)
            }
            if !model.phoneGames.isEmpty {
                Button("Back up all saves") { model.backUpAllSaves() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!model.backingUp.isEmpty || model.checkingPhone)
            }
            Button("Refresh") { model.refreshPhoneGames() }.buttonStyle(QuietButtonStyle()).disabled(model.checkingPhone)
        } content: {
            if let problem = model.phoneProblem {
                SettingRow(symbol: "exclamationmark.triangle", tint: Ink.bad, title: "Could not read the iPhone", detail: problem,
                           detailColor: Ink.bad, detailLines: 3) { EmptyView() }
            } else if model.phoneGames.isEmpty && model.phoneCheckedAt != nil {
                SettingRow(symbol: "tray", title: "No game installed yet",
                           detail: "A game sent shows here once the app on the iPhone has imported it.", detailLines: 2) { EmptyView() }
            }
            ForEach(model.phoneGames, id: \.titleID) { game in
                SettingRow(symbol: "gamecontroller", title: game.name,
                           detail: "\(game.version.isEmpty ? "version unknown" : "v\(game.version)") · \(backupText(game.titleID))") {
                    if model.backingUp.contains(game.titleID) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Back up saves") { model.backUpSaves(of: [game.titleID]) }
                            .buttonStyle(QuietButtonStyle(large: true)).disabled(model.checkingPhone)
                    }
                }
            }
        }
    }

    private func backupText(_ titleID: String) -> String {
        if let note = model.backupNotes[titleID.uppercased()] { return Friendly.text(note) }
        guard let date = model.lastBackup(titleID) else { return "saves not backed up yet" }
        return "saves backed up \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The built games, each with its own Send button: this screen is where a game goes to the phone, so it says what
    /// can be sent rather than sending people back to the library.
    private var builtGroup: some View {
        SettingsGroup(title: "Built games") {
            if model.games.isEmpty {
                SettingRow(symbol: "hammer", title: "No game built yet", detail: "Add a game to build it, then send it here.") {
                    Button("Add a game") { model.screen = .build }.buttonStyle(PrimaryButtonStyle(large: true))
                }
            }
            ForEach(model.games) { game in
                SettingRow(image: game.iconURL.flatMap(IconCache.image(contentsOf:)), title: game.title,
                           detail: game.problem?.detail ?? "\(game.version.isEmpty ? "" : "v\(game.version) · ")\(game.byteCountText)",
                           detailColor: game.problem == nil ? Ink.secondary : Ink.bad) {
                    if let phone = model.phoneGame(game.titleID) {
                        let same = phone.packageVersion == game.packageVersion
                        Pill(text: same ? "on the iPhone" : "other version on the iPhone", color: same ? Ink.good : Ink.secondary)
                    }
                    if game.problem == nil {
                        if let device = model.selectedDevice {
                            Button { model.queueSend(game, to: device) } label: { Label("Send", systemImage: "arrow.up") }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(!game.isReady || model.queue.contains { !$0.phase.isFinished && $0.titleID == game.titleID && $0.sends })
                        } else {
                            Text("connect an iPhone").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// When a game's saves were last copied to the Mac, or why the last try copied nothing.
struct BackupLine: View {
    @EnvironmentObject private var model: AppModel
    let titleID: String

    var body: some View {
        HStack(spacing: 6) {
            if let date = model.lastBackup(titleID) {
                Text("saves backed up \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(Ink.good)
            } else {
                Text("saves not backed up yet").font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
            if let note = model.backupNotes[titleID.uppercased()] {
                Text("· \(Friendly.text(note))").font(.system(size: 11))
                    .foregroundStyle(note.hasPrefix("backup failed") ? Ink.bad : Ink.secondary).lineLimit(2)
            }
        }
    }
}
