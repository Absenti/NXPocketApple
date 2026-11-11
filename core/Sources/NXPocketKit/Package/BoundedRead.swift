import Foundation

/// Reads a small file whole, refusing it when it is larger than `limit`. `Documents` is open to Files, the Finder and
/// the Mac's transfers, so a file named `package.json` can be any size; read without a bound, a large one is loaded
/// in full and the app is killed for its memory, at every launch, since the library is read at launch.
public enum BoundedRead {
    /// More than any manifest, package listing, settings file or signing record this app writes.
    public static let metadataLimit: Int64 = 4 << 20

    /// The file's bytes. Throws `packageMissing` when it cannot be read and `packageDamaged` when it is larger than
    /// `limit` or not a regular file.
    public static func data(at url: URL, limit: Int64 = metadataLimit, fileManager: FileManager = .default) throws -> Data {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fileManager.attributesOfItem(atPath: url.path) }
        catch { throw NXPocketError(.packageMissing, "\(url.lastPathComponent) could not be read", path: url.path) }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw NXPocketError(.packageDamaged, "\(url.lastPathComponent) is not a regular file", path: url.path)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= limit else {
            throw NXPocketError(.packageDamaged,
                                "\(url.lastPathComponent) is \(size) bytes, more than the \(limit) a metadata file may have",
                                path: url.path)
        }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw NXPocketError(.packageMissing, "\(url.lastPathComponent) could not be opened", path: url.path)
        }
        defer { try? handle.close() }
        // The size is read again through the handle: the file can grow between the stat and the read.
        let data = (try? handle.read(upToCount: Int(limit) + 1)) ?? Data()
        guard Int64(data.count) <= limit else {
            throw NXPocketError(.packageDamaged, "\(url.lastPathComponent) grew past \(limit) bytes while it was read",
                                path: url.path)
        }
        return data
    }

    /// `data(at:)`, nil when the file is missing, unreadable or too large.
    public static func dataIfPresent(at url: URL, limit: Int64 = metadataLimit,
                                     fileManager: FileManager = .default) -> Data? {
        try? data(at: url, limit: limit, fileManager: fileManager)
    }
}
