import Foundation
import NXPocketKit

/// One built game the server may serve: which files, of which size, and which build of it that is.
public struct SharedGame: Sendable {
    public let titleID: String
    /// The `<title ID>.nxgame` folder.
    public let root: URL
    public let package: GamePackage
    /// SHA-256 of `package.json`.
    public let revision: String
    /// Every file the server will serve for this game, by its path relative to `root`, with its size. Nothing else is
    /// served, whatever a request says.
    public let files: [String: Int64]
    /// The framework's icon, relative to `root`.
    public let iconPath: String?

    func remote(busy: Bool) -> RemoteGame { RemoteGame(package: package, revision: revision, busy: busy) }

    var listing: RemotePackageListing {
        RemotePackageListing(revision: revision, files: files.map { RemotePackageFile(path: $0.key, size: $0.value) }.sorted { $0.path < $1.path })
    }
}

public enum SharedLibraryError: Error, Equatable {
    case notFound
    /// The package was rebuilt, renamed or replaced since the revision asked for.
    case changed
}

/// A file opened for serving, held by its descriptor: what was checked is what is read.
public struct OpenedFile: @unchecked Sendable {
    public let descriptor: Int32
    public let size: Int64
    public func close() { _ = Darwin.close(descriptor) }
}

/// What the server shows of the player's built games, and the only door to their files.
///
/// For each ready package the set of servable files is built from the package itself (its `package.json`, the framework's
/// listed files, the RomFS image, the add-on files it counts, the icon). A request is a lookup in that set: a path that
/// is not an entry, in whatever spelling, has nothing to match, so `prod.keys`, dumps, saves, logs, partial builds and
/// hidden files are not served for the reason that they are not in it.
public final class SharedLibrary: @unchecked Sendable {
    public let folder: URL
    private let realFolder: String
    private let busy: @Sendable () -> Set<String>
    private let lock = NSLock()
    private var cache: (at: Date, games: [String: SharedGame])?
    private let cacheLife: TimeInterval

    public init(folder: URL, cacheLife: TimeInterval = 2, busy: @escaping @Sendable () -> Set<String> = { [] }) {
        self.folder = folder
        self.realFolder = Self.canonicalPath(folder) ?? folder.standardizedFileURL.path
        self.cacheLife = cacheLife
        self.busy = busy
    }

    public func games() -> [SharedGame] { scan().values.sorted { $0.titleID < $1.titleID } }

    public func game(titleID: String) -> SharedGame? { scan()[titleID.uppercased()] }

    /// What `GET /v1/games` answers.
    public func listing() -> [RemoteGame] {
        let building = busy()
        return games().map { $0.remote(busy: building.contains($0.titleID)) }
    }

    public func invalidate() { lock.withLock { cache = nil } }

    private func scan() -> [String: SharedGame] {
        if let cached = lock.withLock({ cache }), Date().timeIntervalSince(cached.at) < cacheLife { return cached.games }
        var found: [String: SharedGame] = [:]
        for local in LocalLibrary.scan(outputFolder: folder) where local.isReady {
            guard let shared = Self.shared(local, inside: realFolder) else { continue }
            found[shared.titleID] = shared
        }
        lock.withLock { cache = (Date(), found) }
        return found
    }

