import Foundation
import NXPMacKit
import NXPocketKit

/// The saves of the games on the phone, copied to the Mac (`SaveBackup`): by themselves once they changed
/// (`SaveWatch`, whenever the launcher sees the phone), before a send replaces a game the phone has, and on demand. The
/// phone is only read. A copy goes back through the iPhone app's own import, from iCloud Drive (`sendBackupToiCloud`).
extension AppModel {
    public var savesFolder: URL { SaveBackup.root(in: settings.value.outputURL) }

    public func refreshBackups() {
        let output = settings.value.outputURL
        lastBackups = SaveBackup.latest(in: output)
        savedGames = SaveBackup.catalogue(in: output).map { entry in
            SavedGame(titleID: entry.titleID, name: displayName(titleID: entry.titleID, own: entry.name ?? entry.titleID),
                      backups: entry.backups)
        }
    }

    public func lastBackup(_ titleID: String) -> Date? { lastBackups[titleID.uppercased()] }

    /// Backs up some games now, reading the phone afresh first.
    public func backUpSaves(of titleIDs: [String]) {
        guard let device = selectedDevice else { return }
        Task {
            guard case .success(let snapshot) = await readPhone(device) else {
                for titleID in titleIDs { backupNotes[titleID] = phoneProblem ?? "the iPhone could not be read" }
                return
            }
            _ = await backUp(titleIDs, from: snapshot, device: device)
        }
    }

    public func backUpAllSaves() {
        backUpSaves(of: phoneGames.map(\.titleID))
    }

    var sendIsRunning: Bool {
        queue.contains { if case .sending = $0.phase { return true }; return false }
    }

    /// After a look at the phone: the games whose saves changed since their newest copy (`SaveWatch.due`). Not while a
    /// send runs, which backs up its own game first anyway, nor while another backup runs.
    func backUpChanged(_ snapshot: PhoneSnapshot, device: Device) async {
        guard settings.value.autoBackup, backingUp.isEmpty, !sendIsRunning else { return }
        let output = settings.value.outputURL
        let due = saveWatch.due(snapshot, newest: { SaveBackup.newest(of: $0, in: output) })
        guard !due.isEmpty else { return }
        append("saves: changed on the iPhone, copying \(due.count) game(s)")
        _ = await backUp(due, from: snapshot, device: device)
    }

    /// Before a send: the game's saves, if the phone has the game. Nil when that went well or there was nothing to
    /// copy; the reason otherwise, which the queue puts to the user.
    func backUpBeforeSend(_ titleID: String, device: Device, item: UUID) async -> String? {
        update(item) { $0.phase = .sending(fraction: 0, detail: "backing up the saves on the iPhone") }
        let snapshot: PhoneSnapshot
        switch await readPhone(device) {
        case .success(let found): snapshot = found
        case .failure(let error):
            return "the iPhone could not be read: \((error as? NXPocketError)?.detail ?? error.localizedDescription)"
        }
        guard snapshot.games.contains(where: { $0.titleID == titleID.uppercased() }) else { return nil }
        return await backUp([titleID], from: snapshot, device: device)[titleID]
    }

    /// Copies each game's saves, one after another. Returns the failures, by title ID.
    func backUp(_ titleIDs: [String], from snapshot: PhoneSnapshot, device: Device) async -> [String: String] {
        let backup = SaveBackup(toolchain: toolchain)
        let output = settings.value.outputURL
        var failures: [String: String] = [:]
        for titleID in titleIDs {
            let name = snapshot.games.first { $0.titleID == titleID }?.name
            backingUp.insert(titleID)
            let outcome = await Task.detached(priority: .utility) { () -> Result<SaveBackupOutcome, Error> in
                Result { try backup.backUp(titleID: titleID, name: name, snapshot: snapshot, device: device, outputFolder: output) }
            }.value
            backingUp.remove(titleID)
            switch outcome {
            case .success(.saved(let record, let files, let bytes)):
                backupNotes[titleID] = nil
                append("saves: \(name ?? titleID) — \(files) file(s), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) → \(record.folder.lastPathComponent)")
            case .success(.nothingToSave):
                backupNotes[titleID] = "no save on the iPhone yet"
            case .failure(let error):
                let reason = (error as? NXPocketError)?.detail ?? "\(error)"
                backupNotes[titleID] = "backup failed: \(reason)"
                failures[titleID] = reason
                append("saves: \(name ?? titleID) — backup failed: \(reason)")
            }
        }
        refreshBackups()
        return failures
    }

