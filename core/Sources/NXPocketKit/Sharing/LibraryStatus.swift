import Foundation

/// How a game a source offers stands against the one in this phone's library.
public enum OfferState: Equatable, Sendable {
    case notInstalled
    /// Same build as the installed one.
    case upToDate
    /// The source has another build, newer or simply different (a rebuild of the same version).
    case updateAvailable
    /// The source's build is older than the installed one: offered only on request, with that said.
    case olderOnSource
    case needsNewerOS(String)
    /// The Mac is building this game now.
    case rebuilding

    /// The player may download it from the list.
    public var isDownloadable: Bool {
        switch self {
        case .notInstalled, .updateAvailable, .olderOnSource: return true
        case .upToDate, .needsNewerOS, .rebuilding: return false
        }
    }
}

public enum LibraryStatus {
    public static func state(of game: RemoteGame, installed: InstalledGame?, deviceOS: OSVersion = .current) -> OfferState {
        if game.busy { return .rebuilding }
        if let minimum = OSVersion(game.minOS), minimum > deviceOS { return .needsNewerOS(minimum.description) }
        guard let installed, installed.package != nil else { return .notInstalled }
        if installedRevision(of: installed) == game.revision { return .upToDate }
        let order = (installed.package?.packageVersion ?? "").compare(game.packageVersion, options: .numeric)
        return order == .orderedDescending ? .olderOnSource : .updateAvailable
    }

    /// The revision of an installed game: the hash of its `package.json`, which signing and import leave alone, so it is
    /// the number a source computes for the same build.
    public static func installedRevision(of game: InstalledGame, fileManager: FileManager = .default) -> String? {
        guard let data = BoundedRead.dataIfPresent(at: game.directory.appendingPathComponent(GamePackage.fileName),
                                                   fileManager: fileManager) else { return nil }
        return FileDigest.sha256(of: data)
    }
}
