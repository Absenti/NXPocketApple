import Foundation

/// A package folder that passed every check, ready to be signed and moved into the library.
public struct VerifiedPackage: Sendable {
    public var root: URL
    public var package: GamePackage
    public var manifest: GameManifest
    public var titleID: TitleID
    public var frameworkURL: URL
    public var executableURL: URL
    public var romfsURL: URL?
    public var aocURL: URL?
    /// What the Mach-O inspection noticed without refusing the framework, for the import log.
    public var codeWarnings: [String] = []
}

public struct VerifyOptions: Sendable {
    public var verifyFileHashes: Bool
    public var verifyRomfsIdentity: Bool
    public var maximumMinimumOS: OSVersion
    public var verifyCode: Bool

    public init(verifyFileHashes: Bool = true, verifyRomfsIdentity: Bool = true,
                maximumMinimumOS: OSVersion = .current, verifyCode: Bool = true) {
        self.verifyFileHashes = verifyFileHashes
        self.verifyRomfsIdentity = verifyRomfsIdentity
        self.maximumMinimumOS = maximumMinimumOS
        self.verifyCode = verifyCode
    }

    public static let `default` = VerifyOptions()
    /// Sizes and paths only: what a listing can afford before the user asks for an import.
    public static let shallow = VerifyOptions(verifyFileHashes: false, verifyRomfsIdentity: false, verifyCode: false)
}

/// Reads a `.nxgame` folder and refuses anything the Mac app would not have written.
public enum PackageVerifier {
    public struct Progress: Sendable {
        public var fraction: Double
        public var detail: String
    }

    public static func loadPackage(_ folder: URL, fileManager: FileManager = .default) throws -> GamePackage {
        let url = folder.appendingPathComponent(GamePackage.fileName)
        guard fileManager.fileExists(atPath: url.path) else {
            throw NXPocketError(.packageMissing, "this folder has no \(GamePackage.fileName)", path: folder.lastPathComponent)
        }
        return try GamePackage.decode(try BoundedRead.data(at: url, fileManager: fileManager))
    }

