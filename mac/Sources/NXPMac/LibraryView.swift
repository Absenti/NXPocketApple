import AppKit
import SwiftUI
import NXPocketKit
import NXPMacKit
import NXPMacModel

/// Where a game stands, for the library: on the iPhone, to update, to send, being sent, or broken.
private enum GameStatus: Equatable {
    case onPhone, update, toSend, sending(Double), broken

    var label: String {
        switch self {
        case .onPhone: return "On iPhone"
        case .update: return "Update"
        case .toSend: return "To send"
        case .sending(let fraction): return "Sending \(Int(fraction * 100))%"
        case .broken: return "Needs rebuild"
        }
    }

    var color: Color {
        switch self {
        case .onPhone: return Ink.good
        case .update, .toSend: return Ink.accent
        case .sending: return Ink.primary
        case .broken: return Ink.bad
        }
    }
}

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", onPhone = "On iPhone", toSend = "To send", toBuild = "To build", broken = "To rebuild"
    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    /// The games selected, by title ID. A click selects one; ⌘ or ⇧ click adds to the selection.
    @State private var picked: Set<String> = []
    /// The game the inspector shows.
    @State private var focusID: String?
    /// The game of the games folder the inspector shows, when a "to build" tile is the one selected.
    @State private var focusBuildID: String?
    @State private var filter: LibraryFilter = .all
    @State private var query = ""
    /// The package the user asked to delete, until they confirm.
    @State private var deleting: LocalGame?
    /// The package being renamed, and the name typed so far.
    @State private var renaming: LocalGame?
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 164), spacing: 16, alignment: .top)]

    var body: some View {
        // The theme is worked out once per pass, not once per tile.
        let theme = self.theme
        let ring = theme.ring
        return VStack(spacing: 0) {
            // The toolbar spans the whole window: whatever the inspector shows, it never covers these buttons.
            topBar
            Divider().overlay(Ink.line)
            HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.setupIncomplete { setupNotice.padding(.top, 16) }
                        toolbar
                        if let problem = model.libraryProblem {
                            Text(Friendly.text(problem)).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled)
                                .padding(.horizontal, 28).padding(.bottom, 8)
                        }
                        if model.games.isEmpty && model.buildableGames.isEmpty {
                            empty
                        } else {
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: 22) {
                                    ForEach(shown) { game in
                                        // A button, so the keyboard and VoiceOver reach it; ⌘ or ⇧ at the click adds to the selection.
                                        Button { tap(game) } label: {
                                            GameTile(game: game, status: status(of: game), selected: picked.contains(game.id),
                                                     focused: focused?.id == game.id, multi: picked.count > 1, ring: ring)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(game.title), \(status(of: game).label)")
                                        .contextMenu { menu(for: game) }
                                    }
                                    ForEach(shownBuildable) { game in
                                        Button { tapBuildable(game) } label: {
                                            BuildableTile(game: game, item: model.buildItem(game.titleID), selected: focusBuildID == game.titleID)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(game.name), to build")
                                    }
                                }
                                .padding(.horizontal, 28)
                                .padding(.top, 6)
                                .padding(.bottom, picked.count > 1 ? 90 : 28)
                            }
                        }
                    }
                    if pickedGames.count > 1 { sendBar }
                }
                .frame(maxWidth: .infinity)

                if let id = focusBuildID, let game = model.buildableGames.first(where: { $0.titleID == id }) {
                    Divider().overlay(Ink.line)
                    BuildInspector(game: game, theme: theme).frame(width: 320)
                } else if let game = focused {
                    Divider().overlay(Ink.line)
                    Inspector(game: game, status: status(of: game), theme: theme, onRename: { startRename(game) }, onDelete: { deleting = game })
                        .frame(width: 320)
                }
            }
        }
        .background {
            // A soft wash of the selected game's colour, behind everything.
            RadialGradient(colors: [theme.glow.opacity(0.20), theme.glow.opacity(0.05), .clear],
                           center: UnitPoint(x: 0.88, y: 0.05), startRadius: 0, endRadius: 760)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.5), value: focused?.id)
        }
        .sheet(item: $renaming) { game in renameSheet(game) }
        .alert("The archive is ready", isPresented: Binding(get: { model.archiveResult != nil }, set: { if !$0 { model.archiveResult = nil } }),
               presenting: model.archiveResult) { result in
            Button("Copy the SHA-256") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.sha256, forType: .string) }
            Button("Show in Finder") { model.revealInFinder(result.url) }
            Button("Done", role: .cancel) {}
        } message: { result in
            Text("\(result.url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))\n\nSHA-256\n\(result.sha256)\n\nPut it behind a link only you know, then give the iPhone the link and this hash: it checks the hash before it unpacks anything.")
        }
        .confirmationDialog(deleting.map { "Move \($0.title) to the Trash?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { game in
            Button("Move to the Trash", role: .destructive) { model.moveToTrash(game) }
            Button("Cancel", role: .cancel) {}
        } message: { game in
            Text("\(game.root.lastPathComponent) (\(game.byteCountText)) goes to the Trash, where it can be put back until the Trash is emptied. The game on the iPhone and its saves are not touched.")
        }
    }

    // MARK: Data

    private var focused: LocalGame? {
        model.games.first { $0.id == focusID } ?? model.games.first
    }

    /// The colours the selected game lends the screen, from its picture.
    private var theme: GameTheme {
        guard let game = focused else { return .standard }
        return ArtTheme.theme(for: game.iconURL.flatMap(IconCache.image(contentsOf:)), key: "\(game.iconURL?.path ?? game.id)#\(game.modified?.timeIntervalSince1970 ?? 0)#\(game.byteCount)#\(game.packageVersion)")
    }

    private func status(of game: LocalGame) -> GameStatus {
        if game.isBroken { return .broken }
        if let item = sending(game) { return .sending(item.fraction) }
        if let phone = model.phoneGame(game.titleID) {
            return phone.packageVersion == game.packageVersion ? .onPhone : .update
        }
        return .toSend
    }

    private func sending(_ game: LocalGame) -> QueueItem? {
        model.queue.first { item in
            guard item.titleID == game.titleID, !item.phase.isFinished else { return false }
            if case .send = item.job { return true }
            if case .sending = item.phase { return true }
            return false
        }
    }

    private func count(_ filter: LibraryFilter) -> Int {
        if filter == .toBuild { return model.buildableGames.count }
        return model.games.filter { matches($0, filter) }.count
    }

    private func matches(_ game: LocalGame, _ filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: return true
        case .onPhone: return status(of: game) == .onPhone
        case .toSend:
            let state = status(of: game)
            return state == .toSend || state == .update
        case .broken: return status(of: game) == .broken
        case .toBuild: return false
        }
    }

    private var shown: [LocalGame] {
        model.games.filter { matches($0, filter) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    }

    /// The selected games that can still be sent: a package gone or damaged since it was picked drops out.
    private var pickedGames: [LocalGame] {
        model.games.filter { picked.contains($0.id) && $0.isReady }
    }

    private var readyGames: [LocalGame] { model.games.filter(\.isReady) }

    /// The games of the folder that can be built, for the "All" and "To build" lists.
    private var shownBuildable: [FolderGame] {
        guard filter == .all || filter == .toBuild else { return [] }
        return model.buildableGames.filter { query.isEmpty || model.displayName(titleID: $0.titleID, own: $0.name).localizedCaseInsensitiveContains(query) }
    }

    private func tapBuildable(_ game: FolderGame) {
        focusBuildID = game.titleID
        picked = []
    }

    private func tap(_ game: LocalGame) {
        let flags = NSEvent.modifierFlags
        focusID = game.id
        focusBuildID = nil
        if flags.contains(.command) || flags.contains(.shift) {
            if picked.contains(game.id) { picked.remove(game.id) } else { picked.insert(game.id) }
        } else {
            picked = [game.id]
        }
    }

    private func startRename(_ game: LocalGame) {
        newName = game.title
        renaming = game
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 12) {
            PageTitle(title: "Library", size: 34,
                      subtitle: "\(model.games.count) \(model.games.count == 1 ? "game" : "games") · \(totalSize)"
                          + (model.buildableGames.isEmpty ? "" : " · \(model.buildableGames.count) to build"))
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 12).frame(width: 190, height: 34)
            .background(Ink.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Ink.line))
            Button {
                model.screen = .build
            } label: {
                Label {
                    HStack(spacing: 8) { Text("Add a game"); Kbd("⇧⌘B", onFill: true) }
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .buttonStyle(PrimaryButtonStyle(large: true, fill: theme.fill))
            .fixedSize()
        }
        .padding(.horizontal, 28)
        .frame(height: 84)
    }

    private var totalSize: String {
        ByteCountFormatter.string(fromByteCount: model.games.reduce(0) { $0 + $1.byteCount }, countStyle: .file)
    }

    private var setupNotice: some View {
        HStack(spacing: 14) {
            Image(systemName: "checklist").font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.accent)
                .frame(width: 34, height: 34).background(Ink.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish setting up this Mac").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.primary)
                Text("A build needs the engine and your prod.keys first.").font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            Spacer()
            Button("Open Setup") { model.screen = .setup }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(Ink.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.accent.opacity(0.3)))
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        HStack(spacing: 6) {
                            Text(item.rawValue)
                            Text("\(count(item))").opacity(0.6)
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(filter == item ? Ink.primary : Ink.secondary)
                        .padding(.horizontal, 13).frame(height: 30)
                        .background(filter == item ? Ink.raised : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(filter == item ? Ink.line.opacity(1.6) : Ink.line))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)
        }
        .padding(.vertical, 14)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            PocketMark(size: 64)
            Text("No games built yet").font(.system(size: 17, weight: .bold)).foregroundStyle(Ink.primary)
            Text("Point NXPocketApple at a folder that holds your own game dump, and it builds a package you can send to the phone.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Add a game") { model.screen = .build }
                .buttonStyle(PrimaryButtonStyle(large: true, fill: theme.fill)).padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .stitched(radius: 22)
        .padding(28)
    }

    /// What to do with the selected games, at the bottom of the grid while several are selected.
    private var sendBar: some View {
        let games = pickedGames
        return HStack(spacing: 12) {
            Text("\(games.count) games selected").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.primary)
            Text(ByteCountFormatter.string(fromByteCount: games.reduce(0) { $0 + $1.byteCount }, countStyle: .file))
                .font(.system(size: 12)).foregroundStyle(Ink.secondary)
            Spacer()
            Button(games.count == readyGames.count ? "Deselect all" : "Select all") {
                picked = games.count == readyGames.count ? [] : Set(readyGames.map(\.id))
            }
            .buttonStyle(QuietButtonStyle())
            if let device = model.selectedDevice {
                Button {
                    model.queueSend(games, to: device)
                    picked = []
                } label: {
                    Label("Send to \(device.name)", systemImage: "arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Text("Connect an iPhone to send").font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
        }
        .padding(.horizontal, 18).frame(height: 54)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.accent.opacity(0.4)))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .padding(.horizontal, 28).padding(.bottom, 22)
    }

    private func renameSheet(_ game: LocalGame) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(game.title)").font(.system(size: 15, weight: .semibold))
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .onSubmit { commitRename(game) }
            Text(model.phoneGame(game.titleID) != nil
                 ? "The new name is written into the package at once. The iPhone shows it once the game is sent again (its saves stay). Every later build of this game keeps it."
                 : "The new name is written into the package, and the iPhone shows it when the game is sent. Every later build of this game keeps it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let original = model.originalName(of: game) {
                    Button("Use its own name (\(original))") {
                        model.renameGame(game, to: nil)
                        renaming = nil
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { renaming = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") { commitRename(game) }
                    .keyboardShortcut(.defaultAction)
                    .disabled((try? PackageRenamer.clean(newName)) == nil || newName == game.title)
            }
        }
        .padding(20)
    }

    private func commitRename(_ game: LocalGame) {
        guard (try? PackageRenamer.clean(newName)) != nil, newName != game.title else { return }
        model.renameGame(game, to: newName)
        renaming = nil
    }

    @ViewBuilder
    private func menu(for game: LocalGame) -> some View {
        if let item = sending(game) {
            Button("Cancel sending") { model.cancelItem(item.id) }
        } else if let device = model.selectedDevice, game.isReady {
            Button("Send to \(device.name)") { model.queueSend(game, to: device) }
        }
        if let fraction = model.uploads[game.titleID] {
            Button("Cancel sending to my server (\(Int(fraction * 100))%)") { model.cancelUpload(game.titleID) }
        } else if model.serverIsSetUp, game.isReady {
            Button("Send to my server") { model.uploadToServer(game) }
        } else if game.isReady {
            Button("Set up a server to send to…") { model.screen = .server }
        }
        if let fraction = model.archiving[game.titleID] {
            Button("Cancel the archive (\(Int(fraction * 100))%)") { model.cancelArchive(game.titleID) }
        } else if game.isReady {
            Button("Export as an archive…") { model.exportArchive(game) }
        }
        if game.isReady {
            Button("Rename…") { startRename(game) }
        }
        Button("Show in Finder") { model.revealInFinder(game.root) }
        Button("Copy title ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(game.titleID, forType: .string) }
        if model.phoneGame(game.titleID) != nil {
            Button("Back up its saves from the iPhone") { model.backUpSaves(of: [game.titleID]) }
                .disabled(model.backingUp.contains(game.titleID))
        }
        Divider()
        Button("Move package to the Trash…", role: .destructive) { deleting = game }
    }
}

