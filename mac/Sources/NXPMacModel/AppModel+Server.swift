import Foundation
import NXPMacKit
import NXPocketKit
import NXPocketSFTP

/// The player's own SFTP server, as a place to put built games so the phone downloads them from there and the Mac need not be on. It is set
/// up the way the phone sets one up (`ServerSetupFlow`): the server's key shown before anything secret is sent, a password or a key, the
/// folder chosen by browsing. What signs in is in the Mac's keychain; the rest is in the settings.
extension AppModel {
    static let serverAccount = "sftp-server"

    public var serverIsSetUp: Bool { settings.value.server != nil && LauncherKeychain.read(account: Self.serverAccount) != nil }

    /// A client for the server, or nil when none is set up or its secret is gone from the keychain.
    func serverSource(idleTimeout: TimeInterval = SharingLimits.idleTimeout) -> SFTPSource? {
        guard let config = settings.value.server, let secret = LauncherKeychain.read(account: Self.serverAccount),
              let credential = SFTPCredential.decode(secret) else { return nil }
        return SFTPSource(config: config, credential: credential, idleTimeout: idleTimeout)
    }

    /// Remembers a server the setup flow checked: its settings, and its secret in the keychain.
    public func saveServer(_ config: SFTPConfig, credential: SFTPCredential, name: String) throws {
        try LauncherKeychain.store(credential.secret, account: Self.serverAccount)
        settings.value.server = config
        settings.value.serverName = name.isEmpty ? config.host : name
        serverGames = []
        serverStatus = .unknown
        append("server: \(config.user)@\(config.host):\(config.folder) is set up")
        refreshServer()
    }

    public func forgetServer() {
        for task in uploadTasks.values { task.cancel() }
        LauncherKeychain.remove(account: Self.serverAccount)
        settings.value.server = nil
        settings.value.serverName = ""
        serverGames = []
        serverStatus = .unknown
        append("server: forgotten")
    }

    /// Looks at what the server holds: the games in its folder, and whether it answers.
    public func refreshServer() {
        guard let source = serverSource() else { serverStatus = .unknown; return }
        serverStatus = .checking
        Task { @MainActor in
            do {
                let found = try await source.games()
                serverGames = found
                serverStatus = .reachable
            } catch {
                serverStatus = .failed(Self.serverMessage(error))
            }
            await source.close()
        }
    }

    public func uploadToServer(_ game: LocalGame) {
        let titleID = game.titleID
        guard game.isReady, uploads[titleID] == nil, let config = settings.value.server, let source = serverSource() else { return }
        uploads[titleID] = 0
        append("server: sending \(game.title) to \(config.user)@\(config.host):\(config.folder)")
        uploadTasks[titleID] = Task { @MainActor in
            defer { uploads[titleID] = nil; uploadTasks[titleID] = nil }
            do {
                try await source.upload(package: game.root) { fraction in
                    Task { @MainActor in if self.uploads[titleID] != nil { self.uploads[titleID] = fraction } }
                }
                append("server: \(game.title) is on \(config.host)")
                refreshServer()
            } catch let error as NXPocketError where error.code == .cancelled {
                append("server: sending \(game.title) was stopped")
            } catch is CancellationError {
                append("server: sending \(game.title) was stopped")
            } catch {
                append("server: \(game.title) was not sent: \(Self.serverMessage(error))")
            }
            await source.close()
        }
    }

    public func cancelUpload(_ titleID: String) { uploadTasks[titleID]?.cancel() }

    /// What went wrong with the server, in words for the player.
    public static func serverMessage(_ error: Error) -> String {
        switch error {
        case PackageSourceError.unauthorized: return "the server refused the sign-in: the password or the key is not right"
        case PackageSourceError.untrusted: return "the server's key is not the one you accepted: it was changed, or this is not that server"
        case PackageSourceError.unreachable(let detail), PackageSourceError.malformed(let detail): return detail
        case PackageSourceError.notFound: return "that folder is not on the server"
        case let failure as NXPocketError: return failure.detail
        default: return error.localizedDescription
        }
    }
}

/// A built game as one archive, with its hash, to put behind a link only the player knows (`ArchiveExport`).
extension AppModel {
    public func exportArchive(_ game: LocalGame) {
        let titleID = game.titleID
        guard game.isReady, archiving[titleID] == nil,
              let destination = Panel.chooseSaveFile(title: "Where to put the archive of \(game.title)", name: ArchiveExport.suggestedName(for: game), types: [.zip]) else { return }
        archiving[titleID] = 0
        append("archive: making \(destination.lastPathComponent)")
        archiveTasks[titleID] = Task { @MainActor in
            defer { archiving[titleID] = nil; archiveTasks[titleID] = nil }
            do {
                let result = try await ArchiveExport.export(package: game.root, to: destination) { fraction in
                    Task { @MainActor in if self.archiving[titleID] != nil { self.archiving[titleID] = fraction } }
                }
                append("archive: \(destination.lastPathComponent) is ready, SHA-256 \(result.sha256)")
                archiveResult = result
            } catch let error as NXPocketError where error.code == .cancelled {
                append("archive: \(game.title) was stopped")
            } catch {
                append("archive: \(game.title) was not made: \((error as? NXPocketError)?.detail ?? error.localizedDescription)")
            }
        }
    }

    public func cancelArchive(_ titleID: String) { archiveTasks[titleID]?.cancel() }
}

/// The built games as a folder a web server can serve (`WebExport`).
extension AppModel {
    public func exportForWeb() {
        guard !exportingWeb, let destination = Panel.chooseDirectory(title: "Choose the folder to put the web copy of your built games in") else { return }
        exportingWeb = true
        webExportMessage = nil
        let built = settings.value.outputURL
        append("web: exporting the built games to \(destination.path)")
        Task { @MainActor in
            defer { exportingWeb = false }
            do {
                let report = try await Task.detached(priority: .userInitiated) { try WebExport.export(from: built, to: destination) }.value
                let text = "\(report.games) game(s), \(ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file)). Put this folder on your web server and give the iPhone the address."
                webExportMessage = text
                append("web: \(text)")
            } catch {
                let reason = (error as? NXPocketError)?.detail ?? error.localizedDescription
                webExportMessage = "Not exported: \(reason)"
                append("web: not exported: \(reason)")
            }
        }
    }
}