    /// Decodes `package.json` and the framework's own manifest, and checks them against each other and this device.
    @discardableResult
    public static func verify(_ folder: URL, options: VerifyOptions = .default,
                              fileManager: FileManager = .default,
                              progress: (Progress) -> Void = { _ in }) throws -> VerifiedPackage {
        let package = try loadPackage(folder, fileManager: fileManager)
        guard package.schema == GamePackage.currentSchema else {
            throw NXPocketError(.packageUnsupported,
                                "\(GamePackage.fileName) has schema \(package.schema), this app reads schema \(GamePackage.currentSchema).")
        }
        guard let titleID = TitleID(package.titleID), titleID.kind == .application else {
            throw NXPocketError(.packageDamaged, "title_id \"\(package.titleID)\" is not an application title ID.")
        }
        guard package.framework.hasSuffix(".framework"), !package.framework.contains("/"), !package.framework.hasPrefix(".") else {
            throw NXPocketError(.packageDamaged, "framework \"\(package.framework)\" is not a .framework name.")
        }

        progress(Progress(fraction: 0.02, detail: "reading \(package.framework)"))
        let frameworkURL = folder.appendingPathComponent(package.framework, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: frameworkURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NXPocketError(.packageMissing, "\(package.framework) is not in the package", path: package.framework)
        }

        let manifestURL = frameworkURL.appendingPathComponent(GameManifest.fileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw NXPocketError(.packageMissing, "the framework has no \(GameManifest.fileName)", path: package.framework)
        }
        let manifest = try GameManifest.decode(try BoundedRead.data(at: manifestURL, fileManager: fileManager))
        try crossCheck(package, manifest, folder: folder, options: options)

        let name = package.frameworkName
        var listed: [String: GamePackage.FileEntry] = [:]
        for entry in package.files {
            guard SafePath.isSafeRelative(entry.path) else {
                throw NXPocketError(.unsafePath, "the package lists \"\(entry.path)\"", path: name)
            }
            guard entry.size >= 0, entry.sha256.isEmpty || FileDigest.isSHA256(entry.sha256) else {
                throw NXPocketError(.packageDamaged, "\"\(entry.path)\" has no valid sha256.", path: name)
            }
            guard listed.updateValue(entry, forKey: entry.path) == nil else {
                throw NXPocketError(.packageDamaged, "\"\(entry.path)\" is listed twice.", path: name)
            }
        }

        let onDisk = try PackageScanner.files(in: frameworkURL, fileManager: fileManager)
        let diskPaths = Set(onDisk.map(\.relativePath))
        for path in listed.keys where !diskPaths.contains(path) {
            throw NXPocketError(.packageMissing, "\(package.framework) has no \"\(path)\"", path: path)
        }
        for item in onDisk where listed[item.relativePath] == nil {
            throw NXPocketError(.packageInconsistent, "the framework holds \"\(item.relativePath)\", which the package does not list", path: item.relativePath)
        }

        let executablePath = manifest.frameworkExecutable
        guard SafePath.isSafeRelative(executablePath), listed[executablePath] != nil else {
            throw NXPocketError(.packageInconsistent, "the manifest's framework_executable \"\(executablePath)\" is not in the package", path: name)
        }
        let executableURL = frameworkURL.appendingPathComponent(executablePath)
        // zsign signs the executable Info.plist names and the launch loads the one the manifest names: the two must be
        // the same file, or the app would load an image that was never signed.
        if let bundleExecutable = try bundleExecutable(of: frameworkURL, fileManager: fileManager),
           bundleExecutable != executablePath {
            throw NXPocketError(.packageInconsistent,
                                "Info.plist names \"\(bundleExecutable)\" as the executable, the manifest names \"\(executablePath)\"",
                                path: name)
        }

        let total = max(package.codeSize, 1)
        var done: Int64 = 0
        for entry in package.files.sorted(by: { $0.path < $1.path }) {
            guard let url = SafePath.resolve(entry.path, under: frameworkURL) else {
                throw NXPocketError(.unsafePath, "the package lists \"\(entry.path)\"", path: name)
            }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            guard size == entry.size else {
                throw NXPocketError(.sizeMismatch, "\"\(entry.path)\" is \(size) bytes, the package says \(entry.size)", path: entry.path)
            }
            if options.verifyFileHashes, !entry.sha256.isEmpty {
                let digest = try FileDigest.sha256(ofFileAt: url)
                guard digest == entry.sha256 else {
                    throw NXPocketError(.hashMismatch, "\"\(entry.path)\" does not match its sha256", path: entry.path)
                }
            }
            done += entry.size
            progress(Progress(fraction: 0.05 + 0.55 * Double(done) / Double(total), detail: entry.path))
        }

        var codeWarnings: [String] = []
        if options.verifyCode {
            progress(Progress(fraction: 0.65, detail: "checking \(executablePath)"))
            codeWarnings = try MachOInspector.inspectExecutable(at: executableURL, frameworkRoot: frameworkURL,
                                                 allowedRoots: [], policy: MachOInspector.Policy(maximumMinimumOS: options.maximumMinimumOS)).warnings
            let hidden = try PackageScanner.nestedMachOs(in: frameworkURL, allowing: [executablePath], fileManager: fileManager)
            guard hidden.isEmpty else {
                throw NXPocketError(.hiddenMachO, "the framework hides code in \(hidden.joined(separator: ", "))", path: package.framework)
            }
        }

        var romfsURL: URL?
        if package.romfsSize > 0 {
            let url = folder.appendingPathComponent(package.romfsPath)
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            guard size == package.romfsSize else {
                throw NXPocketError(.sizeMismatch, "\(package.romfsPath) is \(size) bytes, the package says \(package.romfsSize)", path: package.romfsPath)
            }
            if options.verifyRomfsIdentity, let expected = RomfsIdentity.parse(package.romfsID) {
                progress(Progress(fraction: 0.8, detail: "checking \(package.romfsPath)"))
                guard let actual = RomfsIdentity.ofImage(at: url) else {
                    throw NXPocketError(.packageDamaged, "\(package.romfsPath) is not a complete RomFS image", path: package.romfsPath)
                }
                guard actual == expected else {
                    throw NXPocketError(.hashMismatch, "\(package.romfsPath) is not the image the framework was built for", path: package.romfsPath)
                }
            }
            romfsURL = url
        }

        // Add-on content is not listed file by file, so its size is the check: what the package counts must be what is
        // there, and nothing may be there when it counts none (a rebuild without the add-ons once left the old ones).
        var aocURL: URL?
        let aoc = folder.appendingPathComponent(package.aocPath, isDirectory: true)
        let aocBytes = fileManager.fileExists(atPath: aoc.path) ? try contentBytes(of: aoc, fileManager: fileManager) : nil
        if package.aocSize > 0 {
            guard let aocBytes else {
                throw NXPocketError(.packageMissing, "the package lists add-on content but has no \(package.aocPath)/", path: package.aocPath)
            }
            guard aocBytes == package.aocSize else {
                throw NXPocketError(.sizeMismatch, "\(package.aocPath)/ holds \(aocBytes) bytes, the package says \(package.aocSize)",
                                    path: package.aocPath)
            }
            aocURL = aoc
        } else if let aocBytes, aocBytes > 0 {
            throw NXPocketError(.packageInconsistent, "\(package.aocPath)/ holds add-on content the package does not count",
                                path: package.aocPath)
        }

        progress(Progress(fraction: 1, detail: "verified"))
        return VerifiedPackage(root: folder, package: package, manifest: manifest, titleID: titleID,
                               frameworkURL: frameworkURL, executableURL: executableURL,
                               romfsURL: romfsURL, aocURL: aocURL, codeWarnings: codeWarnings)
    }

