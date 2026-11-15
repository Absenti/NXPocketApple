import NXPocketKit
import NXPocketSFTP
import NXShellUI
import SwiftUI
import UIKit

/// Looks for Macs on this network. The browse starts when this opens and stops when it closes.
struct DiscoverySheet: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sources: NetworkSources
    @ObservedObject private var discovery: MacDiscovery
    @State private var pairing: DiscoveredMac?

    init(sources: NetworkSources) {
        self.sources = sources
        self.discovery = sources.discovery
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.text(.findMyMac)).font(ShellFont.display(24)).foregroundStyle(ShellInk.primary).padding(.top, 20)
                if discovery.denied {
                    Text(model.text(.localNetworkDenied)).font(.system(size: 13)).foregroundStyle(ShellInk.bad)
                    Button(model.text(.openSettings)) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(ShellButtonStyle())
                } else if discovery.found.isEmpty {
                    if discovery.searching {
                        HStack(spacing: 8) { ProgressView(); Text(model.text(.searchingMacs)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary) }
                    }
                    Text(model.text(.noMacFound)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                }
                ForEach(discovery.found) { mac in
                    Button { choose(mac) } label: {
                        ShellCard(padding: 14) {
                            HStack {
                                Image(systemName: "laptopcomputer").foregroundStyle(ShellInk.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mac.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(ShellInk.primary)
                                    Text("\(mac.host):\(mac.port)").font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                                }
                                Spacer()
                                if known(mac) != nil { ShellPill(model.text(.stateUpToDate), color: ShellInk.good) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button(model.text(.close)) { dismiss() }.buttonStyle(ShellButtonStyle()).padding(.top, 8)
            }
            .padding(.horizontal, 20)
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .sheet(item: $pairing) { mac in
            PairSheet(sources: sources, address: "\(mac.host):\(mac.port)", contactOnAppear: true)
                .environmentObject(model)
                .presentationBackground(ShellInk.background)
                .preferredColorScheme(.dark)
        }
    }

    /// A Mac this iPhone is already paired with: found by its key's fingerprint, whatever address it has now.
    private func known(_ mac: DiscoveredMac) -> SourceRecord? {
        guard let fingerprint = mac.fingerprint, !fingerprint.isEmpty else { return nil }
        return sources.store.records.first { $0.kind == .mac && ($0.pin ?? "").hasPrefix(fingerprint) }
    }

    private func choose(_ mac: DiscoveredMac) {
        if let record = known(mac) {
            sources.updateAddress(of: record, to: mac)
            dismiss()
        } else {
            pairing = mac
        }
    }
}

/// Pairs with a Mac. The QR code is the way in (`PairLinkSheet`); this is for when it cannot be scanned: the Mac's key is
/// shown, then either a number is compared with the one on the Mac's screen or its typed code is entered. Whatever was
/// typed in the address is only where to knock; what makes it the right Mac is the number or the code.
struct PairSheet: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sources: NetworkSources
    @State private var address: String
    let contactOnAppear: Bool
    @State private var contact: (pin: String, name: String, host: String, port: Int)?
    @State private var comparison: NumberPairing?
    @State private var waiting = false
    @State private var code = ""
    @State private var showCode = false
    @State private var deviceName = UIDevice.current.name
    @State private var busy = false
    @State private var message: String?

    init(sources: NetworkSources, address: String, contactOnAppear: Bool) {
        self.sources = sources
        self.contactOnAppear = contactOnAppear
        _address = State(initialValue: address)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.text(.addMacByAddress)).font(ShellFont.display(24)).foregroundStyle(ShellInk.primary).padding(.top, 20)
                if let contact {
                    ShellCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(contact.name).font(.system(size: 17, weight: .bold)).foregroundStyle(ShellInk.primary)
                            Text("\(model.text(.keyLabel)): \(TLSPin.display(contact.pin).prefix(19))…")
                                .font(.system(size: 13, design: .monospaced)).foregroundStyle(ShellInk.primary).textSelection(.enabled)
                            Text(model.text(.compareKeyHint)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                        }
                    }
                    if let comparison {
                        numberCard(comparison)
                    } else {
                        TextField(model.text(.deviceNameLabel), text: $deviceName).textFieldStyle(.roundedBorder)
                        Button(model.text(.pairByNumber)) { compare(contact) }
                            .buttonStyle(ShellButtonStyle(prominent: true)).disabled(busy)
                        DisclosureGroup(isExpanded: $showCode) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(model.text(.pairingCodeHint)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                                TextField(model.text(.pairingCodeLabel), text: $code)
                                    .keyboardType(.numberPad).autocorrectionDisabled()
                                    .font(.system(size: 24, weight: .bold, design: .monospaced)).textFieldStyle(.roundedBorder)
                                Button(model.text(.pairAction)) { pair(contact) }
                                    .buttonStyle(ShellButtonStyle(prominent: true)).disabled(busy || PairingProof.normalise(code) == nil)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text(model.text(.typeCodeInstead)).font(.system(size: 13, weight: .medium)).foregroundStyle(ShellInk.primary)
                        }
                        .tint(ShellInk.secondary)
                    }
                } else {
                    TextField(model.text(.macAddressLabel), text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder)
                    Button(model.text(.sftpConnect)) { reach() }
                        .buttonStyle(ShellButtonStyle(prominent: true)).disabled(busy || address.isEmpty)
                }
                if busy { ProgressView() }
                if let message {
                    Text(message).font(.system(size: 13)).foregroundStyle(ShellInk.bad)
                }
                Button(model.text(.close)) { close() }.buttonStyle(ShellButtonStyle()).padding(.top, 8)
            }
            .padding(.horizontal, 20)
        }
        .onAppear { if contactOnAppear, contact == nil { reach() } }
    }

    /// The number, with the two answers. "Same" is what asks the Mac to let this iPhone in; the Mac still waits for its own Allow.
    private func numberCard(_ comparison: NumberPairing) -> some View {
        ShellCard {
            VStack(spacing: 10) {
                Text(model.text(.sameNumberQuestion)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary)
                Text(comparison.number)
                    .font(.system(size: 40, weight: .bold, design: .monospaced)).foregroundStyle(ShellInk.primary)
                    .minimumScaleFactor(0.6).lineLimit(1)
                if waiting {
                    HStack(spacing: 8) { ProgressView(); Text(model.text(.waitingForMac)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary) }
                } else {
                    Text(model.text(.numberHint)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button(model.text(.numberSame)) { confirm(comparison) }.buttonStyle(ShellButtonStyle(prominent: true))
                        Button(model.text(.numberDifferent)) { differs(comparison) }.buttonStyle(ShellButtonStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func close() {
        if let comparison { Task { await comparison.cancel() } }
        dismiss()
    }

    private func compare(_ contact: (pin: String, name: String, host: String, port: Int)) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                comparison = try await NumberPairing.begin(host: contact.host, port: contact.port, deviceName: deviceName)
            } catch {
                message = model.pairingMessage(error)
            }
        }
    }

    private func confirm(_ comparison: NumberPairing) {
        waiting = true
        message = nil
        Task {
            defer { waiting = false }
            do {
                _ = try await sources.pairMac(comparison: comparison)
                self.comparison = nil
                dismiss()
            } catch {
                message = model.pairingMessage(error)
                self.comparison = nil
            }
        }
    }

    private func differs(_ comparison: NumberPairing) {
        Task { await comparison.cancel() }
        self.comparison = nil
        message = model.text(.pairingDifferent)
    }

    private func reach() {
        guard let target = LocalNetworkAddress.parse(address, defaultPort: 49217) else { message = model.text(.sourceUnreachable); return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let hello = try await PinnedHTTPSSource.hello(host: target.host, port: target.port)
                if let known = sources.store.records.first(where: { $0.kind == .mac && $0.pin == hello.pin }) {
                    // Already paired: only the address is new.
                    var updated = known
                    updated.host = target.host
                    updated.port = target.port
                    sources.store.update(updated)
                    dismiss()
                    return
                }
                contact = (hello.pin, hello.name, target.host, target.port)
            } catch {
                message = model.pairingMessage(error)
            }
        }
    }

    private func pair(_ contact: (pin: String, name: String, host: String, port: Int)) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                _ = try await sources.pairMac(host: contact.host, port: contact.port, code: code, deviceName: deviceName, name: contact.name)
                dismiss()
            } catch {
                message = model.pairingMessage(error)
            }
        }
    }
}

