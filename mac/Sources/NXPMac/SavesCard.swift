import SwiftUI
import NXPMacKit
import NXPMacModel

/// The copies of the saves kept on this Mac: every game that has one, whether or not the phone has it now, the switch
/// for the automatic copies, and the way a copy goes back to the iPhone.
struct SavesCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeading(text: "Saves on this Mac")
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: model.savesFolder, withIntermediateDirectories: true)
                        model.revealInFinder(model.savesFolder)
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.accent)
                }
                Toggle("Copy a game's saves by themselves once they change on the iPhone", isOn: Binding(
                    get: { model.settings.value.autoBackup },
                    set: { model.settings.value.autoBackup = $0 }))
                    .toggleStyle(.switch)
                Text(explanation)
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                if model.savedGames.isEmpty {
                    Text("No copy yet.").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                }
                ForEach(model.savedGames) { game in
                    SavedGameRow(game: game)
                }
            }
        }
    }

    private var explanation: String {
        let checks = Int(SaveWatch.checkInterval / 60)
        let spacing = Int(SaveWatch.minimumSpacing / 60)
        let automatic = model.settings.value.autoBackup
            ? "While the launcher runs, even in the background, it lists the iPhone's saves every \(checks) minutes (cable or Wi-Fi) and copies a game whose saves changed, a minute after the game last wrote them and at most every \(spacing) minutes per game. "
            : "Automatic copies are off: saves are copied before a send replaces a game, and with the buttons. "
        return automatic + "Nothing is written on the iPhone. The last \(SaveBackup.keep) copies of each game are kept."
    }
}

private struct SavedGameRow: View {
    @EnvironmentObject private var model: AppModel
    let game: SavedGame

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(game.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.primary)
                        Text(game.titleID).font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.secondary)
                    }
                    if let newest = game.backups.first {
                        Text("\(game.backups.count) cop\(game.backups.count == 1 ? "y" : "ies") · newest \(newest.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(Ink.good)
                    }
                }
                Spacer()
                Menu("Put back on the iPhone…") {
                    ForEach(game.backups, id: \.folder) { backup in
                        Button(backup.date.formatted(date: .abbreviated, time: .standard)) {
                            model.sendBackupToiCloud(backup, game: game.name)
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
                .help("Zips the copy you pick into iCloud Drive → Downloads, for the iPhone app's own import.")
            }
            if let found = export {
                ExportLine(state: found.state, file: SaveExport.archiveName(game: game.name, backup: found.backup.folder),
                           game: game.name)
            }
        }
    }

    /// The copy of this game last sent to iCloud Drive, and where it stands.
    private var export: (backup: SaveBackupRecord, state: CloudCopyState)? {
        for backup in game.backups {
            if let state = model.saveExports[backup.folder.path], state != .none { return (backup, state) }
        }
        return nil
    }
}

private struct ExportLine: View {
    let state: CloudCopyState
    let file: String
    let game: String

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .copying:
            Text("Zipping into iCloud Drive…").font(.system(size: 11)).foregroundStyle(Ink.secondary)
        case .uploading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Uploading to iCloud: the iPhone sees it once this is done.").font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
        case .inCloud:
            Text("In iCloud Drive → Downloads. On the iPhone, in NXPocket: touch and hold \(game), Import a save (Importer une sauvegarde), then Browse → iCloud Drive → Downloads → \(file). The game must be on the iPhone; the app checks the copy is this game's and whole, and keeps the saves it replaces in Files → NXPocket → Saves.")
                .font(.system(size: 11)).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .failed(let reason):
            Text(reason).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled)
        }
    }
}