    /// `CFBundleExecutable` of the framework's Info.plist; nil when there is no Info.plist or it names none.
    static func bundleExecutable(of framework: URL, fileManager: FileManager) throws -> String? {
        let url = framework.appendingPathComponent("Info.plist")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try BoundedRead.data(at: url, fileManager: fileManager)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NXPocketError(.packageDamaged, "the framework's Info.plist could not be read", path: framework.lastPathComponent)
        }
        return plist["CFBundleExecutable"] as? String
    }

    /// The bytes of the regular files under `folder`, the Finder's own files left out. A link is refused: nothing in
    /// a package is one.
    static func contentBytes(of folder: URL, fileManager: FileManager) throws -> Int64 {
        try PackageScanner.files(in: folder, fileManager: fileManager).reduce(0) { $0 + $1.size }
    }

    /// The values the plan says are read from the framework's own manifest rather than recomputed.
    static func crossCheck(_ package: GamePackage, _ manifest: GameManifest, folder: URL, options: VerifyOptions) throws {
        guard manifest.titleID == package.titleID else {
            throw NXPocketError(.packageInconsistent,
                                "\(GamePackage.fileName) says \(package.titleID), the framework's manifest says \(manifest.titleID)")
        }
        guard manifest.name == package.name else {
            throw NXPocketError(.packageInconsistent,
                                "\(GamePackage.fileName) says \"\(package.name)\", the framework's manifest says \"\(manifest.name)\"")
        }
        guard manifest.chain == package.chain else {
            throw NXPocketError(.packageInconsistent,
                                "\(GamePackage.fileName) says chain \(package.chain), the framework's manifest says \(manifest.chain)")
        }
        guard manifest.minOS == package.minOS else {
            throw NXPocketError(.packageInconsistent,
                                "\(GamePackage.fileName) says min_os \(package.minOS), the framework's manifest says \(manifest.minOS)")
        }
        let minimum = manifest.minOSVersion ?? OSVersion(package.minOS)
        guard let minimum else {
            throw NXPocketError(.packageDamaged, "min_os \"\(package.minOS)\" is not a version.")
        }
        guard minimum <= options.maximumMinimumOS else {
            throw NXPocketError(.minimumOSNewer, "this game needs iOS \(minimum), this device runs \(options.maximumMinimumOS)")
        }
    }
}
