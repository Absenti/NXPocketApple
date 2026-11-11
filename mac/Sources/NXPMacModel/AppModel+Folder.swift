import Foundation
import NXPMacKit
import NXPocketKit

/// The games folder: the scan, what is ticked in it, and what is already built or on the phone.
extension AppModel {
    /// Reads the games folder and its subfolders in the background, with prod.keys when Settings has it. Files
    /// already read are not read again (`PackageIdentityCache`), so a rescan costs only the walk.
    public func refreshFolder() {
        guard let url = settings.value.gameURL else {
            folder = GameFolderListing()
            return
        }
        scanGeneration += 1
        let generation = scanGeneration
        scanningFolder = true
        let keysURL = settings.value.keysURL
        let cache = identities
        Task {
            let (listing, problem) = await Task.detached(priority: .userInitiated) { () -> (GameFolderListing, String?) in
                var keys: SwitchKeys?
                var problem: String?
                if let keysURL {
                    do {
                        keys = try SwitchKeys.load(from: keysURL)
                    } catch {
                        // The error names the file "prod.keys", never its path.
                        problem = "\((error as? NXPocketError)?.detail ?? "prod.keys could not be read"): games are recognised by their file names only."
                    }
                } else {
                    problem = "No prod.keys in Settings: games are recognised by their file names only, and a file named without its title ID is skipped."
                }
                let listing = GameFolder.scan(url) { cache.identify($0, bytes: $1, keys: keys) }
                return (listing, problem)
            }.value
            // A newer scan (another folder chosen meanwhile) wins.
            guard generation == self.scanGeneration else { return }
            self.folder = listing
            self.keysProblem = problem
            self.scanningFolder = false
            self.pruneSelections()
        }
    }

    /// Drops ticks that no longer name something in the folder: a game gone, an update or DLC file moved.
    private func pruneSelections() {
        let games = Dictionary(folder.games.map { ($0.titleID, $0) }, uniquingKeysWith: { first, _ in first })
        checkedGames = checkedGames.filter { games[$0] != nil }
        var kept: [String: GameSelection] = [:]
        for (titleID, selection) in selections {
            guard let game = games[titleID] else { continue }
            // An update that is gone sends the game back to its defaults rather than to the base game alone.
            if let update = selection.updateID, !game.updates.contains(where: { $0.id == update }) { continue }
            kept[titleID] = GameSelection(updateID: selection.updateID,
                                          dlcIDs: selection.dlcIDs.intersection(game.dlc.map(\.id)))
        }
        selections = kept
    }

    public func selection(for game: FolderGame) -> GameSelection {
        selections[game.titleID] ?? .defaults(for: game)
    }

    public func isChecked(_ game: FolderGame) -> Bool { checkedGames.contains(game.titleID) }

    public func toggleChecked(_ game: FolderGame) {
        if checkedGames.contains(game.titleID) { checkedGames.remove(game.titleID) } else { checkedGames.insert(game.titleID) }
    }

    public func checkAll(_ on: Bool) {
        checkedGames = on ? Set(folder.games.filter(\.hasBase).map(\.titleID)) : []
    }

    /// Ticks one update, or unticks it for the base game alone: the engine builds one version, so ticking an update
    /// unticks the one before.
    public func toggleUpdate(_ update: FolderContent, of game: FolderGame) {
        var selection = selection(for: game)
        selection.updateID = selection.updateID == update.id ? nil : update.id
        selections[game.titleID] = selection
    }

    public func toggleDLC(_ item: FolderContent, of game: FolderGame) {
        var selection = selection(for: game)
        if selection.dlcIDs.contains(item.id) { selection.dlcIDs.remove(item.id) } else { selection.dlcIDs.insert(item.id) }
        selections[game.titleID] = selection
    }

    public func setAllDLC(_ on: Bool, of game: FolderGame) {
        var selection = selection(for: game)
        selection.dlcIDs = on ? Set(game.dlc.map(\.id)) : []
        selections[game.titleID] = selection
    }

    /// The version a game's selection builds, as `package.json` writes it ("v65536"), when it is known.
    public func selectedVersionTag(of game: FolderGame) -> String? {
        let selection = selection(for: game)
        guard let id = selection.updateID else { return "v0" }
        return game.updates.first { $0.id == id }?.versionTag
    }

    /// The package already built for this title, if the output folder has one.
    public func builtPackage(_ titleID: String) -> LocalGame? {
        games.first { $0.titleID == titleID.uppercased() && $0.isReady }
    }
}
