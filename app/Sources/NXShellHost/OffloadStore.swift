import Foundation
import NXPocketKit

/// A game taken off this iPhone to free its space, whose tile stays in the library. Its saves, settings and logs stay too
/// (`GameRemoval` with the saves kept), so downloading it again from a source puts the player back where they were.
public struct OffloadedGame: Codable, Equatable, Identifiable, Sendable {
    public var titleID: String
    public var name: String
    public var version: String
    /// What leaving it freed, for the tile.
    public var bytes: Int64
    public var date: Date
    public var id: String { titleID }
}

/// What was offloaded, in `Documents/.offloaded/`: one small index and each game's icon, copied before the game goes (the
/// tile has nothing else to draw from). Never more than a few hundred kilobytes.
public struct OffloadStore {
    let folder: URL
    private let fileManager: FileManager

    public init(documents: URL, fileManager: FileManager = .default) {
        folder = documents.appendingPathComponent(".offloaded", isDirectory: true)
        self.fileManager = fileManager
    }

    private var index: URL { folder.appendingPathComponent("index.json") }

    public func records() -> [OffloadedGame] {
        guard let data = BoundedRead.dataIfPresent(at: index, limit: 1 << 20),
              let found = try? JSONDecoder().decode([OffloadedGame].self, from: data) else { return [] }
        // A title ID names a file below: only a game's is accepted from a file anyone can edit through Files.
        return found.filter { TitleID.isGame($0.titleID) }
    }

    public func iconURL(for titleID: String) -> URL? {
        guard TitleID.isGame(titleID) else { return nil }
        let url = folder.appendingPathComponent("\(titleID).icon")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Keeps the game's icon and a line about it. The caller removes the game afterwards.
    public func add(_ game: OffloadedGame, iconFrom icon: URL?) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        if let icon {
            let target = folder.appendingPathComponent("\(game.titleID).icon")
            try? fileManager.removeItem(at: target)
            try? fileManager.copyItem(at: icon, to: target)
        }
        var all = records().filter { $0.titleID != game.titleID }
        all.append(game)
        try JSONEncoder().encode(all).write(to: index, options: .atomic)
    }

    /// Drops a game's line and icon: it is installed again, or the player forgot it.
    public func remove(titleID: String) {
        guard TitleID.isGame(titleID) else { return }
        try? fileManager.removeItem(at: folder.appendingPathComponent("\(titleID).icon"))
        let rest = records().filter { $0.titleID != titleID }
        if rest.isEmpty { try? fileManager.removeItem(at: folder) }
        else { try? JSONEncoder().encode(rest).write(to: index, options: .atomic) }
    }
}
