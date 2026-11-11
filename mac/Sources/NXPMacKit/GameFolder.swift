import Foundation

/// One package file found in the games folder, and the titles it holds.
public struct FolderPackage: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// Read from its content metas, with the keys (`PackageInspector`).
        case contents
        /// Read from its ticket's name or the `[0100…]` / `[v…]` tags of its file name: no keys, or they failed.
        case name
    }

    public var url: URL
    public var bytes: Int64
    public var titles: [PackageTitle]
    public var source: Source
    /// Title IDs whose version the file name gave none of, when read without keys.
    public var unknownVersions: Set<UInt64> = []

    public init(url: URL, bytes: Int64, titles: [PackageTitle], source: Source, unknownVersions: Set<UInt64> = []) {
        self.url = url
        self.bytes = bytes
        self.titles = titles
        self.source = source
        self.unknownVersions = unknownVersions
    }

    public var fileName: String { url.lastPathComponent }
    /// NSZ or XCZ: the engine decompresses it with nsz first, which needs nsz in its Python.
    public var isCompressed: Bool { ["nsz", "xcz"].contains(url.pathExtension.lowercased()) }
    /// Several titles in one file (base game + update + DLC): the engine takes them all from it.
    public var isMerged: Bool { titles.count > 1 }
}

/// One title of a game as the folder offers it: the base game, one update or one DLC, in one package.
public struct FolderContent: Identifiable, Hashable, Sendable {
    public var titleID: UInt64
    public var kind: GameFolder.Kind
    /// Nil when it is not known: read without keys from a name without `[v…]`.
    public var version: UInt32?
    public var label: String
    public var package: FolderPackage

    public var id: String { "\(titleIDText)@\(version.map(String.init) ?? "?")@\(package.url.path)" }
    public var titleIDText: String { String(format: "%016llX", titleID) }
    /// "v327680", as the engine and `package.json` write a version.
    public var versionTag: String? { version.map { "v\($0)" } }
}

/// A game of the folder: its base game, its updates and its DLC, wherever in the folder they are.
public struct FolderGame: Identifiable, Equatable, Sendable {
    /// The application's title ID, 16 uppercase hex digits.
    public var titleID: String
    public var name: String
    /// The displayed version of the newest control data found ("1.05"), with the keys.
    public var displayVersion: String?
    /// The control data's icon (JPEG), with the keys.
    public var icon: Data?
    /// Usually one; a second copy (an NSP beside its NSZ in another folder) is listed but not used.
    public var bases: [FolderContent]
    /// Newest first.
    public var updates: [FolderContent]
    /// By title ID.
    public var dlc: [FolderContent]

    public var id: String { titleID }
    public var base: FolderContent? { bases.first }
    public var hasBase: Bool { !bases.isEmpty }
    public var packages: [FolderPackage] {
        var seen = Set<URL>()
        return (bases + updates + dlc).map(\.package).filter { seen.insert($0.url).inserted }
    }
    public var compressed: Bool { packages.contains(where: \.isCompressed) }
    public var bytes: Int64 { packages.reduce(0) { $0 + $1.bytes } }

