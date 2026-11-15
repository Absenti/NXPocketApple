import Foundation
import NXPocketKit

public struct PackagedGame: Sendable {
    public var root: URL
    public var package: GamePackage
    public var manifest: GameManifest
}

/// Assembles a `<title ID>.nxgame` folder: the framework the engine built, its RomFS image, its add-on content and
/// the `package.json` the phone verifies before it signs anything.
///
/// Written whole into `<title ID>.nxgame.partial`, checked there with the phone's own `PackageVerifier`, then swapped in by
/// a rename: a build cut off halfway never leaves the old `package.json` beside new content, nor an old `aoc/` behind.
public enum PackageWriter {
    public static let createdBy = "nxpocket-desktop 0.1"
    public static let partialSuffix = ".partial"

    public struct Progress: Sendable {
        public var fraction: Double
        public var detail: String
    }

    /// What the Mac checks of a package it wrote: everything the phone checks, save the phone's own OS version.
    static let macVerification = VerifyOptions(maximumMinimumOS: OSVersion(major: 999))

    public static func partialFolder(for destination: URL) -> URL {
        URL(fileURLWithPath: destination.path + partialSuffix, isDirectory: true)
    }

    @discardableResult
    public static func write(framework: URL, romfsImage: URL?, aocFolder: URL?, into destination: URL,
                             fileManager: FileManager = .default,
                             progress: (Progress) -> Void = { _ in }) throws -> PackagedGame {
        let manifest = try GameManifest.decode(try BoundedRead.data(at: framework.appendingPathComponent(GameManifest.fileName),
                                                                    fileManager: fileManager))
        guard let titleID = TitleID(manifest.titleID) else {
            throw NXPocketError(.packageDamaged, "the manifest's title_id \"\(manifest.titleID)\" is not 16 hex digits")
        }

        let partial = partialFolder(for: destination)
        // What a build cut off left: never a package, always started again.
        if fileManager.fileExists(atPath: partial.path) { try fileManager.removeItem(at: partial) }
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            let package = try assemble(framework: framework, manifest: manifest, titleID: titleID, romfsImage: romfsImage,
                                       aocFolder: aocFolder, into: partial, fileManager: fileManager, progress: progress)
            progress(Progress(fraction: 0.95, detail: "checking the package as the iPhone will"))
            _ = try PackageVerifier.verify(partial, options: macVerification, fileManager: fileManager)
            if fileManager.fileExists(atPath: destination.path) {
                // A swap of the two folders, then the old one goes: the destination is never half written.
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
            progress(Progress(fraction: 1, detail: "packed \(titleID)"))
            return PackagedGame(root: destination, package: package, manifest: manifest)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private static func assemble(framework: URL, manifest: GameManifest, titleID: TitleID, romfsImage: URL?,
                                 aocFolder: URL?, into folder: URL, fileManager: FileManager,
                                 progress: (Progress) -> Void) throws -> GamePackage {
        let name = "DmGame\(titleID.description).framework"
        let installed = folder.appendingPathComponent(name, isDirectory: true)
        try fileManager.copyItem(at: framework, to: installed)
        try stripSignature(installed, fileManager: fileManager)

        progress(Progress(fraction: 0.1, detail: "hashing \(name)"))
        var entries: [GamePackage.FileEntry] = []
        let items = try PackageScanner.files(in: installed, fileManager: fileManager)
        for (index, item) in items.enumerated() {
            entries.append(GamePackage.FileEntry(path: item.relativePath, size: item.size,
                                                 sha256: try FileDigest.sha256(ofFileAt: item.url)))
            progress(Progress(fraction: 0.1 + 0.4 * Double(index + 1) / Double(max(items.count, 1)), detail: item.relativePath))
        }
        entries.sort { $0.path < $1.path }

        var romfsIdentity = ""
        var romfsSize: Int64 = 0
        if let romfsImage {
            progress(Progress(fraction: 0.55, detail: "reading \(romfsImage.lastPathComponent)"))
            // The engine's own stamp is authoritative; the identity is recomputed only when it is missing.
            let stamp = romfsImage.appendingPathExtension("id")
            if let data = try? BoundedRead.data(at: stamp, fileManager: fileManager),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let line = json["identity"] as? String, RomfsIdentity.parse(line) != nil {
                romfsIdentity = line
            } else if let identity = RomfsIdentity.ofImage(at: romfsImage) {
                romfsIdentity = identity.description
            } else {
                throw NXPocketError(.packageDamaged, "\(romfsImage.lastPathComponent) is not a complete RomFS image")
            }
            romfsSize = Int64((try? fileManager.attributesOfItem(atPath: romfsImage.path)[.size] as? Int64) ?? 0)
            progress(Progress(fraction: 0.7, detail: "copying \(romfsImage.lastPathComponent)"))
            // On APFS, on the volume of the engine's build folder, copyItem makes a clone: no bytes are copied and no
            // space is used until one side changes (measured: 2 GB in 1 ms). A hard link would share the file with
            // the engine's next build, which may rewrite it.
            try fileManager.copyItem(at: romfsImage, to: folder.appendingPathComponent(GameLayout.romfsFile))
        }

        // The hash of every megabyte of the image, so that an update of this game on a phone that has it fetches only what changed.
        var romfsBlocks: RomfsBlocks?
        if romfsSize > 0 {
            progress(Progress(fraction: 0.78, detail: "hashing the blocks of \(GameLayout.romfsFile)"))
            let list = try RomfsBlocks.digests(of: folder.appendingPathComponent(GameLayout.romfsFile))
            try list.write(to: folder.appendingPathComponent(GameLayout.romfsBlocksFile), options: .atomic)
            romfsBlocks = RomfsBlocks(sha256: FileDigest.sha256(of: list))
        }

        var aocSize: Int64 = 0
        if let aocFolder {
            let target = folder.appendingPathComponent(GameLayout.addOnFolder, isDirectory: true)
            progress(Progress(fraction: 0.85, detail: "copying add-on content"))
            try fileManager.copyItem(at: aocFolder, to: target)
            // Counted as the phone counts it, the Finder's own files aside: it refuses an aoc/ of any other size.
            _ = PackageScanner.removeFinderMetadata(in: target, fileManager: fileManager)
            aocSize = try PackageScanner.files(in: target, fileManager: fileManager).reduce(0) { $0 + $1.size }
            if aocSize == 0 { try fileManager.removeItem(at: target) }
        }

        let manifestOS = manifest.minOSVersion ?? OSVersion(GamePackage.defaultMinimumOS)!
        let package = GamePackage(titleID: titleID, name: manifest.name, version: manifest.displayVersion,
                                  packageVersion: manifest.packageVersion, framework: name,
                                  chain: manifest.chain, minOS: manifestOS.description,
                                  romfsID: romfsIdentity, romfsSize: romfsSize, aocSize: aocSize,
                                  files: entries, createdBy: createdBy, romfsBlocks: romfsBlocks)
        try package.data().write(to: folder.appendingPathComponent(GamePackage.fileName), options: .atomic)
        return package
    }

    /// A framework that arrives with a `_CodeSignature` is stripped: the phone signs it again on the device.
    static func stripSignature(_ framework: URL, fileManager: FileManager) throws {
        let signature = framework.appendingPathComponent("_CodeSignature", isDirectory: true)
        if fileManager.fileExists(atPath: signature.path) {
            try fileManager.removeItem(at: signature)
        }
        let resources = framework.appendingPathComponent("CodeResources")
        if fileManager.fileExists(atPath: resources.path) {
            try fileManager.removeItem(at: resources)
        }
    }

    static func size(of folder: URL, fileManager: FileManager) -> Int64 {
        var total: Int64 = 0
        var stack = [folder]
        while let url = stack.popLast() {
            let entries = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                               options: [])) ?? []
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true { stack.append(entry) } else { total += Int64(values?.fileSize ?? 0) }
            }
        }
        return total
    }
}
