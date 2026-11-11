import Foundation
import NXPocketKit
import NXShellUI
import UIKit

/// What a game's long press offers beyond Play: its name, its signature alone, its saves and its logs.
extension ShellHostModel {
    // MARK: - Name

    /// The name the player gave the game, else the game's own.
    public func name(of game: InstalledGame) -> String { names[game.id] ?? game.title }

    public func isRenamed(_ game: InstalledGame) -> Bool { names[game.id] != nil }

    /// Keeps the name shown for a game, beside its settings (`GameChoices`). An empty name, or the game's own, brings the
    /// game's own back. The game's files are not touched.
    public func rename(_ game: InstalledGame, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var choices = GameChoices.load(titleID: game.id, documents: documents)
        choices.name = trimmed.isEmpty || trimmed == game.title ? nil : String(trimmed.prefix(80))
        do {
            try choices.save(titleID: game.id, documents: documents)
            names[game.id] = choices.name
            log.append("\(game.titleID) is shown as \"\(choices.name ?? game.title)\"")
        } catch {
            log.append("could not rename \(game.titleID): \(error.localizedDescription)")
        }
    }

    // MARK: - Signing one game

    /// The library's copy of a game: a screen keeps the copy it was opened with, and a signature made since then must count.
    func current(_ game: InstalledGame) -> InstalledGame { games.first { $0.id == game.id } ?? game }

    /// What the player reads for a failure: the refusals with a step to take in their language, the detail otherwise.
    public func message(for error: Error) -> String {
        if let refusal = error as? KeychainRefusal { return keychainMessage(refusal) }
        guard let error = error as? NXPocketError else { return error.localizedDescription }
        switch error.code {
        case .noCertificate: return text(.certificateNeededToPlay)
        case .certificateExpired: return text(.certificateExpiredBody)
        default: return error.detail
        }
    }

    /// A refused keychain write in the player's words, then what the app was signed with, one fact per line.
    public func keychainMessage(_ refusal: KeychainRefusal, facts: SigningFacts = .current) -> String {
        let head = refusal.status == KeychainRefusal.missingEntitlement ? text(.keychainMissingEntitlement) : text(.keychainRefused)
        return (["\(head) (\(refusal.status))."] + facts.lines).joined(separator: "\n")
    }

    /// Signs one game again, as Sign does for every game that needs it. The library's notice shows how it goes.
    public func resign(_ game: InstalledGame) {
        let game = current(game)
        guard !importState.isRunning, !gameIsOnScreen, !game.isBroken, let identity = signingIdentity else { return }
        importState = .running(stage: text(.resigning), fraction: 0, detail: name(of: game))
        Task { [importer] in
            do {
                _ = try await Task.detached(priority: .userInitiated) { try importer.resign(game, identity: identity) }.value
                self.refresh()
                self.importState = .finished("\(self.name(of: game)) · \(self.text(.resignDone))")
            } catch {
                self.importState = .failed(self.message(for: error))
                self.log.append("re-signing \(game.titleID) failed: \(error)")
                self.refresh()
            }
        }
    }

    // MARK: - Saves

    public func hasSaves(_ game: InstalledGame) -> Bool { !GameSaves.entries(in: game.directory).isEmpty }

    /// The game's saves as one .zip to share: the dated folder a Mac copy is, with `backup.json`.
    public func exportSaves(_ game: InstalledGame) async -> Result<URL, SaveProblem> {
        let name = name(of: game)
        let device = UIDevice.current.name
        let exports = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, SaveProblem> in
            do {
                // Each export in its own folder: a share sheet may still be offering an earlier one. Those older than
                // a day were shared or dropped.
                GameSaves.pruneExports(in: exports, olderThan: 24 * 3600)
                let folder = exports.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return .success(try GameSaves.export(game, name: name, device: device, temporary: folder))
            } catch let problem as SaveProblem {
                return .failure(problem)
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
        }.value
        switch result {
        case .success(let url): log.append("saves of \(game.titleID) exported as \(url.lastPathComponent)")
        case .failure(let problem): log.append("export of the saves of \(game.titleID) failed: \(problem)")
        }
        return result
    }

