import Foundation
import XCTest

@testable import NXPocketKit

/// A `PackageSource` over a package folder on disk, with the failures a network and a hostile server produce, each one a
/// switch. It speaks to the downloader exactly as the HTTPS and FTP sources do.
final class FolderSource: PackageSource, @unchecked Sendable {
    let sourceID: String
    let root: URL
    private let lock = NSLock()
    private var _reads: [(path: String, offset: UInt64)] = []
    private var _bytesServed: Int64 = 0

    /// The connection fails after this many bytes in all (one time: the field clears when it fires).
    var cutAfterBytes: Int64?
    /// The stream never ends: it waits, as a stalled server does, until the consumer goes away.
    var stallAfterBytes: Int64?
    var chunkSize = 1024
    /// `read` throws `.changed` once, on the n-th call.
    var changedOnRead: Int?
    var changedEveryTime = false
    var listingEdit: ((inout RemotePackageListing) -> Void)?
    /// Rewrites a file's bytes on the way out: a tampered server.
    var contentEdit: ((String, Data) -> Data)?
    var offsetLie: UInt64?
    var lengthLie: UInt64?

    init(root: URL, sourceID: String = "test-source") {
        self.root = root
        self.sourceID = sourceID
    }

    var reads: [(path: String, offset: UInt64)] { lock.withLock { _reads } }
    var bytesServed: Int64 { lock.withLock { _bytesServed } }

    func games() async throws -> [RemoteGame] {
        let data = try Data(contentsOf: root.appendingPathComponent(GamePackage.fileName))
        let package = try GamePackage.decode(data)
        return [RemoteGame(package: package, revision: FileDigest.sha256(of: data))]
    }

    func listing(titleID: String) async throws -> RemotePackageListing {
        let data = try Data(contentsOf: root.appendingPathComponent(GamePackage.fileName))
        var files = try PackageScanner.files(in: root).map { RemotePackageFile(path: $0.relativePath, size: $0.size) }
        files.removeAll { $0.path.hasPrefix(".") }
        var listing = RemotePackageListing(revision: FileDigest.sha256(of: data), files: files)
        listingEdit?(&listing)
        return listing
    }

    func icon(titleID: String) async throws -> Data? { nil }

    func read(titleID: String, revision: String, path: String, offset: UInt64) async throws -> RemoteBody {
        let number: Int = lock.withLock { _reads.append((path, offset)); return _reads.count }
        if changedEveryTime { throw PackageSourceError.changed }
        if let changedOnRead, changedOnRead == number {
            self.changedOnRead = nil
            throw PackageSourceError.changed
        }
        var data = try Data(contentsOf: root.appendingPathComponent(path))
        if let contentEdit { data = contentEdit(path, data) }
        let start = Int(min(UInt64(data.count), offset))
        let body = data.subdata(in: start..<data.count)
        let size = chunkSize
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var position = 0
                while position < body.count {
                    if Task.isCancelled { return }
                    if let stall = self.stallAfterBytes, self.bytesServed >= stall {
                        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                        return
                    }
                    if let cut = self.cutAfterBytes, self.bytesServed >= cut {
                        self.cutAfterBytes = nil
                        continuation.finish(throwing: PackageSourceError.unreachable("the connection was cut"))
                        return
                    }
                    var end = min(position + size, body.count)
                    if let cut = self.cutAfterBytes { end = min(end, position + Int(max(cut - self.bytesServed, 1))) }
                    continuation.yield(body.subdata(in: position..<end))
                    self.lock.withLock { self._bytesServed += Int64(end - position) }
                    position = end
                    try? await Task.sleep(nanoseconds: 50_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return RemoteBody(offset: offsetLie ?? offset, length: lengthLie ?? UInt64(body.count), chunks: stream)
    }
}

extension TestWorkspace {
    /// A package a source serves, and the downloader that writes into this workspace's Documents.
    func makeSource(_ fixture: PackageFixture = PackageFixture(), folder: String = "server/package") throws -> FolderSource {
        FolderSource(root: try fixture.write(into: self, at: folder))
    }

    func makeDownloader(space: Int64? = nil, checkpoint: Int64 = 2048) throws -> PackageDownloader {
        try FileManager.default.createDirectory(at: url("Documents/.incoming"), withIntermediateDirectories: true)
        return PackageDownloader(documents: url("Documents"), availableSpace: { space }, headroom: 0,
                                 maximumMinimumOS: OSVersion(major: 27), checkpointBytes: checkpoint)
    }

    var incomingFolders: [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url("Documents/.incoming").path)) ?? []).sorted()
            .map { url("Documents/.incoming/\($0)") }
    }
}

extension RemoteGame {
    static func fixture(titleID: String = "0100111000200000") -> RemoteGame {
        RemoteGame(titleID: titleID, name: "Fixture Game", version: "1.0.0", packageVersion: "65536", minOS: "26.0",
                   revision: String(repeating: "a", count: 64), codeBytes: 1, romfsBytes: 1, aocBytes: 0)
    }
}
