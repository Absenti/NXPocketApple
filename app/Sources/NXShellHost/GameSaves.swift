import Foundation
import NXPocketKit

/// Why a save copy was not taken. The screen says it in the player's language (`ShellHostModel.text(for:)`).
public enum SaveProblem: Error, Equatable {
    /// The game has no save to export.
    case noSaves
    /// No `backup.json` at the top of what was picked, nor in its one folder.
    case notACopy
    /// The copy's `backup.json` names another game.
    case otherGame(titleID: String, name: String)
    /// Fewer files or bytes than `backup.json` counts.
    case incomplete
    /// A copy with no `save*` entry in it.
    case empty
    /// The file could not be read, or the saves could not be written.
    case failed(String)
}

/// A copy of a game's saves, laid out as the Mac's (`SaveBackup` in mac/): a folder named after its date,
/// `yyyy-MM-dd HHmmss`, holding the game's `save*` entries as the phone has them and `backup.json`.
public struct SaveCopy: Equatable, Sendable {
    public var root: URL
    public var titleID: String
    public var name: String
    public var entries: [String]
}

/// A game's saves are the `save*` entries of its folder (the engine's `DM_SAVE` is `games/<title ID>/save`): what an
/// update carries over (`GameImporter`), what the Mac copies, and what is exported, imported and deleted here.
public enum GameSaves {
    public static let manifestName = "backup.json"
    /// `Documents/Saves/<title ID>/<date>/`: the saves an import replaced, as the Mac keeps its copies.
    public static let folderName = "Saves"
    public static let keep = 10
    static let stagingPrefix = ".saves-"

