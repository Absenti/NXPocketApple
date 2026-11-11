import SwiftUI
import NXShellHost

@main
struct NXPocketApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ShellHostModel()

    init() {
        // Before anything makes a Metal device: see FrameworkEngineHost.prepareProcess.
        FrameworkEngineHost.prepareProcess()
    }

    var body: some Scene {
        WindowGroup {
            ShellRootView()
                .environmentObject(model)
                // The model already read the library when it was made, and becoming active reads it again: a third
                // pass here only delayed the first screen. What it records instead is how long that screen took.
                .onAppear {
                    model.firstScreenAppeared()
                    model.watchTransfers(true)
                    // At most once a day, unless the player turned it off in Settings › Updates.
                    model.updates.checkIfDue()
                }
                // A game's icon on the home screen (nxpocket://play/<title ID>), at launch or while the app runs.
                .onOpenURL { model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            // A game that dies takes the app with it: the marker it left behind is read on the way back in.
            if phase == .active {
                model.refresh()
                model.updates.checkIfDue()
            }
            // A game sent while the app is in front is imported when it lands; in the background nothing is watched.
            model.watchTransfers(phase == .active)
        }
    }
}
