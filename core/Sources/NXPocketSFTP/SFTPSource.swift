import Citadel
import Foundation
import NIOCore
import NXPocketKit

/// Games on a server reached over SFTP: a NAS with its SSH service on, a seedbox, any machine that runs an SSH server. The
/// phone is the client: it connects out, never listens, and the only requests it makes are the ones that read.
///
/// The server is known by its host key, accepted once by the player (`hostKey(of:)` shows it before anything secret is sent)
/// and pinned from then on, so a changed key stops the connection before a password or a signature leaves the phone. Like
/// FTP, SFTP has no revisions: the plan is made from the `package.json` read at the start and every file is checked against
/// it as it arrives, so a package rebuilt on the server during a download is refused by its hashes and sizes.
public final class SFTPSource: PackageSource, @unchecked Sendable {
    public let config: SFTPConfig
    let session: SFTPSession
    private let lock = NSLock()
    private var folderNames: [String: String] = [:]

    public var sourceID: String { Self.sourceID(for: config) }

    /// A server is identified by where it is, who logs in and which folder: the same server with another folder is another
    /// source, with its own paused downloads.
    public static func sourceID(for config: SFTPConfig) -> String {
        "sftp-" + FileDigest.sha256(of: Data("\(config.host):\(config.port):\(config.user):\(config.folder)".utf8)).prefix(16)
    }

    public init(config: SFTPConfig, credential: SFTPCredential, idleTimeout: TimeInterval = SharingLimits.idleTimeout) {
        self.config = config
        self.session = SFTPSession(config: config, credential: credential, timeout: idleTimeout)
    }

    deinit { Task { [session] in await session.close() } }

    // MARK: first contact and browsing

    /// The key the server presents. Nothing of the player's is sent: the handshake stops at the key, as `ssh` does when it asks
    /// "are you sure you want to continue connecting".
    public static func hostKey(of config: SFTPConfig, timeout: TimeInterval = 10) async throws -> SFTPHostKey {
        try await SFTPSession.hostKey(of: config, timeout: timeout)
    }

    /// Where the server puts this user: the real path of ".". The folder browser starts there.
    public func homeDirectory() async throws -> String {
        try await session.withSFTP { try await $0.getRealPath(atPath: ".") }
    }

    /// The folders in `path`, for the player to pick the one that holds the games.
    public func directories(in path: String) async throws -> [String] {
        try await session.withSFTP { sftp in
            try Self.entries(try await sftp.listDirectory(atPath: path)).filter { $0.kind == .directory }.map(\.name).sorted()
        }
    }

    /// A folder on the server, for the player who browses to where the games should go and finds it is not there yet.
    public func makeDirectory(_ path: String) async throws {
        try await session.withSFTP { try await $0.createDirectory(atPath: path) }
    }

    public func close() async { await session.close() }

    // MARK: PackageSource

    public func games() async throws -> [RemoteGame] {
        let folder = config.folder
        let (games, names) = try await session.withSFTP { sftp -> ([RemoteGame], [String: String]) in
            var games: [RemoteGame] = []
            var names: [String: String] = [:]
            for entry in try Self.entries(try await sftp.listDirectory(atPath: folder)) where entry.kind == .directory && Self.isPackageFolder(entry.name) {
                guard games.count < SharingLimits.maxGames else { break }
                guard let data = try? await Self.readSmall(sftp, Self.join(folder, entry.name, GamePackage.fileName)),
                      let package = try? GamePackage.decode(data), let id = TitleID(package.titleID), id.kind == .application,
                      entry.name.uppercased() == "\(id.description).NXGAME" else { continue }
                names[id.description] = entry.name
                games.append(RemoteGame(package: package, revision: FileDigest.sha256(of: data)))
            }
            return (games, names)
        }
        lock.withLock { folderNames = names }
        return games.sorted { $0.titleID < $1.titleID }
    }

    public func listing(titleID: String) async throws -> RemotePackageListing {
        let root = try await packageFolder(titleID)
        let folder = config.folder
        return try await session.withSFTP { sftp in
            let manifest = try await Self.readSmall(sftp, Self.join(folder, root, GamePackage.fileName))
            var files: [RemotePackageFile] = []
            try await Self.walk(sftp, Self.join(folder, root), relative: "", depth: 0, into: &files)
            return RemotePackageListing(revision: FileDigest.sha256(of: manifest), files: files)
        }
    }