    public static func entries(in directory: URL, fileManager: FileManager = .default) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("save") }.sorted()
    }

    /// What removing a game while keeping its saves leaves: its folder with only `save*` in it. Not a game to list,
    /// and the next import of that game puts the saves back in (`GameImporter` carries them over).
    public static func holdsOnlySaves(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        let names = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }
        return !names.isEmpty && names.allSatisfy { $0.hasPrefix("save") }
    }

    /// The files and bytes under the `save*` entries, a folder counted for what it holds.
    static func measure(_ entries: [String], in directory: URL, fileManager: FileManager) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for name in entries {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                files += 1
                bytes += (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
                continue
            }
            guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let child as URL in walker {
                let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                files += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
        }
        return (files, bytes)
    }

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    /// Copies the game's saves into `<parent>/<date>/` with `backup.json`, as the Mac writes a copy.
    @discardableResult
    static func copy(_ game: InstalledGame, name: String, into parent: URL, device: String, now: Date,
                     fileManager: FileManager) throws -> URL {
        let entries = entries(in: game.directory, fileManager: fileManager)
        guard !entries.isEmpty else { throw SaveProblem.noSaves }
        let folder = try datedFolder(in: parent, now: now, fileManager: fileManager)
        for entry in entries {
            try fileManager.copyItem(at: game.directory.appendingPathComponent(entry), to: folder.appendingPathComponent(entry))
        }
        try writeManifest(titleID: game.titleID.description, name: name, device: device, now: now,
                          measured: measure(entries, in: folder, fileManager: fileManager), in: folder)
        return folder
    }

    /// One file to share: `<name> <date>.zip`, holding the dated folder a Mac copy is. Written under `temporary`.
    public static func export(_ game: InstalledGame, name: String, device: String, temporary: URL, now: Date = Date(),
                              fileManager: FileManager = .default) throws -> URL {
        let staging = temporary.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        let folder = try copy(game, name: name, into: staging, device: device, now: now, fileManager: fileManager)
        let fileName = "\(safeFileName(name)) \(folder.lastPathComponent).zip"
        let destination = temporary.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: destination)
        try SaveArchive.zip(folder: folder, to: destination, fileManager: fileManager)
        return destination
    }

    static func safeFileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }.joined(separator: " ")
        return cleaned.isEmpty ? "Saves" : String(cleaned.prefix(60))
    }

    /// The largest copy taken: far beyond any game's saves, and a bound on what a picked file can make this app write.
    public static let maxCopyBytes: Int64 = 1 << 30

    /// Reads a copy, a folder the Mac made or a .zip exported here, into `staging` and checks it belongs to `titleID`
    /// and is whole. A folder is checked where it is before anything is copied, and then only its saves are.
    public static func read(_ source: URL, for titleID: String, staging: URL,
                            fileManager: FileManager = .default) throws -> SaveCopy {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw SaveProblem.failed("\(source.lastPathComponent) is not there")
        }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            if isDirectory.boolValue {
                guard let root = copyRoot(in: source, fileManager: fileManager) else { throw SaveProblem.notACopy }
                let picked = try check(root, for: titleID, fileManager: fileManager)
                let staged = staging.appendingPathComponent("copy", isDirectory: true)
                try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
                for entry in picked.entries + [manifestName] {
                    try fileManager.copyItem(at: root.appendingPathComponent(entry), to: staged.appendingPathComponent(entry))
                }
                // Checked again as copied: the folder may have changed in between.
                return try check(staged, for: titleID, fileManager: fileManager)
            }
            guard SaveArchive.isZip(source) else { throw SaveProblem.notACopy }
            try SaveArchive.extract(source, into: staging, maxBytes: maxCopyBytes, fileManager: fileManager)
            guard let root = copyRoot(in: staging, fileManager: fileManager) else { throw SaveProblem.notACopy }
            return try check(root, for: titleID, fileManager: fileManager)
        } catch let problem as SaveProblem {
            throw problem
        } catch {
            throw SaveProblem.failed(describe(error))
        }
    }

    /// A copy where it is: its `backup.json` names this game, it holds `save*` entries and no link, it is no larger than
    /// `maxCopyBytes`, and it has every file and byte its `backup.json` counts.
    static func check(_ root: URL, for titleID: String, fileManager: FileManager) throws -> SaveCopy {
        guard let data = BoundedRead.dataIfPresent(at: root.appendingPathComponent(manifestName), limit: 64 << 10,
                                                   fileManager: fileManager),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let copyTitle = manifest["title_id"] as? String else { throw SaveProblem.notACopy }
        let name = manifest["name"] as? String ?? ""
        guard copyTitle.uppercased() == titleID.uppercased() else {
            throw SaveProblem.otherGame(titleID: copyTitle.uppercased(), name: name)
        }
        if containsLink(root, fileManager: fileManager) { throw SaveProblem.failed("the copy holds a link") }
        let entries = entries(in: root, fileManager: fileManager)
        guard !entries.isEmpty else { throw SaveProblem.empty }
        let measured = measure(entries, in: root, fileManager: fileManager)
        guard measured.bytes <= maxCopyBytes else { throw SaveProblem.failed("the copy is larger than a save can be") }
        if let files = manifest["files"] as? Int, files != measured.files { throw SaveProblem.incomplete }
        if let bytes = (manifest["bytes"] as? NSNumber)?.int64Value, bytes != measured.bytes { throw SaveProblem.incomplete }
        return SaveCopy(root: root, titleID: copyTitle.uppercased(), name: name, entries: entries)
    }

    /// The folder holding `backup.json`: the top of what was read, or its only folder (a .zip holds the dated folder,
    /// and a folder picked in Files may be the one above it).
    static func copyRoot(in folder: URL, fileManager: FileManager) -> URL? {
        if fileManager.fileExists(atPath: folder.appendingPathComponent(manifestName).path) { return folder }
        let folders = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
            .map { folder.appendingPathComponent($0, isDirectory: true) }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent(manifestName).path) }
        return folders.count == 1 ? folders[0] : nil
    }

    static func containsLink(_ folder: URL, fileManager: FileManager) -> Bool {
        guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return false }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return true
        }
        return false
    }

    /// Puts `copy` in place of the game's saves. The saves it replaces move first into a dated copy,
    /// `Documents/Saves/<title ID>/<date>/`, its `backup.json` written before them: wherever the app stops, they are in
    /// the game or in a copy Files shows and an import brings back, never in a hidden folder. Returns that copy, nil when
    /// there were no saves. A failure puts the previous saves back.
    @discardableResult
    public static func restore(_ copy: SaveCopy, into game: InstalledGame, name: String, documents: URL, device: String,
                               now: Date = Date(), fileManager: FileManager = .default) throws -> URL? {
        let current = entries(in: game.directory, fileManager: fileManager)
        let parent = keptFolder(titleID: game.titleID.description, documents: documents)
        var kept: URL?
        var movedOut: [String] = []
        var movedIn: [String] = []
        do {
            if !current.isEmpty {
                let folder = try datedFolder(in: parent, now: now, fileManager: fileManager)
                kept = folder
                try writeManifest(titleID: game.titleID.description, name: name, device: device, now: now,
                                  measured: measure(current, in: game.directory, fileManager: fileManager), in: folder)
                for entry in current {
                    try fileManager.moveItem(at: game.directory.appendingPathComponent(entry), to: folder.appendingPathComponent(entry))
                    movedOut.append(entry)
                }
            }
            for entry in copy.entries {
                try fileManager.moveItem(at: copy.root.appendingPathComponent(entry), to: game.directory.appendingPathComponent(entry))
                movedIn.append(entry)
            }
        } catch {
            // What came in is a staged copy of what the player picked, which is still where it was.
            for entry in movedIn { try? fileManager.removeItem(at: game.directory.appendingPathComponent(entry)) }
            if let kept {
                for entry in movedOut {
                    try? fileManager.moveItem(at: kept.appendingPathComponent(entry), to: game.directory.appendingPathComponent(entry))
                }
                if entries(in: kept, fileManager: fileManager).isEmpty { try? fileManager.removeItem(at: kept) }
            }
            if let problem = error as? SaveProblem { throw problem }
            throw SaveProblem.failed(describe(error))
        }
        rotate(parent, fileManager: fileManager)
        return kept
    }

    /// A new folder named after `now` under `parent`, never one that is there already.
    static func datedFolder(in parent: URL, now: Date, fileManager: FileManager) throws -> URL {
        let base = stamp.string(from: now)
        var folder = parent.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(base) \(index)", isDirectory: true)
            index += 1
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func writeManifest(titleID: String, name: String, device: String, now: Date,
                              measured: (files: Int, bytes: Int64), in folder: URL) throws {
        let manifest: [String: Any] = ["title_id": titleID, "name": name, "device": device,
                                       "created": ISO8601DateFormatter().string(from: now),
                                       "files": measured.files, "bytes": measured.bytes]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent(manifestName))
    }

    /// Saves earlier versions could leave in hidden folders when the app stopped halfway: `games/.saves-<uuid>` (a
    /// removal that kept the saves) and `games/<title ID>/.saves-<uuid>` (an import of a copy). A game with no saves
    /// gets them back; otherwise they become a dated copy in `Saves/`, which Files shows. Returns what was done.
    public static func recoverHiddenCopies(documents: URL, now: Date = Date(), fileManager: FileManager = .default) -> [String] {
        let games = GameLayout.gamesDirectory(in: documents)
        var notes: [String] = []
        func hidden(in folder: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(stagingPrefix) }
                .map { folder.appendingPathComponent($0, isDirectory: true) }
        }
        func keep(_ folder: URL, titleID: String) {
            let parent = keptFolder(titleID: titleID, documents: documents)
            guard let target = try? datedFolder(in: parent, now: now, fileManager: fileManager) else { return }
            try? fileManager.removeItem(at: target)
            if (try? fileManager.moveItem(at: folder, to: target)) != nil {
                notes.append("saves found in \(folder.lastPathComponent) kept in Saves/\(parent.lastPathComponent)/\(target.lastPathComponent)")
            }
        }
        for folder in hidden(in: games) { keep(folder, titleID: "Recovered") }
        for game in (try? fileManager.contentsOfDirectory(atPath: games.path)) ?? [] where TitleID(game) != nil {
            let directory = games.appendingPathComponent(game, isDirectory: true)
            for folder in hidden(in: directory) {
                if entries(in: directory, fileManager: fileManager).isEmpty {
                    for entry in entries(in: folder, fileManager: fileManager) {
                        try? fileManager.moveItem(at: folder.appendingPathComponent(entry), to: directory.appendingPathComponent(entry))
                    }
                    if entries(in: folder, fileManager: fileManager).isEmpty {
                        try? fileManager.removeItem(at: folder)
                        notes.append("saves of \(game) found in \(folder.lastPathComponent) put back")
                        continue
                    }
                }
                keep(folder, titleID: game)
            }
        }
        return notes
    }

    public static func keptFolder(titleID: String, documents: URL) -> URL {
        documents.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(titleID.uppercased(), isDirectory: true)
    }

    /// The `keep` newest copies of a game. Only folders named after a date go.
    static func rotate(_ parent: URL, fileManager: FileManager) {
        let names = ((try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? [])
            .filter { $0.count >= 17 && stamp.date(from: String($0.prefix(17))) != nil }
            .sorted(by: >)
        for name in names.dropFirst(keep) { try? fileManager.removeItem(at: parent.appendingPathComponent(name)) }
    }

    /// The game's saves go, nothing else.
    public static func delete(in game: InstalledGame, fileManager: FileManager = .default) throws {
        for entry in entries(in: game.directory, fileManager: fileManager) {
            try fileManager.removeItem(at: game.directory.appendingPathComponent(entry))
        }
    }

    /// The exports older than `age`: each export has its own folder, which a share sheet may still be offering.
    public static func pruneExports(in exports: URL, olderThan age: TimeInterval, now: Date = Date(),
                                    fileManager: FileManager = .default) {
        for name in (try? fileManager.contentsOfDirectory(atPath: exports.path)) ?? [] {
            let url = exports.appendingPathComponent(name)
            let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
            if now.timeIntervalSince(modified) > age { try? fileManager.removeItem(at: url) }
        }
    }

    /// What an export or an import left behind when the app stopped in the middle.
    public static func cleanLeftovers(in folders: [URL], fileManager: FileManager = .default) {
        for folder in folders {
            for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(stagingPrefix) {
                try? fileManager.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SaveArchive.Failure.damaged(let why): return "damaged .zip: \(why)"
        case SaveArchive.Failure.unsupported(let what): return "this .zip uses \(what), which is not read here"
        case SaveArchive.Failure.tooLarge: return "the .zip is too large for a save"
        default: return error.localizedDescription
        }
    }
}
