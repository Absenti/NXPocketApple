import Foundation

/// The `.nsp` and `.xci` files `nsz -D` makes out of the user's `.nsz` and `.xcz` dumps.
///
/// The engine decompresses a compressed dump once, into `<title ID>_build/nsp/`, and keeps the result "for the next build":
/// a copy as large as the whole game (14 GB for one of the user's). It is not the dump and it is not the build; it can be
/// made again from the dump at any time, at the cost of the minutes `nsz` takes. This removes it, and only it.
///
/// What it never touches, whatever the settings say:
/// - the user's own dumps, wherever they are: a file that is one of the build's inputs (the very file, links resolved) is
///   skipped, so a dump kept inside the work folder by mistake is still safe;
/// - a link, in `nsp/` or as `nsp/` itself, and anything that is not a regular `.nsp` / `.xci` file there;
/// - the build (`.nxgame`), the extraction, the shaders, the logs: everything outside `nsp/`.
public enum DecompressedCopies {
    public struct Result: Equatable, Sendable {
        public var removed: [String] = []
        public var bytes: Int64 = 0
        public var isEmpty: Bool { removed.isEmpty }
    }

    static let suffixes: Set<String> = ["nsp", "xci"]

    /// `workFolder` is the build's `<title ID>_build`; `originals` are the files the build was given (`BuildPlan.inputs`).
    @discardableResult
    public static func remove(in workFolder: URL, keeping originals: [URL], fileManager: FileManager = .default) -> Result {
        var result = Result()
        let work = workFolder.standardizedFileURL
        guard work.lastPathComponent.hasSuffix("_build"),
              let workKind = BuildFootprint.Kind(of: work), workKind.isDirectory, !workKind.isSymbolicLink else { return result }
        let folder = work.appendingPathComponent("nsp", isDirectory: true)
        guard let folderKind = BuildFootprint.Kind(of: folder), folderKind.isDirectory, !folderKind.isSymbolicLink else { return result }

        let protected = Set(originals.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        for name in ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
            let url = folder.appendingPathComponent(name)
            guard suffixes.contains(url.pathExtension.lowercased()),
                  let kind = BuildFootprint.Kind(of: url), !kind.isDirectory, !kind.isSymbolicLink,
                  !protected.contains(url.resolvingSymlinksInPath().standardizedFileURL.path) else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                result.removed.append(name)
                result.bytes += kind.size
            }
        }
        // The folder goes too once nothing is left in it; anything else in it keeps it.
        if let left = try? fileManager.contentsOfDirectory(atPath: folder.path), left.isEmpty {
            try? fileManager.removeItem(at: folder)
        }
        return result
    }
}
