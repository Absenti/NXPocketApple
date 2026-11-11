import SwiftUI
import NXPMacKit
import NXPMacModel

/// The games of the games folder, each with a tick to build it and, under it, its updates and DLC.
struct FolderGamesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded: Set<String> = []

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeading(text: model.folder.games.isEmpty ? "Games" : "Games · \(model.folder.games.count)")
                    if model.scanningFolder {
                        ProgressView().controlSize(.small)
                        Text("Reading the folder…").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                    Spacer()
                    if model.folder.games.count > 1 {
                        Button(model.checkedGames.isEmpty ? "Tick all" : "Untick all") {
                            model.checkAll(model.checkedGames.isEmpty)
                        }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.accent)
                    }
                    Button("Rescan") { model.refreshFolder() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.accent)
                        .disabled(model.scanningFolder)
                }
                if let problem = model.keysProblem {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "key").foregroundStyle(Ink.accent).font(.system(size: 11))
                        Text(problem).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                        Spacer(minLength: 0)
                        Button("Settings") { model.screen = .settings }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.accent)
                    }
                }
                if model.folder.games.isEmpty && !model.scanningFolder {
                    Text(model.folder.packageCount == 0
                         ? "No NSP, NSZ, XCI or XCZ file in this folder or its subfolders."
                         : "No game could be recognised in this folder.")
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                ForEach(model.folder.games) { game in
                    gameRow(game)
                    if game.id != model.folder.games.last?.id { Divider().overlay(Ink.line) }
                }
                if !model.folder.unidentified.isEmpty {
                    Divider().overlay(Ink.line)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Not recognised").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.secondary)
                        ForEach(model.folder.unidentified, id: \.url) { package in
                            Text("\(package.url.lastPathComponent): \(package.reason)")
                                .font(.system(size: 10)).foregroundStyle(Ink.secondary).lineLimit(2).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func gameRow(_ game: FolderGame) -> some View {
        let checked = model.isChecked(game)
        let open = expanded.contains(game.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    model.toggleChecked(game)
                    if !checked && (!game.updates.isEmpty || !game.dlc.isEmpty) { expanded.insert(game.id) }
                } label: {
                    TickBox(checked: checked, disabled: !game.hasBase)
                }
                .buttonStyle(.plain)
                .disabled(!game.hasBase)

                Thumbnail(image: IconCache.image(key: "folder-\(game.titleID)", data: game.icon), size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName(titleID: game.titleID, own: game.name))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.primary).lineLimit(1)
                    Text("\(game.titleID) · \(game.summary)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.secondary).lineLimit(1)
                    badges(game)
                }
                Spacer(minLength: 0)
                if !game.updates.isEmpty || !game.dlc.isEmpty {
                    Button {
                        if open { expanded.remove(game.id) } else { expanded.insert(game.id) }
                    } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 11))
                            .foregroundStyle(Ink.secondary).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(open ? "Hide the updates and DLC" : "Show the updates and DLC")
                }
            }
            if !game.hasBase {
                Text("Only an update or DLC of this game is here: put its base game in the folder to build it.")
                    .font(.system(size: 10)).foregroundStyle(Ink.bad).padding(.leading, 24)
            }
            if open { contents(game) }
        }
    }

    @ViewBuilder
    private func badges(_ game: FolderGame) -> some View {
        let selected = model.selectedVersionTag(of: game)
        let built = model.builtPackage(game.titleID)
        let phone = model.phoneGame(game.titleID)
        if built != nil || phone != nil || game.displayVersion != nil {
            HStack(spacing: 6) {
                if let version = game.displayVersion { Pill(text: version) }
                if let built {
                    // Green when the package already built is the version ticked now.
                    Pill(text: "built \(built.packageVersion)", color: built.packageVersion == selected ? Ink.good : Ink.secondary)
                }
                if let phone {
                    Pill(text: "on the iPhone \(phone.packageVersion)",
                         color: phone.packageVersion == selected ? Ink.good : Ink.secondary)
                }
            }
        }
    }

    /// The updates (one at most: the engine builds one version) and the DLC, each with its tick.
    private func contents(_ game: FolderGame) -> some View {
        let selection = model.selection(for: game)
        let forced = game.forcedDLC(selection)
        return VStack(alignment: .leading, spacing: 4) {
            if !game.updates.isEmpty {
                Text(game.updates.count > 1 ? "Version to build (one at a time)" : "Update")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.secondary)
                ForEach(game.updates) { update in
                    contentRow(update, checked: selection.updateID == update.id, forced: false) {
                        model.toggleUpdate(update, of: game)
                    }
                }
                if selection.updateID == nil {
                    Text("No update ticked: the base game alone (v0) is built.")
                        .font(.system(size: 10)).foregroundStyle(Ink.secondary)
                }
            }
            if !game.dlc.isEmpty {
                HStack {
                    Text("DLC").font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.secondary)
                    if game.dlc.count > 1 {
                        Button(selection.dlcIDs.isEmpty ? "all" : "none") { model.setAllDLC(selection.dlcIDs.isEmpty, of: game) }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Ink.accent)
                    }
                }
                ForEach(game.dlc) { item in
                    contentRow(item, checked: selection.dlcIDs.contains(item.id) || forced.contains(item.id),
                               forced: forced.contains(item.id)) {
                        model.toggleDLC(item, of: game)
                    }
                }
                if !forced.isEmpty {
                    Text("A DLC in the same file as something ticked is always packed: the engine takes every DLC of the files it is given.")
                        .font(.system(size: 10)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 74)
    }

    private func contentRow(_ content: FolderContent, checked: Bool, forced: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                TickBox(checked: checked, disabled: forced)
                Text(content.label).font(.system(size: 11)).foregroundStyle(Ink.primary)
                if content.version == nil {
                    Text("version unknown").font(.system(size: 10)).foregroundStyle(Ink.secondary)
                }
                Text(content.package.fileName).font(.system(size: 10)).foregroundStyle(Ink.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(forced)
        .help(content.package.url.path)
    }
}
