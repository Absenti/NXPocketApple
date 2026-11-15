import Foundation

/// What a transfer folder remembers so the download can go on after a pause, a dropped connection, a locked phone or a
/// killed app. It is the phone's own record, written beside the files it describes (`GameLayout.downloadJournal`).
///
/// It carries no plan: the plan is made again from the `package.json` in the folder, whose hash is `revision`. It records
/// only progress, and only progress that is safe to build on: a file is `completed` after it was flushed to disk and
/// checked, and the one file in flight is `partialOffset` bytes in, a figure written after an `fsync`. A resume
/// truncates that file to the offset and trusts nothing past it, so a tail torn by a crash is never taken for data.
public struct DownloadJournal: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var sourceID: String
    public var titleID: String
    public var revision: String
    public var started: Date
    public var completed: [String]
    public var partialPath: String?
    public var partialOffset: Int64

    public init(sourceID: String, titleID: String, revision: String, started: Date = Date(),
                completed: [String] = [], partialPath: String? = nil, partialOffset: Int64 = 0) {
        self.version = Self.currentVersion
        self.sourceID = sourceID
        self.titleID = titleID
        self.revision = revision
        self.started = started
        self.completed = completed
        self.partialPath = partialPath
        self.partialOffset = partialOffset
    }

    public static func url(in folder: URL) -> URL { folder.appendingPathComponent(GameLayout.downloadJournal) }

    public static func read(in folder: URL) -> DownloadJournal? {
        guard let data = BoundedRead.dataIfPresent(at: url(in: folder), limit: 16 << 20) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let journal = try? decoder.decode(DownloadJournal.self, from: data),
              journal.version == currentVersion, TitleID(journal.titleID) != nil,
              FileDigest.isSHA256(journal.revision) else { return nil }
        return journal
    }

    public func write(in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: folder), options: .atomic)
    }
}

/// A download waiting in `.incoming`, for the Sources screen to offer to resume or cancel.
public struct PendingDownload: Identifiable, Equatable, Sendable {
    public var folder: URL
    public var sourceID: String
    public var titleID: String
    public var name: String
    public var revision: String
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var id: String { folder.lastPathComponent }
}
