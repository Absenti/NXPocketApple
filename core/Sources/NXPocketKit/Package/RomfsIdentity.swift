import Foundation

/// The identity of a RomFS image (`DMROMFS1`): its size and a hash of its header and index, never of the file data.
/// Ported from nxnative's `romfs_id_of_image` (`dm/host/romfs_identity.h`) through NX2Apple's Swift reader, so a
/// `romfs.img` in a received package is the one the framework was built against.
public struct RomfsIdentity: Equatable, Sendable, CustomStringConvertible {
    public var size: UInt64
    public var index: UInt64

    public static let magic = "DMROMFS1"
    public static let chunkSize: UInt64 = 1 << 20
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    public init(size: UInt64, index: UInt64) {
        self.size = size
        self.index = index
    }

    public var description: String {
        "DMROMFSID1 size=\(size) index=\(String(index, radix: 16))"
    }

    /// The line the engine prints (`romfs_image.py --identity`), carrying a title and a version we do not need.
    public static func parse(_ line: String) -> RomfsIdentity? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard fields.first == "DMROMFSID1" else { return nil }
        var size: UInt64?, index: UInt64?
        for field in fields.dropFirst() {
            guard let separator = field.firstIndex(of: "=") else { continue }
            let value = field[field.index(after: separator)...]
            switch field[..<separator] {
            case "size": guard let parsed = UInt64(value) else { return nil }; size = parsed
            case "index": guard let parsed = UInt64(value, radix: 16) else { return nil }; index = parsed
            default: break
            }
        }
        guard let size, let index else { return nil }
        return RomfsIdentity(size: size, index: index)
    }

    /// FNV-1a 64 over the little-endian 64-bit words of `bytes`, the last word zero-padded.
    static func mix(_ hash: UInt64, _ bytes: [UInt8]) -> UInt64 {
        var hash = hash
        var index = 0
        while index < bytes.count {
            var word: UInt64 = 0
            for k in 0..<8 where index + k < bytes.count { word |= UInt64(bytes[index + k]) << (8 * UInt64(k)) }
            hash = (hash ^ word) &* prime
            index += 8
        }
        return hash
    }

    /// A complete image, or nil when it is missing, cut short or not a RomFS image at all.
    public static func ofImage(at url: URL, chunk: UInt64 = chunkSize) -> RomfsIdentity? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: 32), head.count == 32 else { return nil }
        let bytes = [UInt8](head)
        func word(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) } }
        let indexOffset = word(8), indexSize = word(16)
        guard Array(bytes[0..<8]) == Array(magic.utf8),
              indexOffset >= 32, indexOffset <= total, indexSize == total - indexOffset else { return nil }
        var hash = mix(offsetBasis, bytes)
        do {
            try handle.seek(toOffset: indexOffset)
            var left = indexSize
            while left > 0 {
                let want = Int(min(left, chunk))
                var piece = Data()
                while piece.count < want {
                    guard let part = try handle.read(upToCount: want - piece.count), !part.isEmpty else { return nil }
                    piece.append(part)
                }
                hash = mix(hash, [UInt8](piece))
                left -= UInt64(want)
            }
        } catch { return nil }
        return RomfsIdentity(size: total, index: hash)
    }
}
