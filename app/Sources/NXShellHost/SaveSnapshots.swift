import CryptoKit
import Foundation
import NXPocketKit

/// A game's saves as they were before each session, kept on the phone: `Documents/SaveSnapshots/<title ID>/<date>/`, the layout
/// of a Mac copy (the `save*` entries and `backup.json`), so a snapshot is restored by the import that already exists and the
/// saves it replaces are kept in their turn. A snapshot is taken when the game is started, never while it runs: the game is not
/// writing, so the copy cannot be torn. One identical to the last (the player did not play, or did not save) is not taken again,
/// and the last `keep` stay. On the same volume the copy is an APFS clone, which costs no space until a save changes.
enum SaveSnapshots {
    static let folderName = "SaveSnapshots"
    static let keep = 20
    /// A game with more saves than this is not copied at every start: the copy would be the wait before the game.
    static let maxBytes: Int64 = 512 << 20
    static let digestName = ".digest"

    struct Snapshot: Identifiable, Equatable {
        var url: URL
        var date: Date
        var bytes: Int64
        var id: String { url.lastPathComponent }
    }

    static func folder(titleID: String, documents: URL) -> URL {
        documents.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(titleID, isDirectory: true)
    }

    /// The snapshots of a game, newest first.
    static func list(titleID: String, documents: URL, fileManager: FileManager = .default) -> [Snapshot] {
        guard TitleID.isGame(titleID) else { return [] }
        let folder = folder(titleID: titleID, documents: documents)
        return ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { name -> Snapshot? in
            let url = folder.appendingPathComponent(name, isDirectory: true)
            guard name.count >= 17, let date = GameSaves.stamp.date(from: String(name.prefix(17))),
                  fileManager.fileExists(atPath: url.appendingPathComponent(GameSaves.manifestName).path) else { return nil }
            let entries = GameSaves.entries(in: url, fileManager: fileManager)
            return Snapshot(url: url, date: date, bytes: GameSaves.measure(entries, in: url, fileManager: fileManager).bytes)
        }
        .sorted { $0.id > $1.id }
    }

    /// What the saves are, in a line: the names, sizes and dates of the files. Two equal digests are the same saves.
    static func digest(of game: InstalledGame, fileManager: FileManager = .default) -> String? {
        let entries = GameSaves.entries(in: game.directory, fileManager: fileManager)
        guard !entries.isEmpty else { return nil }
        var lines: [String] = []
        for entry in entries {
            let root = game.directory.appendingPathComponent(entry)
            guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else {
                continue
            }
            var files = [root]
            for case let url as URL in walker { files.append(url) }
            for url in files {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { continue }
                let relative = String(url.path.dropFirst(game.directory.path.count))
                lines.append("\(relative)|\(values?.fileSize ?? 0)|\(Int((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000))")
            }
        }
        return SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Takes a snapshot of the game's saves. Nil when there is nothing to keep: no saves, saves too large, or the same as the last
    /// snapshot.
    @discardableResult
    static func take(_ game: InstalledGame, name: String, device: String, documents: URL, now: Date = Date(),
                     fileManager: FileManager = .default) throws -> URL? {
        guard let digest = digest(of: game, fileManager: fileManager) else { return nil }
        let entries = GameSaves.entries(in: game.directory, fileManager: fileManager)
        guard GameSaves.measure(entries, in: game.directory, fileManager: fileManager).bytes <= maxBytes else { return nil }
        let parent = folder(titleID: game.id, documents: documents)
        if let last = list(titleID: game.id, documents: documents, fileManager: fileManager).first,
           let known = BoundedRead.dataIfPresent(at: last.url.appendingPathComponent(digestName), limit: 256, fileManager: fileManager),
           String(decoding: known, as: UTF8.self) == digest { return nil }
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = try GameSaves.copy(game, name: name, into: parent, device: device, now: now, fileManager: fileManager)
        try Data(digest.utf8).write(to: folder.appendingPathComponent(digestName))
        let all = list(titleID: game.id, documents: documents, fileManager: fileManager)
        for old in all.dropFirst(keep) { try? fileManager.removeItem(at: old.url) }
        return folder
    }

    /// Removes a game's snapshots: the player erased everything of it.
    static func removeAll(titleID: String, documents: URL, fileManager: FileManager = .default) {
        guard TitleID.isGame(titleID) else { return }
        try? fileManager.removeItem(at: folder(titleID: titleID, documents: documents))
    }
}
