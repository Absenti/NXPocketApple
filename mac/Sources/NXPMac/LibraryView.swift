import AppKit
import SwiftUI
import NXPocketKit
import NXPMacKit
import NXPMacModel

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    /// The games ticked to send together, by title ID.
    @State private var picked: Set<String> = []
    /// The package the user asked to delete, until they confirm.
    @State private var deleting: LocalGame?
    /// The package being renamed, and the name typed so far.
    @State private var renaming: LocalGame?
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let problem = model.libraryProblem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            Divider().overlay(Ink.line)
            if model.games.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.games) { game in
                            GameCard(game: game, selected: picked.contains(game.id))
                                .onTapGesture { toggle(game) }
                                .contextMenu { menu(for: game) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !pickedGames.isEmpty { sendBar }
        }
        .sheet(item: $renaming) { game in renameSheet(game) }
        .confirmationDialog(deleting.map { "Move \($0.title) to the Trash?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { game in
            Button("Move to the Trash", role: .destructive) { model.moveToTrash(game) }
            Button("Cancel", role: .cancel) {}
        } message: { game in
            Text("\(game.root.lastPathComponent) (\(game.byteCountText)) goes to the Trash, where it can be put back until the Trash is emptied. The game on the iPhone and its saves are not touched.")
        }
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

    private var readyGames: [LocalGame] { model.games.filter(\.isReady) }

    /// The ticked games that can still be sent: a package gone or damaged since it was ticked drops out.
    private var pickedGames: [LocalGame] {
        model.games.filter { picked.contains($0.id) && $0.isReady }
    }

    private func toggle(_ game: LocalGame) {
        guard game.isReady else { return }
        if picked.contains(game.id) { picked.remove(game.id) } else { picked.insert(game.id) }
    }

    /// What to do with the ticked games, at the bottom of the window while some are ticked.
    private var sendBar: some View {
        let games = pickedGames
        return HStack(spacing: 12) {
            Text(games.count == 1 ? "1 game ticked" : "\(games.count) games ticked")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.primary)
            Button(games.count == model.games.filter(\.isReady).count ? "Untick all" : "Tick all") {
                let ready = Set(model.games.filter(\.isReady).map(\.id))
                picked = picked == ready ? [] : ready
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.accent)
            Spacer()
            if let device = model.selectedDevice {
                Button {
                    model.queueSend(games, to: device)
                    picked = []
                } label: {
                    Label(games.count == 1 ? "Send to \(device.name)" : "Send \(games.count) games to \(device.name)",
                          systemImage: "arrow.up.circle")
                }
                .buttonStyle(.borderedProminent).tint(Ink.accent).foregroundStyle(.black)
            } else {
                Text("Connect an iPhone to send").font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
            Button("Cancel") { picked = [] }.buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Ink.surface)
        .overlay(alignment: .top) { Divider().overlay(Ink.line) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Library").font(.system(size: 22, weight: .semibold)).foregroundStyle(Ink.primary)
                Text(model.settings.value.outputURL.path)
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !readyGames.isEmpty {
                Button(pickedGames.count == readyGames.count ? "Untick all" : "Tick all") {
                    picked = pickedGames.count == readyGames.count ? [] : Set(readyGames.map(\.id))
                }
                .buttonStyle(.bordered)
            }
            if let device = model.selectedDevice {
                if !readyGames.isEmpty {
                    Button {
                        model.queueSend(readyGames, to: device)
                        picked = []
                    } label: {
                        Label(readyGames.count == 1 ? "Send to \(device.name)" : "Send all \(readyGames.count) to \(device.name)",
                              systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("Queues every game of the library: they go to the iPhone one after another, each one's saves backed up first.")
                }
                Pill(text: "\(device.name) · \(device.transport ?? "usb")", color: Ink.good)
                if model.checkingPhone { ProgressView().controlSize(.small) }
            } else {
                Button("Find devices") { model.refreshDevices() }.buttonStyle(.plain).foregroundStyle(Ink.accent)
            }
            Button("Build a game") { model.screen = .build }
                .buttonStyle(.borderedProminent)
                .tint(Ink.accent)
                .foregroundStyle(.black)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2").font(.system(size: 34)).foregroundStyle(Ink.secondary)
            Text("No games built yet").font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.primary)
            Text("Point NXPocket at a folder that holds your own game dump, and it builds a package you can send to the phone.")
                .font(.system(size: 12)).foregroundStyle(Ink.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Build a game") { model.screen = .build }
                .buttonStyle(.borderedProminent).tint(Ink.accent).foregroundStyle(.black)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for game: LocalGame) -> some View {
        if let device = model.selectedDevice, game.isReady {
            Button("Send to \(device.name)") { model.queueSend(game, to: device) }
                .disabled(model.queue.contains { !$0.phase.isFinished && $0.titleID == game.titleID && $0.sends })
        }
        if game.isReady {
            Button("Rename…") {
                newName = game.title
                renaming = game
            }
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

private struct GameCard: View {
    @EnvironmentObject private var model: AppModel
    let game: LocalGame
    let selected: Bool

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.raised)
                    if let icon = game.iconURL.flatMap(IconCache.image(contentsOf:)) {
                        Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: game.isBroken ? "exclamationmark.triangle" : "gamecontroller")
                            .font(.system(size: 30))
                            .foregroundStyle(game.isBroken ? Ink.bad : Ink.secondary)
                    }
                }
                .frame(height: 108)
                .clipped()
                .overlay(alignment: .topLeading) {
                    // The tick that picks the game for the send bar; a tap anywhere on the card does the same.
                    if game.isReady {
                        TickBox(checked: selected)
                            .padding(5)
                            .background(Ink.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .padding(6)
                    }
                }

                Text(game.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.primary).lineLimit(1)
                HStack(spacing: 6) {
                    if !game.version.isEmpty { Pill(text: "v\(game.version)") }
                    Pill(text: game.byteCountText)
                }
                if let phone = model.phoneGame(game.titleID) {
                    Pill(text: phone.packageVersion == game.packageVersion ? "on the iPhone" : "iPhone has \(phone.packageVersion)",
                         color: phone.packageVersion == game.packageVersion ? Ink.good : Ink.secondary)
                    BackupLine(titleID: game.titleID)
                }
                if let problem = game.problem {
                    Text(problem.detail).font(.system(size: 10)).foregroundStyle(Ink.bad).lineLimit(2)
                } else if let item = sending {
                    // One transfer at a time, through the queue: a second Send while the first was still copying put
                    // a second 5 GB copy of the game on the phone.
                    Text(item.phase == .waiting ? "Waiting to send" : "Sending · \(Int(item.fraction * 100))%")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.secondary)
                } else if let device = model.selectedDevice {
                    Button("Send to \(device.name)") { model.queueSend(game, to: device) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.accent)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Ink.accent : .clear, lineWidth: 1.5))
    }

    /// This game's send, waiting or under way in the queue.
    private var sending: QueueItem? {
        model.queue.first { item in
            guard item.titleID == game.titleID, !item.phase.isFinished else { return false }
            if case .send = item.job { return true }
            if case .sending = item.phase { return true }
            return false
        }
    }
}