/// What the Mac's QR code opens: the Mac is named, its key is the one in the link, and pairing is one button. Nothing is sent
/// before it is pressed, and network sources are turned on by that same press, since the player chose them by scanning.
struct PairLinkSheet: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sources: NetworkSources
    let link: PairLink
    @State private var deviceName = UIDevice.current.name
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.text(.pairLinkTitle)).font(ShellFont.display(24)).foregroundStyle(ShellInk.primary).padding(.top, 20)
                ShellCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(link.name).font(.system(size: 17, weight: .bold)).foregroundStyle(ShellInk.primary)
                        Text("\(model.text(.keyLabel)): \(TLSPin.display(link.pin).prefix(19))…")
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(ShellInk.primary)
                        Text(model.text(.pairLinkBody)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                    }
                }
                TextField(model.text(.deviceNameLabel), text: $deviceName).textFieldStyle(.roundedBorder)
                Button(model.text(sources.enabled ? .pairAction : .pairLinkTurnOn)) { pair() }
                    .buttonStyle(ShellButtonStyle(prominent: true)).disabled(busy)
                if busy { ProgressView() }
                if let message { Text(message).font(.system(size: 13)).foregroundStyle(ShellInk.bad) }
                Button(model.text(.close)) { dismiss() }.buttonStyle(ShellButtonStyle()).padding(.top, 8)
            }
            .padding(.horizontal, 20)
        }
    }

    private func pair() {
        busy = true
        message = nil
        if !sources.enabled { sources.enabled = true }
        Task {
            defer { busy = false }
            do {
                _ = try await sources.pairMac(link: link, deviceName: deviceName)
                dismiss()
            } catch {
                message = model.pairingMessage(error)
            }
        }
    }
}