/// A game in the grid: its picture, what it is, and where it stands.
private struct GameTile: View {
    let game: LocalGame
    let status: GameStatus
    let selected: Bool
    let focused: Bool
    let multi: Bool
    let ring: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                GameCover(game: game, radius: 22)
                    .aspectRatio(1, contentMode: .fit)
                if case .sending(let fraction) = status {
                    Bar(fraction: fraction).padding(10)
                } else {
                    StatusChip(status: status).padding(10)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected && multi {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Ink.onDeep)
                        .frame(width: 22, height: 22).background(Ink.deep, in: Circle()).padding(8)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(focused && selected ? ring : (selected ? ring.opacity(0.55) : .clear), lineWidth: 2)
                .padding(-4))
            Text(game.title).font(.system(size: 13.5, weight: .bold)).tracking(-0.2).foregroundStyle(Ink.primary)
                .lineLimit(1).padding(.top, 10)
            Text(game.isBroken ? "Package damaged" : [game.version.isEmpty ? nil : "v\(game.version)", game.byteCountText].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(Ink.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// The game's icon, or a placeholder.
private struct GameCover: View {
    let game: LocalGame
    var radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.raised)
            if let icon = game.iconURL.flatMap(IconCache.image(contentsOf:)) {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: game.isBroken ? "exclamationmark.triangle" : "gamecontroller")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(game.isBroken ? Ink.bad : Ink.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Ink.line))
    }
}

