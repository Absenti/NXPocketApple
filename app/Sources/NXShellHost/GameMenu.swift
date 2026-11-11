import NXPocketKit
import NXShellUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What a game's menu can ask for: the long press on its cover, and the "…" of its detail screen.
enum GameMenuAction {
    case play, testLoad, settings
    case rename, resign
    case exportSaves, importSaves, deleteSaves
    case addToHomeScreen, logs, copyIdentifier, remove
}

/// The menu itself. Play and the test first; then what changes the game; then what identifies it and what it takes.
struct GameMenuItems: View {
    @EnvironmentObject private var model: ShellHostModel
    let game: InstalledGame
    var showsSettings = true
    let perform: (GameMenuAction) -> Void

    var body: some View {
        Section {
            item(.play, .play, "play.fill").disabled(game.isBroken)
            item(.testLoad, .testLoad, "gauge.with.dots.needle.33percent").disabled(game.isBroken)
            if showsSettings { item(.settings, .gameSettings, "slider.horizontal.3") }
        }
        Section {
            item(.rename, .rename, "pencil")
            item(.resign, .resignGame, "signature")
                .disabled(model.signingIdentity == nil || game.isBroken || model.importState.isRunning)
            Menu {
                item(.exportSaves, .exportSaves, "square.and.arrow.up").disabled(!hasSaves)
                item(.importSaves, .importSaves, "square.and.arrow.down")
                Button(role: .destructive) { perform(.deleteSaves) } label: {
                    Label(model.text(.deleteSaves), systemImage: "trash")
                }
                .disabled(!hasSaves)
            } label: {
                Label(model.text(.saves), systemImage: "externaldrive")
            }
            item(.addToHomeScreen, .addToHomeScreen, "apps.iphone.badge.plus")
            item(.logs, .logs, "doc.text")
        }
        Section(game.version.isEmpty ? game.id : "\(game.id) · v\(game.version)") {
            item(.copyIdentifier, .copyIdentifier, "doc.on.doc")
        }
        Section(model.sizesText(game)) {
            Button(role: .destructive) { perform(.remove) } label: { Label(model.text(.remove), systemImage: "trash") }
        }
    }

    private var hasSaves: Bool { model.hasSaves(game) }

    private func item(_ action: GameMenuAction, _ key: ShellStrings.Key, _ symbol: String) -> some View {
        Button { perform(action) } label: { Label(model.text(key), systemImage: symbol) }
    }
}

/// A sheet a game's menu opens.
enum GameSheet: Identifiable {
    case share(URL)
    case logs(titleID: String?, open: LogFile?)
    case shortcut(name: String, file: URL)

    var id: String {
        switch self {
        case .share(let url): return "share:\(url.path)"
        case .logs(let titleID, let open): return "logs:\(titleID ?? ""):\(open?.id ?? "")"
        case .shortcut(_, let file): return "shortcut:\(file.path)"
        }
    }
}

struct GameNotice: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// What a game's menu leaves open: the question, the file picker or the sheet it asked for. One per screen that shows
/// the menu, so the library and a detail screen (itself a sheet) each present their own.
@MainActor
final class GameActionCenter: ObservableObject {
    @Published var renaming: InstalledGame?
    @Published var newName = ""
    @Published var removing: InstalledGame?
    @Published var deletingSaves: InstalledGame?
    @Published var showingImporter = false
    @Published var sheet: GameSheet?
    @Published var notice: GameNotice?
    /// The game the file picker imports into: kept apart from `showingImporter`, which the picker clears on its own.
    var importTarget: InstalledGame?

    /// The actions that ask something first, or open something; Play, the test and the settings belong to the screen.
    func perform(_ action: GameMenuAction, on game: InstalledGame, model: ShellHostModel) {
        switch action {
        case .play: model.play(game)
        case .testLoad: model.testLoad(game)
        case .settings: break
        case .rename:
            newName = model.name(of: game)
            renaming = game
        case .resign: model.resign(game)
        case .exportSaves: export(game, model: model)
        case .importSaves:
            importTarget = game
            showingImporter = true
        case .deleteSaves: deletingSaves = game
        case .addToHomeScreen:
            switch model.makeShortcut(game) {
            case .success(let file): sheet = .shortcut(name: model.name(of: game), file: file)
            case .failure(let error): notice = GameNotice(title: model.text(.shortcutFailed), message: model.message(for: error))
            }
        case .logs: sheet = .logs(titleID: game.id, open: nil)
        case .copyIdentifier: UIPasteboard.general.string = game.id
        case .remove: removing = game
        }
    }

    private func export(_ game: InstalledGame, model: ShellHostModel) {
        Task {
            switch await model.exportSaves(game) {
            case .success(let url): sheet = .share(url)
            case .failure(let problem): notice = GameNotice(title: model.text(.exportSaves), message: model.text(for: problem))
            }
        }
    }

    func importSaves(from result: Result<URL, Error>, model: ShellHostModel) {
        guard let game = importTarget else { return }
        importTarget = nil
        switch result {
        case .success(let url):
            Task {
                switch await model.importSaves(game, from: url) {
                case .success(let kept):
                    notice = GameNotice(title: model.text(.savesImported),
                                        message: kept == nil ? model.name(of: game) : model.text(.previousSavesKept))
                case .failure(let problem):
                    notice = GameNotice(title: model.text(.savesNotImported), message: model.text(for: problem))
                }
            }
        case .failure(let error):
            notice = GameNotice(title: model.text(.savesNotImported), message: error.localizedDescription)
        }
    }
}

