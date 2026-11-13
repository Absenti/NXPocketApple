import Foundation
import NXPocketKit

/// The launcher's log on disk: `~/Library/Logs/NXPocketApple/launcher.log`, one timestamped line per line the window's
/// log shows (the engine's own output, what was built, packed, sent, and why anything failed).
///
/// The window keeps the last 800 lines in memory and nothing else, so a build that failed an hour ago, or in a launcher
/// that has since quit, left nothing to read. This keeps the last 2 MB (`launcher.1.log` holds the one before), written
/// off the main thread: the engine can print tens of thousands of lines while it compiles shaders.
public final class LauncherLog: @unchecked Sendable {
    public static let byteLimit = 1 << 20
    public let url: URL
    private let log: ImportLog
    private let queue = DispatchQueue(label: "dev.nxpocketapple.launcher-log", qos: .utility)

    public init(url: URL = LauncherLog.standardURL, limit: Int = LauncherLog.byteLimit) {
        self.url = url
        self.log = ImportLog(url: url, limits: limit)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public static var standardURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NXPocketApple/launcher.log")
    }

    public func append(_ line: String, at date: Date = Date()) {
        queue.async { [log] in log.append(line, at: date) }
    }

    /// Waits for what was appended so far to reach the file: for a test, and for the quit.
    public func flush() {
        queue.sync {}
    }

    /// The log as text, the older file first.
    public func read() -> String {
        flush()
        let older = BoundedRead.dataIfPresent(at: log.archive, limit: Int64(Self.byteLimit) * 2)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return older + (BoundedRead.dataIfPresent(at: url, limit: Int64(Self.byteLimit) * 2)
            .flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }
}
