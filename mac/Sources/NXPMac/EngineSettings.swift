import SwiftUI
import NXPMacKit
import NXPMacModel

/// Which engine builds are made with, from a menu of what is on this Mac. The stable release this launcher is made for comes first and can be
/// installed from here; any other copy of NX2Apple, such as a clone of the player's own, is listed with what it is.
struct EngineGroup: View {
    @EnvironmentObject private var model: AppModel
    @State private var choices: [EngineChoice] = []

    private static let other = "\u{0}other"

    var body: some View {
        SettingsGroup(title: "Engine") {
            SettingRow(symbol: "gearshape.2", title: "Engine used for builds", detail: detail, detailLines: 3) {
                Picker("", selection: Binding(get: { current }, set: { choose($0) })) {
                    ForEach(choices) { choice in
                        Text(choice.isStable ? "\(choice.menuTitle) (recommended)" : choice.menuTitle).tag(choice.id)
                    }
                    if !choices.contains(where: { $0.id == current }) { Text(model.engineInUse.lastPathComponent).tag(current) }
                    Divider()
                    Text("Another folder…").tag(Self.other)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            if !choices.contains(where: \.isStable) {
                SettingRow(symbol: "arrow.down.circle", title: "Install NX2Apple \(SetupPins.nx2appleVersion), the stable release",
                           detail: "Into this launcher's own folder. Nothing of yours is touched.", detailLines: 2) {
                    Button("Install") { model.installStableEngine() }.buttonStyle(PrimaryButtonStyle(large: true))
                }
            }
            if !model.settings.value.engineRoot.isEmpty {
                SettingRow(symbol: "wand.and.stars", title: "Let the launcher choose", detail: "Goes back to the first engine it finds.") {
                    Button("Automatic") { model.useEngine(nil) }.buttonStyle(QuietButtonStyle(large: true))
                }
            }
            Note("Each engine version compiles its shaders under its own name: a game built with another engine than before has its shaders compiled again at its next build, which takes a while and some disk. Games already on the iPhone keep working: each carries its own engine.")
                .padding(16)
        }
        .onAppear { choices = model.availableEngines() }
        .onChange(of: model.settings.value.engineRoot) { _ in choices = model.availableEngines() }
        .onChange(of: model.toolchain.engine.root) { _ in choices = model.availableEngines() }
    }

    /// The menu entry of the engine in use: the listed one at the same place, else its own path.
    private var current: String {
        let used = model.engineInUse.resolvingSymlinksInPath().path
        return choices.first { $0.url.resolvingSymlinksInPath().path == used }?.id ?? model.engineInUse.path
    }

    private var detail: String {
        choices.first { $0.id == current }?.detail ?? "\(model.engineInUse.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · not one this launcher can tell the version of"
    }

    private func choose(_ id: String) {
        if id == Self.other {
            model.chooseEngineFolder()
        } else if let choice = choices.first(where: { $0.id == id }) {
            model.useEngine(choice)
        }
    }
}
