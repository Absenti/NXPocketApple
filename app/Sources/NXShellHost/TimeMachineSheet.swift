import NXPocketKit
import NXShellUI
import SwiftUI

/// The snapshots of a game's saves, newest first: a touch asks, then puts those saves back (the ones they replace are kept
/// as a copy, as every import of saves does).
struct TimeMachineSheet: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    @State private var snapshots: [SaveSnapshots.Snapshot] = []
    @State private var choosing: SaveSnapshots.Snapshot?
    @State private var message: String?
    @State private var working = false
    @State private var remote: [(record: SourceRecord, copies: [RemoteSaveCopy])] = []
    @State private var loadingRemote = false
    @State private var choosingRemote: RemoteChoice?

    struct RemoteChoice: Identifiable {
        var record: SourceRecord
        var copy: RemoteSaveCopy
        var id: String { "\(record.id)|\(copy.name)" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text(.timeMachineBody)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary).lineSpacing(2)
                    if snapshots.isEmpty {
                        Text(model.text(.timeMachineEmpty)).font(.system(size: 14)).foregroundStyle(ShellInk.secondary).padding(.top, 8)
                    }
                    ForEach(snapshots) { snapshot in
                        Button { choosing = snapshot } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snapshot.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en"))))
                                        .font(.system(size: 15, weight: .medium)).foregroundStyle(ShellInk.primary)
                                    Text(model.sizeText(snapshot.bytes)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                                }
                                Spacer()
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(ShellInk.accent)
                            }
                            .padding(14).frame(maxWidth: .infinity)
                            .background(ShellInk.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ShellInk.line))
                        }
                        .buttonStyle(.plain)
                        .disabled(working)
                    }
                    if loadingRemote || !remote.isEmpty {
                        Text(model.text(.timeMachineRemote)).font(.system(size: 12, weight: .semibold)).tracking(1).foregroundStyle(ShellInk.secondary).padding(.top, 10)
                    }
                    if loadingRemote { Text(model.text(.timeMachineRemoteLoading)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary) }
                    ForEach(remote, id: \.record.id) { entry in
                        ForEach(entry.copies) { copy in
                            Button { choosingRemote = RemoteChoice(record: entry.record, copy: copy) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(copy.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en"))))
                                            .font(.system(size: 15, weight: .medium)).foregroundStyle(ShellInk.primary)
                                        Text("\(entry.record.name) · \(model.sizeText(copy.size))").font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: model.sources.isMine(copy, titleID: game.id, on: entry.record) ? "iphone" : "icloud.and.arrow.down").foregroundStyle(ShellInk.accent)
                                }
                                .padding(14).frame(maxWidth: .infinity)
                                .background(ShellInk.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ShellInk.line))
                            }
                            .buttonStyle(.plain)
                            .disabled(working)
                        }
                    }
                    if let message { Text(message).font(.system(size: 13)).foregroundStyle(ShellInk.accent).padding(.top, 6) }
                }
                .padding(20)
            }
            .background(ShellInk.background)
            .navigationTitle(model.text(.timeMachine))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.text(.close)) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { snapshots = model.saveSnapshots(of: game) }
        .task {
            loadingRemote = model.sources.enabled
            remote = await model.sources.remoteCopies(of: game.id)
            loadingRemote = false
        }
        .confirmationDialog(model.text(.timeMachineRestore), isPresented: Binding(get: { choosingRemote != nil }, set: { if !$0 { choosingRemote = nil } }),
                            titleVisibility: .visible, presenting: choosingRemote) { choice in
            Button(model.text(.timeMachineRestore)) { restoreRemote(choice) }
            Button(model.text(.cancel), role: .cancel) {}
        } message: { _ in
            Text(model.text(.restoreRemoteBody))
        }
        .confirmationDialog(model.text(.timeMachineRestore), isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                            titleVisibility: .visible, presenting: choosing) { snapshot in
            Button(model.text(.timeMachineRestore)) { restore(snapshot) }
            Button(model.text(.cancel), role: .cancel) {}
        } message: { _ in
            Text(model.text(.timeMachineRestoreBody))
        }
    }

    private func restoreRemote(_ choice: RemoteChoice) {
        working = true
        Task {
            switch await model.restoreRemote(game, copy: choice.copy, from: choice.record) {
            case .success: message = model.text(.timeMachineDone)
            case .failure(let problem): message = model.text(for: problem)
            }
            snapshots = model.saveSnapshots(of: game)
            working = false
        }
    }

    private func restore(_ snapshot: SaveSnapshots.Snapshot) {
        working = true
        Task {
            switch await model.importSaves(game, from: snapshot.url) {
            case .success: message = model.text(.timeMachineDone)
            case .failure(let problem): message = model.text(for: problem)
            }
            snapshots = model.saveSnapshots(of: game)
            working = false
        }
    }
}

extension ShellHostModel {
    func saveSnapshots(of game: InstalledGame) -> [SaveSnapshots.Snapshot] {
        SaveSnapshots.list(titleID: game.id, documents: documents)
    }
}
