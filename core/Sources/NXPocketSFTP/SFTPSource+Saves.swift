import Citadel
import Foundation
import NIOCore
import NXPocketKit

/// Copies of saves on the server: `<folder>/.nxpocket-saves/<title ID>/iPhone <date>.zip`. The folder is hidden and inside the
/// one the player picked for games, so a server that is also a NAS keeps the copies beside the games and the listing of games
/// (which reads only `<title ID>.nxgame` folders) never sees them. A copy is written under a temporary name and renamed
/// once whole, so a connection cut in the middle leaves no copy that looks complete.
extension SFTPSource: SaveDestination {
    @discardableResult
    public func store(saves archive: URL, titleID: String) async throws -> String {
        _ = try SaveUpload.checked(archive, titleID: titleID)
        let root = Self.join(config.folder, SaveUpload.sftpFolder)
        let gameFolder = Self.join(root, titleID.uppercased())
        let partial = Self.join(gameFolder, ".part-\(UUID().uuidString)")
        let date = Date()
        return try await session.withSFTP { sftp -> String in
            // A folder that exists already is an error to `mkdir`, and the one wanted: only a missing one is created.
            for folder in [root, gameFolder] { try? await sftp.createDirectory(atPath: folder) }
            let existing = Set(try Self.entries(try await sftp.listDirectory(atPath: gameFolder)).filter { $0.kind == .file }.map(\.name))
            var name = SaveUpload.fileName(at: date)
            var index = 2
            while existing.contains(name) {
                name = String(SaveUpload.fileName(at: date).dropLast(4)) + " \(index).zip"
                index += 1
            }
            do {
                try await sftp.withFile(filePath: partial, flags: [.write, .create, .truncate]) { file in
                    let reader = try FileHandle(forReadingFrom: archive)
                    defer { try? reader.close() }
                    var offset: UInt64 = 0
                    while let chunk = try reader.read(upToCount: 256 * 1024), !chunk.isEmpty {
                        try await file.write(ByteBuffer(data: chunk), at: offset)
                        offset += UInt64(chunk.count)
                    }
                }
                try await sftp.rename(at: partial, to: Self.join(gameFolder, name))
            } catch {
                try? await sftp.remove(at: partial)
                throw error
            }
            // Only the files this app named go: whatever else is in the folder is the player's.
            let copies = (existing.union([name])).filter(SaveUpload.isCopyName).sorted(by: >)
            for old in copies.dropFirst(SaveUpload.keep) { try? await sftp.remove(at: Self.join(gameFolder, old)) }
            return name
        }
    }
}

extension SFTPSource: SaveSource {
    public func saveCopies(titleID: String) async throws -> [RemoteSaveCopy] {
        guard TitleID.isGame(titleID) else { throw NXPocketError(.packageDamaged, "\"\(titleID)\" is not a game's title ID") }
        let folder = Self.join(config.folder, SaveUpload.sftpFolder, titleID.uppercased())
        let entries: [Entry]
        do { entries = try await session.withSFTP { sftp in try Self.entries(try await sftp.listDirectory(atPath: folder)) } }
        catch PackageSourceError.notFound { return [] }
        return entries.compactMap { entry in
            guard entry.kind == .file, SaveUpload.isCopyName(entry.name), let date = SaveUpload.date(ofName: entry.name),
                  let size = entry.size, size > 0, size <= SaveUpload.maxBytes else { return nil }
            return RemoteSaveCopy(name: entry.name, size: size, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    public func fetchSaveCopy(titleID: String, name: String, to destination: URL) async throws {
        guard TitleID.isGame(titleID), SaveUpload.isCopyName(name) else { throw NXPocketError(.packageDamaged, "that is not a copy of saves") }
        let remote = Self.join(config.folder, SaveUpload.sftpFolder, titleID.uppercased(), name)
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw NXPocketError(.transferFailed, "a file for the copy could not be made")
        }
        do {
            try await session.withSFTP { sftp in
                try await sftp.withFile(filePath: remote, flags: .read) { file in
                    let size = try await file.readAttributes().size ?? 0
                    guard size > 0, size <= UInt64(SaveUpload.maxBytes) else { throw PackageSourceError.noRoom }
                    let writer = try FileHandle(forWritingTo: destination)
                    defer { try? writer.close() }
                    var offset: UInt64 = 0
                    while offset < size {
                        var chunk = try await file.read(from: offset, length: UInt32(min(256 * 1024, size - offset)))
                        guard chunk.readableBytes > 0 else { break }
                        offset += UInt64(chunk.readableBytes)
                        try writer.write(contentsOf: Data(chunk.readBytes(length: chunk.readableBytes) ?? []))
                    }
                    guard offset == size else { throw PackageSourceError.unreachable("the connection ended before the copy was whole") }
                }
            }
            guard SaveUpload.isZip(destination) else { throw PackageSourceError.malformed("what came is not a copy of saves") }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
