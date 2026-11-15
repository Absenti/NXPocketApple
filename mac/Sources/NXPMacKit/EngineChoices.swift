import Foundation

/// An engine found on this Mac, as the Settings list shows it.
public struct EngineChoice: Identifiable, Equatable, Sendable {
    public var url: URL
    public var title: String
    public var detail: String
    /// It is the release this launcher is pinned to (`SetupPins.engineKey`), whoever put it there.
    public var isStable: Bool
    /// Where it is, in a few words: "installed by this launcher", or its folder.
    public var place: String
    public var id: String { url.path }
    /// One line for a menu.
    public var menuTitle: String { "\(title) · \(place)" }
}

/// The engines on this Mac a build can be made with, so the player chooses rather than finds out which one is used: the one the launcher
/// installs (the pinned stable release), the player's own copy of NX2Apple, and any folder named in Settings. Each is told by what it is: its
/// stamp (`engine.py sync` writes the pin and a digest of every patch), not by its name.
public enum EngineChoices {
    public static func available(selected: URL?, candidates: [URL] = ToolchainLocator.engineCandidates(),
                                 pinnedInstall: URL = SetupPaths.standard.engine, fileManager: FileManager = .default) -> [EngineChoice] {
        var seen = Set<String>()
        var found: [EngineChoice] = []
        for url in [pinnedInstall] + candidates + (selected.map { [$0] } ?? []) {
            let real = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(real).inserted, EngineLocation(root: url).isUsable else { continue }
            found.append(describe(url, isLauncherInstall: real == pinnedInstall.resolvingSymlinksInPath().standardizedFileURL.path, fileManager: fileManager))
        }
        // The stable one first, then the rest as they were found.
        return found.sorted { ($0.isStable ? 0 : 1) < ($1.isStable ? 0 : 1) }
    }

    static func describe(_ url: URL, isLauncherInstall: Bool, fileManager: FileManager = .default) -> EngineChoice {
        let identity = EngineIdentity.read(url, fileManager: fileManager)
        let place = isLauncherInstall ? "installed by this launcher" : url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if case .stamp(let text) = identity {
            let key = text.split(separator: "\n").first { $0.hasPrefix("key ") }.map { String($0.dropFirst(4)) }
            if key == SetupPins.engineKey {
                return EngineChoice(url: url, title: "NX2Apple \(SetupPins.nx2appleVersion), stable",
                                    detail: "The release this launcher is made for · nxnative \(identity.pin ?? "?") · \(place)", isStable: true, place: place)
            }
            return EngineChoice(url: url, title: "Another NX2Apple engine",
                                detail: "nxnative \(identity.pin ?? "?") · \(place) · not the stable release", isStable: false, place: place)
        }
        return EngineChoice(url: url, title: "An engine tree of your own", detail: "\(place) · no stamp, its version is not known", isStable: false, place: place)
    }
}
