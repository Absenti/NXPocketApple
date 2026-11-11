import Foundation
import NXPocketKit

/// Decides, from one listing of the phone, which games' saves to copy to the Mac by themselves.
///
/// Nothing is downloaded to compare: a game's saves are summed up by the listing devicectl gives (each file's path,
/// size and modification date), and that summary is written into each copy's `backup.json` (`SaveBackup`). A game
/// is copied when its summary differs from its newest copy's, when its newest save file was written a while ago (a
/// game in the middle of writing its save is not copied halfway), and when its newest copy is old enough that ten
/// copies cover more than the last minutes of play.
public struct SaveWatch: Sendable {
    /// How often the phone's games folder is listed for this, while the launcher runs (in front or not).
    public static let checkInterval: TimeInterval = 120
    /// How long after its last write a save counts as settled.
    public static let settleTime: TimeInterval = 60
    /// The least time between two copies of a game made by themselves. A game that saves every few minutes would
    /// otherwise fill the ten copies kept within the hour, and a save gone bad would push every good copy out.
    public static let minimumSpacing: TimeInterval = 30 * 60

    /// Each game's summary at the previous look: when the phone gave no usable date, a summary seen twice in a row is
    /// what tells a settled save.
    private var previous: [String: String] = [:]

    public init() {}

    /// What a game's newest copy on the Mac says.
    public struct Newest: Sendable, Equatable {
        public var date: Date
        /// Nil for a copy made before the summary was written into `backup.json`: the next look copies the game again.
        public var listing: String?

        public init(date: Date, listing: String?) {
            self.date = date
            self.listing = listing
        }
    }

    /// The title IDs to copy now, in the snapshot's order.
    public mutating func due(_ snapshot: PhoneSnapshot, newest: (String) -> Newest?, now: Date = Date()) -> [String] {
        var due: [String] = []
        var seen: [String: String] = [:]
        for game in snapshot.games {
            let files = snapshot.saveFiles(of: game.titleID).filter { !$0.isDirectory }
            guard !files.isEmpty else { continue }
            let summary = Self.listingDigest(files)
            seen[game.titleID] = summary
            let last = newest(game.titleID)
            if let last {
                guard last.listing != summary, now.timeIntervalSince(last.date) >= Self.minimumSpacing else { continue }
            }
            let settled: Bool
            if let written = Self.newestWrite(files) {
                settled = now.timeIntervalSince(written) >= Self.settleTime
            } else {
                settled = previous[game.titleID] == summary
            }
            if settled { due.append(game.titleID) }
        }
        previous = seen
        return due
    }

    /// The summary of a game's saves as the phone lists them: SHA-256 of each file's path, size and date, sorted.
    public static func listingDigest(_ files: [RemoteFile]) -> String {
        let lines = files.filter { !$0.isDirectory }.map { "\($0.path)\t\($0.size)\t\($0.date)\n" }.sorted()
        return FileDigest.sha256(of: Data(lines.joined().utf8))
    }

    /// The latest modification date among the files, nil when one of them has none devicectl's format gives.
    static func newestWrite(_ files: [RemoteFile]) -> Date? {
        var latest: Date?
        for file in files {
            guard let date = parseDate(file.date) else { return nil }
            latest = max(latest ?? date, date)
        }
        return latest
    }

    /// devicectl writes `2026-11-11T00:13:24.000Z`.
    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// A copy of a game's saves on the Mac, packed for the iPhone app's own import ("Import a save" in a game's menu takes
/// a .zip holding the dated folder and its `backup.json`, and checks it is that game's and whole).
public enum SaveExport {
    /// `ditto` writes the zip the iPhone app reads (deflate, sizes in the central directory). Resource forks, extended
    /// attributes and ACLs stay out, so the archive holds the saves and `backup.json` only.
    public static func zipArguments(backup folder: URL, to archive: URL) -> [String] {
        ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noacl", folder.path, archive.path]
    }

    /// The file name the copy goes by in iCloud Drive: the game's name and the copy's date.
    public static func archiveName(game: String, backup folder: URL) -> String {
        let cleaned = game.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines))
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty ? "Saves" : String(cleaned.prefix(60))
        return "\(name) saves \(folder.lastPathComponent).zip"
    }

    /// Zips a backup into `archive`, replacing nothing: the caller moves it where it goes.
    public static func zip(backup folder: URL, to archive: URL) throws {
        let result = try ProcessRunner.capture(URL(fileURLWithPath: "/usr/bin/ditto"),
                                               zipArguments(backup: folder, to: archive), timeout: 120)
        guard result.status == 0 else {
            let line = result.lines.last { !$0.isEmpty } ?? "ditto exited with \(result.status)"
            throw NXPocketError(.transferFailed, "the copy could not be zipped: \(line)")
        }
    }
}
