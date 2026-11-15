import Foundation

/// Atmosphère cheat files, as the engine reads them (`hle_cheats.c`): what a cheat site shares, one `.txt` per version of a game, named after
/// the first eight bytes of the main module's build ID. The engine does the cheating; this is what a front end does around it: checks a file
/// the way the engine will read it (so a bad file is said at once and not by a game that ignores it), keeps it where an update of the game
/// does not take it, lists its cheats, and writes the two small files the engine reads: which cheats are on, and the master switch.
///
/// Cheats are data the player brings, from a source they chose: nothing here fetches one. The engine refuses what it cannot do on a
/// phone (a cheat that writes into the game's code: the pages are signed), and says so in its log.
public enum Cheats {
    /// The folder the engine is given for a game (`DM_CHEATS`): outside the game's own folder, which an update or an offload replaces.
    public static func folder(titleID: String, documents: URL) -> URL {
        documents.appendingPathComponent("Cheats", isDirectory: true).appendingPathComponent(titleID, isDirectory: true)
    }

    public static let maxFileBytes = 64 * 1024 - 1
    public static let maxCheats = 127
    public static let maxWordsPerCheat = 0x100

    public struct Entry: Equatable, Sendable, Identifiable {
        /// The name the `.enabled` file uses: the file's own spelling, a repeated name numbered (`Name #2`).
        public var name: String
        public var isMaster: Bool
        public var words: Int
        public var id: String { (isMaster ? "{" : "[") + name }
    }

