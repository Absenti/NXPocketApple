import Foundation

/// `Documents/import-log.txt`: what was imported, when, and what went wrong. Rotated by size, never unbounded: when
/// the file is full it becomes `import-log.1.txt` (the one before that goes), so the last hours are never lost whole.
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
        var rotated = false
        if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value,
           size + UInt64(data.count) > UInt64(limits) {
            rotate(fileManager)
            rotated = true
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil else { return }
        if rotated { try? handle.write(contentsOf: Data("-- log rotated, earlier lines in \(archive.lastPathComponent) --\n".utf8)) }
        try? handle.write(contentsOf: data)
    }

    /// The file the full log is moved to.
    public var archive: URL {
        url.deletingPathExtension().appendingPathExtension("1").appendingPathExtension(url.pathExtension)
    }

    private func rotate(_ fileManager: FileManager) {
        try? fileManager.removeItem(at: archive)
        if (try? fileManager.moveItem(at: url, to: archive)) == nil {
            // Could not be moved: emptied instead, so the log still never grows without bound.
            try? fileManager.removeItem(at: url)
        }
    }

    /// The log, bounded like every file `Documents` lets others write to: one that is far larger than the app ever
    /// writes is not read at all.
    public func read() -> String {
        BoundedRead.dataIfPresent(at: url, limit: Int64(limits) * 4).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