    /// The real path of `url`, links resolved. Foundation's `resolvingSymlinksInPath` drops a leading `/private`, which is
    /// not what the kernel reports for an open file (`F_GETPATH`), so the two would never be compared.
    static func canonicalPath(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    static func shared(_ local: LocalGame, inside realFolder: String) -> SharedGame? {
        guard let package = local.package, let titleID = TitleID(package.titleID),
              // The folder is named for the game it holds: a `.nxgame` called something else is not one of ours.
              local.root.lastPathComponent == "\(titleID.description).\(LocalLibrary.folderExtension)",
              // And it is itself in the shared folder, not a link to somewhere else.
              canonicalPath(local.root) == realFolder + "/" + local.root.lastPathComponent,
              let manifestData = BoundedRead.dataIfPresent(at: local.root.appendingPathComponent(GamePackage.fileName)) else { return nil }
        var files: [String: Int64] = [GamePackage.fileName: Int64(manifestData.count)]
        for entry in package.files { files["\(package.framework)/\(entry.path)"] = entry.size }
        if package.romfsSize > 0 { files[GameLayout.romfsFile] = package.romfsSize }
        // The list of the image's blocks, when the package names one and it is there as a regular file of its own size: what lets an
        // update fetch only what changed. The phone refuses a package that names a list the source does not serve.
        if package.romfsBlocks != nil {
            let list = local.root.appendingPathComponent(GameLayout.romfsBlocksFile)
            let attributes = try? FileManager.default.attributesOfItem(atPath: list.path)
            if attributes?[.type] as? FileAttributeType == .typeRegular, let size = attributes?[.size] as? Int64 {
                files[GameLayout.romfsBlocksFile] = size
            }
        }
        if package.aocSize > 0 {
            let aoc = local.root.appendingPathComponent(GameLayout.addOnFolder, isDirectory: true)
            guard let items = try? PackageScanner.files(in: aoc) else { return nil }
            for item in items { files["\(GameLayout.addOnFolder)/\(item.relativePath)"] = item.size }
        }
        guard files.keys.allSatisfy({ SafePath.isSafeRelative($0) }) else { return nil }
        let icon = local.iconURL.map { "\(package.framework)/\($0.lastPathComponent)" }
        return SharedGame(titleID: titleID.description, root: local.root, package: package,
                          revision: FileDigest.sha256(of: manifestData), files: files, iconPath: icon)
    }

    /// Opens one file of one build for reading. `revision` is the build the caller planned from; a package that is no
    /// longer that build is `changed`, not served.
    public func open(titleID: String, revision: String, path: String) throws -> OpenedFile {
        guard let game = game(titleID: titleID), game.files[path] != nil else { throw SharedLibraryError.notFound }
        let file = try openChecked(game.root.appendingPathComponent(path), under: game.root)
        // The descriptor is held before the revision is read: if the package is swapped in between, the two disagree and
        // the request is `changed`; if it is swapped after, the descriptor still reads the build that was asked for.
        guard let current = BoundedRead.dataIfPresent(at: game.root.appendingPathComponent(GamePackage.fileName)),
              FileDigest.sha256(of: current) == revision else {
            file.close()
            throw SharedLibraryError.changed
        }
        return file
    }

    /// The icon, a PNG that passes `PNGHeader`, or nil.
    public func icon(titleID: String) -> Data? {
        guard let game = game(titleID: titleID), let path = game.iconPath,
              let file = try? openChecked(game.root.appendingPathComponent(path), under: game.root),
              file.size <= SharingLimits.iconBytes else { return nil }
        defer { file.close() }
        var data = Data(count: Int(file.size))
        let read = data.withUnsafeMutableBytes { pread(file.descriptor, $0.baseAddress, $0.count, 0) }
        guard read == Int(file.size), PNGHeader.isAcceptableIcon(data) else { return nil }
        return data
    }

    /// `O_NOFOLLOW` covers the last component only, so the descriptor is then asked where it really is: a regular file
    /// inside the package's own folder, whatever a link in between did.
    private func openChecked(_ url: URL, under root: URL) throws -> OpenedFile {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw SharedLibraryError.notFound }
        var info = stat()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, fcntl(descriptor, F_GETPATH, &buffer) == 0,
              String(cString: buffer).hasPrefix(realFolder + "/" + root.lastPathComponent + "/") else {
            _ = Darwin.close(descriptor)
            throw SharedLibraryError.notFound
        }
        return OpenedFile(descriptor: descriptor, size: Int64(info.st_size))
    }
}