    public struct Problem: Error, Equatable, Sendable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { line > 0 ? "line \(line): \(message)" : message }
    }

    /// Reads a file the way the engine does: `[Name]` opens a cheat, `{Name}` the master code, a run of hex digits is cut into 8-digit
    /// words, and anything else is refused (there is no comment syntax). A cheat with no word is not one (a label), and is left out.
    public static func parse(_ data: Data) throws -> [Entry] {
        guard data.count <= maxFileBytes else { throw Problem(line: 0, message: "the file is larger than 64 KiB: it is not a cheat file") }
        guard let text = String(data: data, encoding: .utf8) else { throw Problem(line: 0, message: "the file is not text") }
        var entries: [Entry] = []
        var current: Int?
        var line = 1
        var seen: [String: Int] = [:]
        var scalars = Array(text.unicodeScalars)[...]
        // A byte order mark and the carriage returns of a file made on Windows are not part of it.
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }

        func finish(_ index: Int?) {
            guard let index, entries[index].words == 0 else { return }
            entries.remove(at: index)
        }

        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\n" { line += 1; index = scalars.index(after: index); continue }
            if scalar == " " || scalar == "\t" || scalar == "\r" { index = scalars.index(after: index); continue }
            if scalar == "[" || scalar == "{" {
                let close: Unicode.Scalar = scalar == "[" ? "]" : "}"
                guard let end = scalars[index...].firstIndex(of: close), !scalars[index..<end].contains("\n") else {
                    throw Problem(line: line, message: "a name opened with \(scalar) is not closed on its line")
                }
                let name = String(String.UnicodeScalarView(scalars[scalars.index(after: index)..<end])).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name.utf8.count < 64 else { throw Problem(line: line, message: "a cheat name is empty or longer than 63 bytes") }
                finish(current)
                let master = scalar == "{"
                if master, entries.contains(where: \.isMaster) { throw Problem(line: line, message: "there is more than one master code {…}") }
                var unique = name
                if !master {
                    seen[name, default: 0] += 1
                    if seen[name]! > 1 { unique = "\(name) #\(seen[name]!)" }
                    guard entries.filter({ !$0.isMaster }).count < maxCheats else { throw Problem(line: line, message: "there are more than \(maxCheats) cheats") }
                }
                entries.append(Entry(name: unique, isMaster: master, words: 0))
                current = entries.count - 1
                index = scalars.index(after: end)
                continue
            }
            if scalar.properties.isASCIIHexDigit {
                var end = index
                while end < scalars.endIndex, scalars[end].properties.isASCIIHexDigit { end = scalars.index(after: end) }
                let digits = scalars.distance(from: index, to: end)
                guard digits % 8 == 0 else { throw Problem(line: line, message: "\(digits) hexadecimal digits are not whole 8-digit words") }
                guard let current else { throw Problem(line: line, message: "a code comes before any [name]") }
                entries[current].words += digits / 8
                guard entries[current].words <= maxWordsPerCheat else { throw Problem(line: line, message: "\"\(entries[current].name)\" has more than \(maxWordsPerCheat) words") }
                index = end
                continue
            }
            throw Problem(line: line, message: "\"\(scalar)\" is not part of a cheat file (there are no comments)")
        }
        finish(current)
        return entries
    }

    /// The build a game was made from, as the engine names it in a cheat file's name: the first 16 hex digits of the main module's build ID,
    /// in capitals. The build writes it into the game (`dm/main.fixups.tsv`); nil for a game built before that.
    public static func buildID(inFramework framework: URL, fileManager: FileManager = .default) -> String? {
        guard let data = BoundedRead.dataIfPresent(at: framework.appendingPathComponent("dm/main.fixups.tsv"), limit: 1 << 20, fileManager: fileManager),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("# BUILD_ID") {
            let id = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).last.map(String.init) ?? ""
            guard id.count >= 16, id.prefix(16).allSatisfy(\.isHexDigit) else { return nil }
            return String(id.prefix(16)).uppercased()
        }
        return nil
    }

    // MARK: the files

    public static func file(buildID: String, in folder: URL) -> URL { folder.appendingPathComponent("\(buildID).txt") }
    public static func enabledFile(buildID: String, in folder: URL) -> URL { folder.appendingPathComponent("\(buildID).enabled") }
    public static func masterOffFile(titleID: String, in folder: URL) -> URL { folder.appendingPathComponent(".cheats-off-\(titleID)") }

    /// Checks `source` and keeps it as this build's file. A file already there is kept as `.bak`, as the engine's own window does.
    @discardableResult
    public static func install(_ source: URL, titleID: String, buildID: String, documents: URL, fileManager: FileManager = .default) throws -> [Entry] {
        guard let data = BoundedRead.dataIfPresent(at: source, limit: Int64(maxFileBytes) + 1, fileManager: fileManager) else {
            throw Problem(line: 0, message: "the file could not be read, or is larger than 64 KiB")
        }
        let entries = try parse(data)
        guard !entries.isEmpty else { throw Problem(line: 0, message: "the file holds no cheat") }
        let folder = folder(titleID: titleID, documents: documents)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = file(buildID: buildID, in: folder)
        if fileManager.fileExists(atPath: target.path) {
            let backup = target.appendingPathExtension("bak")
            try? fileManager.removeItem(at: backup)
            try? fileManager.moveItem(at: target, to: backup)
        }
        try data.write(to: target, options: .atomic)
        // A new file starts with nothing on: the player chooses what to switch on.
        try? fileManager.removeItem(at: enabledFile(buildID: buildID, in: folder))
        return entries
    }

    public static func installed(titleID: String, buildID: String, documents: URL, fileManager: FileManager = .default) -> [Entry]? {
        let url = file(buildID: buildID, in: folder(titleID: titleID, documents: documents))
        guard let data = BoundedRead.dataIfPresent(at: url, limit: Int64(maxFileBytes) + 1, fileManager: fileManager) else { return nil }
        return try? parse(data)
    }

    /// The names that are on, as the engine keeps them in `<build ID>.enabled`: one per line, the master never.
    public static func enabled(titleID: String, buildID: String, documents: URL, fileManager: FileManager = .default) -> Set<String> {
        let url = enabledFile(buildID: buildID, in: folder(titleID: titleID, documents: documents))
        guard let data = BoundedRead.dataIfPresent(at: url, limit: 1 << 20, fileManager: fileManager), let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Writes which cheats are on, a temporary file renamed over the old one so it is never half written.
    public static func setEnabled(_ names: Set<String>, titleID: String, buildID: String, documents: URL, fileManager: FileManager = .default) throws {
        let folder = folder(titleID: titleID, documents: documents)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = names.sorted().joined(separator: "\n") + (names.isEmpty ? "" : "\n")
        try Data(text.utf8).write(to: enabledFile(buildID: buildID, in: folder), options: .atomic)
    }

    public static func isMasterOn(titleID: String, documents: URL, fileManager: FileManager = .default) -> Bool {
        !fileManager.fileExists(atPath: masterOffFile(titleID: titleID, in: folder(titleID: titleID, documents: documents)).path)
    }

    public static func setMaster(_ on: Bool, titleID: String, documents: URL, fileManager: FileManager = .default) throws {
        let folder = folder(titleID: titleID, documents: documents)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = masterOffFile(titleID: titleID, in: folder)
        if on { try? fileManager.removeItem(at: marker) } else { try Data().write(to: marker, options: .atomic) }
    }

    public static func remove(titleID: String, buildID: String, documents: URL, fileManager: FileManager = .default) {
        let folder = folder(titleID: titleID, documents: documents)
        for url in [file(buildID: buildID, in: folder), enabledFile(buildID: buildID, in: folder)] { try? fileManager.removeItem(at: url) }
    }

    /// Whether any cheat would run at the next start: the master is on and at least one cheat is switched on (a master code runs with them).
    public static func isActive(titleID: String, buildID: String, documents: URL, fileManager: FileManager = .default) -> Bool {
        isMasterOn(titleID: titleID, documents: documents, fileManager: fileManager)
            && !enabled(titleID: titleID, buildID: buildID, documents: documents, fileManager: fileManager).isEmpty
    }
}