extension View {
    /// The questions, picker and sheets of a game's menu. `removed` runs once a game is gone (a detail screen closes).
    func gameActions(_ center: GameActionCenter, removed: @escaping (InstalledGame) -> Void = { _ in }) -> some View {
        modifier(GameActionsModifier(center: center, removed: removed))
    }
}

/// Each question hangs on its own view: two alerts, or two dialogs, on one view do not both show.
private struct GameActionsModifier: ViewModifier {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var center: GameActionCenter
    let removed: (InstalledGame) -> Void

    func body(content: Content) -> some View {
        content
            .alert(model.text(.rename), isPresented: isSet(\.renaming), presenting: center.renaming) { game in
                TextField(game.title, text: $center.newName)
                Button(model.text(.rename)) { model.rename(game, to: center.newName) }
                if model.isRenamed(game) { Button(model.text(.originalName)) { model.rename(game, to: "") } }
                Button(model.text(.cancel), role: .cancel) {}
            } message: { game in
                Text("\(model.text(.renameBody))\n\(model.labelled(.originalName, game.title))")
            }
            .background {
                Color.clear.confirmationDialog(model.text(.remove), isPresented: isSet(\.removing), titleVisibility: .visible,
                                               presenting: center.removing) { game in
                    Button(model.text(.removeKeepSaves)) {
                        model.remove(game, saves: false)
                        removed(game)
                    }
                    Button(model.text(.removeEverything), role: .destructive) {
                        model.remove(game, saves: true)
                        removed(game)
                    }
                    Button(model.text(.cancel), role: .cancel) {}
                } message: { game in
                    Text("\(model.name(of: game))\n\(model.sizesText(game))\n\(model.text(.removeGameBody))")
                }
            }
            .background {
                Color.clear.confirmationDialog(model.text(.deleteSaves), isPresented: isSet(\.deletingSaves),
                                               titleVisibility: .visible, presenting: center.deletingSaves) { game in
                    Button(model.text(.deleteSaves), role: .destructive) {
                        if let problem = model.deleteSaves(game) {
                            center.notice = GameNotice(title: model.text(.deleteSaves), message: model.text(for: problem))
                        }
                    }
                    Button(model.text(.cancel), role: .cancel) {}
                } message: { game in
                    Text("\(model.name(of: game)) · \(model.sizeText(model.saveBytes(game)))\n\(model.text(.deleteSavesBody))")
                }
            }
            .background {
                Color.clear.alert(center.notice?.title ?? "", isPresented: isSet(\.notice), presenting: center.notice) { _ in
                    Button(model.text(.close), role: .cancel) {}
                } message: { notice in
                    Text(notice.message)
                }
            }
            .fileImporter(isPresented: $center.showingImporter, allowedContentTypes: [.zip, .folder]) { result in
                center.importSaves(from: result, model: model)
            }
            .sheet(item: $center.sheet) { sheet in
                switch sheet {
                case .share(let url):
                    ActivityView(items: [url]).presentationDetents([.medium, .large])
                case .logs(let titleID, let open):
                    LogsView(titleID: titleID, open: open)
                        .environmentObject(model)
                        .presentationBackground(ShellInk.background)
                case .shortcut(let name, let file):
                    ShortcutSheet(name: name, file: file)
                        .environmentObject(model)
                        .presentationBackground(ShellInk.background)
                }
            }
    }

    private func isSet<T>(_ keyPath: ReferenceWritableKeyPath<GameActionCenter, T?>) -> Binding<Bool> {
        Binding(get: { center[keyPath: keyPath] != nil }, set: { if !$0 { center[keyPath: keyPath] = nil } })
    }
}

/// How to put a game on the home screen: iOS lets no app add an icon there, so the app writes a profile with a web clip
/// and the player installs it in Settings. The steps stay on screen while the player goes to Files and back.
struct ShortcutSheet: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    let name: String
    let file: URL
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            ZStack {
                ShellInk.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(name).font(.system(size: 20, weight: .semibold)).foregroundStyle(ShellInk.primary)
                        ShellCard {
                            VStack(alignment: .leading, spacing: 12) {
                                step(1, .shortcutStep1)
                                step(2, .shortcutStep2)
                                step(3, .shortcutStep3)
                            }
                        }
                        Text(model.text(.shortcutRemove)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                        Button(model.text(.openInFiles)) {
                            Task { if await !model.showInFiles(file) { sharing = true } }
                        }
                        .buttonStyle(ShellButtonStyle(prominent: true))
                        Button(model.text(.shareFile)) { sharing = true }.buttonStyle(ShellButtonStyle())
                    }
                    .padding(20)
                }
            }
            .navigationTitle(model.text(.addToHomeScreen))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(model.text(.close)) { dismiss() } }
            }
            .sheet(isPresented: $sharing) { ActivityView(items: [file]).presentationDetents([.medium, .large]) }
        }
        .preferredColorScheme(.dark)
    }

    private func step(_ number: Int, _ key: ShellStrings.Key) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.system(size: 13, weight: .bold)).foregroundStyle(ShellInk.background)
                .frame(width: 24, height: 24).background(ShellInk.accent, in: Circle())
                .accessibilityHidden(true)
            Text(model.text(key)).font(.system(size: 14)).foregroundStyle(ShellInk.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The system's share sheet: Save to Files, AirDrop to the Mac, and the rest.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
