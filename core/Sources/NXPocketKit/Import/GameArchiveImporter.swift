import CryptoKit
import Foundation

/// A build that arrived as one archive, made a transfer the importer takes: unpacked into `Documents/.incoming/<uuid>/`, found (the
/// build may be at the top of the archive or inside one or two folders, as Finder and 7-Zip wrap it), checked, and marked `.complete`
/// last. From there the importer does what it does for a push from the Mac or a download: it verifies every file against `package.json`,
/// signs the framework and moves the folder into the library, saves carried over.
///
/// What is checked here is what only this step can: that the archive was whole and unpacked as it said. A build whose `package.json`
/// names a list of blocks (`RomfsBlocks`) has its whole image read against the list, so an archive cut short or damaged is found now and
/// not by a game that crashes. Whatever goes wrong, the folder this made is removed: nothing is left of a failed unpacking.
public struct GameArchiveImporter: Sendable {
    public enum Stage: String, Sendable { case hashing, unpacking, checking }

    /// The markers a folder of `.incoming` carries as the phone's own bookkeeping.
    static let markers: Set<String> = [GameLayout.completeMarker, GameLayout.abandonedMarker, GameLayout.downloadJournal, GameLayout.signingRecord]

    public let documents: URL
    public var availableSpace: @Sendable () -> Int64?
    public var headroom: Int64

    public init(documents: URL, availableSpace: @escaping @Sendable () -> Int64? = { nil }, headroom: Int64 = 1 << 30) {
        self.documents = documents
        self.availableSpace = availableSpace
        self.headroom = headroom
    }

    /// A SHA-256 as people copy it: spaces, colons and capitals allowed. Nil when it is not 64 hex digits.
    public static func normalisedDigest(_ text: String) -> String? {
        let cleaned = text.filter { !$0.isWhitespace && $0 != ":" }.lowercased()
        return FileDigest.isSHA256(cleaned) ? cleaned : nil
    }

