import NXShellHost
import UIKit

/// The scene of the app's window, for what SwiftUI does not give: links and files, and the quick actions of the icon's long press, which reach a scene
/// at a cold start (in its connection options) or while the app runs. Both hand the game to `GameLaunchInbox`.
final class ShellSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem, let id = QuickActions.titleID(of: item) { GameLaunchInbox.request(id) }
        LinkInbox.receive(connectionOptions.urlContexts.map(\.url))
    }

    /// Links and files while the app runs. SwiftUI's `onOpenURL` is not called when the scene has a delegate of ours.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        LinkInbox.receive(contexts.map(\.url))
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let id = QuickActions.titleID(of: shortcutItem) else { return completionHandler(false) }
        GameLaunchInbox.request(id)
        completionHandler(true)
    }
}
