import AppIntents
import NXShellHost
import UIKit

/// A game of the library, as the Shortcuts app sees it: pick one in "Play a game", and a shortcut made of it can be added to the home
/// screen from Shortcuts, with an icon and a name of the player's choosing.
struct GameEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Game")
    static let defaultQuery = GameQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct GameQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [GameEntity] {
        GameCatalog.read(documents: GameCatalog.documentsFolder()).filter { identifiers.contains($0.id) }.map { GameEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [GameEntity] {
        GameCatalog.read(documents: GameCatalog.documentsFolder()).map { GameEntity(id: $0.id, name: $0.name) }
    }
}

/// Starts a game. The app opens, and the game starts as if its icon had been touched (`GameLaunchInbox`).
struct PlayGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a game"
    static let description = IntentDescription("Starts a game of your NXPocketApple library.")
    static let openAppWhenRun = true

    @Parameter(title: "Game") var game: GameEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$game)") }

    func perform() async throws -> some IntentResult {
        GameLaunchInbox.request(game.id)
        return .result()
    }
}

struct ShellShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayGameIntent(), phrases: ["Play a game in \(.applicationName)", "Open a game in \(.applicationName)"],
                    shortTitle: "Play a game", systemImageName: "gamecontroller.fill")
    }
}
