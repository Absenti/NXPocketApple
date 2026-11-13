import NXPocketKit
import NXShellUI
import SwiftUI

/// The library: the games as covers, and above them only what needs the player now (a game arriving from the Mac, an
/// import, a launch that failed, games to sign again). A game sent from the Mac is imported as it lands
/// (`ShellHostModel.watchTransfers`), so there is no import button to find.
struct LibraryScreen: View {
    @EnvironmentObject private var model: ShellHostModel

    @State private var sheet: Sheet?
    @State private var selected: InstalledGame?
    @StateObject private var actions = GameActionCenter()
    /// The game in front, kept across tabs and launches; and how the library is shown: one cover at a time, or all.
    @AppStorage("libraryFocusID") private var focusID = ""
    @AppStorage("libraryStyle") private var style = "covers"
    @State private var scrolledID: String?

    enum Sheet: Identifiable {
        /// The Logs screen, opened on one log or on the list.
        case logs(LogFile?)

        var id: String {
            switch self {
            case .logs(let open): return "logs:\(open?.id ?? "")"
            }
        }
    }

    /// Takes the player to the settings, where the certificate is imported.
    let openSettings: () -> Void

    init(openSettings: @escaping () -> Void) { self.openSettings = openSettings }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    LibraryNotices(openSettings: openSettings, openLog: { sheet = .logs($0) }, compact: style == "covers" && !model.games.isEmpty)
                    if model.games.isEmpty {
                        // Nothing until the first read of the library is back: "no games yet" would be a lie for a moment.
                        if model.libraryLoaded { emptyState }
                    } else if style == "covers" {
                        // The stage fills the screen: the covers sit in the middle of what the header and notices leave.
                        Spacer(minLength: 0)
                        covers
                        Spacer(minLength: 0)
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
                .padding(.bottom, 110)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .gameActions(actions)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { which in
            Group {
                switch which {
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

    // MARK: The covers, one at a time

    /// The game in front: the remembered one if it is still there, else the first.
    private var focused: InstalledGame? {
        model.games.first { $0.id == focusID } ?? model.games.first
    }

    private var covers: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(model.games) { game in
                            cover(game)
                                .frame(width: 230, height: 230)
                                .padding(.horizontal, 6)
                                .scrollTransition(axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(phase.isIdentity ? 1.06 : 0.82)
                                        .opacity(phase.isIdentity ? 1 : 0.55)
                                        .rotation3DEffect(.degrees(phase.value * -24), axis: (0, 1, 0), perspective: 0.6)
                                }
                                .id(game.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, max(0, (geometry.size.width - 242) / 2), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $scrolledID, anchor: .center)
            }
            .frame(height: 290)
            .padding(.horizontal, -20)
            .onAppear { scrolledID = focused?.id }
            .onChange(of: scrolledID) { _, id in if let id { focusID = id } }

            if let game = focused { stage(game) }
        }
    }

    private func cover(_ game: InstalledGame) -> some View {
        Button {
            if game.id == focused?.id { selected = game } else { withAnimation(.easeOut(duration: 0.3)) { scrolledID = game.id } }
        } label: {
            GameIcon(game: game, cornerRadius: 38)
                .overlay(RoundedRectangle(cornerRadius: 38, style: .continuous).strokeBorder(ShellInk.line))
                .overlay(alignment: .topLeading) { GameBadge(game: game).padding(14) }
                .shadow(color: ArtTheme.theme(for: game).glow.opacity(0.45), radius: 26, y: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.name(of: game))
        .contextMenu { GameMenuItems(game: game) { perform($0, on: game) } }
    }

    /// Under the covers: the game's name, what it is, where it stands in the library, and the two things to do.
    private func stage(_ game: InstalledGame) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: game.byteCount, countStyle: .file)
        let meta = game.version.isEmpty ? size : "v\(game.version) · \(size)"
        let theme = ArtTheme.theme(for: game)
        return VStack(spacing: 6) {
            Text(model.name(of: game)).font(ShellFont.display(30)).foregroundStyle(ShellInk.primary)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
            Text(meta).font(.system(size: 13)).foregroundStyle(ShellInk.secondary)
            dots.padding(.vertical, 14)
            HStack(spacing: 14) {
                Button { selected = game } label: {
                    Text(model.text(.details)).font(ShellFont.body(15, .semibold)).foregroundStyle(ShellInk.primary)
                        .padding(.horizontal, 24).frame(height: 58)
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                Button { model.play(game) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "play.fill").font(.system(size: 16))
                        Text(model.text(.play)).font(ShellFont.body(17, .semibold))
                    }
                    .foregroundStyle(ShellInk.onDeep)
                    .padding(.horizontal, 30).frame(height: 58)
                    .background(theme.bright, in: Capsule())
                    .shadow(color: theme.glow.opacity(0.55), radius: 14, y: 8)
                }
                .buttonStyle(.plain)
                .disabled(game.isBroken)
                .opacity(game.isBroken ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.25), value: game.id)
    }

    /// One dot per game, the current one long; at most nine, around the current one.
    private var dots: some View {
        let ids = model.games.map(\.id)
        let current = ids.firstIndex(of: focused?.id ?? "") ?? 0
        let first = max(0, min(current - 4, ids.count - 9))
        let window = Array(ids.indices[first..<min(ids.count, first + 9)])
        return HStack(spacing: 6) {
            ForEach(window, id: \.self) { index in
                Capsule().fill(index == current ? ShellInk.primary : Color.white.opacity(0.3))
                    .frame(width: index == current ? 22 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.25), value: current)
        .accessibilityHidden(true)
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
            AppMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.text(.library))
                    .font(ShellFont.display(26)).foregroundStyle(ShellInk.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(summary).font(.system(size: 12)).foregroundStyle(ShellInk.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if style == "covers", !model.games.isEmpty {
                // The design's pill: the one thing the player has to do, short. No certificate: sign in; games to sign: sign.
                if model.certificate == nil {
                    headerPill(model.text(.signIn), action: openSettings)
                } else if !model.importState.isRunning, !model.gamesNeedingSignature().isEmpty {
                    headerPill(model.text(.sign)) { model.resignAll() }
                }
            }
            if !model.games.isEmpty {
                Button { withAnimation(.easeOut(duration: 0.2)) { style = style == "covers" ? "grid" : "covers" } } label: {
                    Image(systemName: style == "covers" ? "square.grid.2x2.fill" : "rectangle.stack.fill")
                        .font(.system(size: 16)).foregroundStyle(ShellInk.primary)
                        .frame(width: 42, height: 42)
                        .background(ShellInk.raised, in: Circle())
                }
                .accessibilityLabel(model.text(style == "covers" ? .showGrid : .showCovers))
            }
        }
        .padding(.top, 6)
    }

    private func headerPill(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(ShellFont.body(12, .semibold)).foregroundStyle(ShellInk.onDeep)
                .lineLimit(1).padding(.horizontal, 14).padding(.vertical, 9).background(ShellInk.deep, in: Capsule())
        }
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
        .padding(32)
        .frame(maxWidth: .infinity)
        .shellStitched(radius: 22)
        .padding(.top, 50)
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
            GameIcon(game: game, cornerRadius: 20)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(ShellInk.line))
                .overlay(alignment: .topLeading) { GameBadge(game: game).padding(8) }
                .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
            Text(model.name(of: game))
                .font(.system(size: 14, weight: .bold)).tracking(-0.2).foregroundStyle(ShellInk.primary)
                .lineLimit(2).multilineTextAlignment(.leading)
            Text(details).font(.system(size: 11)).foregroundStyle(ShellInk.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: game.byteCount, countStyle: .file)
        return game.version.isEmpty ? size : "v\(game.version) · \(size)"
    }
}

