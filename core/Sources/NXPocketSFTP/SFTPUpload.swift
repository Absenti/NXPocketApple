import Citadel
import Foundation
import NIOCore
import NXPocketKit

/// A built game put on the player's own server, so the phone downloads it from there and the Mac need not be on.
///
/// The server is reached the way the phone reaches it (`SFTPSource`: the host key the player accepted, a password or a key), and a game
/// goes in as `<folder>/<title ID>.nxgame/`, where `games()` looks. Files go in the order that makes a game appear only when it is
/// whole: the small ones, the image, the list of its blocks, and `package.json` last, which is what lists a game. The old `package.json`
/// of a game already there is removed first, so a game being replaced is not offered half-written. A file is always sent from its start
/// (a prefix left by an earlier try is not known to be the same build), and its size is read back from the server before the next one.
extension SFTPSource {
    public struct UploadPlan: Equatable, Sendable {
        public struct File: Equatable, Sendable {
            public var path: String
            public var size: Int64
        }
        public var name: String
        public var files: [File]
        public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
        /// Every folder the files are in, shallowest first.
        public var folders: [String] {
            var found = Set<String>()
            for file in files {
                var parent = (file.path as NSString).deletingLastPathComponent
                while !parent.isEmpty { found.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
            }
            return found.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
        }
    }

    /// What goes up, in the order it goes. Only regular files of a `<title ID>.nxgame` folder: a link is refused, the Finder's files and
    /// this app's own markers are left out.
    public static func uploadPlan(package: URL, fileManager: FileManager = .default) throws -> UploadPlan {
        let name = package.lastPathComponent
        guard name.lowercased().hasSuffix(".nxgame"), TitleID(String(name.dropLast(7))) != nil else {
            throw NXPocketError(.packageInconsistent, "\"\(name)\" is not a built game (<title ID>.nxgame)")
        }
        // The folder as the file system names it (`/var` is `/private/var`), so the paths the walk finds are under it.
        let root = realURL(package)
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            throw NXPocketError(.packageMissing, "\(name) cannot be read")
        }
        var files: [UploadPlan.File] = []
        for case let url as URL in walker {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let last = url.lastPathComponent
            if PackageScanner.isFinderMetadata(last) || last == ".signing.json" || last == ".complete" || last == ".abandoned" { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { throw NXPocketError(.symbolicLink, "\"\(relative)\" is a link: a built game holds none", path: relative) }
            guard values.isRegularFile == true else { continue }
            guard SafePath.isSafeRelative(relative) else { throw NXPocketError(.unsafePath, "\"\(relative)\" cannot be sent", path: relative) }
            files.append(UploadPlan.File(path: relative, size: Int64(values.fileSize ?? 0)))
        }
        let last = [GameLayout.romfsFile, GameLayout.romfsBlocksFile, GamePackage.fileName]
        files.sort { (last.firstIndex(of: $0.path) ?? -1, $0.path) < (last.firstIndex(of: $1.path) ?? -1, $1.path) }
        guard files.contains(where: { $0.path == GamePackage.fileName }) else { throw NXPocketError(.packageMissing, "\(name) has no \(GamePackage.fileName)") }
        return UploadPlan(name: name, files: files)
    }

    /// Puts `package` on the server. `progress` goes from 0 to 1 by the bytes written. Cancelling the task stops it between two writes;
    /// what was sent stays, without a `package.json`, so no game is offered.
    public func upload(package: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let plan = try Self.uploadPlan(package: package)
        let root = Self.realURL(package)
        let base = config.folder.hasSuffix("/") && config.folder.count > 1 ? String(config.folder.dropLast()) : config.folder
        let remoteRoot = Self.join(base, plan.name)
        let total = max(plan.totalBytes, 1)
        try await session.withSFTP { sftp in
            // Every folder from the top, as `mkdir -p` would: one that exists is not an error here.
            var prefix = base.hasPrefix("/") ? "" : nil as String?
            for part in base.split(separator: "/", omittingEmptySubsequences: true) {
                prefix = (prefix.map { $0 + "/" } ?? "") + part
                try? await sftp.createDirectory(atPath: prefix!)
            }
            try? await sftp.createDirectory(atPath: remoteRoot)
            // A game being replaced is not a game until its new `package.json` is there.
            try? await sftp.remove(at: Self.join(remoteRoot, GamePackage.fileName))
            for folder in plan.folders { try? await sftp.createDirectory(atPath: Self.join(remoteRoot, folder)) }

            var done: Int64 = 0
            for file in plan.files {
                if Task.isCancelled { throw Self.cancelled }
                let local = root.appendingPathComponent(file.path)
                let remote = Self.join(remoteRoot, file.path)
                let before = done
                try await Self.put(local, size: file.size, to: remote, with: sftp) { written in progress(min(1, Double(before + written) / Double(total))) }
                done += file.size
                progress(min(1, Double(done) / Double(total)))
            }
        }
    }

    private static let cancelled = NXPocketError(.cancelled, "the upload was stopped")
    /// One write, and how many may be on their way at once: a request waits for its answer, so one at a time is the round trip's pace.
    private static let chunk = 256 * 1024
    private static let window = 4

    private static func put(_ local: URL, size: Int64, to remote: String, with sftp: SFTPClient, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await sftp.withFile(filePath: remote, flags: [.write, .create, .truncate]) { file in
            let reader = try FileHandle(forReadingFrom: local)
            defer { try? reader.close() }
            var offset: UInt64 = 0
            try await withThrowingTaskGroup(of: Int64.self) { group in
                var inFlight = 0
                var written: Int64 = 0
                while let data = try reader.read(upToCount: chunk), !data.isEmpty {
                    if Task.isCancelled { group.cancelAll(); throw cancelled }
                    let at = offset
                    offset += UInt64(data.count)
                    group.addTask { try await file.write(ByteBuffer(data: data), at: at); return Int64(data.count) }
                    inFlight += 1
                    if inFlight >= window, let finished = try await group.next() {
                        inFlight -= 1
                        written += finished
                        progress(written)
                    }
                }
                while let finished = try await group.next() {
                    written += finished
                    progress(written)
                }
            }
            let stored = try await file.readAttributes().size ?? 0
            guard stored == UInt64(size) else {
                throw NXPocketError(.transferFailed, "the server holds \(stored) bytes of \(local.lastPathComponent), not \(size)", path: local.lastPathComponent)
            }
        }
    }

    /// The folder as the file system names it (`/var` is `/private/var`: `resolvingSymlinksInPath` does not say so, `realpath` does).
    public static func realURL(_ url: URL) -> URL {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return url }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
    }
}
