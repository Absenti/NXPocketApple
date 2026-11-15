import Darwin
import Foundation

/// The engine's work folders (`<title ID>_build`): where a game is extracted and its code, shaders and framework are made, gigabytes of
/// what the package no longer needs once it is written. This removes one whole, and finds the ones earlier builds left.
///
/// What may be removed is decided by name and by kind, never by what is inside: exactly sixteen hex digits and `_build`, a real
/// directory and not a link. A link in it (the inputs are links to the dumps) is removed as a link: nothing it points at is touched.
public enum BuildFolders {
    public static func isBuildFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasSuffix("_build"), name.count == 22, name.dropLast(6).allSatisfy(\.isHexDigit),
              let kind = BuildFootprint.Kind(of: url) else { return false }
        return kind.isDirectory && !kind.isSymbolicLink
    }

    /// The title ID a work folder is named after.
    public static func titleID(of folder: URL) -> String? {
        isBuildFolder(folder) ? String(folder.lastPathComponent.dropLast(6)).uppercased() : nil
    }

    /// The bytes it held, nil when it is not a work folder or could not be removed.
    @discardableResult
    public static func remove(_ folder: URL, fileManager: FileManager = .default) -> Int64? {
        guard isBuildFolder(folder) else { return nil }
        let size = size(of: folder, fileManager: fileManager)
        return (try? fileManager.removeItem(at: folder)) != nil ? size : nil
    }

    /// The work folders directly in each root and in the root's own folders (a games folder with a folder per game), not deeper.
    public static func find(in roots: [URL], fileManager: FileManager = .default) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        for root in roots {
            var candidates = [root]
            for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
                let url = root.appendingPathComponent(name, isDirectory: true)
                if let kind = BuildFootprint.Kind(of: url), kind.isDirectory, !kind.isSymbolicLink { candidates.append(url) }
            }
            for directory in candidates {
                for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix("_build") {
                    let url = directory.appendingPathComponent(name, isDirectory: true)
                    if isBuildFolder(url), seen.insert(url.standardizedFileURL.path).inserted { found.append(url) }
                }
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The bytes under a folder, links counted as themselves and never followed.
    public static func size(of folder: URL, fileManager: FileManager = .default) -> Int64 {
        var total: Int64 = 0
        var stack = [folder]
        while let directory = stack.popLast() {
            for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
                let url = directory.appendingPathComponent(name)
                guard let kind = BuildFootprint.Kind(of: url) else { continue }
                if kind.isDirectory, !kind.isSymbolicLink { stack.append(url) } else { total += kind.size }
            }
        }
        return total
    }
}