    /// Reads `archive` once and compares its SHA-256 with `expected`: an archive that is not the one the player was given the hash of
    /// (a link whose file was replaced, a copy that was altered) is refused before a byte of it is unpacked.
    static func verifyDigest(of archive: URL, expected: String, progress: @escaping @Sendable (Double) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let total = Double((try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 1)
        var hasher = SHA256()
        var read = 0.0
        while let chunk = try handle.read(upToCount: FileDigest.chunkSize), !chunk.isEmpty {
            if Task.isCancelled { throw NXPocketError(.cancelled, "stopped") }
            hasher.update(data: chunk)
            read += Double(chunk.count)
            progress(min(read / max(total, 1), 1))
        }
        guard FileDigest.hex(hasher.finalize()) == expected else {
            throw NXPocketError(.hashMismatch, "the archive is not the one whose SHA-256 you gave: it was changed, or it is damaged")
        }
    }

    /// Unpacks, checks and hands over `archive`; returns the transfer folder, marked complete. The archive itself is not touched. With
    /// `expectedSHA256`, the archive is read and compared first.
    public func importArchive(_ archive: URL, expectedSHA256: String? = nil,
                              progress: @escaping @Sendable (Stage, Double) -> Void = { _, _ in }) throws -> URL {
        let format = ArchiveExtractor.detect(archive)
        if let refusal = ArchiveExtractor.unsupported(format) { throw refusal }
        if let expectedSHA256 {
            guard let expected = Self.normalisedDigest(expectedSHA256) else {
                throw NXPocketError(.packageDamaged, "that is not a SHA-256: it is 64 hexadecimal digits")
            }
            try Self.verifyDigest(of: archive, expected: expected) { progress(.hashing, $0) }
        }
        let fileManager = FileManager.default
        let root = GameLayout.incomingDirectory(in: documents)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try ArchiveExtractor.extract(archive, into: folder, availableSpace: availableSpace, headroom: headroom,
                                         progress: { progress(.unpacking, $0) })
            try Self.settle(folder, fileManager: fileManager)
            progress(.checking, 0)
            try Self.check(folder, progress: { progress(.checking, $0) })
            try Data().write(to: folder.appendingPathComponent(GameLayout.completeMarker), options: .atomic)
            return folder
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    /// A build that is already a folder (unpacked on a Mac, or on a share Files shows): copied into a transfer, then found, checked and
    /// handed over as an archive's is. A link is refused, as are the Finder's files and the markers of a transfer; the free space is checked
    /// against the folder's own size before anything is written. A copy on the same volume is a clone and costs no space.
    public func importFolder(_ source: URL, progress: @escaping @Sendable (Stage, Double) -> Void = { _, _ in }) throws -> URL {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NXPocketError(.packageMissing, "that is not a folder")
        }
        let root = GameLayout.incomingDirectory(in: documents)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try Self.copyTree(from: source, into: folder, availableSpace: availableSpace, headroom: headroom,
                              progress: { progress(.unpacking, $0) })
            try Self.settle(folder, fileManager: fileManager)
            progress(.checking, 0)
            try Self.check(folder, progress: { progress(.checking, $0) })
            try Data().write(to: folder.appendingPathComponent(GameLayout.completeMarker), options: .atomic)
            return folder
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    static func copyTree(from source: URL, into folder: URL, availableSpace: @escaping @Sendable () -> Int64?, headroom: Int64,
                         progress: @escaping @Sendable (Double) -> Void) throws {
        let fileManager = FileManager.default
        let real = source.withUnsafeFileSystemRepresentation { path -> URL in
            guard let path, let resolved = realpath(path, nil) else { return source }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
        guard let walker = fileManager.enumerator(at: real, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]) else {
            throw NXPocketError(.packageMissing, "the folder cannot be read")
        }
        var items: [(relative: String, size: Int64, isDirectory: Bool, url: URL)] = []
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
            let relative = String(url.path.dropFirst(real.path.count + 1))
            if values.isSymbolicLink == true { throw NXPocketError(.symbolicLink, "\"\(relative)\" is a link: a build holds none", path: relative) }
            if values.isDirectory == true { items.append((relative, 0, true, url)); continue }
            guard values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
            items.append((relative, Int64(values.fileSize ?? 0), false, url))
            guard items.count <= SharingLimits.maxFilesPerGame * 2 else { throw NXPocketError(.packageDamaged, "the folder holds more than \(SharingLimits.maxFilesPerGame) files") }
        }
        if let free = availableSpace(), total + headroom > free {
            throw NXPocketError(.notEnoughSpace, "\(GameImporter.bytes(total + headroom)) needed, \(GameImporter.bytes(free)) free")
        }
        let sink = ArchiveExtractor.Sink(folder: folder, availableSpace: availableSpace, headroom: headroom, progress: progress)
        sink.expectedTotal = total
        for item in items {
            guard let path = try sink.accept(item.relative) else { continue }
            if item.isDirectory { try sink.makeFolder(path); continue }
            let destination = try sink.destination(for: path)
            // On the same volume the copy is a clone: instant, and no space until a side changes.
            if copyfile(item.url.path, destination.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE | COPYFILE_DATA)) == 0 {
                try sink.account(item.size)
                continue
            }
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw NXPocketError(.transferFailed, "\"\(path)\" could not be written", path: path)
            }
            let reader = try FileHandle(forReadingFrom: item.url)
            let writer = try FileHandle(forWritingTo: destination)
            defer { try? reader.close(); try? writer.close() }
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
                try sink.wrote(chunk.count)
            }
        }
    }

    /// Puts the build at the top of `folder`: it is there already, or inside the one folder that holds it (up to two deep). Anything
    /// else is no build.
    static func settle(_ folder: URL, fileManager: FileManager) throws {
        func holdsPackage(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.appendingPathComponent(GamePackage.fileName).path) }
        func subfolders(_ url: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []).sorted().compactMap { name in
                var isDirectory: ObjCBool = false
                let child = url.appendingPathComponent(name)
                return name.hasPrefix(".") || !(fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory) && isDirectory.boolValue) ? nil : child
            }
        }
        if !holdsPackage(folder) {
            var found = subfolders(folder).filter(holdsPackage)
            if found.isEmpty { found = subfolders(folder).flatMap(subfolders).filter(holdsPackage) }
            guard found.count == 1, let build = found.first else {
                throw NXPocketError(.packageMissing, found.isEmpty
                                    ? "the archive holds no build: there is no \(GamePackage.fileName) in it, or not one this app can read"
                                    : "the archive holds several builds: unpack one game at a time")
            }
            // Moved up by renames, after the folder is renamed out of the way (a build's folder may hold an entry of its own name).
            let aside = folder.appendingPathComponent(".build-\(UUID().uuidString)", isDirectory: true)
            var top = build
            while top.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL { top = top.deletingLastPathComponent() }
            let relative = String(build.path.dropFirst(top.path.count))
            try fileManager.moveItem(at: top, to: aside)
            let inner = aside.appendingPathComponent(relative)
            for name in try fileManager.contentsOfDirectory(atPath: inner.path) {
                try fileManager.moveItem(at: inner.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            }
            try fileManager.removeItem(at: aside)
        }
        // Whatever is left beside the build that is not part of one goes, and so do any markers the archive carried inside a folder.
        for name in markers { try? fileManager.removeItem(at: folder.appendingPathComponent(name)) }
        PackageScanner.removeFinderMetadata(in: folder, fileManager: fileManager)
    }

    /// Reads the build: `package.json` is one this app reads, the framework and the image are there, the root holds only what a package
    /// holds, and, when the build carries the list of its image's blocks, every block of the image matches it.
    static func check(_ folder: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        let package = try PackageVerifier.loadPackage(folder)
        guard let titleID = TitleID(package.titleID), titleID.kind == .application else {
            throw NXPocketError(.packageInconsistent, "the build is for \(package.titleID), which is not a game")
        }
        try PackageVerifier.checkRoot(of: folder, package: package, fileManager: .default)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(package.framework).path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NXPocketError(.packageMissing, "the build has no \(package.framework)", path: package.framework)
        }
        guard package.romfsSize > 0 else { return }
        let image = folder.appendingPathComponent(GameLayout.romfsFile)
        let size = (try? FileManager.default.attributesOfItem(atPath: image.path)[.size] as? Int64) ?? nil
        guard size == package.romfsSize else {
            throw NXPocketError(.sizeMismatch, "\(GameLayout.romfsFile) is \(size ?? 0) bytes, the build says \(package.romfsSize): the archive is incomplete", path: GameLayout.romfsFile)
        }
        guard package.romfsBlocks != nil else { return }   // an earlier build: the importer checks the image's identity
        let scan: GameRepair.Scan
        do { scan = try GameRepair.scan(directory: folder, package: package, progress: progress) }
        catch GameRepair.Unavailable.noList {
            throw NXPocketError(.packageMissing, "the build names a list of blocks (\(GameLayout.romfsBlocksFile)) that is not in the archive", path: GameLayout.romfsBlocksFile)
        } catch GameRepair.Unavailable.listDamaged {
            throw NXPocketError(.hashMismatch, "\(GameLayout.romfsBlocksFile) is not the list \(GamePackage.fileName) names: the archive is damaged", path: GameLayout.romfsBlocksFile)
        }
        guard scan.isClean else {
            throw NXPocketError(.hashMismatch, "\(scan.badBlocks.count) of \(scan.blockCount) parts of \(GameLayout.romfsFile) do not match the build's list: the archive is incomplete or damaged",
                                path: GameLayout.romfsFile)
        }
    }
}
