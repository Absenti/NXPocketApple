import Darwin
import Foundation

/// What a build leaves in its work folder, so that cancelling it can take away what it made and nothing else.
///
/// The work folder (`<title ID>_build`) is where the engine extracts the game, compiles its shaders and keeps both "for
/// the next build": gigabytes, and for a game that was built before, hours of earlier work. A cancel must not touch that.
/// So the folder is looked at *before* the build starts, and a cancel removes only what has appeared since:
///
/// - a folder that did not exist is the build's own, and goes whole;
/// - a folder that did exist loses only the files and folders absent from the first look. A file that was already there
///   and has been rewritten since stays as it is: this cannot give it back.
///
/// Nothing outside the folder is touched, whatever a link inside it points at: a link is removed as a link.
public struct BuildFootprint: Sendable {
    public struct Removal: Equatable, Sendable {
        public var items = 0
        public var bytes: Int64 = 0
        /// The folder itself was the build's and went with all it held.
        public var wholeFolder = false
        public var isEmpty: Bool { items == 0 && !wholeFolder }
    }

    public let folder: URL
    /// False when the folder was not there to begin with.
    public let existedBefore: Bool
    /// False when the folder is not one this may delete in (not a plain `*_build` folder), or could not be read: then
    /// `removeCreated` does nothing at all.
    public let isSafe: Bool
    private let before: Set<String>

    /// Looks at `folder` now. Call it before anything is written there, `BuildInputs.prepare` included.
    public static func capture(_ folder: URL, fileManager: FileManager = .default) -> BuildFootprint {
        let folder = folder.standardizedFileURL
        guard folder.lastPathComponent.hasSuffix("_build") else {
            return BuildFootprint(folder: folder, existedBefore: false, isSafe: false, before: [])
        }
        guard let kind = Kind(of: folder) else {
            return BuildFootprint(folder: folder, existedBefore: false, isSafe: true, before: [])
        }
        // A link, or a file, in place of the folder is not something to delete in or through.
        guard kind.isDirectory, !kind.isSymbolicLink, let paths = relativePaths(under: folder, fileManager: fileManager) else {
            return BuildFootprint(folder: folder, existedBefore: true, isSafe: false, before: [])
        }
        return BuildFootprint(folder: folder, existedBefore: true, isSafe: true, before: paths)
    }

    /// Removes what has appeared in the folder since `capture`, and says how much that was.
    @discardableResult
    public func removeCreated(fileManager: FileManager = .default) -> Removal {
        var removal = Removal()
        guard isSafe, folder.lastPathComponent.hasSuffix("_build"), let kind = Kind(of: folder),
              kind.isDirectory, !kind.isSymbolicLink else { return removal }
        if !existedBefore {
            let size = Self.measure(folder, fileManager: fileManager)
            if (try? fileManager.removeItem(at: folder)) != nil {
                removal.items = size.items
                removal.bytes = size.bytes
                removal.wholeFolder = true
            }
            return removal
        }
        prune(folder, relative: "", removal: &removal, fileManager: fileManager)
        return removal
    }

    // MARK: - Walking

    private func prune(_ directory: URL, relative: String, removal: inout Removal, fileManager: FileManager) {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            let url = directory.appendingPathComponent(name)
            let path = relative.isEmpty ? name : "\(relative)/\(name)"
            guard let kind = Kind(of: url) else { continue }
            if !before.contains(path) {
                let size = Self.measure(url, fileManager: fileManager)
                if (try? fileManager.removeItem(at: url)) != nil {
                    removal.items += size.items
                    removal.bytes += size.bytes
                }
            } else if kind.isDirectory, !kind.isSymbolicLink {
                prune(url, relative: path, removal: &removal, fileManager: fileManager)
            }
        }
    }

    /// Every path under `folder` relative to it, files, folders and links alike, never following a link; nil when a
    /// folder could not be listed (a snapshot that is not whole must not be the basis of a deletion).
    private static func relativePaths(under folder: URL, fileManager: FileManager) -> Set<String>? {
        var found = Set<String>()
        var stack: [(URL, String)] = [(folder, "")]
        while let (directory, relative) = stack.popLast() {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
            for name in names {
                let url = directory.appendingPathComponent(name)
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                found.insert(path)
                if let kind = Kind(of: url), kind.isDirectory, !kind.isSymbolicLink { stack.append((url, path)) }
            }
        }
        return found
    }

    /// The entries and bytes under `url` (itself included), links counted as themselves and never followed.
    private static func measure(_ url: URL, fileManager: FileManager) -> (items: Int, bytes: Int64) {
        guard let kind = Kind(of: url) else { return (0, 0) }
        var items = 1
        var bytes: Int64 = kind.isDirectory ? 0 : kind.size
        if kind.isDirectory, !kind.isSymbolicLink {
            for name in (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [] {
                let inner = measure(url.appendingPathComponent(name), fileManager: fileManager)
                items += inner.items
                bytes += inner.bytes
            }
        }
        return (items, bytes)
    }

    /// What `lstat` says about a path: it describes a link itself, not what it points at.
    struct Kind {
        var isDirectory: Bool
        var isSymbolicLink: Bool
        var size: Int64

        init?(of url: URL) {
            var info = stat()
            guard url.withUnsafeFileSystemRepresentation({ path in path.map { lstat($0, &info) == 0 } ?? false }) else { return nil }
            let type = info.st_mode & S_IFMT
            isSymbolicLink = type == S_IFLNK
            isDirectory = type == S_IFDIR
            size = Int64(info.st_size)
        }
    }
}