/// A status over a picture: dark, with the status colour on the text and the outline, so it reads on any artwork.
private struct StatusChip: View {
    let status: GameStatus

    var body: some View {
        Text(status.label)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Color(red: 0.055, green: 0.055, blue: 0.070).opacity(0.86), in: Capsule())
            .overlay(Capsule().strokeBorder(status.color.opacity(0.8)))
    }
}

/// The selected game: what it is and where it stands scroll; the actions stay pinned at the bottom, never cut off.
private struct Inspector: View {
    @EnvironmentObject private var model: AppModel
    let game: LocalGame
    let status: GameStatus
    let theme: GameTheme
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        GameCover(game: game, radius: 32)
                        StatusChip(status: status).padding(14)
                    }
                    .frame(width: 236, height: 236)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                    // The halo is a background: it is drawn wide but never makes the column wider than the panel.
                    .background {
                        Circle().fill(RadialGradient(colors: [theme.glow.opacity(0.30), .clear], center: .center, startRadius: 0, endRadius: 190))
                            .frame(width: 380, height: 380)
                    }
                    .frame(maxWidth: .infinity, minHeight: 250)
                    .animation(.easeInOut(duration: 0.4), value: game.id)

                    Text(game.title).font(.system(size: 25, weight: .heavy)).tracking(-0.8).foregroundStyle(Ink.primary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 10)

                    HStack(spacing: 6) {
                        if !game.version.isEmpty { chip("v\(game.version)") }
                        chip(game.byteCountText)
                    }
                    .padding(.top, 8)

                    if let problem = game.problem {
                        Text(Friendly.text(problem.detail)).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled).padding(.top, 10)
                    }

                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            row("Installed on the iPhone", model.phoneGame(game.titleID).map { $0.version.isEmpty ? "yes" : "v\($0.version)" } ?? "not yet")
                            if model.phoneGame(game.titleID) != nil { BackupLine(titleID: game.titleID) }
                        }
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 22).padding(.vertical, 22)
            }

            VStack(spacing: 10) {
                primaryAction
                HStack(spacing: 8) {
                    Button("Rename", action: onRename).buttonStyle(QuietButtonStyle(large: true)).disabled(!game.isReady)
                    Button("Finder") { model.revealInFinder(game.root) }.buttonStyle(QuietButtonStyle(large: true))
                    Menu {
                        Button("Copy title ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(game.titleID, forType: .string)
                        }
                        if model.phoneGame(game.titleID) != nil {
                            Button("Back up its saves") { model.backUpSaves(of: [game.titleID]) }
                                .disabled(model.backingUp.contains(game.titleID))
                        }
                        Divider()
                        Button("Move to the Trash…", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.primary)
                            .frame(width: 36, height: 36)
                            .background(Ink.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More actions")
                }
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 18)
            .background(Ink.surface)
            .overlay(alignment: .top) { Divider().overlay(Ink.line) }
        }
        .background(Ink.background)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch status {
        case .broken:
            Button { model.screen = .build } label: { wide("Rebuild this game") }.buttonStyle(PrimaryButtonStyle(large: true, fill: theme.fill))
        case .sending(let fraction):
            HStack(spacing: 8) {
                Button {} label: { wide("Sending · \(Int(fraction * 100))%") }.buttonStyle(PrimaryButtonStyle(large: true, fill: theme.fill)).disabled(true)
                if let item = sendingItem {
                    Button("Cancel") { model.cancelItem(item.id) }.buttonStyle(QuietButtonStyle(large: true))
                }
            }
        case .onPhone:
            Button { model.backUpSaves(of: [game.titleID]) } label: { wide("Back up the saves") }
                .buttonStyle(PrimaryButtonStyle(large: true, fill: theme.fill)).disabled(model.backingUp.contains(game.titleID))
        case .toSend, .update:
            if let device = model.selectedDevice {
                Button { model.queueSend(game, to: device) } label: {
                    wide(status == .update ? "Update on \(device.name)" : "Send to \(device.name)")
                }
                .buttonStyle(PrimaryButtonStyle(large: true, fill: theme.fill))
            } else {
                Button {} label: { wide("Connect an iPhone to send") }.buttonStyle(PrimaryButtonStyle(large: true, fill: theme.fill)).disabled(true)
            }
        }
    }

    private func wide(_ text: String) -> some View {
        Text(text).lineLimit(1).frame(maxWidth: .infinity)
    }

    /// This game's send, waiting or under way in the queue.
    private var sendingItem: QueueItem? {
        model.queue.first { item in
            guard item.titleID == game.titleID, !item.phase.isFinished else { return false }
            if case .send = item.job { return true }
            if case .sending = item.phase { return true }
            return false
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.secondary)
            .padding(.horizontal, 9).frame(height: 22).background(Ink.raised, in: Capsule())
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.primary)
        }
    }
}

