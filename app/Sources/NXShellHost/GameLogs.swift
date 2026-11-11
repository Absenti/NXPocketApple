import Foundation
import NXPocketKit

/// One log the Logs screen lists: the app's own journal (`import-log.txt`) or one start of a game.
public struct LogFile: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case app
        case game(String)
    }

    public var url: URL
    public var kind: Kind
    public var date: Date
    public var bytes: Int64

    public var id: String { url.path }

    public var titleID: String? {
        if case .game(let titleID) = kind { return titleID }
        return nil
    }
}

/// Each start of a game writes its own log, `Documents/logs/<title ID>/<yyyy-MM-dd HHmmss>.txt`, where one shared
/// `log.txt` used to be overwritten by the next start of any game. The newest `keep` of each game stay.
public enum GameLogs {
    public static let folderName = "logs"
    public static let keep = 10
    /// What the screen shows of a log: the end, where a failure is. Sharing gives the whole file.
    public static let shownBytes = 512 * 1024

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    public static func root(documents: URL) -> URL {
        documents.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func folder(titleID: String, documents: URL) -> URL {
        root(documents: documents).appendingPathComponent(titleID.uppercased(), isDirectory: true)
    }

    /// Where a start at `now` writes: a new file, never one an earlier start wrote in the same second.
    public static func newLogURL(titleID: String, documents: URL, now: Date = Date(),
                                 fileManager: FileManager = .default) -> URL {
        let folder = folder(titleID: titleID, documents: documents)
        let base = stamp.string(from: now)
        var candidate = folder.appendingPathComponent("\(base).txt")
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index).txt")
            index += 1
        }
        return candidate
    }

    /// The date a log is named after; nil for any other file.
    static func date(ofFileNamed name: String) -> Date? {
        guard name.hasSuffix(".txt"), name.count >= 17 else { return nil }
        return stamp.date(from: String(name.prefix(17)))
    }

    /// The games' logs, newest first: one game's, or every game's.
    public static func logs(titleID: String? = nil, documents: URL, fileManager: FileManager = .default) -> [LogFile] {
        let titles = titleID.map { [$0.uppercased()] }
            ?? ((try? fileManager.contentsOfDirectory(atPath: root(documents: documents).path)) ?? []).filter { TitleID($0) != nil }
        var found: [LogFile] = []
        for title in titles {
            let folder = folder(titleID: title, documents: documents)
            for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard let date = date(ofFileNamed: name) else { continue }
                let url = folder.appendingPathComponent(name)
                let bytes = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
                found.append(LogFile(url: url, kind: .game(title), date: date, bytes: bytes))
            }
        }
        return found.sorted { ($0.date, $0.url.lastPathComponent) > ($1.date, $1.url.lastPathComponent) }
    }

    public static func latest(titleID: String, documents: URL, fileManager: FileManager = .default) -> LogFile? {
        logs(titleID: titleID, documents: documents, fileManager: fileManager).first
    }

    /// The app's own journal: imports, signing, launches. It may not exist yet.
    public static func appLog(documents: URL, fileManager: FileManager = .default) -> LogFile {
        let url = documents.appendingPathComponent(GameLayout.importLog)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return LogFile(url: url, kind: .app, date: attributes?[.modificationDate] as? Date ?? .distantPast,
                       bytes: attributes?[.size] as? Int64 ?? 0)
    }

    /// Before a start: the game's folder, with room for the new log among the `keep` newest.
    public static func prepare(for log: URL, keep: Int = keep, fileManager: FileManager = .default) {
        let folder = log.deletingLastPathComponent()
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { date(ofFileNamed: $0) != nil }
            .sorted(by: >)
        for name in names.dropFirst(max(keep - 1, 0)) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// A game log goes; the app's journal starts again empty.
    public static func remove(_ log: LogFile, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: log.url.path) else { return }
        try fileManager.removeItem(at: log.url)
    }

    /// Every log of a game, when the game goes with everything it left.
    public static func removeAll(titleID: String, documents: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: folder(titleID: titleID, documents: documents))
    }

    /// The end of a log, at most `limit` bytes, starting on a whole line; and whether anything was left out.
    public static func text(of log: LogFile, limit: Int = shownBytes) -> (text: String, isTail: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: log.url) else { return ("", false) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return ("", false) }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return ("", false) }
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newline)...]
        }
        return (String(decoding: data, as: UTF8.self), start > 0)
    }

    /// The single `log.txt` and `log.prev.txt` of earlier versions, filed under the game they name: the host's first
    /// line is `shell: starting <the game's folder>/…`. A log that names no game stays where it is.
    public static func fileSharedLogs(documents: URL, fileManager: FileManager = .default) {
        for name in ["log.prev.txt", "log.txt"] {
            let url = documents.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let head = (try? handle.read(upToCount: 16 * 1024)) ?? Data()
            try? handle.close()
            guard let titleID = titleID(in: String(decoding: head, as: UTF8.self)) else { continue }
            let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? Date()
            let destination = newLogURL(titleID: titleID, documents: documents, now: modified, fileManager: fileManager)
            try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.moveItem(at: url, to: destination)
        }
    }

    /// The first `games/<title ID>/` a log names.
    static func titleID(in text: String) -> String? {
        let marker = "/\(GameLayout.gamesFolder)/"
        var rest = Substring(text)
        while let range = rest.range(of: marker) {
            let candidate = rest[range.upperBound...].prefix(16)
            if candidate.count == 16, TitleID(String(candidate)) != nil { return String(candidate).uppercased() }
            rest = rest[range.upperBound...]
        }
        return nil
    }
}