/// The mark a game carries only when something stands between it and Play.
struct GameBadge: View {
    @EnvironmentObject private var model: ShellHostModel
    let game: InstalledGame

    @ViewBuilder
    var body: some View {
        if game.problem != nil {
            TileBadge(text: model.text(.broken), color: ShellInk.bad)
        } else if game.isExpired() {
            TileBadge(text: model.text(.resignNeeded), color: ShellInk.bad)
        } else if let identity = model.signingIdentity, !game.isSigned(by: identity) {
            TileBadge(text: model.text(.resignNeeded), color: ShellInk.accent)
        }
    }
}

struct TileBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
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

    /// The colours this game lends the screen, from its picture.
    private var theme: GameTheme { ArtTheme.theme(for: game) }

    public var body: some View {
        ZStack {
            ShellInk.background.ignoresSafeArea()
            // A soft wash of the game's colour from the top, behind everything.
            RadialGradient(colors: [theme.glow.opacity(0.24), theme.glow.opacity(0.06), .clear],
                           center: UnitPoint(x: 0.2, y: 0.0), startRadius: 0, endRadius: 520)
                .ignoresSafeArea().allowsHitTesting(false)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero

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
                            .buttonStyle(ShellButtonStyle(prominent: true, fill: theme.fill, radius: 16))
                            .disabled(game.isBroken)
                        Button(model.text(.remove)) { actions.removing = game }
                            .buttonStyle(ShellButtonStyle(radius: 16, textColor: Color(red: 0.95, green: 0.55, blue: 0.52)))
                    }

                    if case .failed(let message) = model.launch {
                        ShellCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message).font(.system(size: 12)).foregroundStyle(ShellInk.bad)
                                CopyReportButton(error: message, titleID: game.id)
                            }
                        }
                    }

                    statTiles

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
    /// The design's header: a band washed with the game's colour and striped like the logo's pocket stitching, the name
    /// large at its foot, the identifier under it, and the game's menu in the corner.
    private var hero: some View {
        var ids = [game.titleID.description]
        if !game.version.isEmpty { ids.append("v\(game.version)") }
        if let chain = game.chain { ids.append(chain) }
        ids.append(ByteCountFormatter.string(fromByteCount: game.byteCount, countStyle: .file))
        return ZStack(alignment: .bottomLeading) {
            ShellInk.surface
            LinearGradient(colors: [theme.glow.opacity(0.80), theme.glow.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
            StripePattern()
            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.name(of: game)).font(ShellFont.display(28)).foregroundStyle(.white)
                    .lineLimit(2).minimumScaleFactor(0.7)
                Text(ids.joined(separator: " · ")).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(20)
        }
        .frame(height: 210)
        .overlay(alignment: .topTrailing) {
            Menu {
                GameMenuItems(game: game, showsSettings: false) { actions.perform($0, on: game, model: model) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel(model.text(.moreActions))
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    /// Play time and saves, side by side.
    private var statTiles: some View {
        let time = model.playTime(of: game)
        return HStack(spacing: 12) {
            tile(model.text(.playTime), time?.total ?? model.text(.neverPlayed), caption: time.map { "\(model.text(.lastPlayed)) · \($0.last)" })
            tile(model.text(.saves), model.sizeText(model.saveBytes(game)), caption: nil)
        }
    }

    private func tile(_ label: String, _ value: String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(ShellInk.secondary)
            Text(value).font(ShellFont.display(19, .semibold)).foregroundStyle(ShellInk.primary).lineLimit(1).minimumScaleFactor(0.6)
            if let caption { Text(caption).font(.system(size: 11)).foregroundStyle(ShellInk.secondary).lineLimit(1) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShellInk.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ShellInk.line))
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


/// Diagonal stripes over a band of colour: the texture of the design's cards, and of the logo's stitching.
struct StripePattern: View {
    var body: some View {
        Canvas { context, size in
            var x = -size.height
            while x < size.width {
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height))
                line.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 10)
                x += 26
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
