import SwiftUI
import NXPMacKit
import NXPMacModel

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                deviceList
                phoneSection
                SavesCard()
                sendSection
                if model.queue.contains(where: \.sends) { QueueView() }
                explanation
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Devices").font(.system(size: 22, weight: .semibold)).foregroundStyle(Ink.primary)
            if model.searchingDevices {
                ProgressView().controlSize(.small)
                Text("Searching…").font(.system(size: 12)).foregroundStyle(Ink.secondary)
            } else if let last = model.lastDeviceSearch {
                // The app looks by itself every AppModel.devicePollInterval seconds while it is in front, when it
                // comes to the front, and before every send.
                Text("checked \(last.formatted(date: .omitted, time: .standard)) · again every \(Int(AppModel.devicePollInterval)) s")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
            Spacer()
            Button {
                model.refreshDevices()
            } label: {
                Label("Find devices", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.searchingDevices)
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        if model.devices.isEmpty {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "cable.connector").font(.system(size: 22)).foregroundStyle(Ink.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.searchingDevices && model.lastDeviceSearch == nil ? "Looking for your iPhone…"
                             : (model.deviceProblem ?? "No iPhone found."))
                            .font(.system(size: 13)).foregroundStyle(Ink.primary)
                        Text("Connect it by cable, unlock it and trust this Mac. It appears here by itself, and later over Wi-Fi too.")
                            .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                }
            }
        } else {
            ForEach(model.devices) { device in
                deviceCard(device)
            }
        }
    }

    private func deviceCard(_ device: Device) -> some View {
        let selected = model.selectedDevice?.udid == device.udid
        return Card {
            HStack(spacing: 14) {
                Image(systemName: "iphone").font(.system(size: 26))
                    .foregroundStyle(selected ? Ink.accent : Ink.secondary).frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.primary)
                    Text(device.summary).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    Text(device.udid).font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Pill(text: device.canReceive ? "paired" : "not paired", color: device.canReceive ? Ink.good : Ink.bad)
                if let transport = device.transport { Pill(text: transport) }
                if selected {
                    Pill(text: "selected", color: Ink.accent)
                } else {
                    Button("Use this one") { model.useDevice(device) }
                        .buttonStyle(.bordered)
                        .disabled(!device.canReceive)
                }
            }
        }
    }

    /// What the selected iPhone has installed, read from its `Documents/games` (`DeviceLibrary`).
    @ViewBuilder
    private var phoneSection: some View {
        if let device = model.selectedDevice {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionHeading(text: "On \(device.name)")
                        if model.checkingPhone {
                            ProgressView().controlSize(.small)
                        } else if let checked = model.phoneCheckedAt {
                            Text("read \(checked.formatted(date: .omitted, time: .standard))")
                                .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                        }
                        Spacer()
                        Button("Refresh") { model.refreshPhoneGames() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.accent)
                            .disabled(model.checkingPhone)
                        if !model.phoneGames.isEmpty {
                            Button("Back up all saves") { model.backUpAllSaves() }
                                .buttonStyle(.bordered)
                                .disabled(!model.backingUp.isEmpty || model.checkingPhone)
                        }
                    }
                    if let problem = model.phoneProblem {
                        Text(problem).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled)
                    } else if model.phoneGames.isEmpty && model.phoneCheckedAt != nil {
                        Text("No game installed yet. A game sent shows here once iPorterNX on the iPhone has imported it.")
                            .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                    ForEach(model.phoneGames, id: \.titleID) { game in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(game.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.primary)
                                    Text("\(game.titleID) · \(game.version) · \(game.packageVersion)")
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.secondary)
                                }
                                BackupLine(titleID: game.titleID)
                            }
                            Spacer()
                            if model.backingUp.contains(game.titleID) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Back up saves") { model.backUpSaves(of: [game.titleID]) }
                                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.accent)
                                    .disabled(model.checkingPhone)
                            }
                        }
                    }
                    if !model.phoneGames.isEmpty {
                        Text("Saves are copied to the Mac, never written on the iPhone: once they change (see Saves on this Mac), before a send replaces a game, and with these buttons.")
                            .font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The built games, each with its own Send button: the tab is where a game goes to the phone, so it says what
    /// can be sent rather than sending people back to the library.
    @ViewBuilder
    private var sendSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(text: "Built games")
                if model.games.isEmpty {
                    HStack {
                        Text("No game built yet.").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        Spacer()
                        Button("Build a game") { model.screen = .build }.buttonStyle(.bordered)
                    }
                }
                ForEach(model.games) { game in
                    HStack(spacing: 10) {
                        Thumbnail(image: game.iconURL.flatMap(IconCache.image(contentsOf:)), size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.primary)
                            Text("\(game.titleID) · \(game.packageVersion) · \(game.byteCountText)")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.secondary)
                        }
                        if let phone = model.phoneGame(game.titleID) {
                            Pill(text: phone.packageVersion == game.packageVersion ? "on the iPhone" : "iPhone has \(phone.packageVersion)",
                                 color: phone.packageVersion == game.packageVersion ? Ink.good : Ink.secondary)
                        }
                        Spacer()
                        if let problem = game.problem {
                            Text(problem.detail).font(.system(size: 11)).foregroundStyle(Ink.bad).lineLimit(1)
                        } else if let device = model.selectedDevice {
                            Button {
                                model.queueSend(game, to: device)
                            } label: {
                                Label("Send to \(device.name)", systemImage: "arrow.up.circle")
                            }
                            .buttonStyle(.borderedProminent).tint(Ink.accent).foregroundStyle(.black)
                            .disabled(!game.isReady || model.queue.contains { !$0.phase.isFinished && $0.titleID == game.titleID && $0.sends })
                        } else {
                            Text("connect an iPhone to send").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                        }
                    }
                }
            }
        }
    }

    private var explanation: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(text: "How a game reaches the phone")
                Text("""
                iPorterNX copies the package into the app's Documents/.incoming folder, over the cable or Wi-Fi, and writes a \
                .complete marker last. iPorterNX on the iPhone imports only a transfer that carries that marker, \
                verifies every file, signs the framework with your certificate, and moves it into the library. \
                No reinstall is needed for a new game. A copy that fails or is cancelled is marked, and iPorterNX on \
                the iPhone deletes it when it next opens; one cut off (cable pulled, this app quit) after ten minutes \
                without activity.
                """)
                .font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.system(size: 22, weight: .semibold)).foregroundStyle(Ink.primary)

                UpdateCard()

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeading(text: "Engine")
                        row("NX2Apple engine", model.settings.value.engineRoot.isEmpty ? model.toolchain.engine.root.path : model.settings.value.engineRoot,
                            "The folder that holds scripts/ and dm/. tools/bootstrap.sh syncs it.") { model.chooseEngineFolder() }
                        row("Xcode", model.toolchain.xcode?.path ?? "not found",
                            "The engine needs the iOS SDK. Pick 27.2 when the App Store build is newer.") { model.chooseXcode() }
                        row("Python", model.toolchain.python.path,
                            "Python 3.12+ with lz4, capstone, fonttools, zbic and nsz. Chosen by itself; tools/setup_python.sh makes one.") {
                            model.choosePython()
                        }
                        if let problem = model.pythonProblem {
                            Text(problem).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled)
                        }
                        FieldRow(label: "Status", hint: "Re-checked when a path changes.") {
                            Text(model.engineReport).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeading(text: "Keys")
                        row("prod.keys", model.settings.value.keysFile.isEmpty ? "not set" : model.settings.value.keysFile,
                            "Your console's keys. They identify each package in the games folder (base game, update, DLC, version, icon) and the engine needs them to build. They stay on this Mac: never copied into a package or written to a log.") {
                            model.chooseKeysFile()
                        }
                        if let problem = model.keysProblem, !model.settings.value.keysFile.isEmpty {
                            Text(problem).font(.system(size: 11)).foregroundStyle(Ink.bad)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeading(text: "Packages")
                        row("Output folder", model.settings.value.outputURL.path,
                            "Each build writes one <title ID>.nxgame folder here.") { model.chooseOutputFolder() }
                        row("Engine work folder", model.settings.value.workFolder.isEmpty ? "beside each base game, in the games folder" : model.settings.value.workFolder,
                            "The engine's <title ID>_build folders: extracted game files and shader cache, gigabytes per game. Beside the games, a build reuses what the engine extracted before. Elsewhere, the games folder is only read (a read-only volume, an iCloud folder), and each game is extracted once more there.") {
                            model.chooseWorkFolder()
                        }
                        if !model.settings.value.workFolder.isEmpty {
                            Button("Put them beside the games again") { model.settings.value.workFolder = "" }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.accent)
                        }
                        FieldRow(label: "iPhone app bundle ID", hint: "Must match the app installed on the phone, or Documents is lost.") {
                            TextField("dev.nxpocket.app", text: Binding(get: { model.settings.value.bundleID },
                                                                        set: { model.settings.value.bundleID = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(text: "What iPorterNX never does")
                        ForEach(["Ask for your Apple ID password.",
                                 "Copy prod.keys into a package, a log or a repository.",
                                 "Send anything to a server: the engine runs on this Mac."], id: \.self) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.seal").foregroundStyle(Ink.good).font(.system(size: 12))
                                Text(line).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, _ value: String, _ hint: String, action: @escaping () -> Void) -> some View {
        FieldRow(label: label, hint: hint) {
            HStack(spacing: 8) {
                Text(value).font(.system(size: 12)).foregroundStyle(Ink.primary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: action).buttonStyle(.bordered).font(.system(size: 12))
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
                    .font(.system(size: 10)).foregroundStyle(Ink.good)
            } else {
                Text("saves not backed up yet").font(.system(size: 10)).foregroundStyle(Ink.secondary)
            }
            if let note = model.backupNotes[titleID.uppercased()] {
                Text("· \(note)").font(.system(size: 10))
                    .foregroundStyle(note.hasPrefix("backup failed") ? Ink.bad : Ink.secondary).lineLimit(2)
            }
        }
    }
}