/// The status as a pill beside a title.
private struct StatusPill: View {
    let status: GameStatus

    var body: some View {
        Text(status.label).font(.system(size: 11, weight: .bold)).foregroundStyle(status.color)
            .padding(.horizontal, 9).frame(height: 22)
            .background(status.color.opacity(0.14), in: Capsule())
    }
}

/// A game of the games folder that is not built yet: its picture from the dump, a dashed outline, and where its build stands.
private struct BuildableTile: View {
    @EnvironmentObject private var model: AppModel
    let game: FolderGame
    let item: QueueItem?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                BuildableCover(game: game, radius: 22).aspectRatio(1, contentMode: .fit)
                if let item, item.phase.isActive {
                    Bar(fraction: item.fraction).padding(10)
                } else {
                    chip(item == nil ? "To build" : "Queued", Ink.accent).padding(10)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(selected ? Ink.accent : Ink.line.opacity(1.8), style: StrokeStyle(lineWidth: selected ? 2 : 1.2, dash: selected ? [] : [5, 4]))
                .padding(selected ? -4 : 0))
            Text(model.displayName(titleID: game.titleID, own: game.name)).font(.system(size: 13.5, weight: .bold)).tracking(-0.2)
                .foregroundStyle(Ink.primary).lineLimit(1).padding(.top, 10)
            Text(game.summary).font(.system(size: 11.5)).foregroundStyle(Ink.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Color(red: 0.055, green: 0.055, blue: 0.070).opacity(0.86), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.8)))
    }
}

