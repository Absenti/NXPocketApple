import Foundation

/// `Documents/.launching`: written and flushed before a `dlopen`, cleared once the game has started or quit cleanly.
/// A marker still there at the next start means the last launch killed the app.
public struct LaunchMarker: Codable, Equatable, Sendable {
    public var titleID: String
    public var startedAt: Date

    public init(titleID: TitleID, startedAt: Date = Date()) {
        self.titleID = titleID.description
        self.startedAt = startedAt
    }

    public static func url(in documents: URL) -> URL {
        documents.appendingPathComponent(GameLayout.launchMarker)
    }

    /// Writes and flushes to the platter: a crash right after the `dlopen` must still leave the marker behind.
    public static func write(_ marker: LaunchMarker, in documents: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(marker)
        let url = url(in: documents)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    public static func read(in documents: URL) -> LaunchMarker? {
        let fileManager = FileManager.default
        let url = url(in: documents)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        // Read at every launch, from a folder Files can write to: a marker of several gigabytes would kill the app
        // before its first screen, at every start, until someone deleted it by hand.
        guard let data = BoundedRead.dataIfPresent(at: url, fileManager: fileManager) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LaunchMarker.self, from: data)
    }

    public static func clear(in documents: URL) {
        try? FileManager.default.removeItem(at: url(in: documents))
    }
}
