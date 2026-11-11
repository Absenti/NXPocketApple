import Foundation
import NXPocketKit

/// One copy of a game's saves on the Mac: `<output folder>/Saves/<title ID>/<yyyy-MM-dd HHmmss>/`, holding the
/// game's `save*` entries as the phone has them, and `backup.json`.
public struct SaveBackupRecord: Equatable, Sendable {
    public var titleID: String
    public var folder: URL
    public var date: Date
}

public enum SaveBackupOutcome: Equatable, Sendable {
    case saved(SaveBackupRecord, files: Int, bytes: Int64)
    /// The game has no save on the phone (never played, or the phone was wiped): nothing is written.
    case nothingToSave
}

/// Copies a game's saves from the iPhone to the Mac. It only reads on the phone (`DeviceLibrary.copyFromArguments`,
/// after the listing a `PhoneSnapshot` already holds), and on the Mac it writes into `.partial-<uuid>`, checks that
/// every file the phone listed arrived with its size, then renames the folder to its date: a copy cut short is never
/// taken for the newest backup. The last `keep` copies of each game are kept.
///
/// Putting a save back is not done here: the Mac writes on the phone only into `Documents/.incoming/`, and the iPhone app
/// imports a save only from a file picked in its game menu (`SaveExport` packs a copy for that).
public final class SaveBackup: @unchecked Sendable {
    public static let folderName = "Saves"
    public static let keep = 10
    static let partialPrefix = ".partial-"
    static let manifestName = "backup.json"

    /// Runs one devicectl command. The tests replace it, and check that every command it is given reads.
    let run: ([String]) throws -> ProcessRunner.Result
    private let fileManager: FileManager

    public convenience init(toolchain: Toolchain) {
        self.init(fileManager: .default) { arguments in
            try ProcessRunner.capture(toolchain.xcrun, arguments, timeout: 300)
        }
    }

    init(fileManager: FileManager, run: @escaping ([String]) throws -> ProcessRunner.Result) {
        self.fileManager = fileManager
        self.run = run
    }

