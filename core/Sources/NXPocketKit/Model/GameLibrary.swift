import Foundation

/// What the library shows for a game, derived from what is on disk. Never a bare title ID: a folder we cannot read
/// is "Unknown game" with the reason kept.
public struct InstalledGame: Identifiable, Sendable {
    public var titleID: TitleID
    public var directory: URL
    public var package: GamePackage?
    public var manifest: GameManifest?
    public var signing: SigningRecord?
    /// Set when the game cannot run at all, whatever the app or the data.
    public var problem: NXPocketError?
    public var dataBytes: Int64
    public var modified: Date?

    public init(titleID: TitleID, directory: URL, package: GamePackage? = nil, manifest: GameManifest? = nil,
                signing: SigningRecord? = nil, problem: NXPocketError? = nil, dataBytes: Int64 = 0,
                modified: Date? = nil) {
        self.titleID = titleID
        self.directory = directory
        self.package = package
        self.manifest = manifest
        self.signing = signing
        self.problem = problem
        self.dataBytes = dataBytes
        self.modified = modified
    }

    public var id: String { titleID.description }
    public var title: String { manifest?.name ?? package?.name ?? "Unknown game" }
    public var version: String { manifest?.displayVersion ?? package?.version ?? "" }
    public var chain: String? { manifest?.chain ?? package?.chain }
    public var isBroken: Bool { problem != nil }

    public var frameworkURL: URL? {
        guard let framework = package?.framework else { return nil }
        return directory.appendingPathComponent(framework, isDirectory: true)
    }

    public var executableURL: URL? {
        guard let frameworkURL, let name = manifest?.frameworkExecutable, SafePath.isSafeRelative(name) else { return nil }
        return frameworkURL.appendingPathComponent(name)
    }

    public var iconURL: URL? {
        guard let icon = manifest?.icon, SafePath.isSafeRelative(icon), let frameworkURL else { return nil }
        return frameworkURL.appendingPathComponent(icon)
    }

    public var romfsURL: URL { directory.appendingPathComponent("romfs.img") }
    public var aocURL: URL { directory.appendingPathComponent("aoc", isDirectory: true) }

    /// The bytes on disk, or the package's declared total when the folder could not be read.
    public var byteCount: Int64 { dataBytes > 0 ? dataBytes : (package?.totalSize ?? 0) }

    /// True when the game has to be signed again before it can run: another certificate, or one about to run out.
    public func needsResign(against identity: SigningIdentity, now: Date = Date()) -> Bool {
        signing?.needsResign(against: identity, now: now) ?? true
    }

    public func isSigned(by identity: SigningIdentity) -> Bool {
        signing?.certificateSHA256 == identity.certificateSHA256 && signing?.identifier == identity.identifier
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let signing else { return true }
        return signing.expires <= now
    }
}

/// Reads the library folder. Every failure is reported, never thrown: a damaged game must still be listed, with its
/// reason, so the user can re-sign or re-import it.
public enum GameLibrary {
    public static func scan(documents: URL, fileManager: FileManager = .default) -> [InstalledGame] {
        let root = GameLayout.gamesDirectory(in: documents)
        let names = ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        return names.compactMap { name in
            var isDirectory: ObjCBool = false
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return entry(at: directory, fileManager: fileManager)
        }
    }

    public static func entry(at directory: URL, fileManager: FileManager = .default) -> InstalledGame {
        let folderName = directory.lastPathComponent
        let modified = (try? fileManager.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
        var game = InstalledGame(titleID: TitleID(folderName) ?? TitleID(rawValue: 0), directory: directory, modified: modified)
        do {
            let package = try PackageVerifier.loadPackage(directory, fileManager: fileManager)
            game.package = package
            guard let titleID = TitleID(package.titleID), titleID.kind == .application else {
                throw NXPocketError(.packageDamaged, "title_id \"\(package.titleID)\" is not an application title ID.")
            }
            game.titleID = titleID
            let framework = directory.appendingPathComponent(package.framework)
            let manifestURL = framework.appendingPathComponent(GameManifest.fileName)
            if fileManager.fileExists(atPath: manifestURL.path) {
                game.manifest = try GameManifest.decode(try BoundedRead.data(at: manifestURL, fileManager: fileManager))
            }
            game.signing = readSigning(directory, fileManager: fileManager)
            game.dataBytes = measuredBytes(of: directory, fileManager: fileManager)
            try checkComplete(game, package: package, fileManager: fileManager)
        } catch let error as NXPocketError {
            game.problem = error
        } catch {
            game.problem = NXPocketError(.packageDamaged, error.localizedDescription)
        }
        return game
    }

    /// A folder that lost part of its game (a copy through Files cut short, a file deleted by hand) is listed as
    /// damaged with what is missing, rather than as a game whose Play button fails at signing or at load.
    static func checkComplete(_ game: InstalledGame, package: GamePackage, fileManager: FileManager) throws {
        guard let framework = game.frameworkURL, fileManager.fileExists(atPath: framework.path) else {
            throw NXPocketError(.packageMissing, "\(package.framework) is missing", path: package.framework)
        }
        guard game.manifest != nil else {
            throw NXPocketError(.packageMissing, "\(package.framework) has no \(GameManifest.fileName)", path: package.framework)
        }
        guard let executable = game.executableURL, fileManager.fileExists(atPath: executable.path) else {
            throw NXPocketError(.packageMissing, "the game's code, \(game.manifest?.frameworkExecutable ?? "?"), is missing",
                                path: package.framework)
        }
        if package.romfsSize > 0, !fileManager.fileExists(atPath: game.romfsURL.path) {
            throw NXPocketError(.packageMissing, "\(GameLayout.romfsFile) is missing", path: GameLayout.romfsFile)
        }
    }

    public static func readSigning(_ directory: URL, fileManager: FileManager = .default) -> SigningRecord? {
        guard let data = BoundedRead.dataIfPresent(at: directory.appendingPathComponent(GameLayout.signingRecord),
                                                   fileManager: fileManager) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SigningRecord.self, from: data)
    }

    public static func writeSigning(_ record: SigningRecord, in directory: URL, fileManager: FileManager = .default) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: directory.appendingPathComponent(GameLayout.signingRecord), options: .atomic)
    }

    /// Every byte under the folder, links skipped.
    static func measuredBytes(of directory: URL, fileManager: FileManager) -> Int64 {
        var total: Int64 = 0
        var stack = [directory]
        while let url = stack.popLast() {
            guard let children = try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey], options: []) else { continue }
            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true { stack.append(child) }
                else { total += Int64(values?.fileSize ?? 0) }
            }
        }
        return total
    }
}
