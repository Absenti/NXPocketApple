import NXPocketKit
import NXShellUI
import SwiftUI

/// The library: the games as covers, and above them only what needs the player now (a game arriving from the Mac, an
/// import, a launch that failed, games to sign again). A game sent from the Mac is imported as it lands
/// (`ShellHostModel.watchTransfers`), so there is no import button to find.
public struct ShellRootView: View {
    @EnvironmentObject private var model: ShellHostModel

    @State private var sheet: Sheet?
    @State private var selected: InstalledGame?
    @StateObject private var actions = GameActionCenter()

    enum Sheet: Identifiable {
        case settings
        /// The Logs screen, opened on one log or on the list.
        case logs(LogFile?)

        var id: String {
            switch self {
            case .settings: return "settings"
            case .logs(let open): return "logs:\(open?.id ?? "")"
            }
        }
    }

    public init() {}

    public var body: some View {
        ZStack {
            ShellInk.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    LibraryNotices(openSettings: { sheet = .settings }, openLog: { sheet = .logs($0) })
                    if model.games.isEmpty {
                        // Nothing until the first read of the library is back: "no games yet" would be a lie for a moment.
                        if model.libraryLoaded { emptyState }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 16, alignment: .top)],
                                  spacing: 22) {
                            ForEach(model.games) { game in
                                Button { selected = game } label: { GameTile(game: game) }
                                    .buttonStyle(.plain)
                                    .contextMenu { GameMenuItems(game: game) { perform($0, on: game) } }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .gameActions(actions)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .settings: ShellSettingsView()
                case .logs(let open): LogsView(open: open)
                }
            }
            .environmentObject(model)
            .presentationBackground(ShellInk.background)
        }
        .sheet(item: $selected) { game in
            GameDetailView(game: game)
                .environmentObject(model)
                .presentationBackground(ShellInk.background)
        }
    }

    /// The settings and the test open the game's screen, where they show; the rest is the menu's own.
    private func perform(_ action: GameMenuAction, on game: InstalledGame) {
        switch action {
        case .settings:
            selected = game
        case .testLoad:
            selected = game
            model.testLoad(game)
        default:
            actions.perform(action, on: game, model: model)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            AppMark(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.text(.library))
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(ShellInk.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(summary).font(.system(size: 12)).foregroundStyle(ShellInk.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { sheet = .settings } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 17)).foregroundStyle(ShellInk.primary)
                    .frame(width: 42, height: 42)
                    .background(ShellInk.raised, in: Circle())
            }
            .accessibilityLabel(model.text(.settings))
        }
        .padding(.top, 6)
    }

    /// "2 games · 6.3 GB · 69 GB free", without the games' size while there are none.
    private var summary: String {
        let free = "\(model.freeText) \(model.text(.free))"
        guard !model.games.isEmpty else { return free }
        return "\(ShellStrings.gameCount(model.games.count, language: model.language)) · \(model.totalText) · \(free)"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            AppMark(size: 72)
            Text(model.text(.libraryEmptyTitle)).font(.system(size: 20, weight: .semibold)).foregroundStyle(ShellInk.primary)
            Text(model.text(.libraryEmptyBody))
                .font(.system(size: 13)).foregroundStyle(ShellInk.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}

/// The app's logo, as on the home screen.
struct AppMark: View {
    let size: CGFloat

    var body: some View {
        Image("Logo")
            .resizable()
            .frame(width: size, height: size)
            .background(ShellInk.raised)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A game as a cover: the whole square icon, its name, and a mark only when something stands between it and Play.
struct GameTile: View {
    @EnvironmentObject private var model: ShellHostModel
    let game: InstalledGame

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameIcon(game: game, cornerRadius: 16)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ShellInk.line))
                .overlay(alignment: .topLeading) { badge.padding(8) }
                .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
            Text(model.name(of: game))
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellInk.primary)
                .lineLimit(2).multilineTextAlignment(.leading)
            Text(details).font(.system(size: 11)).foregroundStyle(ShellInk.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: game.byteCount, countStyle: .file)
        return game.version.isEmpty ? size : "v\(game.version) · \(size)"
    }

    @ViewBuilder
    private var badge: some View {
        if game.problem != nil {
            TileBadge(text: model.text(.broken), color: ShellInk.bad)
        } else if game.isExpired() {
            TileBadge(text: model.text(.resignNeeded), color: ShellInk.bad)
        } else if let identity = model.signingIdentity, !game.isSigned(by: identity) {
            TileBadge(text: model.text(.resignNeeded), color: ShellInk.accent)
        }
    }
}

