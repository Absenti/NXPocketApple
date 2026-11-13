import AppKit
import SwiftUI
import NXPMacKit
import NXPMacModel

/// Adding a game: pick the folder, tick the games, build. Built from rows, like Settings; the engine's own output and
/// the rarely-used options stay one tap away rather than on the page.
struct BuildView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLog = false
    @State private var showOptions = false

    var body: some View {
        RowsPage {
            PageTitle(title: "Add a game", subtitle: "Pick the games to build. They are built one after another, then sent to the iPhone.")
        } content: {
            SettingsGroup(title: "Games folder") {
                SettingRow(symbol: "folder", title: "Your games folder",
                           detail: model.settings.value.gameFolder.isEmpty ? "not set" : Friendly.path(model.settings.value.gameFolder)) {
                    Button("Change") { model.chooseGameFolder() }.buttonStyle(QuietButtonStyle(large: true))
                }
            }
            .help("A folder of NSP, NSZ, XCI or XCZ files, its subfolders included: games, updates and DLC, in any order. Nothing here is uploaded anywhere.")

            if !model.settings.value.gameFolder.isEmpty { FolderGamesView() }

            SettingsGroup(title: "After building") {
                SettingRow(symbol: "arrow.up", title: "Send to the iPhone",
                           detail: model.selectedDevice.map { "\($0.name) · \($0.transport ?? "usb")" } ?? "No iPhone connected") {
                    Toggle("", isOn: Binding(get: { model.settings.value.sendAfterBuild },
                                             set: { model.settings.value.sendAfterBuild = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showOptions.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showOptions ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                        Text("More options").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Ink.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 4)
                if showOptions { options }
            }

            if !model.queue.isEmpty { QueueView() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { buildBar }
        .sheet(isPresented: $showLog) { logSheet }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup(title: "Options") {
                SettingRow(symbol: "character.bubble", title: "Language", detail: "Blank uses the engine's default.") {
                    TextField("English", text: Binding(get: { model.settings.value.language }, set: { model.settings.value.language = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                }
                SettingRow(symbol: "trash", title: "Delete the decompressed copy after a build",
                           detail: "For .nsz and .xcz dumps: the .nsp or .xci made from them, as large as the game. Your dump and the built game are never touched; the next build decompresses it again.",
                           detailLines: 3) {
                    Toggle("", isOn: Binding(get: { model.settings.value.removeDecompressed }, set: { model.settings.value.removeDecompressed = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingRow(symbol: "cpu", title: "Use this Mac's Metal compiler", detail: "For an NVN game, when it is not the one tested.") {
                    Toggle("", isOn: Binding(get: { model.settings.value.allowOtherMetal }, set: { model.settings.value.allowOtherMetal = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            HelpText(title: "About the Metal compiler", text: "Most Switch games draw with NVN, whose shaders the engine compiles with Xcode's Metal compiler. It accepts only the one they were tested with (Xcode 27.2) and stops otherwise. On, it builds with this Mac's compiler anyway, and the game may show wrong pictures. Leave it off while the build does not ask for it.")
        }
    }

    /// The one action, pinned to the bottom so it is never scrolled away.
    private var buildBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if model.checkingToolchain {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking the toolchain…") }
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                if let blocker = model.buildBlocker, !model.checkedGames.isEmpty {
                    Text(Friendly.text(blocker)).font(.system(size: 12)).foregroundStyle(Ink.bad).lineLimit(2)
                }
                if let problem = model.pythonProblem {
                    Text(Friendly.text(problem)).font(.system(size: 12)).foregroundStyle(Ink.bad).lineLimit(2).textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            Button("Engine output") { showLog = true }.buttonStyle(QuietButtonStyle(large: true))
            Button("Output folder") { model.revealInFinder(model.settings.value.outputURL) }.buttonStyle(QuietButtonStyle(large: true))
            Button {
                model.queueCheckedGames()
            } label: {
                Label(buildLabel, systemImage: "hammer")
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
            .disabled(model.buildBlocker != nil)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Ink.surface)
        .overlay(alignment: .top) { Divider().overlay(Ink.line) }
    }

    private var buildLabel: String {
        let count = model.checkedGames.count
        let verb = model.settings.value.sendAfterBuild && model.selectedDevice != nil ? "Build and send" : "Build"
        switch count {
        case 0: return verb
        case 1: return "\(verb) 1 game"
        default: return "\(verb) \(count) games"
        }
    }

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                PageTitle(title: "Engine output", size: 28)
                Spacer()
                Button("Show the log file") { NSWorkspace.shared.activateFileViewerSelecting([model.fileLog.url]) }
                    .buttonStyle(QuietButtonStyle(large: true))
                    .help("~/Library/Logs/NXPocketApple/launcher.log keeps the last 2 MB of this output, after the window forgot it")
                Button("Clear") { model.clearLog() }.buttonStyle(QuietButtonStyle(large: true))
                Button("Done") { showLog = false }.buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.log) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.text.hasPrefix("fail") || line.text.hasPrefix("[RED]") ? Ink.bad : Ink.primary.opacity(0.85))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                }
                .background(Ink.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.line))
                .onChange(of: model.log.last?.id) { last in
                    if let last { reader.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .padding(24)
        .frame(width: 760, height: 520)
        .background(Ink.background)
    }
}