    public func read(titleID: String, revision: String, path relative: String, offset: UInt64) async throws -> RemoteBody {
        guard SafePath.isSafeRelative(relative) else { throw PackageSourceError.malformed("\"\(relative)\" is not a path in a package") }
        let root = try await packageFolder(titleID)
        let remote = Self.join(config.folder, root, relative)
        let channel = try await session.openChannel()
        let file: SFTPFile
        let size: UInt64
        do {
            file = try await channel.openFile(filePath: remote, flags: .read)
            size = try await file.readAttributes().size ?? 0
        } catch {
            try? await channel.close()
            throw SFTPErrors.map(error, judge: nil)
        }
        guard offset <= size else {
            try? await file.close()
            try? await channel.close()
            throw PackageSourceError.malformed("the server's file is shorter than the offset asked for")
        }
        let stream = SFTPReadStream(file: file, channel: channel, offset: offset, end: size, timeout: config.timeout,
                                    onTimeout: { [session] in Task { await session.close() } })
        return RemoteBody(offset: offset, length: size - offset, chunks: stream.chunks())
    }

    /// The framework's `icon.png`, read from the server like any file of the package (the Mac and a web library serve the same picture): a
    /// PNG that passes `PNGHeader`, or nil. Nothing is run through an image decoder before that.
    public func icon(titleID: String) async throws -> Data? {
        let root = try await packageFolder(titleID)
        let folder = config.folder
        return try await session.withSFTP { sftp -> Data? in
            guard let manifest = try? await Self.readSmall(sftp, Self.join(folder, root, GamePackage.fileName)),
                  let package = try? GamePackage.decode(manifest), SafePath.isSafeComponent(package.framework),
                  let data = try? await Self.readSmall(sftp, Self.join(folder, root, package.framework, GameLayout.icon),
                                                       limit: SharingLimits.iconBytes),
                  PNGHeader.isAcceptableIcon(data) else { return nil }
            return data
        }
    }

    // MARK: listings

    struct Entry: Equatable {
        enum Kind: Equatable { case file, directory, other }
        var name: String
        var kind: Kind
        var size: Int64?
    }

    /// The entries of a directory as the server lists them, `.` and `..` left out. The kind comes from the permission bits the
    /// server reports (`S_IFMT`): a link is `other`, and is never read as the file or folder it points to.
    static func entries(_ names: [SFTPMessage.Name]) throws -> [Entry] {
        var found: [Entry] = []
        for name in names {
            for component in name.components {
                let file = component.filename
                guard file != ".", file != ".." else { continue }
                guard SafePath.isSafeComponent(file) else { throw PackageSourceError.malformed("the server lists a file with an odd name") }
                let type = (component.attributes.permissions ?? 0) & 0o170000
                let kind: Entry.Kind = type == 0o100000 ? .file : type == 0o040000 ? .directory : .other
                found.append(Entry(name: file, kind: kind, size: component.attributes.size.flatMap { Int64(exactly: $0) }))
                guard found.count <= 200_000 else { throw PackageSourceError.malformed("the folder lists too many entries") }
            }
        }
        return found
    }

    static func walk(_ sftp: SFTPClient, _ folder: String, relative: String, depth: Int, into files: inout [RemotePackageFile]) async throws {
        guard depth <= 8 else { throw PackageSourceError.malformed("the package is nested too deep") }
        let remote = relative.isEmpty ? folder : join(folder, relative)
        for entry in try entries(try await sftp.listDirectory(atPath: remote)) {
            let child = relative.isEmpty ? entry.name : "\(relative)/\(entry.name)"
            switch entry.kind {
            case .file:
                guard let size = entry.size, size >= 0 else { throw PackageSourceError.malformed("the server does not give the size of \(child)") }
                files.append(RemotePackageFile(path: child, size: size))
                guard files.count <= SharingLimits.maxFilesPerGame else { throw PackageSourceError.malformed("the package holds too many files") }
            case .directory:
                try await walk(sftp, folder, relative: child, depth: depth + 1, into: &files)
            case .other:
                throw PackageSourceError.malformed("\(child) is a link or a special file: a package holds neither")
            }
        }
    }

