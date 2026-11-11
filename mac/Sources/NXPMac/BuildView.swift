import SwiftUI
import NXPMacKit
import NXPMacModel

struct BuildView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Build").font(.system(size: 22, weight: .semibold)).foregroundStyle(Ink.primary)
                    folderCard
                    if !model.settings.value.gameFolder.isEmpty { FolderGamesView() }
                    optionsCard
                    actions
                }
                .padding(.bottom, 20)
            }
            .frame(minWidth: 460, idealWidth: 560, maxWidth: 640)

            VStack(alignment: .leading, spacing: 14) {
                QueueView()
                logCard
            }
            .frame(minWidth: 340)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var folderCard: some View {
        Card {
            FieldRow(label: "Games folder",
                     hint: "A folder of NSP, NSZ, XCI or XCZ files, its subfolders included: games, updates and DLC, in any order. Nothing here is uploaded anywhere.") {
                HStack(spacing: 8) {
                    Text(model.settings.value.gameFolder.isEmpty ? "not set" : model.settings.value.gameFolder)
                        .font(.system(size: 12))
                        .foregroundStyle(model.settings.value.gameFolder.isEmpty ? Ink.secondary : Ink.primary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { model.chooseGameFolder() }.buttonStyle(.bordered).font(.system(size: 12))
                }
            }
        }
    }

    private var optionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(text: "Options")
                FieldRow(label: "Language", hint: "Blank uses the engine's default.") {
                    TextField("English", text: Binding(get: { model.settings.value.language },
                                                       set: { model.settings.value.language = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                Toggle(sendToggleLabel, isOn: Binding(get: { model.settings.value.sendAfterBuild },
                                                      set: { model.settings.value.sendAfterBuild = $0 }))
                    .toggleStyle(.switch)
                Toggle("Keep the extracted files for the next build", isOn: Binding(
                    get: { model.settings.value.keepExtracted },
                    set: { model.settings.value.keepExtracted = $0 }))
                    .toggleStyle(.switch)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Allow this Mac's Metal compiler for an NVN game", isOn: Binding(
                        get: { model.settings.value.allowOtherMetal },
                        set: { model.settings.value.allowOtherMetal = $0 }))
                        .toggleStyle(.switch)
                    Text("Most Switch games draw with NVN, whose shaders the engine compiles with Xcode's Metal compiler. It accepts only the one they were tested with (Xcode 27.2) and stops otherwise. On, it builds with this Mac's compiler anyway, and the game may show wrong pictures. Leave it off while the build does not ask for it.")
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sendToggleLabel: String {
        model.selectedDevice.map { "Send each game to \($0.name) once built" } ?? "Send each game to the iPhone once built (none connected)"
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    model.queueCheckedGames()
                } label: {
                    Label(buildLabel, systemImage: "hammer")
                }
                .buttonStyle(.borderedProminent).tint(Ink.accent).foregroundStyle(.black)
                .disabled(model.buildBlocker != nil)
                if model.checkingToolchain {
                    ProgressView().controlSize(.small)
                    Text("Checking the toolchain…").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                }
                Spacer()
                Button("Open the output folder") { model.revealInFinder(model.settings.value.outputURL) }
                    .buttonStyle(.plain).foregroundStyle(Ink.accent)
            }
            if let blocker = model.buildBlocker, !model.checkedGames.isEmpty {
                Text(blocker).font(.system(size: 11)).foregroundStyle(Ink.bad)
            }
            if let problem = model.pythonProblem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled)
            }
        }
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

    private var logCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeading(text: "Engine output")
                    Spacer()
                    Button("Clear") { model.clearLog() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.secondary)
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
                    }
                    .onChange(of: model.log.last?.id) { last in
                        if let last { reader.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}
