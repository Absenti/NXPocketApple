import Foundation
import NXPocketKit

/// A game installed on the phone: its `Documents/games/<title ID>/package.json`, as the Mac wrote it.
public struct PhoneGame: Equatable, Sendable {
    public var titleID: String
    public var name: String
    /// The displayed version ("1.0.0") and the version built ("v0", "v65536").
    public var version: String
    public var packageVersion: String
}

/// One entry of a listing of the phone's `Documents/games`, its path relative to that folder.
public struct RemoteFile: Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var date: String
    public var isDirectory: Bool
}

/// One look at the phone's `Documents/games`: the games installed, and every file under them, saves included.
public struct PhoneSnapshot: Sendable {
    public var deviceUDID: String
    /// The app's bundle ID on that phone (SideStore's, with the team appended).
    public var bundleID: String
    public var games: [PhoneGame]
    public var files: [RemoteFile]

    /// A game's saves: everything under its `save*` entries, as the phone's importer counts them
    /// (`GameImporter` copies every `save*` entry of a game across an update).
    public func saveFiles(of titleID: String) -> [RemoteFile] {
        files.filter { file in
            let parts = file.path.split(separator: "/", maxSplits: 2)
            return parts.count >= 2 && parts[0] == Substring(titleID) && parts[1].hasPrefix("save")
        }
    }
}

/// What the paired iPhone has in `Documents/games/`: one recursive listing (about a second over the cable or Wi-Fi),
/// then each `package.json` copied back, only when its size or date changed since the last look. A transfer still
/// waiting in `.incoming` is not counted: it is on the phone once iPorterNX there has imported it.
///
/// Everything here reads: `devicectl device info files` and `devicectl device copy from`, never with
/// `--remove-existing-content` (`readArguments`). The Mac writes on the phone only through `DeviceTransfer`, into
/// `Documents/.incoming/`.
public final class DeviceLibrary: @unchecked Sendable {
    public let toolchain: Toolchain
    private let lock = NSLock()
    /// "title ID|size|date" of a package.json → what it said.
    private var known: [String: PhoneGame] = [:]
    /// The bundle ID each phone has the app under (SideStore appends the team), looked up once per device.
    private var bundleIDs: [String: String] = [:]

    public init(toolchain: Toolchain) {
        self.toolchain = toolchain
    }

    public func games(on device: Device, bundleID configured: String) throws -> [PhoneGame] {
        try snapshot(on: device, bundleID: configured).games
    }

    public func snapshot(on device: Device, bundleID configured: String) throws -> PhoneSnapshot {
        let bundleID = try resolvedBundleID(on: device, configured: configured)
        let files: [RemoteFile]
        do {
            files = try listGames(on: device, bundleID: bundleID)
        } catch {
            // iPorterNX may have been installed again under another bundle ID (SideStore appends its team, a new
            // install can bring another): the next look asks the phone again instead of keeping a gone one.
            forgetBundleID(on: device, configured: configured)
            throw error
        }
        var games: [PhoneGame] = []
        for entry in Self.packageFiles(files) {
            let key = "\(entry.titleID)|\(entry.size)|\(entry.date)"
            if let game = cached(key) {
                games.append(game)
            } else if let game = try? copyPackage(of: entry.titleID, from: device, bundleID: bundleID) {
                remember(key, game)
                games.append(game)
            }
        }
        return PhoneSnapshot(deviceUDID: device.udid, bundleID: bundleID,
                             games: games.sorted { $0.titleID < $1.titleID }, files: files)
    }

    // MARK: - The two read-only commands

    /// `devicectl device info files` of a folder of the app's `Documents`, recursively, as JSON.
    static func listArguments(device: Device, bundleID: String, folder: String, output: URL) -> [String] {
        ["devicectl", "device", "info", "files", "--device", device.udid,
         "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
         "--subdirectory", folder.isEmpty ? "Documents" : "Documents/\(folder)", "--json-output", output.path, "-q"]
    }

    /// `devicectl device copy from` of a file or a folder of the app's `Documents` to the Mac. A folder arrives as
    /// its contents in `destination`, which it creates.
    static func copyFromArguments(device: Device, bundleID: String, source: String, destination: URL) -> [String] {
        ["devicectl", "device", "copy", "from", "--device", device.udid,
         "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
         "--source", "Documents/\(source)", "--destination", destination.path, "-q"]
    }

