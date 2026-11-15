import CryptoKit
import Foundation

/// The hash of every megabyte of `romfs.img`, so that an update downloads only the megabytes that changed. The Mac writes the list
/// beside the image (`romfs.blocks`: the SHA-256 of each block, 32 bytes after 32 bytes) and names it in `package.json` with its
/// own hash, so the list is as trustworthy as the package itself. The phone compares the image it has with the list, keeps the
/// blocks that match, and fetches only the others, each checked against the list as it arrives.
public struct RomfsBlocks: Codable, Equatable, Sendable {
    public static let blockSize = 1 << 20
    public static let digestBytes = 32
    /// The longest list read: 64 MiB of hashes is a RomFS of two terabytes, more than the package format admits.
    public static let maxListBytes = 64 << 20

    public var blockSize: Int
    /// SHA-256 of the list file.
    public var sha256: String

    enum CodingKeys: String, CodingKey {
        case blockSize = "block_size"
        case sha256
    }

    public init(blockSize: Int = RomfsBlocks.blockSize, sha256: String) {
        self.blockSize = blockSize
        self.sha256 = sha256
    }

    /// Whether the numbers are ones a list can have: a block of 64 KiB to 64 MiB, a power of two, and a hash that is one.
    public var isValid: Bool {
        blockSize >= 64 << 10 && blockSize <= 64 << 20 && blockSize & (blockSize - 1) == 0 && FileDigest.isSHA256(sha256)
    }

    /// How many blocks an image of `size` bytes has, and how long its list is.
    public func count(forImageOf size: Int64) -> Int { size <= 0 ? 0 : Int((size + Int64(blockSize) - 1) / Int64(blockSize)) }
    public func listBytes(forImageOf size: Int64) -> Int64 { Int64(count(forImageOf: size)) * Int64(Self.digestBytes) }

    /// The list of an image: one SHA-256 per block, the last block as long as it is.
    public static func digests(of image: URL, blockSize: Int = RomfsBlocks.blockSize) throws -> Data {
        let handle = try FileHandle(forReadingFrom: image)
        defer { try? handle.close() }
        var list = Data()
        while let block = try handle.read(upToCount: blockSize), !block.isEmpty {
            list.append(contentsOf: SHA256.hash(data: block))
            if block.count < blockSize { break }
        }
        return list
    }
}