    /// A small file, whole, refused beyond `SharingLimits.metadataBytes`.
    static func readSmall(_ sftp: SFTPClient, _ path: String, limit: Int = SharingLimits.metadataBytes) async throws -> Data {
        let file = try await sftp.openFile(filePath: path, flags: .read)
        defer { Task { try? await file.close() } }
        let size = try await file.readAttributes().size ?? 0
        guard size <= UInt64(limit) else { throw PackageSourceError.malformed("\(path) is larger than \(limit) bytes") }
        var data = Data()
        while UInt64(data.count) < size {
            var chunk = try await file.read(from: UInt64(data.count), length: 64 * 1024)
            guard chunk.readableBytes > 0 else { break }
            data.append(contentsOf: chunk.readBytes(length: chunk.readableBytes) ?? [])
        }
        return data
    }

    static func isPackageFolder(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".nxgame"), SafePath.isSafeComponent(name) else { return false }
        return TitleID(String(name.dropLast(7))) != nil
    }

    static func join(_ parts: String...) -> String {
        var path = parts[0]
        for part in parts.dropFirst() { path += (path.hasSuffix("/") ? "" : "/") + part }
        return path
    }

    private func packageFolder(_ titleID: String) async throws -> String {
        if let known = lock.withLock({ folderNames[titleID.uppercased()] }) { return known }
        _ = try await games()
        guard let known = lock.withLock({ folderNames[titleID.uppercased()] }) else { throw PackageSourceError.notFound }
        return known
    }
}

extension SFTPConfig {
    var timeout: TimeInterval { SharingLimits.idleTimeout }
}

/// A file read in slots of 128 KiB, eight in flight, handed out in order. A request and its answer cost one round trip, so
/// reading one slot at a time would cap the speed at a slot per round trip: over the internet, to a seedbox, that is a few
/// megabytes a second at best. The window is what the stream holds in memory, 1 MiB, and what a consumer that stops reading
/// leaves unread: nothing is requested beyond it.
final class SFTPReadStream: @unchecked Sendable {
    static let slot = 128 * 1024
    static let window = 8

    private let file: SFTPFile
    private let channel: SFTPClient
    private let end: UInt64
    private let timeout: TimeInterval
    private let onTimeout: @Sendable () -> Void
    private let lock = NSLock()
    private var next: UInt64
    private var pending: [Task<Data, Error>] = []
    private var closed = false

    init(file: SFTPFile, channel: SFTPClient, offset: UInt64, end: UInt64, timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
        self.file = file
        self.channel = channel
        self.next = offset
        self.end = end
        self.timeout = timeout
        self.onTimeout = onTimeout
    }

    deinit { shutdown() }

    func chunks() -> AsyncThrowingStream<Data, Error> {
        let guardian = Guardian(stream: self)
        return AsyncThrowingStream(unfolding: { try await guardian.stream.nextChunk() })
    }

    func nextChunk() async throws -> Data? {
        let task: Task<Data, Error>? = lock.withLock {
            while pending.count < Self.window, next < end, !closed {
                let offset = next
                let length = Int(min(UInt64(Self.slot), end - offset))
                next += UInt64(length)
                pending.append(Task { [file] in try await Self.slot(file, offset: offset, length: length) })
            }
            return pending.isEmpty ? nil : pending.removeFirst()
        }
        guard let task else {
            shutdown()
            return nil
        }
        do {
            return try await Timeout.run(seconds: timeout, onTimeout: onTimeout) { try await task.value }
        } catch {
            shutdown()
            throw SFTPErrors.map(error, judge: nil)
        }
    }

    /// One slot, filled even when the server answers with less than was asked: the stream's order must not have holes.
    private static func slot(_ file: SFTPFile, offset: UInt64, length: Int) async throws -> Data {
        var data = Data()
        while data.count < length {
            var buffer = try await file.read(from: offset + UInt64(data.count), length: UInt32(length - data.count))
            guard buffer.readableBytes > 0 else { break }
            data.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        }
        return data
    }

    func shutdown() {
        let (tasks, already) = lock.withLock { () -> ([Task<Data, Error>], Bool) in
            defer { closed = true; pending = [] }
            return (pending, closed)
        }
        guard !already else { return }
        tasks.forEach { $0.cancel() }
        let file = file, channel = channel
        Task {
            try? await file.close()
            try? await channel.close()
        }
    }

    /// Lives as long as the stream: one that is dropped unfinished closes the file and its channel.
    private final class Guardian {
        let stream: SFTPReadStream
        init(stream: SFTPReadStream) { self.stream = stream }
        deinit { stream.shutdown() }
    }
}