extension PairLink: Identifiable {
    public var id: String { pin + secret }
}

/// Adds an SFTP server in three steps: where it is and who logs in, whose key to trust, which folder holds the games. The
/// server's key is shown before a password or a key signature is sent, as `ssh` does.
struct SFTPSheet: View {
    enum Step { case form, trust(SFTPHostKey), folder }
    enum Auth { case password, key }

    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sources: NetworkSources
    @State private var step: Step = .form
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var auth: Auth = .password
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var busy = false
    @State private var message: String?
    @State private var hostKey: String?
    @State private var path = "/"
    @State private var folders: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.text(.addSFTPServer)).font(ShellFont.display(24)).foregroundStyle(ShellInk.primary).padding(.top, 20)
                switch step {
                case .form: form
                case .trust(let key): trust(key)
                case .folder: folder
                }
                if busy { ProgressView() }
                if let message { Text(message).font(.system(size: 13)).foregroundStyle(ShellInk.bad) }
                Button(model.text(.close)) { dismiss() }.buttonStyle(ShellButtonStyle()).padding(.top, 8)
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: steps

    @ViewBuilder
    private var form: some View {
        TextField(model.text(.sourceNameLabel), text: $name).textFieldStyle(.roundedBorder)
        TextField(model.text(.sftpServerLabel), text: $host)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder)
        TextField("\(model.text(.sftpPortLabel)) (\(SFTPConfig.defaultPort))", text: $port).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
        TextField(model.text(.sftpUserLabel), text: $user)
            .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
        Picker(model.text(.sftpAuthLabel), selection: $auth) {
            Text(model.text(.sftpAuthPassword)).tag(Auth.password)
            Text(model.text(.sftpAuthKey)).tag(Auth.key)
        }
        .pickerStyle(.segmented)
        if auth == .password {
            SecureField(model.text(.sftpPasswordLabel), text: $password).textFieldStyle(.roundedBorder)
        } else {
            Text(model.text(.sftpPrivateKeyLabel)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            TextEditor(text: $privateKey)
                .font(.system(size: 11, design: .monospaced)).frame(minHeight: 110)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .scrollContentBackground(.hidden).padding(6)
                .background(ShellInk.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            SecureField(model.text(.sftpPassphraseLabel), text: $passphrase).textFieldStyle(.roundedBorder)
        }
        Button(model.text(.sftpConnect)) { connect() }
            .buttonStyle(ShellButtonStyle(prominent: true))
            .disabled(busy || host.isEmpty || user.isEmpty || (auth == .password ? password.isEmpty : privateKey.isEmpty))
    }

    private func trust(_ key: SFTPHostKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.text(.sftpTrustTitle)).font(.system(size: 18, weight: .bold)).foregroundStyle(ShellInk.primary)
            Text(key.type).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellInk.secondary)
            Text(key.display).font(.system(size: 13, design: .monospaced)).foregroundStyle(ShellInk.primary).textSelection(.enabled)
            Text(model.text(.sftpTrustBody)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            Text(model.text(.sftpKeyHint)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            HStack(spacing: 8) {
                Button(model.text(.sftpTrust)) { hostKey = key.pin; step = .folder; startBrowsing() }.buttonStyle(ShellButtonStyle(prominent: true))
                Button(model.text(.sftpBack)) { step = .form }.buttonStyle(ShellButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var folder: some View {
        Text(model.text(.sftpChooseFolder)).font(.system(size: 15, weight: .semibold)).foregroundStyle(ShellInk.primary)
        Text(path).font(.system(size: 13, design: .monospaced)).foregroundStyle(ShellInk.secondary)
        if path != "/" {
            Button { path = (path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent; loadFolders() } label: {
                Label(model.text(.sftpFolderUp), systemImage: "arrow.up.left").font(.system(size: 14))
            }
            .foregroundStyle(ShellInk.accent)
        }
        if folders.isEmpty, !busy, message == nil { Text(model.text(.sftpNoFolders)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary) }
        ForEach(folders, id: \.self) { entry in
            Button { path = path == "/" ? "/\(entry)" : "\(path)/\(entry)"; loadFolders() } label: {
                HStack { Image(systemName: "folder.fill").foregroundStyle(ShellInk.accent); Text(entry).foregroundStyle(ShellInk.primary); Spacer() }
                    .padding(12).background(ShellInk.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        HStack(spacing: 8) {
            Button(model.text(.sftpUseFolder)) {
                _ = sources.saveSFTP(config(folder: path), credential: credential(), name: name)
                dismiss()
            }
            .buttonStyle(ShellButtonStyle(prominent: true))
            Button(model.text(.sftpBack)) { step = .form; message = nil }.buttonStyle(ShellButtonStyle())
        }
    }

    // MARK: actions

    private func config(folder: String = "/") -> SFTPConfig {
        SFTPConfig(host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? SFTPConfig.defaultPort, user: user,
                   hostKey: hostKey, folder: folder)
    }

    private func credential() -> SFTPCredential {
        auth == .password ? SFTPCredential(password: password)
                          : SFTPCredential(privateKey: privateKey.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
                                           passphrase: passphrase.isEmpty ? nil : passphrase)
    }

    /// Asks for the server's key. The handshake stops there: no password and no signature has been sent.
    private func connect() {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do { step = .trust(try await SFTPSource.hostKey(of: config())) }
            catch { message = model.sftpMessage(error) }
        }
    }

    private func startBrowsing() {
        busy = true
        message = nil
        let source = SFTPSource(config: config(), credential: credential())
        Task {
            do {
                path = try await source.homeDirectory()
                folders = try await source.directories(in: path)
            } catch {
                message = model.sftpMessage(error)
                folders = []
            }
            busy = false
            await source.close()
        }
    }

    private func loadFolders() {
        busy = true
        message = nil
        let source = SFTPSource(config: config(), credential: credential())
        let current = path
        Task {
            do {
                let found = try await source.directories(in: current)
                if path == current { folders = found }
            } catch {
                message = model.sftpMessage(error)
                folders = []
            }
            busy = false
            await source.close()
        }
    }
}

extension ShellHostModel {
    /// What went wrong with a source, in the player's words. `reason` is `NetworkSources.reason(_:)`: a code for what the
    /// screen explains itself, or the source's own sentence.
    public func sourceMessage(_ reason: String) -> String {
        switch reason {
        case "signedOut": return text(.sourceSignedOut)
        case "keyChanged": return text(.sourceKeyChanged)
        case "rebuilding": return text(.stateRebuilding)
        case "notFound": return text(.noGamesOnSource)
        case "buildsRefused": return text(.buildsRefused)
        case "buildBusy": return text(.buildBusy)
        case "buildGone": return text(.buildGone)
        case "savesRefused": return text(.savesRefused)
        case "noRoom": return text(.sourceNoRoom)
        default: return reason.isEmpty ? text(.sourceUnreachable) : reason
        }
    }

    func pairingMessage(_ error: Error) -> String {
        switch error {
        case PairingError.malformedCode: return text(.pairingBadCode)
        case PairingError.refused: return text(.pairingRefused)
        case PackageSourceError.busy: return text(.pairingBusy)
        case PairingError.rateLimited: return text(.pairingRateLimited)
        case PairingError.wrongMac: return text(.pairingWrongMac)
        case PackageSourceError.untrusted: return text(.sourceKeyChanged)
        case PackageSourceError.unreachable, PackageSourceError.malformed: return "\(text(.sourceUnreachable)) \(text(.localNetworkDenied))"
        default: return error.localizedDescription
        }
    }

    func sftpMessage(_ error: Error) -> String {
        switch error {
        case PackageSourceError.unauthorized: return text(.sftpWrongLogin)
        case PackageSourceError.untrusted: return text(.sourceKeyChanged)
        case PackageSourceError.unreachable(let detail):
            return detail.contains("cipher or key in common") ? text(.sftpNoCommonAlgorithms) : "\(text(.sourceUnreachable)) \(detail)"
        case PackageSourceError.malformed(let detail):
            return detail.contains("private key") ? text(.sftpBadKey) : detail
        case PackageSourceError.notFound: return text(.sftpNoFolders)
        default: return error.localizedDescription
        }
    }
}
