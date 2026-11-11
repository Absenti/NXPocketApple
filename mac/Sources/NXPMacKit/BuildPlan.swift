import Foundation

/// What the user ticked for one game: the version to build (an update, or none for the base game alone) and its DLC.
public struct GameSelection: Equatable, Hashable, Sendable {
    /// A `FolderContent.id` among the game's updates, or nil for the base game alone.
    public var updateID: String?
    public var dlcIDs: Set<String>

    public init(updateID: String? = nil, dlcIDs: Set<String> = []) {
        self.updateID = updateID
        self.dlcIDs = dlcIDs
    }

    /// The newest update and every DLC: what the engine took when it was given the whole folder.
    public static func defaults(for game: FolderGame) -> GameSelection {
        GameSelection(updateID: game.updates.first?.id, dlcIDs: Set(game.dlc.map(\.id)))
    }
}

/// One game, ready for the engine: the package files it is given, under the names it is given them, the version it
/// builds and the DLC it packs.
///
/// The engine takes a folder and everything in it, so the plan is a folder of symbolic links to the packages picked,
/// `<build folder>/inputs/`, the build folder being `<title ID>_build` beside the base game: where the engine kept it
/// when it was pointed at the base game's folder, so an earlier extraction is reused.
public struct BuildPlan: Sendable, Equatable {
    public struct Input: Sendable, Equatable {
        public var source: URL
        /// The link's name: the file's own, with `[title ID][v…]` added when the name lacks them and the engine would
        /// otherwise not know the version (it reads an update's version from its name, `version_of`).
        public var linkName: String
    }

    public var titleID: String
    public var name: String
    public var inputs: [Input]
    /// The version built, 0 for the base game alone; nil when no keys and no name said it.
    public var version: UInt32?
    /// `--package v<N>`, only when the engine's own choice, the newest version among the files, would be another:
    /// an update the user left unticked that sits in the same file as the base game.
    public var packageVersion: String?
    /// The DLC the engine packs: those ticked, and any other in a file it is given anyway.
    public var dlcTitleIDs: [UInt64]
    public var workFolder: URL
    public var compressed: Bool

    public init(titleID: String, name: String, inputs: [Input], version: UInt32?, packageVersion: String?,
                dlcTitleIDs: [UInt64], workFolder: URL, compressed: Bool) {
        self.titleID = titleID
        self.name = name
        self.inputs = inputs
        self.version = version
        self.packageVersion = packageVersion
        self.dlcTitleIDs = dlcTitleIDs
        self.workFolder = workFolder
        self.compressed = compressed
    }

    public var inputFolder: URL { workFolder.appendingPathComponent("inputs", isDirectory: true) }
    public var versionTag: String? { version.map { "v\($0)" } }
}

extension FolderGame {
    /// The packages a selection gives the engine.
    func packages(for selection: GameSelection) -> [FolderPackage] {
        var picked: [FolderPackage] = []
        var seen = Set<URL>()
        func add(_ package: FolderPackage) { if seen.insert(package.url).inserted { picked.append(package) } }
        if let base { add(base.package) }
        if let update = updates.first(where: { $0.id == selection.updateID }) { add(update.package) }
        for item in dlc where selection.dlcIDs.contains(item.id) { add(item.package) }
        return picked
    }

    /// DLC the engine packs whatever is ticked: they are in a file it is given for something else (a merged XCI's
    /// DLC come with its base game). The engine packs every DLC of the files it is given; it has no switch to leave
    /// one out.
    public func forcedDLC(_ selection: GameSelection) -> Set<String> {
        let files = Set(packages(for: selection).map(\.url))
        return Set(dlc.filter { files.contains($0.package.url) && !selection.dlcIDs.contains($0.id) }.map(\.id))
    }

    /// `workRoot` holds the engine's `<title ID>_build` folders when set; without it each goes beside its base
    /// game, where the engine put it when it was pointed at that game's folder (so an earlier extraction is reused).
    public func plan(_ selection: GameSelection, workRoot: URL? = nil) throws -> BuildPlan {
        guard let base else {
            throw SwitchFormatError("\(name) has no base game in the folder, only its update or DLC")
        }
        let update = updates.first { $0.id == selection.updateID }
        let packages = packages(for: selection)
        let files = Set(packages.map(\.url))

        // The engine builds the newest version among its files unless told otherwise.
        let chosen: UInt32? = update == nil ? 0 : update?.version
        let present = packages.flatMap { package in
            package.titles.filter { $0.kind == .update && !package.unknownVersions.contains($0.titleID) }.map(\.version)
        }
        var packageVersion: String?
        if let chosen, let newest = present.max(), newest > chosen { packageVersion = "v\(chosen)" }

        var dlcIDs: [UInt64] = []
        for item in dlc where files.contains(item.package.url) && !dlcIDs.contains(item.titleID) {
            dlcIDs.append(item.titleID)
        }

        var inputs: [BuildPlan.Input] = []
        var names = Set<String>()
        for package in packages {
            let name = Self.linkName(for: package)
            guard names.insert(name.lowercased()).inserted else {
                throw SwitchFormatError("two packages of \(self.name) are named \(package.fileName): rename one")
            }
            inputs.append(BuildPlan.Input(source: package.url, linkName: name))
        }
        let work = (workRoot ?? base.package.url.deletingLastPathComponent())
            .appendingPathComponent("\(titleID)_build", isDirectory: true)
        return BuildPlan(titleID: titleID, name: name, inputs: inputs, version: chosen, packageVersion: packageVersion,
                         dlcTitleIDs: dlcIDs, workFolder: work, compressed: packages.contains(where: \.isCompressed))
    }

    /// A single-title package whose name lacks its title ID or version gets them in its link's name: the engine reads
    /// a version only from there, and a title ID from there when the package has no ticket (a cartridge dump). An
    /// NSZ or XCZ keeps its name: nsz names what it decompresses after the file, and the engine looks for that name.
    static func linkName(for package: FolderPackage) -> String {
        let name = package.fileName
        guard !package.isCompressed, !package.isMerged, let title = package.titles.first,
              !package.unknownVersions.contains(title.titleID) else { return name }
        var tags = ""
        if GameFolder.titleID(inName: name) != title.titleID { tags += String(format: "[%016llX]", title.titleID) }
        if title.kind != .base, GameFolder.version(inName: name) != title.version { tags += "[v\(title.version)]" }
        guard !tags.isEmpty else { return name }
        let url = URL(fileURLWithPath: name)
        return "\(url.deletingPathExtension().lastPathComponent) \(tags).\(url.pathExtension)"
    }
}

/// Lays out a plan's input folder: links only, so nothing is copied, and a run replaces the last run's links.
public enum BuildInputs {
    public static func prepare(_ plan: BuildPlan, fileManager: FileManager = .default) throws {
        let folder = plan.inputFolder
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only the links of an earlier run go: the engine's survey folder lives here too.
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let url = folder.appendingPathComponent(name)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                try fileManager.removeItem(at: url)
            }
        }
        for input in plan.inputs {
            try fileManager.createSymbolicLink(at: folder.appendingPathComponent(input.linkName),
                                               withDestinationURL: input.source)
        }
    }
}