    // MARK: - Putting a copy back

    /// Where a copy's zip goes: iCloud Drive → Downloads, where the iPhone app's file picker finds it.
    func cloudArchive(of backup: SaveBackupRecord, game: String) -> URL? {
        iCloudDrive?.appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(SaveExport.archiveName(game: game, backup: backup.folder))
    }

    /// Zips a copy (the dated folder and its `backup.json`, as the iPhone app takes it) into iCloud Drive → Downloads,
    /// then follows its upload. Nothing is written on the phone: the player imports it there, in the game's menu.
    ///
    /// Not through `Documents/.incoming/`: the iPhone app takes every finished transfer there for a game package, would
    /// refuse a save copy as one and delete it.
    public func sendBackupToiCloud(_ backup: SaveBackupRecord, game: String) {
        let key = backup.folder.path
        guard let destination = cloudArchive(of: backup, game: game) else {
            saveExports[key] = .failed("iCloud Drive is off on this Mac: turn it on in System Settings → Apple Account → iCloud.")
            return
        }
        saveExports[key] = .copying
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                Result {
                    let manager = FileManager.default
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: destination, create: true)
                    defer { try? manager.removeItem(at: scratch) }
                    let fresh = scratch.appendingPathComponent(destination.lastPathComponent)
                    try SaveExport.zip(backup: backup.folder, to: fresh)
                    if manager.fileExists(atPath: destination.path) {
                        _ = try manager.replaceItemAt(destination, withItemAt: fresh)
                    } else {
                        try manager.moveItem(at: fresh, to: destination)
                    }
                }
            }.value
            if case .failure(let error) = outcome {
                let reason = (error as? NXPocketError)?.detail ?? error.localizedDescription
                self.saveExports[key] = .failed("The copy to iCloud Drive failed: \(reason)")
                return
            }
            self.append("saves: \(destination.lastPathComponent) put in iCloud Drive → Downloads")
            self.watchSaveExport(key: key, file: destination)
        }
    }

    /// Reads a zip's upload state every 2 seconds until it is in iCloud or failed.
    private func watchSaveExport(key: String, file: URL) {
        Task { [weak self] in
            while !Task.isCancelled {
                let state = await Task.detached(priority: .utility) { Self.cloudState(of: file) }.value
                guard let self else { return }
                self.saveExports[key] = state
                guard state == .uploading || state == .copying else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - A question from the queue

    /// Stops a queue item until the user answers `question` with "send anyway" or "cancel".
    func ask(_ id: UUID, _ question: String) async -> Bool {
        if isCancelledForAnswer(id) { return false }
        update(id) { $0.phase = .needsAnswer(question) }
        let answer = await withCheckedContinuation { continuation in
            pendingAnswers[id] = continuation
        }
        if answer { update(id) { $0.phase = .sending(fraction: 0, detail: "starting") } }
        return answer
    }

    public func answer(_ id: UUID, sendAnyway: Bool) {
        guard let continuation = pendingAnswers.removeValue(forKey: id) else { return }
        continuation.resume(returning: sendAnyway)
    }

    private func isCancelledForAnswer(_ id: UUID) -> Bool {
        cancelledItems.contains(id) || queue.first { $0.id == id }?.phase == .cancelled
    }
}

/// A game that has copies of its saves on the Mac, whether or not the phone has it now.
public struct SavedGame: Identifiable, Equatable {
    public var titleID: String
    public var name: String
    /// Newest first.
    public var backups: [SaveBackupRecord]
    public var id: String { titleID }
}
