import Foundation

/// `Documents/import-log.txt`: what was imported, when, and what went wrong. Rotated by size, never unbounded.
public struct ImportLog: Sendable {
    public let url: URL
    public let limits: Int

    public init(url: URL, limits: Int = GameLayout.importLogByteLimit) {
        self.url = url
        self.limits = limits
    }

    public static func standard(in documents: URL) -> ImportLog {
        ImportLog(url: documents.appendingPathComponent(GameLayout.importLog))
    }

    /// Several logs can name the same file (the importer's, the app's) and write from different threads. One lock for
    /// the process keeps each line whole and the rotation from cutting another writer's line.
    private static let lock = NSLock()

    public func append(_ message: String, at date: Date = Date()) {
        let line = "[\(Self.stamp.string(from: date))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return }
        if end + UInt64(data.count) > UInt64(limits) {
            try? handle.truncate(atOffset: 0)
            try? handle.write(contentsOf: Data("-- log rotated --\n".utf8))
        }
        try? handle.write(contentsOf: data)
    }

    public func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
