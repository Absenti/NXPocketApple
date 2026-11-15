import NXPocketKit
import NXShellUI
import SwiftUI
import UniformTypeIdentifiers

/// A game's cheats: the file the player brought (an Atmosphère cheat file, as cheat sites share them), a switch for each cheat, and a master
/// switch. What is on is applied at the next start. A cheat the phone cannot run (one that writes into the game's code) is refused by the
/// engine, which says so in its log: the last of what it said is shown here.
struct CheatsSheet: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    @State private var entries: [Cheats.Entry]?
    @State private var enabled: Set<String> = []
    @State private var master = true
    @State private var search = ""
    @State private var picking = false
    @State private var message: String?
    @State private var engineLines: [String] = []
    @State private var removing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(model.name(of: game)).font(ShellFont.display(20)).foregroundStyle(ShellInk.primary)
                    if model.cheatsSafeModeFor == game.id {
                        Label(model.text(.cheatsSafeMode), systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(ShellInk.accent)
                    }
                    if model.cheatBuildID(of: game) == nil {
                        Text(model.text(.cheatsNoBuild)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary)
                    } else {
                        content
                    }
                    if let message { Text(message).font(.system(size: 13)).foregroundStyle(ShellInk.bad).textSelection(.enabled) }
                    if !engineLines.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.text(.cheatsEngineSaid)).font(.system(size: 11, weight: .semibold)).foregroundStyle(ShellInk.secondary)
                            ForEach(engineLines, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).foregroundStyle(ShellInk.secondary) }
                        }
                    }
                }
                .padding(20)
            }
            .background(ShellInk.background)
            .navigationTitle(model.text(.cheats))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.text(.close)) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: reload)
        .sheet(isPresented: $picking) {
            DocumentPicker(types: [.plainText, .item], onPick: { url in
                picking = false
                message = model.importCheats(game, from: url)
                reload()
            }, onCancel: { picking = false })
                .ignoresSafeArea()
        }
        .confirmationDialog(model.text(.cheatsRemove), isPresented: $removing, titleVisibility: .visible) {
            Button(model.text(.cheatsRemove), role: .destructive) { model.removeCheats(of: game); reload() }
            Button(model.text(.cancel), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var content: some View {
        Text(model.text(.cheatsBody)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary).lineSpacing(2)
        HStack(spacing: 8) {
            Button(entries == nil ? model.text(.cheatsImport) : model.text(.cheatsReplace)) { message = nil; picking = true }.buttonStyle(ShellButtonStyle(prominent: entries == nil))
            if entries != nil { Button(model.text(.cheatsRemove)) { removing = true }.buttonStyle(ShellButtonStyle()) }
        }
        if let entries {
            Toggle(model.text(.cheatsOn), isOn: Binding(get: { master }, set: { master = $0; model.setCheatsMaster($0, for: game) }))
                .font(.system(size: 15, weight: .medium)).tint(ShellInk.accent)
            TextField(model.text(.cheatsSearch), text: $search).textFieldStyle(.roundedBorder)
            VStack(spacing: 0) {
                ForEach(shown(entries)) { entry in
                    if entry.isMaster {
                        row(entry.name, detail: model.text(.cheatsMasterCode), isOn: .constant(true), enabled: false)
                    } else {
                        row(entry.name, detail: nil, isOn: Binding(get: { enabled.contains(entry.name) }, set: { on in
                            model.setCheat(entry.name, on: on, for: game)
                            if on { enabled.insert(entry.name) } else { enabled.remove(entry.name) }
                        }), enabled: master)
                    }
                    Divider().overlay(ShellInk.line)
                }
            }
            .background(ShellInk.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ShellInk.line))
            Text(model.text(.cheatsNextStart)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
        }
    }

    private func shown(_ entries: [Cheats.Entry]) -> [Cheats.Entry] {
        search.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func row(_ name: String, detail: String?, isOn: Binding<Bool>, enabled: Bool) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14)).foregroundStyle(ShellInk.primary)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(ShellInk.secondary) }
            }
        }
        .tint(ShellInk.accent).disabled(!enabled).padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func reload() {
        entries = model.cheatEntries(of: game)
        enabled = model.enabledCheats(of: game)
        master = model.cheatsMasterOn(game)
        engineLines = model.cheatLog(of: game)
    }
}
