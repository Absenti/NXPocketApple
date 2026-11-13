import SwiftUI
import NXPMacKit
import NXPMacModel

/// The copies of the saves kept on this Mac: the switch for the automatic copies, then every game that has one, and
/// the way a copy goes back to the iPhone.
struct SavesCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsGroup(title: "Saves on this Mac") {
            Button("Show in Finder") {
                try? FileManager.default.createDirectory(at: model.savesFolder, withIntermediateDirectories: true)
                model.revealInFinder(model.savesFolder)
            }
            .buttonStyle(QuietButtonStyle())
        } content: {
            SettingRow(symbol: "arrow.triangle.2.circlepath", title: "Copy the saves by themselves",
                       detail: "When they change on the iPhone. Nothing is written on it.") {
                Toggle("", isOn: Binding(get: { model.settings.value.autoBackup }, set: { model.settings.value.autoBackup = $0 }))
                    .toggleStyle(.switch).labelsHidden()
            }
            if model.savedGames.isEmpty {
                SettingRow(symbol: "tray", title: "No copy yet", detail: "Copies appear here once a game's saves have been backed up.") { EmptyView() }
            }
            ForEach(model.savedGames) { game in
                SavedGameRow(game: game)
            }
        }
        .help(explanation)
    }

    private var explanation: String {
        let checks = Int(SaveWatch.checkInterval / 60)
        let spacing = Int(SaveWatch.minimumSpacing / 60)
        let automatic = model.settings.value.autoBackup
            ? "While the launcher runs, it lists the iPhone's saves every \(checks) minutes and copies a game whose saves changed, at most every \(spacing) minutes per game. "
            : "Automatic copies are off: saves are copied before a send replaces a game, and with the buttons. "
        return automatic + "The last \(SaveBackup.keep) copies of each game are kept."
    }
}

private struct SavedGameRow: View {
    @EnvironmentObject private var model: AppModel
    let game: SavedGame

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(symbol: "externaldrive", title: game.name, detail: detail, detailColor: Ink.secondary) {
                Menu("Put back on the iPhone…") {
                    ForEach(game.backups, id: \.folder) { backup in
                        Button(backup.date.formatted(date: .abbreviated, time: .standard)) {
                            model.sendBackupToiCloud(backup, game: game.name)
                        }
                    }
                }
                .menuStyle(.button).fixedSize()
                .help("Zips the copy you pick into iCloud Drive → Downloads, for the iPhone app's own import.")
            }
            if let found = export {
                ExportLine(state: found.state, file: SaveExport.archiveName(game: game.name, backup: found.backup.folder),
                           game: game.name)
                    .padding(.horizontal, 68).padding(.bottom, 12)
            }
        }
    }

    private var detail: String {
        guard let newest = game.backups.first else { return "no copy yet" }
        return "\(game.backups.count) cop\(game.backups.count == 1 ? "y" : "ies") · newest \(newest.date.formatted(date: .abbreviated, time: .shortened))"
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
            Text("Zipping into iCloud Drive…").font(.system(size: 12)).foregroundStyle(Ink.secondary)
        case .uploading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Uploading to iCloud: the iPhone sees it once this is done.").font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
        case .inCloud:
            VStack(alignment: .leading, spacing: 4) {
                Text("In iCloud Drive → Downloads.").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.good)
                Text("On the iPhone, in NXPocketApple: touch and hold \(game), Import a save, then Browse → iCloud Drive → Downloads → \(file). The game must be on the iPhone.")
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .failed(let reason):
            Text(Friendly.text(reason)).font(.system(size: 12)).foregroundStyle(Ink.bad).textSelection(.enabled)
        }
    }
}
