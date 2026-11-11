import Foundation
import NXPocketKit

/// Gives a built package another name, the one the iPhone's library shows.
///
/// The name lives in two places the phone compares before it signs anything (docs/PACKAGE.md, check 4):
/// `package.json` and the framework's `game.manifest.json`. Both change together, and the manifest's entry in
/// `package.json`'s file list gets its new size and SHA-256 (check 8), so the renamed package passes the same
/// verification as a fresh one. Nothing else in the framework is touched: the executable keeps its bytes.
public enum PackageRenamer {
    public static let maximumLength = 120

    /// The name as it will be written: trimmed, on one line. Throws for an empty or overlong one.
    public static func clean(_ name: String) throws -> String {
        let oneLine = name.components(separatedBy: .controlCharacters).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NXPocketError(.packageInconsistent, "a game needs a name") }
        guard trimmed.count <= maximumLength else {
            throw NXPocketError(.packageInconsistent, "a name of at most \(maximumLength) characters")
        }
        return trimmed
    }

    /// The name the package carries now, from its `package.json`.
    public static func currentName(of root: URL, fileManager: FileManager = .default) throws -> String {
        try PackageVerifier.loadPackage(root, fileManager: fileManager).name
    }

    @discardableResult
    public static func rename(_ root: URL, to newName: String, fileManager: FileManager = .default) throws -> GamePackage {
        let name = try clean(newName)
        var package = try PackageVerifier.loadPackage(root, fileManager: fileManager)
        guard let index = package.files.firstIndex(where: { $0.path == GameManifest.fileName }) else {
            throw NXPocketError(.packageInconsistent, "the package does not list its \(GameManifest.fileName)")
        }
        let manifestURL = root.appendingPathComponent(package.framework).appendingPathComponent(GameManifest.fileName)
        guard let data = try? BoundedRead.data(at: manifestURL, fileManager: fileManager),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NXPocketError(.packageDamaged, "\(GameManifest.fileName) could not be read", path: manifestURL.path)
        }
        object["name"] = name
        let renamed = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Every other field the engine wrote stays as it was: the manifest must still decode as one.
        _ = try GameManifest.decode(renamed)

        // The manifest first, then package.json: until package.json is written, the package still describes the old
        // manifest, and a package caught in between fails the phone's checks instead of importing half renamed.
        try renamed.write(to: manifestURL, options: .atomic)
        package.files[index] = GamePackage.FileEntry(path: GameManifest.fileName, size: Int64(renamed.count),
                                                     sha256: try FileDigest.sha256(ofFileAt: manifestURL))
        package.name = name
        try package.data().write(to: root.appendingPathComponent(GamePackage.fileName), options: .atomic)
        return package
    }
}
