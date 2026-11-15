import CryptoKit
import Foundation

/// Checking the data of an installed game against the list of its image's blocks (`RomfsBlocks`), and putting right the blocks that
/// are wrong from a source that holds the same image. A copy cut short through Files, a flash error or a stray write leave an image
/// of the right size that is not the one built; the importer's identity check reads only the header and the index, so this is the
/// check that reads all of it.
///
/// Only the image is checked: the framework is signed on the phone after the import, so its files no longer have the hashes in
/// `package.json`, and iOS checks its signature itself. Only a block that is wrong is rewritten, in place, after its replacement
/// matched the list: a repair that fails leaves the image as bad as it was and never worse.
public enum GameRepair {
    public struct Scan: Equatable, Sendable {
        public var blockCount: Int
        public var badBlocks: [Int]
        /// The image is not the size the package says, so it cannot be one of the build's.
        public var sizeWrong: Bool
        public var isClean: Bool { badBlocks.isEmpty && !sizeWrong }
    }

    public enum Unavailable: Error, Equatable, Sendable {
        /// The game was installed from a package with no list of blocks: nothing to compare with.
        case noList
        /// The list in the game's folder is not the one `package.json` names.
        case listDamaged
        case noImage
    }

    /// Compares every block of `directory/romfs.img` with the list in `directory/romfs.blocks`.
    public static func scan(directory: URL, package: GamePackage, progress: @Sendable (Double) -> Void = { _ in }) throws -> Scan {
        guard let declared = package.romfsBlocks, declared.isValid, package.romfsSize > 0 else { throw Unavailable.noList }
        let list = try readList(directory: directory, declared: declared, package: package)
        let image = directory.appendingPathComponent(GameLayout.romfsFile)
        guard FileManager.default.fileExists(atPath: image.path) else { throw Unavailable.noImage }
        let handle = try FileHandle(forReadingFrom: image)
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: image.path)[.size] as? Int64).flatMap { $0 } ?? 0
        let blockSize = Int64(declared.blockSize)
        var bad: [Int] = []
        for index in 0..<list.count {
            if Task.isCancelled { throw NXPocketError(.cancelled, "stopped") }
            let length = Int(min(blockSize, package.romfsSize - Int64(index) * blockSize))
            try handle.seek(toOffset: UInt64(Int64(index) * blockSize))
            let block = try handle.read(upToCount: length) ?? Data()
            if block.count != length || Data(SHA256.hash(data: block)) != list[index] { bad.append(index) }
            progress(Double(index + 1) / Double(max(list.count, 1)))
        }
        return Scan(blockCount: list.count, badBlocks: bad, sizeWrong: size != package.romfsSize)
    }

    /// Fetches the wrong blocks from `source` and writes them over the image. The source must hold the same image: its
    /// `package.json` names the same list (the same hash), so a source that has since been updated with another image is refused
    /// rather than mixed in. Returns how many blocks were put right.
    @discardableResult
    public static func repair(directory: URL, package: GamePackage, scan: Scan, from source: PackageSource,
                              progress: @Sendable (Double) -> Void = { _ in }) async throws -> Int {
        guard let declared = package.romfsBlocks else { throw Unavailable.noList }
        let list = try readList(directory: directory, declared: declared, package: package)
        guard let titleID = TitleID(package.titleID) else { throw NXPocketError(.packageDamaged, "\(package.titleID) is not a title ID") }
        let listing = try await source.listing(titleID: titleID.description)
        let manifest = try await PackageDownloader.readWhole(source, titleID: titleID, revision: listing.revision, path: GamePackage.fileName,
                                                             limit: SharingLimits.metadataBytes)
        guard FileDigest.sha256(of: manifest) == listing.revision,
              let theirs = try? GamePackage.decode(manifest), theirs.romfsBlocks?.sha256 == declared.sha256,
              theirs.romfsSize == package.romfsSize else {
            throw NXPocketError(.packageInconsistent, "the source holds another image of this game")
        }
        let image = directory.appendingPathComponent(GameLayout.romfsFile)
        let handle = try FileHandle(forUpdating: image)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(package.romfsSize))
        let blockSize = Int64(declared.blockSize)
        var fixed = 0
        var position = 0
        while position < scan.badBlocks.count {
            var last = position
            while last + 1 < scan.badBlocks.count, scan.badBlocks[last + 1] == scan.badBlocks[last] + 1 { last += 1 }
            let first = scan.badBlocks[position], final = scan.badBlocks[last]
            let start = Int64(first) * blockSize
            let body = try await source.read(titleID: titleID.description, revision: listing.revision, path: GameLayout.romfsFile, offset: UInt64(start))
            guard body.offset == UInt64(start) else { throw NXPocketError(.transferFailed, "the source answered from byte \(body.offset)") }
            var pending = Data()
            var next = first
            var written = start
            for try await chunk in body.chunks {
                if Task.isCancelled { throw NXPocketError(.cancelled, "stopped") }
                pending.append(chunk)
                while next <= final {
                    let length = Int(min(blockSize, package.romfsSize - Int64(next) * blockSize))
                    guard pending.count >= length else { break }
                    let block = pending.prefix(length)
                    guard Data(SHA256.hash(data: block)) == list[next] else {
                        throw NXPocketError(.hashMismatch, "block \(next) from the source does not match the list")
                    }
                    try handle.seek(toOffset: UInt64(written))
                    try handle.write(contentsOf: block)
                    written += Int64(length)
                    pending = Data(pending.dropFirst(length))
                    next += 1
                    fixed += 1
                    progress(Double(fixed) / Double(max(scan.badBlocks.count, 1)))
                }
                if next > final { break }
            }
            guard next > final else { throw NXPocketError(.transferFailed, "the connection ended before block \(next)") }
            position = last + 1
        }
        try handle.synchronize()
        return fixed
    }

    private static func readList(directory: URL, declared: RomfsBlocks, package: GamePackage) throws -> [Data] {
        let url = directory.appendingPathComponent(GameLayout.romfsBlocksFile)
        guard let data = BoundedRead.dataIfPresent(at: url, limit: Int64(RomfsBlocks.maxListBytes)) else { throw Unavailable.noList }
        guard FileDigest.sha256(of: data) == declared.sha256, data.count % RomfsBlocks.digestBytes == 0,
              data.count == Int(declared.listBytes(forImageOf: package.romfsSize)) else { throw Unavailable.listDamaged }
        return stride(from: 0, to: data.count, by: RomfsBlocks.digestBytes).map { data.subdata(in: $0..<($0 + RomfsBlocks.digestBytes)) }
    }
}