    public var summary: String {
        var parts: [String] = [hasBase ? "base" : "no base game"]
        if !updates.isEmpty { parts.append(updates.count == 1 ? "1 update" : "\(updates.count) updates") }
        if !dlc.isEmpty { parts.append("\(dlc.count) DLC") }
        if compressed { parts.append("NSZ") }
        parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

/// A package the scan could not place in a game, and why.
public struct UnidentifiedPackage: Error, Hashable, Sendable {
    public var url: URL
    public var reason: String
}

public struct GameFolderListing: Equatable, Sendable {
    public var games: [FolderGame]
    public var unidentified: [UnidentifiedPackage]
    /// Package files seen: what "nothing found" is measured against.
    public var packageCount: Int

    public init(games: [FolderGame] = [], unidentified: [UnidentifiedPackage] = [], packageCount: Int = 0) {
        self.games = games
        self.unidentified = unidentified
        self.packageCount = packageCount
    }
}

/// The games of a dump folder and its subfolders, read from the packages themselves when the keys are there
/// (`PackageInspector`), else from the names dump tools give them: `Name [0100…][v…].nsp`.
///
/// The engine reads one folder, its top level only, and wants one game in it (or `--title-id`). The launcher scans a
/// whole tree instead and hands the engine one game at a time, in a folder of links to the files picked
/// (`BuildPlan`), so a base game in one folder and its update in another build together.
public enum GameFolder {
    public static let packageExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz"]

    /// How deep the scan goes, and how many entries it reads at most: a folder chosen by mistake (the home folder)
    /// is cut short instead of being walked for minutes.
    static let maximumDepth = 8
    static let maximumEntries = 200_000

    /// The application a title ID belongs to. A base game ends in 000, its update in 800, and its DLC count up from
    /// the next 0x1000: 01008F2005155006 is DLC 6 of 01008F2005154000.
    public static func applicationID(of titleID: UInt64) -> UInt64 {
        let low = titleID & 0xFFF
        if low == 0 || low == 0x800 { return titleID & ~0xFFF }
        return (titleID &- 0x1000) & ~0xFFF
    }

    public enum Kind: Equatable, Hashable, Sendable { case base, update, dlc }

    public static func kind(of titleID: UInt64) -> Kind {
        switch titleID & 0xFFF {
        case 0: return .base
        case 0x800: return .update
        default: return .dlc
        }
    }

    /// The first `[…]` of 16 hex digits starting with 01 in a file name.
    public static func titleID(inName name: String) -> UInt64? {
        tags(in: name).lazy.compactMap { tag -> UInt64? in
            tag.count == 16 && tag.hasPrefix("01") ? UInt64(tag, radix: 16) : nil
        }.first
    }

    /// The `[v65536]` tag of a file name.
    public static func version(inName name: String) -> UInt32? {
        tags(in: name).lazy.compactMap { tag -> UInt32? in
            tag.hasPrefix("v") || tag.hasPrefix("V") ? UInt32(tag.dropFirst()) : nil
        }.first
    }

    /// The `[DLC Danger Deck]` tag of a file name: the only place a DLC's name is, since its package has no control data.
    public static func dlcName(inName name: String) -> String? {
        tags(in: name).lazy.compactMap { tag -> String? in
            guard tag.uppercased().hasPrefix("DLC ") else { return nil }
            let text = tag.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }.first
    }

    static func tags(in name: String) -> [String] {
        var found: [String] = []
        var rest = Substring(name)
        while let open = rest.firstIndex(of: "[") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "]") else { break }
            found.append(String(after[..<close]))
            rest = after[after.index(after: close)...]
        }
        return found
    }

    /// The game's name from a file name: what comes before the first `[`, cleaned of separators.
    public static func displayName(fromName name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let head = stem.split(separator: "[", maxSplits: 1).first.map(String.init) ?? stem
        let cleaned = head.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? stem : cleaned
    }

    // MARK: - Scan

