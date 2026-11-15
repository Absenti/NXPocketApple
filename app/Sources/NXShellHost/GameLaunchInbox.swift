import Foundation
import NXPocketKit
import UIKit

/// How a game asked for from outside the library reaches the model: a quick action of the home screen icon (a long press), or the
/// Shortcuts app's "Play a game". Both run before the model may exist (a cold start), so they leave the request here and the model
/// takes it as soon as it can, through `ShellHostModel.request`, which knows what to do when a game is on screen already.
public enum GameLaunchInbox {
    public static let didRequest = Notification.Name("dev.nxpocketapple.launch-request")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: TitleID?

    /// Leaves the request. Anything that is not a game's title ID is dropped. `notify` is false for a test, which reads the inbox itself.
    public static func request(_ titleID: String, notify: Bool = true) {
        guard let id = TitleID(titleID), id.kind == .application else { return }
        lock.withLock { pending = id }
        if notify { NotificationCenter.default.post(name: didRequest, object: nil) }
    }

    public static func take() -> TitleID? { lock.withLock { defer { pending = nil }; return pending } }
}

/// Links and files handed to the app (a pairing QR code, a game's icon, an archive sent by AirDrop). SwiftUI's own `onOpenURL` stops working
/// once the window's scene has a delegate of ours (the quick actions need one), so the scene delegate leaves what it receives here, and the
/// model takes it as soon as it exists: a cold start delivers the link before the model is made.
public enum LinkInbox {
    public static let didReceive = Notification.Name("dev.nxpocketapple.link-received")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [URL] = []

    public static func receive(_ urls: [URL], notify: Bool = true) {
        guard !urls.isEmpty else { return }
        lock.withLock { pending.append(contentsOf: urls.prefix(8)) }
        if notify { NotificationCenter.default.post(name: didReceive, object: nil) }
    }

    public static func take() -> [URL] { lock.withLock { defer { pending = [] }; return pending } }
}

/// What the system hands the app about downloads that went on while it was away (`BackgroundTransfers`).
public enum BackgroundHandoff {
    /// The system started or woke the app for a session of ours. The service is made, which makes the system hand over what it holds, and
    /// the handler is called once it has been heard out. Any other session is none of ours: the handler is called at once.
    public static func handle(identifier: String, completion: @escaping () -> Void) {
        guard identifier == BackgroundTransfers.identifier, let service = BackgroundTransfers.shared else {
            completion()
            return
        }
        service.handleEvents(completion)
    }
}

/// The games in the library as the Shortcuts app needs them (a name to pick, an ID to start), kept in `Documents/.catalog.json` by the
/// model at each read of the library, since an intent runs without it.
public struct GameCatalogEntry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum GameCatalog {
    public static func url(documents: URL) -> URL { documents.appendingPathComponent(".catalog.json") }

    public static func write(_ entries: [GameCatalogEntry], documents: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url(documents: documents), options: .atomic)
    }

    public static func read(documents: URL) -> [GameCatalogEntry] {
        guard let data = BoundedRead.dataIfPresent(at: url(documents: documents), limit: 1 << 20),
              let entries = try? JSONDecoder().decode([GameCatalogEntry].self, from: data) else { return [] }
        return entries.filter { TitleID($0.id).map { $0.kind == .application } ?? false }
    }

    public static func documentsFolder() -> URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
}

/// The long press of the app's icon: the three games played last, newest first.
public enum QuickActions {
    public static let type = "dev.nxpocketapple.play"
    public static let limit = 3

    /// The games to offer, by when each was last played; a game never played is not offered.
    static func recent(_ games: [InstalledGame], name: (InstalledGame) -> String, documents: URL) -> [(id: String, name: String, last: Date)] {
        games.compactMap { game -> (String, String, Date)? in
            guard !game.isBroken, let last = GameChoices.load(titleID: game.id, documents: documents).lastPlayed else { return nil }
            return (game.id, name(game), last)
        }
        .sorted { $0.2 > $1.2 }
        .prefix(limit)
        .map { (id: $0.0, name: $0.1, last: $0.2) }
    }

    @MainActor
    static func update(_ games: [InstalledGame], name: (InstalledGame) -> String, documents: URL) {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en")
        formatter.unitsStyle = .short
        UIApplication.shared.shortcutItems = recent(games, name: name, documents: documents).map { entry in
            UIApplicationShortcutItem(type: type, localizedTitle: entry.name,
                                      localizedSubtitle: formatter.localizedString(for: entry.last, relativeTo: Date()),
                                      icon: UIApplicationShortcutIcon(type: .play), userInfo: ["titleID": entry.id as NSString])
        }
    }

    /// The game a quick action names, when it is one of ours.
    public static func titleID(of item: UIApplicationShortcutItem) -> String? {
        guard item.type == type else { return nil }
        return item.userInfo?["titleID"] as? String
    }
}