    /// Puts a copy picked in Files in place of the game's saves: a folder the Mac copied or a .zip exported here. The
    /// saves it replaces are kept in `Documents/Saves/<title ID>/<date>/` first (returned, nil when there were none).
    public func importSaves(_ game: InstalledGame, from source: URL) async -> Result<URL?, SaveProblem> {
        let name = name(of: game)
        let device = UIDevice.current.name
        let documents = documents
        let staging = documents.appendingPathComponent("\(GameSaves.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL?, SaveProblem> in
            let scoped = source.startAccessingSecurityScopedResource()
            defer {
                if scoped { source.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: staging)
            }
            do {
                let copy = try GameSaves.read(source, for: game.id, staging: staging)
                return .success(try GameSaves.restore(copy, into: game, name: name, documents: documents, device: device))
            } catch let problem as SaveProblem {
                return .failure(problem)
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
        }.value
        switch result {
        case .success(let kept):
            log.append("saves of \(game.titleID) imported from \(source.lastPathComponent)"
                       + (kept.map { ", the previous ones kept in Saves/\(game.id)/\($0.lastPathComponent)" } ?? ""))
        case .failure(let problem):
            log.append("import of saves for \(game.titleID) from \(source.lastPathComponent) refused: \(problem)")
        }
        refresh()
        return result
    }

    /// The game's saves go, the game stays.
    @discardableResult
    public func deleteSaves(_ game: InstalledGame) -> SaveProblem? {
        defer { refresh() }
        do {
            try GameSaves.delete(in: game)
            log.append("saves of \(game.titleID) deleted")
            return nil
        } catch {
            log.append("could not delete the saves of \(game.titleID): \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// The player's words for why a save copy was not taken.
    public func text(for problem: SaveProblem) -> String {
        switch problem {
        case .noSaves: return text(.noSavesYet)
        case .notACopy: return text(.notASaveCopy)
        case .otherGame(let titleID, let name): return "\(text(.saveOfOtherGame)) \(name.isEmpty ? titleID : "\(name) (\(titleID))")."
        case .incomplete: return text(.saveIncomplete)
        case .empty: return text(.saveCopyEmpty)
        case .failed(let why): return "\(text(.saveUnreadable)) \(why)"
        }
    }

    /// "Original name: X", with the space French puts before a colon.
    public func labelled(_ key: ShellStrings.Key, _ value: String) -> String {
        language.hasPrefix("fr") ? "\(text(key)) : \(value)" : "\(text(key)): \(value)"
    }

    public func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// "Game 5.9 GB · Saves 1.2 MB".
    public func sizesText(_ game: InstalledGame) -> String {
        "\(text(.gameSize)) \(sizeText(game.byteCount)) · \(text(.saves)) \(sizeText(saveBytes(game)))"
    }

    // MARK: - Logs

    /// The app's log first, then the games' logs, newest first; only one game's when `titleID` is given.
    public func logs(for titleID: String? = nil) -> [LogFile] {
        let games = GameLogs.logs(titleID: titleID, documents: documents)
        return titleID == nil ? [GameLogs.appLog(documents: documents)] + games : games
    }

    /// What a log is called on screen: the app's log, or the game's name. A game removed with its saves kept still has
    /// its name in its settings, or else its title ID.
    public func title(of log: LogFile) -> String { log.titleID.map(title(ofTitleID:)) ?? text(.appLog) }

    public func title(ofTitleID titleID: String) -> String {
        // A launch marker too damaged to name its game reads as title ID zero (`LaunchGuard.failedLaunch`).
        if titleID == TitleID(rawValue: 0).description { return text(.aGame) }
        if let game = games.first(where: { $0.id == titleID }) { return name(of: game) }
        return GameChoices.load(titleID: titleID, documents: documents).name ?? titleID
    }

    public func deleteLog(_ log: LogFile) {
        do {
            try GameLogs.remove(log)
        } catch {
            self.log.append("could not delete \(log.url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
