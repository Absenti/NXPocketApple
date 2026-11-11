import Foundation
import NXPocketKit

/// A `.nxgame` folder the launcher has already built, sitting in the output folder.
public struct LocalGame: Identifiable, Sendable {
    public var root: URL
    public var package: GamePackage?
    public var manifest: GameManifest?
    public var problem: NXPocketError?
    public var byteCount: Int64
    public var modified: Date?

    public init(root: URL, package: GamePackage? = nil, manifest: GameManifest? = nil,
                problem: NXPocketError? = nil, byteCount: Int64 = 0, modified: Date? = nil) {
        self.root = root
        self.package = package
        self.manifest = manifest
        self.problem = problem
        self.byteCount = byteCount
        self.modified = modified
    }

    public var id: String { package?.titleID ?? root.deletingPathExtension().lastPathComponent }
    public var title: String { manifest?.name ?? package?.name ?? root.deletingPathExtension().lastPathComponent }
    public var version: String { manifest?.displayVersion ?? package?.version ?? "" }
    public var titleID: String { package?.titleID ?? "" }
    public var frameworkName: String? { package?.framework }
    public var isBroken: Bool { problem != nil }
    public var isReady: Bool { problem == nil && package != nil }
    public var byteCountText: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }
    /// The version built, as the engine names it: "v0", "v65536".
    public var packageVersion: String { package?.packageVersion ?? manifest?.packageVersion ?? "" }

    /// The framework's icon: the file its manifest names, else the `icon.png` the engine puts in every framework
    /// (its manifest does not name it today, so the library showed a placeholder for every game).
    public var iconURL: URL? {
        guard let package else { return nil }
        let name = manifest?.icon.flatMap { SafePath.isSafeRelative($0) ? $0 : nil } ?? GameLayout.icon
        return root.appendingPathComponent(package.framework).appendingPathComponent(name)
    }
}

public enum LocalLibrary {
    public static let folderExtension = "nxgame"

    /// Every `<title ID>.nxgame` in the output folder. A damaged one is listed with its reason.
    ///
    /// Each is checked the cheap way the phone's listing is (`VerifyOptions.shallow`: every listed file there with
    /// its size, the RomFS image and the add-on content of the sizes `package.json` gives, no hashing), so a package
    /// that lost its RomFS image is not shown as ready to send. Its size is the one `package.json` gives, not a walk.
    public static func scan(outputFolder: URL, fileManager: FileManager = .default) -> [LocalGame] {
        let names = ((try? fileManager.contentsOfDirectory(atPath: outputFolder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        var games: [LocalGame] = []
        for name in names where name.hasSuffix(".\(folderExtension)") {
            var isDirectory: ObjCBool = false
            let root = outputFolder.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let modified = (try? fileManager.attributesOfItem(atPath: root.path))?[.modificationDate] as? Date
            var game = LocalGame(root: root, modified: modified)
            do {
                let package = try PackageVerifier.loadPackage(root, fileManager: fileManager)
                game.package = package
                game.byteCount = package.totalSize
                game.manifest = try GameManifest.decode(try BoundedRead.data(
                    at: root.appendingPathComponent(package.framework).appendingPathComponent(GameManifest.fileName),
                    fileManager: fileManager))
                _ = try PackageVerifier.verify(root, options: shallowCheck, fileManager: fileManager)
            } catch let error as NXPocketError {
                game.problem = error
            } catch {
                game.problem = NXPocketError(.packageDamaged, error.localizedDescription)
            }
            games.append(game)
        }
        return games.sorted { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) }
    }

    /// The phone's shallow check, without its OS version: this runs on a Mac.
    static let shallowCheck = VerifyOptions(verifyFileHashes: false, verifyRomfsIdentity: false,
                                            maximumMinimumOS: OSVersion(major: 999), verifyCode: false)

    public static func destination(for titleID: TitleID, in outputFolder: URL) -> URL {
        outputFolder.appendingPathComponent("\(titleID.description).\(folderExtension)", isDirectory: true)
    }
}
