import SwiftUI
import UIKit
import NXShellHost

/// A TV, by cable or AirPlay, is a scene of its own, not a mirror of the phone. The game's front end (the engine's `front_ios.m`) moves
/// the picture there and keeps the pad on the phone: it asks for the TV scene itself on iOS 27 (a scene accessory, registered when the
/// game's view loads), and on iOS 26 it is the app that must offer one, naming the front end's `DmTVSceneDelegate`. That class is in
/// the game's framework, which is loaded when a game starts: a TV plugged in before that has nothing to show, and one plugged in
/// after finds it. The window's scene gets a delegate for the icon's quick actions, and is otherwise SwiftUI's.
final class ShellAppDelegate: NSObject, UIApplicationDelegate {
    /// The system's transfer service has something for the app: segments of a game that finished while it was away. The service is made
    /// here, which is what makes the system hand over what it holds; the downloads that were running go on from the start of the app
    /// (`NetworkSources.resumeInterrupted`). The handler is called once the service has been heard out.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundHandoff.handle(identifier: identifier, completion: completionHandler)
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: connectingSceneSession.configuration.name, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive, let delegate = NSClassFromString("DmTVSceneDelegate") {
            configuration.delegateClass = delegate
        } else if connectingSceneSession.role == .windowApplication {
            // The quick actions of the icon's long press arrive in a scene delegate.
            configuration.delegateClass = ShellSceneDelegate.self
        }
        return configuration
    }
}

@main
struct NXPocketApp: App {
    @UIApplicationDelegateAdaptor(ShellAppDelegate.self) private var appDelegate
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
                // Links (a game's icon, the Mac's QR code) and files arrive through the scene delegate: see `LinkInbox`.
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
