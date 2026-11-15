import Foundation
import NXPocketKit

/// Copies of saves sent to a Mac or an SFTP server, from the game's menu or from a source's menu in Settings. The copy is the
/// .zip the game menu already exports; what keeps it, and how many, is the destination's business (`SaveDestination`).
extension ShellHostModel {
    /// The sources that can keep a copy: the ones remembered, when network sources are on.
    public var backupDestinations: [SourceRecord] {
        sources.enabled ? sources.store.records.filter { sources.canKeepSaves($0) } : []
    }

    /// One game's saves, and what to tell the player when it is over.
    public func backUpSaves(of game: InstalledGame, to record: SourceRecord) async -> String {
        await sources.backUpSaves([game], to: record, export: { await self.exportSaves($0) })
        defer { sources.dismissBackup() }
        return backupMessage(sources.backup) ?? ""
    }

    /// Every game's saves, to one destination; the progress shows in Settings.
    public func backUpAllSaves(to record: SourceRecord) {
        Task { await sources.backUpSaves(games, to: record, export: { await self.exportSaves($0) }) }
    }

    /// The player's words for where a backup stands; nil while there is nothing to say.
    public func backupMessage(_ state: NetworkSources.BackupState) -> String? {
        switch state {
        case .idle: return nil
        case .running(let done, let total): return "\(text(.backupRunning)) \(done + 1)/\(total)"
        case .failed(let reason): return "\(text(.backupFailed)). \(backupReason(reason))"
        case .finished(let sent, let failed, let first):
            if sent == 0, failed == 0 { return text(.backupNothing) }
            if failed == 0 { return "\(text(.backupDone)) · \(sent)" }
            return "\(text(.backupFailed)) · \(failed)/\(sent + failed). \(first.map(backupReason) ?? "")"
        }
    }

    private func backupReason(_ reason: String) -> String {
        switch reason {
        case "savesRefused": return text(.savesRefused)
        case "noRoom": return text(.sourceNoRoom)
        default: return sourceMessage(reason)
        }
    }
}
