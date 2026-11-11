import SwiftUI
import NXPMacModel

@main
struct NXPocketApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("NXPocket") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    model.screen = .settings
                    model.checkForUpdates()
                }
            }
            CommandGroup(after: .newItem) {
                Button("Build a game…") { model.screen = .build }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Refresh library") { model.refreshLibrary() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Find devices") { model.refreshDevices() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}