private struct TileBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.7), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.8)))
            .foregroundStyle(color)
    }
}

public struct GameDetailView: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    /// The game as it was when the screen opened.
    let opened: InstalledGame

    public init(game: InstalledGame) { opened = game }

    /// The library's copy, which a signature or an import since then has changed: the screen shows that, and Play uses it.
    private var game: InstalledGame { model.games.first { $0.id == opened.id } ?? opened }

    @State private var settings: GameSettings?
    @State private var showingTouchControls = false
    @StateObject private var actions = GameActionCenter()

    public var body: some View {
        ZStack {
            ShellInk.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        icon
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.name(of: game)).font(.system(size: 22, weight: .semibold)).foregroundStyle(ShellInk.primary)
                            Text(game.titleID.description).font(.system(size: 12, design: .monospaced)).foregroundStyle(ShellInk.secondary)
                            HStack(spacing: 6) {
                                if !game.version.isEmpty { ShellPill("v\(game.version)") }
                                if let chain = game.chain { ShellPill(chain) }
                                ShellPill(ByteCountFormatter.string(fromByteCount: game.byteCount, countStyle: .file))
                            }
                        }
                        Spacer()
                        Menu {
                            GameMenuItems(game: game, showsSettings: false) { actions.perform($0, on: game, model: model) }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(ShellInk.primary)
                                .frame(width: 40, height: 40)
                                .background(ShellInk.raised, in: Circle())
                        }
                        .accessibilityLabel(model.text(.moreActions))
                    }

                    if let problem = game.problem {
                        ShellCard {
                            VStack(alignment: .leading, spacing: 6) {
                                ShellSectionLabel(model.text(.broken))
                                Text(problem.detail).font(.system(size: 13)).foregroundStyle(ShellInk.bad)
                                Text(problem.code.rawValue).font(.system(size: 11, design: .monospaced)).foregroundStyle(ShellInk.secondary)
                                CopyReportButton(error: "\(problem.code.rawValue): \(problem.detail)", titleID: game.id)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button(model.text(.play)) { model.play(game) }
                            .buttonStyle(ShellButtonStyle(prominent: true))
                            .disabled(game.isBroken)
                        Button(model.text(.remove)) { actions.removing = game }.buttonStyle(ShellButtonStyle())
                    }

                    if case .failed(let message) = model.launch {
                        ShellCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message).font(.system(size: 12)).foregroundStyle(ShellInk.bad)
                                CopyReportButton(error: message, titleID: game.id)
                            }
                        }
                    }

                    playTimeCard

                    if let settings {
                        QuickSettingsCard(settings: settings, choose: choose)
                        GameSettingsCards(settings: settings, choose: choose,
                                          reset: { self.settings = model.resetSettings(settings, for: game) },
                                          openTouchControls: { showingTouchControls = true })
                    }

                    if let signing = game.signing {
                        ShellCard {
                            VStack(alignment: .leading, spacing: 8) {
                                ShellSectionLabel(model.text(.certificate))
                                row(model.text(.certificateSubject), signing.subject)
                                row(model.text(.certificateTeam), signing.teamID)
                                row(model.text(.certificateExpires), signing.expires.formatted(date: .abbreviated, time: .shortened))
                                row(model.text(.identifierLabel), signing.identifier)
                            }
                        }
                    }

                    ShellCard {
                        VStack(alignment: .leading, spacing: 8) {
                            ShellSectionLabel(model.text(.storage))
                            row(model.text(.gameSize), model.sizeText(game.byteCount))
                            row(model.text(.saves), model.sizeText(model.saveBytes(game)))
                            row(model.text(.freeSpace), model.freeText)
                        }
                    }

                    loadTestCard

                    logsCard
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
        }
        .onAppear { settings = model.settings(for: game) }
        .sheet(isPresented: $showingTouchControls) {
            NavigationStack {
                ZStack {
                    ShellInk.background.ignoresSafeArea()
                    ScrollView { TouchControlsCard().padding(20) }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(model.text(.done)) { showingTouchControls = false } }
                }
                .navigationTitle(model.text(.touchControls))
            }
            .environmentObject(model)
            .presentationBackground(ShellInk.background)
        }
        .gameActions(actions, removed: { _ in dismiss() })
    }

    /// The time spent in the game and when it was last played, and what it takes on disk.
    private var playTimeCard: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 8) {
                ShellSectionLabel(model.text(.playTime))
                if let time = model.playTime(of: game) {
                    row(model.text(.playTime), time.total)
                    row(model.text(.lastPlayed), time.last)
                } else {
                    Text(model.text(.neverPlayed)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                }
                row(model.text(.gameSize), model.sizeText(game.byteCount))
            }
        }
    }

    /// The game's logs, one per start: the newest one's date, and the list.
    private var logsCard: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 8) {
                ShellSectionLabel(model.text(.logs))
                if let latest = GameLogs.latest(titleID: game.id, documents: model.documents) {
                    Text("\(latest.date.formatted(date: .abbreviated, time: .shortened)) · \(model.sizeText(latest.bytes))")
                        .font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                } else {
                    Text(model.text(.noLogs)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                }
                Button(model.text(.logs)) { actions.sheet = .logs(titleID: game.id, open: nil) }
                    .buttonStyle(ShellButtonStyle())
            }
        }
    }

    /// "Test loading": what `play()` does before the engine, on this game, and what it measured.
    private var loadTestCard: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 8) {
                ShellSectionLabel(model.text(.testLoad))
                switch model.loadTest {
                case .idle:
                    Text(model.text(.testLoadBody)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                    Button(model.text(.testLoad)) { model.testLoad(game) }
                        .buttonStyle(ShellButtonStyle())
                        .disabled(game.isBroken || model.importState.isRunning)
                case .running(let what):
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(what).font(.system(size: 13)).foregroundStyle(ShellInk.primary)
                    }
                case .finished(let report):
                    ShellPill(report.passed ? model.text(.testLoadPassed) : model.text(.testLoadFailed),
                              color: report.passed ? ShellInk.good : ShellInk.bad)
                    ForEach(report.lines, id: \.self) { line in
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(ShellInk.secondary)
                    }
                    Button(model.text(.close)) { model.clearLoadTest() }.buttonStyle(ShellButtonStyle())
                case .failed(let message):
                    ShellPill(model.text(.testLoadFailed), color: ShellInk.bad)
                    Text(message).font(.system(size: 12)).foregroundStyle(ShellInk.bad)
                    HStack(spacing: 8) {
                        CopyReportButton(error: message, titleID: game.id)
                        Button(model.text(.close)) { model.clearLoadTest() }.buttonStyle(ShellButtonStyle())
                    }
                }
            }
        }
    }

    private var icon: some View {
        GameIcon(game: game, cornerRadius: 14).frame(width: 84, height: 84)
    }

    /// Keeps a choice at once: the next Play reads it from disk.
    private func choose(_ env: String, _ value: String) {
        guard let settings else { return }
        self.settings = model.choose(env, value, in: settings, for: game)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            Spacer(minLength: 12)
            Text(value).font(.system(size: 12)).foregroundStyle(ShellInk.primary)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
