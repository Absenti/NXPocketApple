import Foundation
import NXPocketKit

/// Cheats for a game (`Cheats`): a file the player brings, a switch for each cheat, a master switch, and a safe mode of the app's own, since
/// the engine's (which turns every cheat off after a start that did not come back) exists on the Mac only. Applied at the next start: the
/// engine reads the files when the game starts.
extension ShellHostModel {
    /// The build the game was made from, as cheat files name it; nil for a game built before the build wrote it.
    public func cheatBuildID(of game: InstalledGame) -> String? { game.frameworkURL.flatMap { Cheats.buildID(inFramework: $0) } }

    public func cheatEntries(of game: InstalledGame) -> [Cheats.Entry]? {
        cheatBuildID(of: game).flatMap { Cheats.installed(titleID: game.id, buildID: $0, documents: documents) }
    }

    public func enabledCheats(of game: InstalledGame) -> Set<String> {
        cheatBuildID(of: game).map { Cheats.enabled(titleID: game.id, buildID: $0, documents: documents) } ?? []
    }

    public func cheatsMasterOn(_ game: InstalledGame) -> Bool { Cheats.isMasterOn(titleID: game.id, documents: documents) }

    /// A file picked in Files, checked the way the engine reads it. Nil when it was kept; else what is wrong, in a sentence.
    public func importCheats(_ game: InstalledGame, from url: URL) -> String? {
        guard let build = cheatBuildID(of: game) else { return text(.cheatsNoBuild) }
        do {
            let entries = try Cheats.install(url, titleID: game.id, buildID: build, documents: documents)
            log.append("cheat file for \(game.titleID) kept: \(entries.count) entries")
            return nil
        } catch let problem as Cheats.Problem {
            log.append("cheat file for \(game.titleID) refused: \(problem)")
            return "\(text(.cheatsRefused)) \(problem)"
        } catch {
            return "\(text(.cheatsRefused)) \(error.localizedDescription)"
        }
    }

    public func setCheat(_ name: String, on: Bool, for game: InstalledGame) {
        guard let build = cheatBuildID(of: game) else { return }
        var names = Cheats.enabled(titleID: game.id, buildID: build, documents: documents)
        if on { names.insert(name) } else { names.remove(name) }
        try? Cheats.setEnabled(names, titleID: game.id, buildID: build, documents: documents)
    }

    public func setCheatsMaster(_ on: Bool, for game: InstalledGame) {
        try? Cheats.setMaster(on, titleID: game.id, documents: documents)
        if on { cheatsSafeModeFor = cheatsSafeModeFor == game.id ? nil : cheatsSafeModeFor }
    }

    public func removeCheats(of game: InstalledGame) {
        guard let build = cheatBuildID(of: game) else { return }
        Cheats.remove(titleID: game.id, buildID: build, documents: documents)
    }

    /// What the engine said about cheats at the game's last start, from its log: which it could not run, and why.
    public func cheatLog(of game: InstalledGame) -> [String] {
        guard let log = GameLogs.latest(titleID: game.id, documents: documents) else { return [] }
        return GameLogs.text(of: log, limit: 256 * 1024).text.split(separator: "\n").filter { $0.contains("cheats:") }.suffix(8).map {
            String($0.replacingOccurrences(of: "[RED] ", with: "").prefix(240))
        }
    }

    // MARK: safe mode

    private var cheatsLaunchMarker: URL { documents.appendingPathComponent(".cheats-launch") }

    /// Before a start with cheats on: remembered, so that a start that does not come back (the game took the app down) is known to have run
    /// them.
    func noteCheatsLaunch(_ game: InstalledGame) {
        guard let build = cheatBuildID(of: game), Cheats.isActive(titleID: game.id, buildID: build, documents: documents) else {
            try? FileManager.default.removeItem(at: cheatsLaunchMarker)
            return
        }
        try? Data(game.id.utf8).write(to: cheatsLaunchMarker, options: .atomic)
    }

    /// At the next start of the app: a launch that did not come back, with cheats on, turns the master switch off and says so. The
    /// toggles stay; the player turns it back on when they choose.
    func applyCheatsSafeMode() {
        guard let data = BoundedRead.dataIfPresent(at: cheatsLaunchMarker, limit: 64), let id = String(data: data, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: cheatsLaunchMarker)
        guard failedLaunch?.titleID == id else { return }
        try? Cheats.setMaster(false, titleID: id, documents: documents)
        cheatsSafeModeFor = id
        log.append("the last start of \(id) with cheats on did not come back: cheats are off for it until you turn them on")
    }
}
