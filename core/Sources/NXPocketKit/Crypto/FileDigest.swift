import CryptoKit
import Foundation

/// Streaming SHA-256. The game data is gigabytes wide, so nothing is ever held whole in memory.
public enum FileDigest {
    public static let chunkSize = 4 << 20

    public static func sha256(ofFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw NXPocketError(.packageMissing, "cannot read the file", path: url.path)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    public static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    public static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// True for 64 lower-case hex digits; the writer normalises to lower case.
    public static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isNumber || ("a"..."f").contains($0) }
    }
}
