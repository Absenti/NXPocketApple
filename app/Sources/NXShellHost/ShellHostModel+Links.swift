import Foundation
import NXPocketKit
import NXShellUI
import UIKit

/// A game started from its icon on the home screen (`nxpocket://play/<title ID>`), and the profile that puts it there.
extension ShellHostModel {
    // MARK: - Links

    /// A link the system hands the app. Anything that does not name a game is ignored.
    public func open(_ url: URL) {
        // A file sent to this app (AirDrop, "Open in…"): never imported at once, the player is asked first, with the warning.
        if url.isFileURL {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            archiveRequest = ArchiveRequest(url: url, isFolder: isFolder.boolValue)
            return
        }
        guard url.scheme?.lowercased() == GameLink.scheme else { return }
        if url.host?.lowercased() == PairLink.host {
            // Never acted on at once: the link only opens a sheet, and the player decides there.
            if let link = PairLink(url: url) { pairLink = link } else { log.append("ignored a pairing link that is not well formed") }
            return
        }
        guard let titleID = GameLink.titleID(from: url) else {
            log.append("ignored a link that names no game")
            return
        }
        request(titleID)
    }

    /// Starts a game asked for from outside the library. While a game is on screen: the same game needs nothing, another
    /// one is a question on top of the game, since starting it means quitting first.
    func request(_ titleID: TitleID) {
        let id = titleID.description
        if gameIsOnScreen, let active = activeTitleID {
            guard active != id else { return }
            if case .running = launch {
                askToSwitch(to: titleID)
            } else {
                log.append("\(id) asked for while \(active) is starting: not opened")
            }
            return
        }
        pendingLaunch = id
        startPendingLaunch()
    }

    /// The game asked for, once the first screen is up and the library read. One whose last start did not come back is
    /// not started again: the library shows why instead.
    func startPendingLaunch() {
        guard firstScreenShown, libraryLoaded, let id = pendingLaunch else { return }
        pendingLaunch = nil
        guard let game = games.first(where: { $0.id == id }) else {
            log.append("\(id) asked for from its icon, but it is not in the library")
            return
        }
        guard failedLaunch?.titleID != id else {
            log.append("\(id) not started from its icon: its last start did not come back")
            return
        }
        log.append("start of \(id) asked for from its icon")
        play(game)
    }

    /// The question goes on the game's own window: the library's is under it, and an alert there would never be seen.
    func askToSwitch(to titleID: TitleID) {
        guard var presenter = engineHost.gameWindow?.rootViewController else {
            log.append("\(titleID) asked for while a game runs, with no game window to ask in")
            return
        }
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIAlertController) else { return }
        let running = activeTitleID.map(title(ofTitleID:)) ?? text(.aGame)
        let question = ShellStrings.closeGameQuestion(running: running, next: title(ofTitleID: titleID.description))
        let alert = UIAlertController(title: question.title, message: question.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: question.confirm, style: .destructive) { [weak self] _ in
            self?.closeForNextGame(titleID)
        })
        alert.addAction(UIAlertAction(title: text(.cancel), style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// The engine cannot start twice in one process, so the app quits and the next launch starts the game asked for
    /// (`NextLaunch`). The launch marker goes first: this exit is no crash.
    func closeForNextGame(_ titleID: TitleID) {
        playClock?.pause()
        do {
            try NextLaunch.write(titleID, documents: documents)
        } catch {
            log.append("could not keep \(titleID) for the next launch: \(error.localizedDescription)")
        }
        LaunchGuard.clear(in: documents)
        log.append("closed \(activeTitleID ?? "the running game") to open \(titleID)")
        exit(0)
    }

    // MARK: - Home screen

    /// The profile that puts the game's icon on the home screen, in `Documents/Shortcuts/`, where Files shows it.
    public func makeShortcut(_ game: InstalledGame) -> Result<URL, NXPocketError> {
        let name = name(of: game)
        let texts = ShortcutProfile.Texts(label: name,
                                          displayName: "NXPocketApple: \(name)",
                                          description: text(.shortcutDescription))
        do {
            let url = try ShortcutProfile.write(game, texts: texts, documents: documents)
            log.append("home screen profile for \(game.titleID) written as \(url.lastPathComponent)")
            return .success(url)
        } catch {
            log.append("could not write the home screen profile of \(game.titleID): \(error.localizedDescription)")
            return .failure(error as? NXPocketError ?? NXPocketError(.transferFailed, error.localizedDescription))
        }
    }

    /// Files, open on the profile: touching it there hands it to Settings. False when Files would not open.
    public func showInFiles(_ url: URL) async -> Bool {
        guard let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let link = URL(string: "shareddocuments://\(path)") else { return false }
        return await UIApplication.shared.open(link)
    }
}