    /// The listing of `Documents/games`, asked twice: over Wi-Fi devicectl now and then fails a call that works a
    /// second later, and an empty answer would have said "no game on the iPhone". A folder that does not exist fails
    /// the same way (iPorterNX makes it at its first start, so after a reinstall it is missing until the app opens):
    /// then `Documents` is listed, and a listing without `games` means no game, not a failure.
    private func listGames(on device: Device, bundleID: String) throws -> [RemoteFile] {
        var lastLine = "devicectl could not list the iPhone's games"
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            let folder = attempt < 2 ? GameLayout.gamesFolder : ""
            let listing = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-games-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: listing) }
            let result = try ProcessRunner.capture(toolchain.xcrun,
                                                   Self.listArguments(device: device, bundleID: bundleID, folder: folder, output: listing),
                                                   timeout: 60)
            if result.status == 0, let data = try? BoundedRead.data(at: listing, limit: DeviceTransfer.listingLimit) {
                let files = Self.files(inFilesListing: data)
                return attempt < 2 ? files : Self.gamesEntries(ofDocumentsListing: files)
            }
            lastLine = result.lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? lastLine
        }
        throw NXPocketError(.deviceUnavailable, "the iPhone's games could not be read: \(lastLine)")
    }

    /// A listing of `Documents` reduced to what is under `games/`, with paths relative to it.
    static func gamesEntries(ofDocumentsListing files: [RemoteFile]) -> [RemoteFile] {
        let prefix = GameLayout.gamesFolder + "/"
        return files.compactMap { file in
            guard file.path.hasPrefix(prefix) else { return nil }
            var inside = file
            inside.path = String(file.path.dropFirst(prefix.count))
            return inside
        }
    }

    /// Every entry of a `devicectl device info files --json-output` listing (`result.files[]`).
    static func files(inFilesListing data: Data) -> [RemoteFile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let files = result["files"] as? [[String: Any]] else { return [] }
        return files.compactMap { file in
            guard let path = file["relativePath"] as? String ?? file["name"] as? String, !path.isEmpty else { return nil }
            let metadata = file["metadata"] as? [String: Any] ?? [:]
            let resources = file["resources"] as? [String: Any] ?? [:]
            return RemoteFile(path: path, size: (metadata["size"] as? NSNumber)?.int64Value ?? 0,
                              date: metadata["lastModDate"] as? String ?? "",
                              isDirectory: resources["isDirectory"] as? Bool ?? false)
        }
    }

    /// `<title ID>/package.json` entries of a listing of `Documents/games`, with what tells a changed one apart.
    static func packageFiles(_ files: [RemoteFile]) -> [(titleID: String, size: Int64, date: String)] {
        files.compactMap { file in
            let parts = file.path.split(separator: "/")
            guard parts.count == 2, parts[1] == Substring(GamePackage.fileName), TitleID(String(parts[0])) != nil else { return nil }
            return (String(parts[0]), file.size, file.date)
        }
    }

    static func packageFiles(inFilesListing data: Data) -> [(titleID: String, size: Int64, date: String)] {
        packageFiles(files(inFilesListing: data))
    }

    /// What a game's package.json says, when its title ID is a title ID and the one of the folder it was read from.
    /// That ID becomes a path on the Mac (`Saves/<title ID>/`): one taken as written could name `../..`.
    static func phoneGame(packageJSON data: Data, folder: String? = nil) -> PhoneGame? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let written = object["title_id"] as? String, let titleID = TitleID(written) else { return nil }
        if let folder, TitleID(folder) != titleID { return nil }
        return PhoneGame(titleID: titleID.description, name: object["name"] as? String ?? titleID.description,
                         version: object["version"] as? String ?? "", packageVersion: object["package_version"] as? String ?? "")
    }

    /// One game's `package.json`, copied back. Asked twice, like the listing: a game left out by one failed call
    /// would lose its badge.
    private func copyPackage(of titleID: String, from device: Device, bundleID: String) throws -> PhoneGame? {
        for attempt in 0..<2 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-package-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: local) }
            let result = try ProcessRunner.capture(toolchain.xcrun,
                                                   Self.copyFromArguments(device: device, bundleID: bundleID,
                                                                          source: "\(GameLayout.gamesFolder)/\(titleID)/\(GamePackage.fileName)",
                                                                          destination: local),
                                                   timeout: 60)
            // A package.json from the phone is the phone's to write: read with the metadata bound, and its title ID
            // must be the folder's (`phoneGame(packageJSON:folder:)`).
            if result.status == 0, let data = try? BoundedRead.data(at: local) {
                return Self.phoneGame(packageJSON: data, folder: titleID)
            }
        }
        return nil
    }

    func resolvedBundleID(on device: Device, configured: String) throws -> String {
        lock.lock()
        let cachedID = bundleIDs[device.udid + "|" + configured]
        lock.unlock()
        if let cachedID { return cachedID }
        let found = try DeviceTransfer(toolchain: toolchain).installedBundleID(on: device, matching: configured)
        lock.lock()
        bundleIDs[device.udid + "|" + configured] = found
        lock.unlock()
        return found
    }

    func forgetBundleID(on device: Device, configured: String) {
        lock.lock()
        bundleIDs[device.udid + "|" + configured] = nil
        lock.unlock()
    }

    private func cached(_ key: String) -> PhoneGame? {
        lock.lock()
        defer { lock.unlock() }
        return known[key]
    }

    private func remember(_ key: String, _ game: PhoneGame) {
        lock.lock()
        known[key] = game
        lock.unlock()
    }
}