    /// The package files under `folder`. Hidden folders, the engine's own `<id>_build` and `<id>_survey` folders
    /// (its decompressed NSPs, and the links to the packages the launcher gave it), app bundles and symbolic links
    /// are not entered; a package file of 0 bytes (a download that never finished) is not a package.
    public static func packageFiles(in folder: URL, fileManager: FileManager = .default) -> [(url: URL, bytes: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(url: URL, bytes: Int64)] = []
        var seen = 0
        while let url = walker.nextObject() as? URL {
            seen += 1
            if seen > maximumEntries { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent
            if values.isDirectory == true {
                if isEngineFolder(name) || walker.level >= maximumDepth { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, !name.hasPrefix("._"),
                  packageExtensions.contains(url.pathExtension.lowercased()),
                  let size = values.fileSize, size > 0 else { continue }
            found.append((url, Int64(size)))
        }
        return found.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    static func isEngineFolder(_ name: String) -> Bool {
        name.hasSuffix("_build") || name.hasSuffix("_survey")
    }

    public typealias Identification = Result<(package: FolderPackage, contents: PackageContents?), UnidentifiedPackage>

    /// Reads every package of the folder and groups them by game. `identify` reads one file: with the keys through
    /// `PackageInspector`, else `identifyByName` (`AppModel` caches either by path, size and date).
    public static func scan(_ folder: URL, fileManager: FileManager = .default,
                            identify: (URL, Int64) -> Identification) -> GameFolderListing {
        let files = packageFiles(in: folder, fileManager: fileManager)
        var packages: [(package: FolderPackage, contents: PackageContents?)] = []
        var unidentified: [UnidentifiedPackage] = []
        for file in files {
            switch identify(file.url, file.bytes) {
            case .success(let found): packages.append(found)
            case .failure(let problem): unidentified.append(problem)
            }
        }
        var listing = group(packages)
        listing.unidentified = unidentified
        listing.packageCount = files.count
        return listing
    }

    /// One package, with the keys when there are some, by its names when there are none or they fail on it.
    public static func identify(_ url: URL, bytes: Int64, keys: SwitchKeys?) -> Identification {
        var keyProblem: String?
        if let keys {
            do {
                let contents = try PackageInspector.inspect(url, keys: keys)
                return .success((FolderPackage(url: url, bytes: bytes, titles: contents.titles, source: .contents), contents))
            } catch {
                keyProblem = "\(error)"
            }
        }
        switch identifyByName(url, bytes: bytes) {
        case .success(let package):
            return .success((package, nil))
        case .failure(var problem):
            if let keyProblem { problem.reason = keyProblem }
            return .failure(problem)
        }
    }

    /// What a package is without the keys: the engine's own fallback (`title_of`), the ticket's name first (its
    /// first 16 digits are the title ID; a name tag can be wrong), then the name's `[0100…]`.
    public static func identifyByName(_ url: URL, bytes: Int64) -> Result<FolderPackage, UnidentifiedPackage> {
        let name = url.lastPathComponent
        var titleID: UInt64?
        if let reader = try? PackageFileReader(url: url), let entries = try? SwitchContainer.entries(of: reader) {
            titleID = entries.lazy.compactMap { entry -> UInt64? in
                let lower = entry.name.lowercased()
                guard lower.hasSuffix(".tik"), lower.count == 36 else { return nil }
                return UInt64(lower.prefix(16), radix: 16)
            }.first
        }
        guard let titleID = titleID ?? self.titleID(inName: name) else {
            return .failure(UnidentifiedPackage(url: url, reason: "no title ID in its name or ticket: set prod.keys in Settings to read it"))
        }
        let kind = self.kind(of: titleID)
        let version = kind == .base ? 0 : self.version(inName: name)
        return .success(FolderPackage(url: url, bytes: bytes,
                                      titles: [PackageTitle(titleID: titleID, kind: kind, version: version ?? 0)],
                                      source: .name, unknownVersions: version == nil ? [titleID] : []))
    }

    /// Groups identified packages by application. Pure, for the tests.
    public static func group(_ packages: [(package: FolderPackage, contents: PackageContents?)]) -> GameFolderListing {
        struct Group {
            var bases: [FolderContent] = []
            var updates: [FolderContent] = []
            var dlc: [FolderContent] = []
            var controlVersion: UInt32 = 0
            var name: String?
            var displayVersion: String?
            var icon: Data?
        }
        var groups: [UInt64: Group] = [:]
        for (package, contents) in packages {
            for title in package.titles {
                let app = applicationID(of: title.titleID)
                var group = groups[app] ?? Group()
                let version = package.unknownVersions.contains(title.titleID) ? nil : title.version
                switch title.kind {
                case .base:
                    group.bases.append(FolderContent(titleID: title.titleID, kind: .base, version: 0, label: "Base game",
                                                     package: package))
                case .update:
                    group.updates.append(FolderContent(titleID: title.titleID, kind: .update, version: version,
                                                       label: version.map { "Update v\($0)" } ?? "Update", package: package))
                case .dlc:
                    let index = title.titleID &- app &- 0x1000
                    let named = package.isMerged ? nil : dlcName(inName: package.fileName)
                    group.dlc.append(FolderContent(titleID: title.titleID, kind: .dlc, version: version,
                                                   label: named.map { "DLC \($0)" } ?? "DLC \(index)", package: package))
                }
                // The newest control data names the game: an update's carries the current version string.
                if let contents, title.kind != .dlc, contents.name != nil,
                   group.name == nil || title.version >= group.controlVersion {
                    group.controlVersion = title.version
                    group.name = contents.name
                    group.displayVersion = contents.displayVersion
                    group.icon = contents.icon ?? group.icon
                }
                groups[app] = group
            }
        }
        let games = groups.map { app, group -> FolderGame in
            // An uncompressed copy first: it needs no nsz -D before the engine can read it.
            let bases = group.bases.sorted {
                ($0.package.isCompressed ? 1 : 0, $0.package.url.path) < ($1.package.isCompressed ? 1 : 0, $1.package.url.path)
            }
            let updates = group.updates.sorted { ($0.version ?? 0, $1.package.url.path) > ($1.version ?? 0, $0.package.url.path) }
            let dlc = group.dlc.sorted { ($0.titleID, $0.version ?? 0, $0.package.url.path) < ($1.titleID, $1.version ?? 0, $1.package.url.path) }
            let fileNamed = (bases + updates + dlc).first.map { displayName(fromName: $0.package.fileName) } ?? ""
            return FolderGame(titleID: String(format: "%016llX", app),
                              name: group.name ?? bases.first.map { displayName(fromName: $0.package.fileName) } ?? fileNamed,
                              displayVersion: group.displayVersion, icon: group.icon,
                              bases: bases, updates: updates, dlc: dlc)
        }
        return GameFolderListing(games: games.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.titleID < $1.titleID : order == .orderedAscending
        })
    }
}
