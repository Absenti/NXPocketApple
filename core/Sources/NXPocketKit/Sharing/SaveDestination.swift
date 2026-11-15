import Foundation

/// Where a copy of a game's saves can be sent: the Mac, or a server reached over SFTP. A copy is one .zip, the one the game
/// menu exports (`GameSaves.export`), and the destination keeps it as it is: nothing on the other side opens it, so a copy
/// that was crafted cannot make the Mac or the server write anywhere but the one file it was given.
public protocol SaveDestination: Sendable {
    /// Sends `archive`, a .zip of at most `SaveUpload.maxBytes`, as the newest copy of `titleID`'s saves. Returns the name the
    /// destination gave the copy, which is how this phone later knows a copy is its own.
    @discardableResult
    func store(saves archive: URL, titleID: String) async throws -> String
}

/// A copy of saves a destination holds: its name (`SaveUpload.fileName`), its size and the date its name carries.
public struct RemoteSaveCopy: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var size: Int64
    public var date: Date
    public var id: String { name }

    public init(name: String, size: Int64, date: Date) {
        self.name = name
        self.size = size
        self.date = date
    }

    /// Decodes and bounds a list of copies: a name that is not one a destination makes is dropped, newest first.
    public static func decode(_ data: Data) throws -> [RemoteSaveCopy] {
        struct Entry: Decodable { var name: String; var size: Int64 }
        struct Listing: Decodable { var copies: [Entry] }
        guard data.count <= SharingLimits.metadataBytes, let listing = try? JSONDecoder().decode(Listing.self, from: data),
              listing.copies.count <= 1_000 else { throw NXPocketError(.packageDamaged, "the list of copies could not be read") }
        return listing.copies.compactMap { entry in
            guard SaveUpload.isCopyName(entry.name), let date = SaveUpload.date(ofName: entry.name),
                  entry.size > 0, entry.size <= SaveUpload.maxBytes else { return nil }
            return RemoteSaveCopy(name: entry.name, size: entry.size, date: date)
        }
        .sorted { $0.date > $1.date }
    }
}

/// A destination that also gives its copies back: the Mac and an SFTP server.
public protocol SaveSource: Sendable {
    func saveCopies(titleID: String) async throws -> [RemoteSaveCopy]
    /// Writes one copy to `destination`, after checking it is a .zip of at most `SaveUpload.maxBytes`.
    func fetchSaveCopy(titleID: String, name: String, to destination: URL) async throws
}

public enum SaveUpload {
    /// Far above any game's saves, and the bound the Mac's server holds a phone to.
    public static let maxBytes: Int64 = 256 << 20
    /// How many copies of one game a destination keeps: the oldest go.
    public static let keep = 10
    /// A .zip starts with this, whatever its name.
    public static let zipMagic = Data([0x50, 0x4B, 0x03, 0x04])
    /// The hidden folder, inside the folder of an SFTP source, that holds the copies: `<folder>/.nxpocket-saves/<title ID>/`.
    public static let sftpFolder = ".nxpocket-saves"

    public static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == zipMagic
    }

    /// The size of a file to send, after the checks that do not depend on the destination.
    public static func checked(_ archive: URL, titleID: String) throws -> Int64 {
        guard TitleID.isGame(titleID) else { throw NXPocketError(.packageDamaged, "\"\(titleID)\" is not a game's title ID") }
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? Int64 ?? 0
        guard size > 0, isZip(archive) else { throw NXPocketError(.packageDamaged, "the copy of the saves is not a .zip") }
        guard size <= maxBytes else { throw NXPocketError(.packageDamaged, "the copy of the saves is larger than \(maxBytes >> 20) MB") }
        return size
    }

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    /// `iPhone 2026-11-14 183012.zip`: the name a copy takes on a destination, made by the destination's own side.
    public static func fileName(at date: Date = Date()) -> String { "iPhone \(stamp.string(from: date)).zip" }

    /// The date a copy's name carries.
    public static func date(ofName name: String) -> Date? {
        guard isCopyName(name) else { return nil }
        return stamp.date(from: String(name.dropFirst(7).prefix(17)))
    }

    /// Whether a name is one `fileName(at:)` made. A destination rotates only these: anything else in the folder is the
    /// player's.
    public static func isCopyName(_ name: String) -> Bool {
        guard name.hasPrefix("iPhone "), name.hasSuffix(".zip") else { return false }
        let middle = name.dropFirst(7).dropLast(4)
        guard middle.count >= 17, let date = stamp.date(from: String(middle.prefix(17))),
              stamp.string(from: date) == String(middle.prefix(17)) else { return false }
        let rest = middle.dropFirst(17)
        return rest.isEmpty || (rest.first == " " && rest.count > 1 && rest.dropFirst().allSatisfy(\.isNumber))
    }
}
