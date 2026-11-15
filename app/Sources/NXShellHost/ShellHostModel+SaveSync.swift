import Foundation
import NXPocketKit
import UIKit

/// Saves copies a source holds from another of the player's devices, and the copies this phone sends by itself.
public struct SyncOffer: Identifiable {
    public var game: InstalledGame
    public var record: SourceRecord
    public var copy: RemoteSaveCopy
    public var id: String { "\(record.id)|\(copy.name)" }
}

extension ShellHostModel {
    /// Starts a game. With *Offer newer saves* on, the sources are asked first (a few seconds at most) whether they hold saves from
    /// another device newer than these; the player decides before the game starts, and the game starts either way.
    public func play(_ game: InstalledGame) {
        guard !gameIsOnScreen else { return }
        guard sources.enabled, sources.syncSaves, syncOffer == nil, !backupDestinations.isEmpty else {
            launchGame(game)
            return
        }
        Task {
            if let offer = await findNewerSaves(for: current(game)) { syncOffer = offer } else { launchGame(game) }
        }
    }

    /// The newest copy among the sources', if it is not one this phone sent or dismissed and is newer than this phone's last session.
    func findNewerSaves(for game: InstalledGame) async -> SyncOffer? {
        let found = await sources.remoteCopies(of: game.id, seconds: 4)
        let all = found.flatMap { entry in entry.copies.map { (record: entry.record, copy: $0) } }
        guard let newest = all.max(by: { $0.copy.date < $1.copy.date }),
              !sources.isMine(newest.copy, titleID: game.id, on: newest.record) else { return nil }
        let last = GameChoices.load(titleID: game.id, documents: documents).lastPlayed ?? .distantPast
        guard newest.copy.date > last.addingTimeInterval(120) else { return nil }
        return SyncOffer(game: game, record: newest.record, copy: newest.copy)
    }

    /// "Use them": the copy is put in place of the saves (these are kept as a copy, as for every import), then the game starts.
    public func acceptSyncOffer() {
        guard let offer = syncOffer else { return }
        syncOffer = nil
        Task {
            switch await restoreRemote(offer.game, copy: offer.copy, from: offer.record) {
            case .success: break
            case .failure(let problem): log.append("the newer saves of \(offer.game.titleID) could not be put in place: \(problem)")
            }
            launchGame(current(offer.game))
        }
    }

    /// "Keep mine": the copy is not offered again, and the game starts.
    public func declineSyncOffer() {
        guard let offer = syncOffer else { return }
        syncOffer = nil
        sources.markSeen(offer.copy, titleID: offer.game.id, on: offer.record)
        launchGame(current(offer.game))
    }

    /// Fetches a copy from a source and puts it in place of the game's saves through the import that exists, which keeps the saves it
    /// replaces. What is there afterwards is what the game's saves look like, so it is not sent back as news.
    public func restoreRemote(_ game: InstalledGame, copy: RemoteSaveCopy, from record: SourceRecord) async -> Result<URL?, SaveProblem> {
        do {
            let file = try await sources.fetchCopy(copy, of: game.id, from: record, temporary: FileManager.default.temporaryDirectory)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let result = await importSaves(game, from: file)
            if case .success = result {
                sources.markSeen(copy, titleID: game.id, on: record)
                sources.markBackedUp(game.id, digest: SaveSnapshots.digest(of: current(game)))
                log.append("saves of \(game.titleID) put back from the copy of \(copy.date.formatted(.iso8601)) on \(record.name)")
            }
            return result
        } catch {
            log.append("copy of the saves of \(game.titleID) from \(record.name) failed: \(error)")
            return .failure(.failed(message(for: error)))
        }
    }

    /// With *Back up my saves automatically* on: the games played since their saves were last sent are sent now, when no game is on
    /// screen (so nothing is being written), at most every five minutes.
    func autoBackupPlayed() {
        guard sources.enabled, sources.autoBackupSaves, !gameIsOnScreen, !importState.isRunning,
              Date().timeIntervalSince(lastAutoBackup) > 300 else { return }
        let records = backupDestinations
        guard !records.isEmpty else { return }
        lastAutoBackup = Date()
        let played = games.filter { !$0.isBroken && hasSaves($0) }
        Task {
            let sent = await sources.backUpPlayedGames(played, to: records, export: { await self.exportSaves($0) })
            if sent > 0 { log.append("sent \(sent) copies of saves by themselves") }
        }
    }
}
