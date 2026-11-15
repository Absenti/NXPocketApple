import Foundation

/// The bounds every source is read within. A source is a machine on a network the phone does not control, so nothing it
/// says is trusted to be small.
public enum SharingLimits {
    /// A listing, a game's file list, `package.json`: the same ceiling as every metadata file the app reads.
    public static let metadataBytes = Int(BoundedRead.metadataLimit)
    public static let maxGames = 1_000
    public static let maxFilesPerGame = 200_000
    public static let maxGameBytes: Int64 = 1 << 40
    public static let iconBytes = 512 * 1024
    public static let iconPixels = 1024
    /// A source that sends no byte for this long has stalled: the transfer stops and can be resumed.
    public static let idleTimeout: TimeInterval = 30
    /// `romfs.img` is the one big file; its journal entry moves forward by this much at a time, after an `fsync`.
    public static let checkpointBytes: Int64 = 64 << 20
}

/// One game a source offers, as the source says it. Only a hint for the list on screen: the download is planned from
/// the game's own `package.json` (`DownloadPlan`), never from this.
public struct RemoteGame: Codable, Equatable, Sendable, Identifiable {
    public var titleID: String
    public var name: String
    public var version: String
    public var packageVersion: String
    public var minOS: String
    /// SHA-256 of that package's `package.json`: one build of the game, whichever way it is reached.
    public var revision: String
    public var codeBytes: Int64
    public var romfsBytes: Int64
    public var aocBytes: Int64
    /// The Mac is building or packing this game right now.
    public var busy: Bool

    public var id: String { titleID }
    public var totalBytes: Int64 { codeBytes + romfsBytes + aocBytes }

    enum CodingKeys: String, CodingKey {
        case name, version, revision, busy
        case titleID = "title_id"
        case packageVersion = "package_version"
        case minOS = "min_os"
        case codeBytes = "code_bytes"
        case romfsBytes = "romfs_bytes"
        case aocBytes = "aoc_bytes"
    }

    public init(titleID: String, name: String, version: String, packageVersion: String, minOS: String, revision: String,
                codeBytes: Int64, romfsBytes: Int64, aocBytes: Int64, busy: Bool = false) {
        self.titleID = titleID
        self.name = name
        self.version = version
        self.packageVersion = packageVersion
        self.minOS = minOS
        self.revision = revision
        self.codeBytes = codeBytes
        self.romfsBytes = romfsBytes
        self.aocBytes = aocBytes
        self.busy = busy
    }

    /// What a package's `package.json` says, as a listing entry: how the phone describes a game it listed itself.
    public init(package: GamePackage, revision: String, busy: Bool = false) {
        self.init(titleID: package.titleID, name: package.name, version: package.version,
                  packageVersion: package.packageVersion, minOS: package.minOS, revision: revision,
                  codeBytes: package.codeSize, romfsBytes: package.romfsSize, aocBytes: package.aocSize, busy: busy)
    }
}

public struct RemoteListing: Codable, Equatable, Sendable {
    public var games: [RemoteGame]
    public init(games: [RemoteGame]) { self.games = games }

    /// Decodes and bounds a listing: a game that is not a game is dropped, a repeated title ID keeps its first entry, and
    /// more than `maxGames` is a refusal rather than a long list.
    public static func decode(_ data: Data) throws -> [RemoteGame] {
        guard data.count <= SharingLimits.metadataBytes else {
            throw NXPocketError(.packageDamaged, "the list of games is larger than \(SharingLimits.metadataBytes) bytes")
        }
        let listing: RemoteListing
        do { listing = try JSONDecoder().decode(RemoteListing.self, from: data) }
        catch { throw NXPocketError(.packageDamaged, "the list of games could not be read") }
        guard listing.games.count <= SharingLimits.maxGames else {
            throw NXPocketError(.packageDamaged, "the list holds more than \(SharingLimits.maxGames) games")
        }
        var seen = Set<String>()
        return listing.games.compactMap { game in
            guard TitleID.isGame(game.titleID), let id = TitleID(game.titleID),
                  FileDigest.isSHA256(game.revision), game.codeBytes >= 0, game.romfsBytes >= 0, game.aocBytes >= 0,
                  seen.insert(id.description).inserted else { return nil }
            var clean = game
            clean.titleID = id.description
            // Free text from a network: shown on screen, so bounded and stripped of control characters.
            clean.name = Self.text(game.name, limit: 120)
            clean.version = Self.text(game.version, limit: 40)
            clean.packageVersion = Self.text(game.packageVersion, limit: 40)
            clean.minOS = Self.text(game.minOS, limit: 16)
            return clean
        }
    }

    static func text(_ value: String, limit: Int) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit))
    }
}

/// One file of a package, its path relative to the package folder.
public struct RemotePackageFile: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int64
    public init(path: String, size: Int64) { self.path = path; self.size = size }
}

/// What a source lists inside one package: which build it is, and every file it holds.
public struct RemotePackageListing: Codable, Equatable, Sendable {
    public var revision: String
    public var files: [RemotePackageFile]
    public init(revision: String, files: [RemotePackageFile]) { self.revision = revision; self.files = files }

    public static func decode(_ data: Data) throws -> RemotePackageListing {
        guard data.count <= SharingLimits.metadataBytes else {
            throw NXPocketError(.packageDamaged, "the file list is larger than \(SharingLimits.metadataBytes) bytes")
        }
        do { return try JSONDecoder().decode(RemotePackageListing.self, from: data) }
        catch { throw NXPocketError(.packageDamaged, "the file list could not be read") }
    }
}
