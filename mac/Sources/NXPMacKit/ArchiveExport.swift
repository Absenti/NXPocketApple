import CryptoKit
import Foundation
import NXPocketKit
import NXPocketSFTP

/// A built game as one archive the player can put behind a link only they know, with the SHA-256 the iPhone can check before it unpacks a
/// byte of it. The archive is the system's `zip` (so any tool opens it, and the iPhone's `GameArchiveImporter` reads it), with the big
/// files stored rather than compressed (an image of gigabytes gains nothing and costs minutes); zip64 is used by itself when a file
/// is over 4 GB. The Finder's files and the markers of a transfer are left out.
public enum ArchiveExport {
    public struct Result: Equatable, Sendable {
        public var url: URL
        public var sha256: String
        public var bytes: Int64
    }

    /// `<game name> <title ID>.zip`, with nothing in the name a file system would object to.
    public static func suggestedName(for game: LocalGame) -> String {
        let cleaned = game.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)).joined()
            .trimmingCharacters(in: .whitespaces)
        return "\(cleaned.isEmpty ? "Game" : String(cleaned.prefix(60))) \(game.titleID).zip"
    }

    public static func export(package: URL, to destination: URL, zip: URL = URL(fileURLWithPath: "/usr/bin/zip"),
                              progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let name = package.lastPathComponent
        guard name.lowercased().hasSuffix(".nxgame"), TitleID(String(name.dropLast(7))) != nil else {
            throw NXPocketError(.packageInconsistent, "\"\(name)\" is not a built game (<title ID>.nxgame)")
        }
        let fileManager = FileManager.default
        let real = SFTPSource.realURL(package)
        let total = try size(of: real)
        // Written under a name of its own and renamed when whole: a cut export is never taken for an archive.
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).partial")
        try? fileManager.removeItem(at: partial)
        defer { try? fileManager.removeItem(at: partial) }

        let process = Process()
        process.executableURL = zip
        process.currentDirectoryURL = real.deletingLastPathComponent()
        process.arguments = ["-r", "-q", "-X", "-n", ".img:.blocks", partial.path, name,
                             "-x", "*.DS_Store", "*/.signing.json", "*/.complete", "*/.abandoned", "*/.download.json"]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        // The archive grows as `zip` goes: its size against the build's is how far it is (the big files are stored, so it is close).
        let watcher = Task {
            while !Task.isCancelled {
                let written = (try? fileManager.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
                if total > 0 { progress(min(Double(written) / Double(total), 0.97) * 0.8) }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) } }
        } onCancel: { process.terminate() }
        watcher.cancel()
        if Task.isCancelled { throw NXPocketError(.cancelled, "stopped") }
        guard status == 0 else {
            let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NXPocketError(.transferFailed, said.isEmpty ? "zip stopped with status \(status)" : said)
        }
        let archiveBytes = (try fileManager.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        let hash = try await hash(of: partial) { progress(0.8 + $0 * 0.2) }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partial, to: destination)
        progress(1)
        return Result(url: destination, sha256: hash, bytes: archiveBytes)
    }

    /// The SHA-256 of a file, a few megabytes at a time, with how far it is.
    public static func hash(of file: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let total = Double((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 1)
            var hasher = SHA256()
            var read = 0.0
            while let chunk = try handle.read(upToCount: FileDigest.chunkSize), !chunk.isEmpty {
                if Task.isCancelled { throw NXPocketError(.cancelled, "stopped") }
                hasher.update(data: chunk)
                read += Double(chunk.count)
                progress(min(read / max(total, 1), 1))
            }
            return FileDigest.hex(hasher.finalize())
        }.value
    }

    private static func size(of folder: URL) throws -> Int64 {
        var total: Int64 = 0
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
}