    public static func root(in outputFolder: URL) -> URL {
        outputFolder.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func folder(of titleID: String, in outputFolder: URL) -> URL {
        root(in: outputFolder).appendingPathComponent(titleID.uppercased(), isDirectory: true)
    }

    public func backUp(titleID: String, name: String?, snapshot: PhoneSnapshot, device: Device, outputFolder: URL,
                       now: Date = Date()) throws -> SaveBackupOutcome {
        // The ID names a folder on the Mac: it must be a title ID, whatever the phone said.
        guard let checked = TitleID(titleID) else {
            throw NXPocketError(.packageDamaged, "\"\(titleID)\" is not a title ID")
        }
        let titleID = checked.description
        let files = snapshot.saveFiles(of: titleID)
        let wanted = files.filter { !$0.isDirectory }
        guard !wanted.isEmpty else { return .nothingToSave }
        let gameFolder = Self.folder(of: titleID, in: outputFolder)
        try fileManager.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        removeLeftovers(in: gameFolder)
        let partial = gameFolder.appendingPathComponent(Self.partialPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            // One copy per `save*` entry: a folder comes whole, as its contents in the folder of its name.
            let entries = Set(files.compactMap { file -> String? in
                let parts = file.path.split(separator: "/", maxSplits: 2)
                return parts.count >= 2 ? String(parts[1]) : nil
            }).sorted()
            for entry in entries {
                let isFolder = files.contains { $0.path == "\(titleID)/\(entry)" && $0.isDirectory }
                    || files.contains { $0.path.hasPrefix("\(titleID)/\(entry)/") }
                let destination = partial.appendingPathComponent(entry, isDirectory: isFolder)
                let result = try run(DeviceLibrary.copyFromArguments(device: device, bundleID: snapshot.bundleID,
                                                                     source: "\(GameLayout.gamesFolder)/\(titleID)/\(entry)",
                                                                     destination: destination))
                guard result.status == 0 else {
                    let line = result.lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "devicectl exited with \(result.status)"
                    throw NXPocketError(.transferFailed, "copying \(entry) from the iPhone failed: \(line)")
                }
            }
            // Every file the phone listed, with the size it listed: a save the game rewrote meanwhile, or a copy
            // cut off, fails here rather than becoming the newest backup.
            var bytes: Int64 = 0
            for file in wanted {
                let relative = String(file.path.dropFirst(titleID.count + 1))
                let local = partial.appendingPathComponent(relative)
                let size = (try? fileManager.attributesOfItem(atPath: local.path))?[.size] as? Int64
                guard size == file.size else {
                    throw NXPocketError(.transferFailed, "\(relative) did not arrive whole (\(size ?? 0) of \(file.size) bytes)")
                }
                bytes += file.size
            }
            // `phone_listing` is what the phone's listing said of these files (`SaveWatch.listingDigest`): the next
            // look compares it, so a game is copied again only once its saves changed.
            let manifest: [String: Any] = ["title_id": titleID.uppercased(), "name": name ?? "", "device": device.name,
                                           "created": ISO8601DateFormatter().string(from: now),
                                           "files": wanted.count, "bytes": bytes,
                                           "phone_listing": SaveWatch.listingDigest(wanted)]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: partial.appendingPathComponent(Self.manifestName))
            let final = uniqueFolder(for: now, in: gameFolder)
            try fileManager.moveItem(at: partial, to: final)
            rotate(gameFolder)
            return .saved(SaveBackupRecord(titleID: titleID.uppercased(), folder: final, date: now), files: wanted.count, bytes: bytes)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    // MARK: - The copies on the Mac

    static let folderDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    /// The date a backup folder is named after: exactly `yyyy-MM-dd HHmmss`, or that and ` <n>` for a second backup
    /// within the same second (`uniqueFolder`). Nil for anything else: "2026-11-11 120000 my copy" is the user's.
    static func date(ofFolderNamed name: String) -> Date? {
        guard name.count >= 17, let date = folderDate.date(from: String(name.prefix(17))),
              folderDate.string(from: date) == String(name.prefix(17)) else { return nil }
        let rest = name.dropFirst(17)
        guard rest.isEmpty || (rest.first == " " && rest.count > 1 && rest.dropFirst().allSatisfy(\.isNumber)) else { return nil }
        return date
    }

    /// A folder this class made: named after a date, holding the `backup.json` it writes before the rename.
    static func isBackup(_ folder: URL, fileManager: FileManager) -> Bool {
        date(ofFolderNamed: folder.lastPathComponent) != nil
            && fileManager.fileExists(atPath: folder.appendingPathComponent(manifestName).path)
    }

    /// A game's backups, newest first.
    public static func backups(of titleID: String, in outputFolder: URL, fileManager: FileManager = .default) -> [SaveBackupRecord] {
        guard TitleID(titleID) != nil else { return [] }
        let folder = self.folder(of: titleID, in: outputFolder)
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> SaveBackupRecord? in
            guard let date = date(ofFolderNamed: name),
                  isBackup(folder.appendingPathComponent(name, isDirectory: true), fileManager: fileManager) else { return nil }
            return SaveBackupRecord(titleID: titleID.uppercased(), folder: folder.appendingPathComponent(name, isDirectory: true), date: date)
        }
        .sorted { $0.folder.lastPathComponent > $1.folder.lastPathComponent }
    }

    /// A game's newest backup, with the listing summary its `backup.json` holds.
    public static func newest(of titleID: String, in outputFolder: URL, fileManager: FileManager = .default) -> SaveWatch.Newest? {
        guard let record = backups(of: titleID, in: outputFolder, fileManager: fileManager).first else { return nil }
        let data = try? BoundedRead.data(at: record.folder.appendingPathComponent(manifestName), limit: 64 << 10,
                                         fileManager: fileManager)
        let manifest = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return SaveWatch.Newest(date: record.date, listing: manifest?["phone_listing"] as? String)
    }

    /// Every game with a backup, by title ID, with the name its newest `backup.json` gives and its backups, newest first.
    public static func catalogue(in outputFolder: URL, fileManager: FileManager = .default)
        -> [(titleID: String, name: String?, backups: [SaveBackupRecord])] {
        let titles = (try? fileManager.contentsOfDirectory(atPath: root(in: outputFolder).path)) ?? []
        return titles.compactMap { folder -> (titleID: String, name: String?, backups: [SaveBackupRecord])? in
            guard let titleID = TitleID(folder)?.description else { return nil }
            let found = backups(of: titleID, in: outputFolder, fileManager: fileManager)
            guard let newest = found.first else { return nil }
            let data = try? BoundedRead.data(at: newest.folder.appendingPathComponent(manifestName), limit: 64 << 10,
                                             fileManager: fileManager)
            let name = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["name"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            return (titleID, name, found)
        }
        .sorted { $0.titleID < $1.titleID }
    }

    /// The newest backup's date of every game that has one.
    public static func latest(in outputFolder: URL, fileManager: FileManager = .default) -> [String: Date] {
        let titles = (try? fileManager.contentsOfDirectory(atPath: root(in: outputFolder).path)) ?? []
        var found: [String: Date] = [:]
        for titleID in titles where TitleID(titleID) != nil {
            if let newest = backups(of: titleID, in: outputFolder, fileManager: fileManager).first { found[titleID] = newest.date }
        }
        return found
    }

    private func uniqueFolder(for date: Date, in gameFolder: URL) -> URL {
        let base = Self.folderDate.string(from: date)
        var candidate = gameFolder.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = gameFolder.appendingPathComponent("\(base) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    /// Keeps the `keep` newest backups of a game. Only the folders this class made can go (`isBackup`): a folder the
    /// user put there under a date-like name is neither counted nor deleted.
    func rotate(_ gameFolder: URL) {
        let names = ((try? fileManager.contentsOfDirectory(atPath: gameFolder.path)) ?? [])
            .filter { Self.isBackup(gameFolder.appendingPathComponent($0, isDirectory: true), fileManager: fileManager) }
            .sorted(by: >)
        for name in names.dropFirst(Self.keep) {
            try? fileManager.removeItem(at: gameFolder.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// A partial copy left by a run that was cut off (the app quit mid-copy) is not a backup.
    private func removeLeftovers(in gameFolder: URL) {
        for name in (try? fileManager.contentsOfDirectory(atPath: gameFolder.path)) ?? [] where name.hasPrefix(Self.partialPrefix) {
            try? fileManager.removeItem(at: gameFolder.appendingPathComponent(name, isDirectory: true))
        }
    }
}
