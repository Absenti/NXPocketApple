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
        // A read that fails is an error, not the end of the file: swallowing it (`try?`) returned the hash of whatever
        // was read so far, a hash of a prefix that looked like the hash of the file.
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: chunkSize) }
            catch { throw NXPocketError(.packageMissing, "the file could not be read to the end: \(error.localizedDescription)", path: url.path) }
            guard let chunk, !chunk.isEmpty else { break }
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