private struct BuildableCover: View {
    let game: FolderGame
    var radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.surface)
            if let icon = IconCache.image(key: "folder-\(game.titleID)", data: game.icon) {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fill).opacity(0.85)
            } else {
                Image(systemName: "shippingbox").font(.system(size: 34, weight: .light)).foregroundStyle(Ink.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The selected game of the folder: what was found for it, and the button that builds it.
private struct BuildInspector: View {
    @EnvironmentObject private var model: AppModel
    let game: FolderGame
    let theme: GameTheme

    private var item: QueueItem? { model.buildItem(game.titleID) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BuildableCover(game: game, radius: 32)
                        .frame(width: 236, height: 236)
                        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(Ink.line.opacity(1.8), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                        .frame(maxWidth: .infinity, minHeight: 250)
                    Text(model.displayName(titleID: game.titleID, own: game.name)).font(.system(size: 25, weight: .heavy)).tracking(-0.8)
                        .foregroundStyle(Ink.primary).lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            row("Found", game.summary)
                            if let base = game.base { row("Base game", base.package.url.lastPathComponent) }
                            if let version = model.selectedVersionTag(of: game) { row("Version to build", version) }
                        }
                    }
                    .padding(.top, 16)
                    Text("Not built yet. A build takes a while and needs room for the game's decompressed copy.")
                        .font(.system(size: 11.5)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                }
                .padding(.horizontal, 22).padding(.vertical, 22)
            }
            VStack(spacing: 10) {
                if let item, item.phase.isActive {
                    Button {} label: { Text("Building · \(Int(item.fraction * 100))%").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle(large: true, fill: theme.fill)).disabled(true)
                    Button("Cancel") { model.cancelItem(item.id) }.buttonStyle(QuietButtonStyle(large: true))
                } else if item != nil {
                    Button {} label: { Text("Waiting in the queue").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle(large: true, fill: theme.fill)).disabled(true)
                } else {
                    Button { model.buildFromLibrary(game) } label: { Text("Build this game").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle(large: true, fill: theme.fill))
                    if !game.updates.isEmpty || !game.dlc.isEmpty {
                        Button("Choose updates and DLC…") { model.screen = .build }.buttonStyle(QuietButtonStyle(large: true))
                    }
                }
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 18)
            .background(Ink.surface)
            .overlay(alignment: .top) { Divider().overlay(Ink.line) }
        }
        .background(Ink.background)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.primary).multilineTextAlignment(.trailing).lineLimit(2)
        }
    }
}
