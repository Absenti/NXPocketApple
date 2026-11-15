import Foundation

/// What a download will fetch, and nothing else. It is derived from the game's own `package.json`: the source's file
/// list is only compared against it. A name or a size that the plan does not contain is never requested, and a list that
/// differs from the plan by one entry refuses the game before a second byte is fetched.
public struct DownloadPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// Relative to the package folder: `<framework>/<file>`, `aoc/<file>` or `romfs.img`.
        public var path: String
        public var size: Int64
        /// Known for the framework's files only: `romfs.img` and the add-on images are too big to read back on a phone,
        /// and are checked by size here and by the importer's identity check later, as for a package the Mac pushes.
        public var sha256: String?
    }

    public let titleID: TitleID
    public let package: GamePackage
    public let revision: String
    /// `package.json` as received. It is written first and is what the revision is the hash of.
    public let manifestData: Data
    public let items: [Item]

    public var blocks: RomfsBlocks? { package.romfsBlocks }

    public var totalBytes: Int64 { items.reduce(Int64(manifestData.count)) { $0 + $1.size } }

    /// Builds the plan, or refuses the package. `expected` is the game the player asked for.
    public static func make(manifestData: Data, listing: RemotePackageListing, expected: TitleID,
                            maximumMinimumOS: OSVersion = .current) throws -> DownloadPlan {
        guard manifestData.count <= SharingLimits.metadataBytes else {
            throw NXPocketError(.packageDamaged, "package.json is larger than \(SharingLimits.metadataBytes) bytes")
        }
        let revision = FileDigest.sha256(of: manifestData)
        guard revision == listing.revision else {
            throw NXPocketError(.hashMismatch, "package.json is not the one the source named (another build)", path: GamePackage.fileName)
        }
        let package = try GamePackage.decode(manifestData)
        guard package.schema == GamePackage.currentSchema else {
            throw NXPocketError(.packageUnsupported,
                                "\(GamePackage.fileName) has schema \(package.schema), this app reads schema \(GamePackage.currentSchema).")
        }
        guard let titleID = TitleID(package.titleID), titleID.kind == .application, titleID == expected else {
            throw NXPocketError(.packageInconsistent, "the package is for \(package.titleID), not for \(expected)")
        }
        guard let minimum = OSVersion(package.minOS) else {
            throw NXPocketError(.packageDamaged, "min_os \"\(package.minOS)\" is not a version.")
        }
        guard minimum <= maximumMinimumOS else {
            throw NXPocketError(.minimumOSNewer, "this game needs iOS \(minimum), this device runs \(maximumMinimumOS)")
        }
        guard package.romfsSize >= 0, package.aocSize >= 0, package.files.count <= SharingLimits.maxFilesPerGame else {
            throw NXPocketError(.packageDamaged, "\(GamePackage.fileName) has impossible sizes")
        }

        // What the package says it holds, by path.
        var expectedSizes: [String: Int64] = [GamePackage.fileName: Int64(manifestData.count)]
        var framework: [Item] = []
        var codeBytes: Int64 = 0
        for entry in package.files {
            let path = "\(package.framework)/\(entry.path)"
            guard SafePath.isSafeRelative(entry.path), SafePath.isSafeRelative(path), !hasFinderName(path) else {
                throw NXPocketError(.unsafePath, "the package lists \"\(entry.path)\"", path: package.framework)
            }
            guard entry.size >= 0, FileDigest.isSHA256(entry.sha256) else {
                throw NXPocketError(.packageDamaged, "\"\(entry.path)\" has no valid size and sha256", path: package.framework)
            }
            guard expectedSizes.updateValue(entry.size, forKey: path) == nil else {
                throw NXPocketError(.packageDamaged, "\"\(entry.path)\" is listed twice", path: package.framework)
            }
            framework.append(Item(path: path, size: entry.size, sha256: entry.sha256))
            codeBytes += entry.size
            guard codeBytes <= SharingLimits.maxGameBytes else {
                throw NXPocketError(.packageDamaged, "the package's code is larger than \(SharingLimits.maxGameBytes) bytes")
            }
        }
        guard codeBytes + package.romfsSize + package.aocSize <= SharingLimits.maxGameBytes,
              codeBytes + package.romfsSize + package.aocSize >= 0 else {
            throw NXPocketError(.packageDamaged, "the package is larger than \(SharingLimits.maxGameBytes) bytes")
        }
        if package.romfsSize > 0 { expectedSizes[GameLayout.romfsFile] = package.romfsSize }
        var blocksItem: Item?
        if let blocks = package.romfsBlocks {
            let listBytes = blocks.listBytes(forImageOf: package.romfsSize)
            guard blocks.isValid, package.romfsSize > 0, listBytes <= Int64(RomfsBlocks.maxListBytes) else {
                throw NXPocketError(.packageDamaged, "romfs_blocks in \(GamePackage.fileName) is not a list of blocks", path: GameLayout.romfsBlocksFile)
            }
            expectedSizes[GameLayout.romfsBlocksFile] = listBytes
            blocksItem = Item(path: GameLayout.romfsBlocksFile, size: listBytes, sha256: blocks.sha256)
        }

        // What the source says it holds, compared with it. The add-on content is not listed file by file in
        // package.json, so its files are the source's, held to the one number the package gives: their total.
        guard listing.files.count <= SharingLimits.maxFilesPerGame + 2 else {
            throw NXPocketError(.packageDamaged, "the source lists more than \(SharingLimits.maxFilesPerGame) files")
        }
        var listed: [String: Int64] = [:]
        var addOns: [Item] = []
        var addOnBytes: Int64 = 0
        let addOnPrefix = GameLayout.addOnFolder + "/"
        for file in listing.files {
            guard SafePath.isSafeRelative(file.path), file.size >= 0, !hasFinderName(file.path) else {
                throw NXPocketError(.unsafePath, "the source lists \"\(file.path)\"")
            }
            guard listed.updateValue(file.size, forKey: file.path) == nil else {
                throw NXPocketError(.packageDamaged, "the source lists \"\(file.path)\" twice")
            }
            if file.path.hasPrefix(addOnPrefix) {
                addOns.append(Item(path: file.path, size: file.size, sha256: nil))
                addOnBytes += file.size
                guard addOnBytes <= SharingLimits.maxGameBytes else {
                    throw NXPocketError(.packageDamaged, "the add-on content is larger than \(SharingLimits.maxGameBytes) bytes")
                }
            }
        }
        for (path, size) in expectedSizes {
            guard let have = listed[path] else {
                throw NXPocketError(.packageMissing, "the source does not hold \"\(path)\"", path: path)
            }
            guard have == size else {
                throw NXPocketError(.sizeMismatch, "the source lists \"\(path)\" at \(have) bytes, the package says \(size)", path: path)
            }
        }
        for path in listed.keys where expectedSizes[path] == nil && !path.hasPrefix(addOnPrefix) {
            throw NXPocketError(.packageInconsistent, "the source holds \"\(path)\", which the package does not list", path: path)
        }
        guard addOnBytes == package.aocSize, addOns.isEmpty == (package.aocSize == 0) else {
            throw NXPocketError(.sizeMismatch, "the add-on content is \(addOnBytes) bytes, the package says \(package.aocSize)",
                                path: GameLayout.addOnFolder)
        }

        var items = framework.sorted { $0.path < $1.path }
        items += addOns.sorted { $0.path < $1.path }
        // The list of blocks comes before the image: the image is fetched by comparing it with the list.
        if let blocksItem { items.append(blocksItem) }
        if package.romfsSize > 0 { items.append(Item(path: GameLayout.romfsFile, size: package.romfsSize, sha256: nil)) }
        try checkCollisions(items.map(\.path))
        return DownloadPlan(titleID: titleID, package: package, revision: revision, manifestData: manifestData, items: items)
    }

    /// A volume that ignores case and Unicode form (the phone's) maps two names that differ only in those to one file,
    /// and a file cannot also be a folder: either would let the source write one planned file over another.
    static func checkCollisions(_ paths: [String]) throws {
        func folded(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        var files = Set<String>()
        var folders = Set<String>()
        for path in paths {
            let key = folded(path)
            guard files.insert(key).inserted, !folders.contains(key) else {
                throw NXPocketError(.packageInconsistent, "\"\(path)\" collides with another name on this volume", path: path)
            }
            var prefix = ""
            for component in key.split(separator: "/").dropLast() {
                prefix += (prefix.isEmpty ? "" : "/") + component
                guard !files.contains(prefix) else {
                    throw NXPocketError(.packageInconsistent, "\"\(path)\" sits under a file of the same name", path: path)
                }
                folders.insert(prefix)
            }
        }
    }

    static func hasFinderName(_ path: String) -> Bool {
        path.split(separator: "/").contains { PackageScanner.isFinderMetadata(String($0)) }
    }
}
