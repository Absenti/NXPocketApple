import Foundation
import NXPMacKit
import NXPocketKit
import NXPocketSFTP

/// Adding the player's server, in the steps the phone uses: where it is and who signs in, then the key it presents (shown before a password or
/// a signature is sent, as `ssh` does), then the folder that holds the games, chosen by browsing it. Nothing is kept until the last step.
@MainActor
public final class ServerSetupFlow: ObservableObject {
    public enum Step: Equatable { case form, trust(SFTPHostKey), folder }
    public enum Auth: Hashable { case password, key }

    @Published public var step: Step = .form
    @Published public var name = ""
    @Published public var host = ""
    @Published public var port = ""
    @Published public var user = ""
    @Published public var auth: Auth = .password
    @Published public var password = ""
    /// The private key's text (an ed25519 key in OpenSSH's format), read from a file the player chose.
    @Published public var privateKey = ""
    @Published public var keyFileName = ""
    @Published public var passphrase = ""
    @Published public var busy = false
    @Published public var message: String?
    @Published public var path = "/"
    @Published public var folders: [String] = []
    private var hostKey: String?

    public init() {}

    public var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !user.isEmpty && (auth == .password ? !password.isEmpty : !privateKey.isEmpty)
            && (port.isEmpty || Int(port).map { (1...65_535).contains($0) } == true)
    }

    func config(folder: String = "/") -> SFTPConfig {
        SFTPConfig(host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? SFTPConfig.defaultPort, user: user, hostKey: hostKey, folder: folder)
    }

    func credential() -> SFTPCredential {
        auth == .password ? SFTPCredential(password: password)
                          : SFTPCredential(privateKey: privateKey.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
                                           passphrase: passphrase.isEmpty ? nil : passphrase)
    }

    /// A private key from a file: read as text, bounded, and only if it looks like an OpenSSH key (the file is never kept, only its text, in the keychain).
    public func chooseKeyFile() {
        guard let url = Panel.chooseFile(title: "Choose the private key to sign in with (ed25519, OpenSSH format)", types: [.item]) else { return }
        guard let data = BoundedRead.dataIfPresent(at: url, limit: 64 << 10), let text = String(data: data, encoding: .utf8),
              text.contains("BEGIN OPENSSH PRIVATE KEY") else {
            message = "That file is not an OpenSSH private key. Only ed25519 keys in that format are supported."
            return
        }
        privateKey = text
        keyFileName = url.lastPathComponent
        message = nil
    }

    /// Asks for the server's key. The handshake stops there: no password and no signature has been sent.
    public func connect() {
        busy = true
        message = nil
        let config = config()
        Task {
            defer { busy = false }
            do { step = .trust(try await SFTPSource.hostKey(of: config)) }
            catch { message = AppModel.serverMessage(error) }
        }
    }

    /// The player accepted the key: from now on it is the only one this server may present. The folder browser starts at the user's home.
    public func trust(_ key: SFTPHostKey) {
        hostKey = key.pin
        step = .folder
        busy = true
        message = nil
        let source = SFTPSource(config: config(), credential: credential())
        Task {
            do {
                path = try await source.homeDirectory()
                folders = try await source.directories(in: path)
            } catch {
                message = AppModel.serverMessage(error)
                folders = []
            }
            busy = false
            await source.close()
        }
    }

    public func back() { step = .form; message = nil }

    public func open(_ folder: String) { go(to: path == "/" ? "/\(folder)" : "\(path)/\(folder)") }

    public func up() {
        let parent = (path as NSString).deletingLastPathComponent
        go(to: parent.isEmpty ? "/" : parent)
    }

    private func go(to target: String) {
        path = target
        busy = true
        message = nil
        let source = SFTPSource(config: config(), credential: credential())
        Task {
            do {
                let found = try await source.directories(in: target)
                if path == target { folders = found }
            } catch {
                message = AppModel.serverMessage(error)
                folders = []
            }
            busy = false
            await source.close()
        }
    }

    /// Makes a folder here and goes into it, for a server whose folder for the games does not exist yet.
    public func newFolder(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, SafePath.isSafeComponent(clean) else { message = "That is not a name a folder can have."; return }
        busy = true
        message = nil
        let target = path == "/" ? "/\(clean)" : "\(path)/\(clean)"
        let source = SFTPSource(config: config(), credential: credential())
        Task {
            do {
                try await source.makeDirectory(target)
                path = target
                folders = try await source.directories(in: target)
            } catch {
                message = AppModel.serverMessage(error)
            }
            busy = false
            await source.close()
        }
    }

    /// Keeps the server, with `path` as the folder that holds the games.
    @discardableResult
    public func finish(into model: AppModel) -> Bool {
        do {
            try model.saveServer(config(folder: path), credential: credential(), name: name.trimmingCharacters(in: .whitespaces))
            return true
        } catch {
            message = AppModel.serverMessage(error)
            return false
        }
    }
}
