import Foundation

/// Relative paths only, contained in the package root. Rejects absolute paths, `..` segments, empty
/// components and NUL bytes before any file system call is made.
public enum SafePath {
    public static let maxLength = 512

    public static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= maxLength else { return false }
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\0") else { return false }
        guard !path.contains("\\") else { return false }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty { return false }
            if component == "." || component == ".." { return false }
        }
        return true
    }

    /// Resolves `path` under `root` and checks the result stays there, following symlinks of the parents.
    public static func resolve(_ path: String, under root: URL) -> URL? {
        guard isSafeRelative(path) else { return nil }
        let candidate = root.appendingPathComponent(path)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved == resolvedRoot || resolved.path.hasPrefix(resolvedRoot.path + "/") else { return nil }
        return resolved
    }

    /// True when `url` sits under `root` without leaving it.
    public static func contains(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
