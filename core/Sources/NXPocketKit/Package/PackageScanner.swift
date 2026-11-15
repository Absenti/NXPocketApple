import Foundation

/// Walks a package on disk without ever following a symbolic link, so a link cannot pull a file from outside into
/// the checks, and reports the two things the inspector needs: every regular file, and every nested Mach-O.
public enum PackageScanner {
    public struct Item: Sendable {
        public var url: URL
        public var relativePath: String
        public var size: Int64
    }

    /// Files the Finder writes on its own: `.DS_Store` in any folder it shows, `._<name>` beside a file it copies to a
    /// volume without extended attributes. They are no part of a package. A Finder window opened on a built package
    /// put one in its framework, and the shell refused the whole transfer for it.
    public static func isFinderMetadata(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }

    /// Deletes the Finder's files under `root`, never following a link, and returns their relative paths. The shell
    /// does this before it checks a package, so nothing the package does not list is ever signed or loaded, whatever
    /// it is named.
    @discardableResult
    public static func removeFinderMetadata(in root: URL, fileManager: FileManager = .default) -> [String] {
        var removed: [String] = []
        func visit(_ folder: URL, relative: String) {
            for child in (try? children(of: folder, fileManager: fileManager)) ?? [] where !isSymbolicLink(child) {
                let path = relative.isEmpty ? child.lastPathComponent : "\(relative)/\(child.lastPathComponent)"
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    visit(child, relative: path)
                } else if isFinderMetadata(child.lastPathComponent), (try? fileManager.removeItem(at: child)) != nil {
                    removed.append(path)
                }
            }
        }
        visit(root, relative: "")
        return removed.sorted()
    }

    /// Every regular file under `root`, with its path relative to `root`, the Finder's own files aside unless asked
    /// for (so a package written next to a Finder window does not list them). A symbolic link is a refusal, not a
    /// skip, whatever its name.
    public static func files(in root: URL, fileManager: FileManager = .default,
                             includingFinderMetadata: Bool = false) throws -> [Item] {
        var items: [Item] = []
        let children = try children(of: root, fileManager: fileManager)
        for child in children {
            try walk(child, relative: child.lastPathComponent, fileManager: fileManager) { item in
                if includingFinderMetadata || !isFinderMetadata(item.url.lastPathComponent) { items.append(item) }
            }
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    /// The files whose first four bytes are a Mach-O magic, minus the ones we expect. The Finder's names are looked
    /// at too: a Mach-O called `.DS_Store` is still a hidden Mach-O.
    public static func nestedMachOs(in root: URL, allowing allowed: Set<String>,
                                    fileManager: FileManager = .default) throws -> [String] {
        var found: [String] = []
        for item in try files(in: root, fileManager: fileManager, includingFinderMetadata: true)
            where !allowed.contains(item.relativePath) {
            guard item.size >= 4, let handle = try? FileHandle(forReadingFrom: item.url),
                  let head = try? handle.read(upToCount: 4) else { continue }
            try? handle.close()
            guard head.count == 4, let magic = MachOFile.magic(of: head), MachOFile.isMachO(magic: magic) else { continue }
            found.append(item.relativePath)
        }
        return found
    }

    /// A folder's entries as the file system has them. Foundation's listing leaves out every `._<name>` file on Apple
    /// platforms (a folder holding only `._other` lists as empty), so such a file would go past every check here and be
    /// signed with the rest; readdir hides nothing.
    static func children(of url: URL, fileManager: FileManager) throws -> [URL] {
        guard let directory = url.withUnsafeFileSystemRepresentation({ $0.flatMap { opendir($0) } }) else { return [] }
        defer { closedir(directory) }
        var children: [URL] = []
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            guard name != ".", name != ".." else { continue }
            children.append(url.appendingPathComponent(name))
        }
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func walk(_ url: URL, relative: String, fileManager: FileManager,
                             visit: (Item) throws -> Void) throws {
        guard isSymbolicLink(url) == false else {
            throw NXPocketError(.symbolicLink, "symbolic links are refused", path: relative)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else {
            let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
            try visit(Item(url: url, relativePath: relative, size: attributes[.size] as? Int64 ?? 0))
            return
        }
        for child in try children(of: url, fileManager: fileManager) {
            try walk(child, relative: "\(relative)/\(child.lastPathComponent)", fileManager: fileManager, visit: visit)
        }
    }

    /// `lstat`, not `stat`: a link to a regular file reports itself only this way.
    static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, lstat(path, &info) == 0 else { return false }
            return (info.st_mode & S_IFMT) == S_IFLNK
        }
    }
}
