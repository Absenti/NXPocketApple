import SwiftUI
import NXPMacKit
import NXPMacModel
import NXPocketKit
import NXPocketSFTP

/// Your own server (a NAS, a seedbox): built games are put there over SFTP, so the iPhone downloads them from it and this Mac need not be on.
/// Set up the way the iPhone sets one up: the server's key shown before anything secret is sent, a password or a key, the folder chosen by browsing.
struct ServerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var confirmingForget = false

    var body: some View {
        RowsPage {
            PageTitle(title: "Server", subtitle: "Put your built games on your own server, so the iPhone downloads them from there and this Mac need not be on.")
        } content: {
            if let config = model.settings.value.server { connected(config) } else { empty }
            webCopy
        }
        .sheet(isPresented: $adding) { ServerSetupSheet() }
        .onAppear { if model.serverIsSetUp { model.refreshServer() } }
    }

    // MARK: no server yet

    private var empty: some View {
        SettingsGroup(title: "Your server") {
            SettingRow(symbol: "externaldrive.connected.to.line.below", title: "Add a server",
                       detail: "Any NAS or seedbox that offers SFTP. You sign in with a password or a key, and pick the folder that holds the games.",
                       detailLines: 3) {
                Button("Add…") { adding = true }.buttonStyle(PrimaryButtonStyle(large: true))
            }
        }
    }

    // MARK: a server

    private func connected(_ config: SFTPConfig) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Your server") {
                SettingRow(symbol: "externaldrive.connected.to.line.below", title: model.settings.value.serverName.isEmpty ? config.host : model.settings.value.serverName,
                           detail: "\(config.user)@\(config.host)\(config.port == 22 ? "" : ":\(config.port)") · \(config.folder)", mono: true, detailLines: 2) {
                    statusPill
                    Button { model.refreshServer() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(QuietButtonStyle(large: true)).disabled(model.serverStatus == .checking).help("Look at the server again")
                }
                if case .failed(let reason) = model.serverStatus {
                    SettingRow(symbol: "exclamationmark.triangle", tint: Ink.bad, title: "The server did not answer as expected", detail: reason,
                               detailColor: Ink.bad, detailLines: 3) { EmptyView() }
                }
                SettingRow(symbol: "key", title: "Its key",
                           detail: config.hostKey.map { SFTPHostKey(pin: $0, type: "").display } ?? "not recorded", mono: true, detailLines: 2) { EmptyView() }
                SettingRow(symbol: "slider.horizontal.3", title: "Change the server or the folder",
                           detail: "Sign in again and browse to another folder.") {
                    Button("Change…") { adding = true }.buttonStyle(QuietButtonStyle(large: true))
                }
                SettingRow(symbol: "trash", tint: Ink.bad, title: "Forget this server",
                           detail: "This Mac forgets the password or key. Nothing on the server is touched.") {
                    Button("Forget…") { confirmingForget = true }.buttonStyle(QuietButtonStyle(large: true))
                }
            }
            .confirmationDialog("Forget this server?", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { model.forgetServer() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The games on the server stay there. This Mac stops sending to it until you add it again.")
            }

            SettingsGroup(title: model.serverGames.isEmpty ? "Games on the server" : "Games on the server · \(model.serverGames.count)") {
                if model.serverGames.isEmpty {
                    SettingRow(symbol: "tray", title: model.serverStatus == .checking ? "Looking…" : "Nothing yet",
                               detail: "Right-click a built game in the Library, then Send to my server.", detailLines: 2) { EmptyView() }
                }
                ForEach(model.serverGames) { game in
                    SettingRow(symbol: "gamecontroller", title: game.name,
                               detail: "v\(game.version) · \(ByteCountFormatter.string(fromByteCount: game.codeBytes + game.romfsBytes + game.aocBytes, countStyle: .file))") {
                        if let fraction = model.uploads[game.titleID] { Bar(fraction: fraction).frame(width: 80) }
                    }
                }
            }

            if !model.uploads.isEmpty {
                SettingsGroup(title: "Sending") {
                    ForEach(model.uploads.keys.sorted(), id: \.self) { titleID in
                        SettingRow(symbol: "arrow.up", title: model.games.first { $0.titleID == titleID }?.title ?? titleID,
                                   detail: "\(Int((model.uploads[titleID] ?? 0) * 100)) %") {
                            Button("Stop") { model.cancelUpload(titleID) }.buttonStyle(QuietButtonStyle(large: true))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch model.serverStatus {
        case .unknown: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .reachable: Pill(text: "Connected", color: Ink.good)
        case .failed: Pill(text: "Not reachable", color: Ink.bad)
        }
    }

    // MARK: a web copy

    private var webCopy: some View {
        SettingsGroup(title: "Or a web copy") {
            SettingRow(symbol: "globe", title: "A web copy of my built games",
                       detail: model.webExportMessage ?? "A folder any web server can serve over https (a NAS, a Nextcloud, a bucket). The iPhone adds its address as a Web link: nothing to run on the server.",
                       detailLines: 3) {
                if model.exportingWeb { ProgressView().controlSize(.small) }
                Button("Export…") { model.exportForWeb() }.buttonStyle(QuietButtonStyle(large: true)).disabled(model.exportingWeb)
            }
        }
    }
}

/// The steps of adding a server (`ServerSetupFlow`): the server and who signs in, its key, its folder.
struct ServerSetupSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow = ServerSetupFlow()
    @State private var newFolderName = ""
    @State private var naming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a server").font(.system(size: 22, weight: .heavy))
            switch flow.step {
            case .form: form
            case .trust(let key): trust(key)
            case .folder: folder
            }
            if flow.busy { ProgressView().controlSize(.small) }
            if let message = flow.message { Text(message).font(.system(size: 12.5)).foregroundStyle(Ink.bad).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { prefill() }
    }

    /// Changing a server starts from what is known of it; the secret is asked for again.
    private func prefill() {
        guard let config = model.settings.value.server, flow.host.isEmpty else { return }
        flow.name = model.settings.value.serverName
        flow.host = config.host
        flow.port = config.port == SFTPConfig.defaultPort ? "" : String(config.port)
        flow.user = config.user
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name (optional)", text: $flow.name).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("Server (nas.local)", text: $flow.host).textFieldStyle(.roundedBorder)
                TextField("Port (22)", text: $flow.port).textFieldStyle(.roundedBorder).frame(width: 90)
            }
            TextField("User", text: $flow.user).textFieldStyle(.roundedBorder)
            Picker("", selection: $flow.auth) {
                Text("Password").tag(ServerSetupFlow.Auth.password)
                Text("Key file").tag(ServerSetupFlow.Auth.key)
            }
            .pickerStyle(.segmented).labelsHidden()
            if flow.auth == .password {
                SecureField("Password", text: $flow.password).textFieldStyle(.roundedBorder)
            } else {
                HStack {
                    Button("Choose a key file…") { flow.chooseKeyFile() }
                    Text(flow.keyFileName.isEmpty ? "ed25519, OpenSSH format" : flow.keyFileName).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                SecureField("Passphrase (if it has one)", text: $flow.passphrase).textFieldStyle(.roundedBorder)
            }
            Text("Nothing is sent yet: the next step shows the server's key first.").font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
            Button("Connect") { flow.connect() }.buttonStyle(PrimaryButtonStyle(large: true)).disabled(flow.busy || !flow.canConnect)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func trust(_ key: SFTPHostKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Is this your server's key?").font(.system(size: 15, weight: .bold))
            Text(key.type).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.secondary)
            Text(key.display).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
            Text("Compare it with what your server shows (for example `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on it). Only this key will be accepted from now on: a different one stops the connection before anything secret is sent.")
                .font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Trust this key") { flow.trust(key) }.buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                Button("Back") { flow.back() }.buttonStyle(QuietButtonStyle(large: true))
            }
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which folder holds the games?").font(.system(size: 15, weight: .bold))
            Text(flow.path).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Ink.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    if flow.path != "/" {
                        row("arrow.up.left", "Up") { flow.up() }
                    }
                    ForEach(flow.folders, id: \.self) { entry in row("folder.fill", entry) { flow.open(entry) } }
                    if flow.folders.isEmpty, !flow.busy { Text("No folder here.").font(.system(size: 12)).foregroundStyle(Ink.secondary).padding(10) }
                }
            }
            .frame(height: 200)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if naming {
                HStack {
                    TextField("New folder", text: $newFolderName).textFieldStyle(.roundedBorder)
                    Button("Create") { flow.newFolder(newFolderName); newFolderName = ""; naming = false }.disabled(newFolderName.isEmpty)
                }
            }
            HStack(spacing: 8) {
                Button("Use this folder") { if flow.finish(into: model) { dismiss() } }.buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                Button("New folder…") { naming.toggle() }.buttonStyle(QuietButtonStyle(large: true))
                Button("Back") { flow.back() }.buttonStyle(QuietButtonStyle(large: true))
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Image(systemName: symbol).foregroundStyle(Ink.accent); Text(title); Spacer() }
                .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
