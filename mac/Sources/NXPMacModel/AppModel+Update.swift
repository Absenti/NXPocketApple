import AppKit
import Foundation
import NXPMacKit
import NXPocketKit

/// Where the launcher's look for a new release of itself stands.
public enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(String)
    /// The repository is private or has no release yet: said once, not an error.
    case noChannel
    case available(LauncherRelease)
    case downloading(LauncherRelease, fraction: Double?)
    /// The new app is checked and the swap script started: the launcher quits and the new one opens.
    case restarting
    case failed(String)
}

/// The launcher updates itself from the project's GitHub releases (`LauncherUpdate`): a look at launch at most once a
/// day, and nowhere else; the download, its checks and the swap only once the user said so.
extension AppModel {
    public static let updateInterval: TimeInterval = 24 * 3600

    public var runningVersion: SemanticVersion? { LauncherUpdate.runningVersion() }

    /// Why this copy cannot replace itself (a development build, a read-only place), nil when it can.
    public var updateRefusal: String? { LauncherUpdate.refusal(for: Bundle.main.bundleURL) }

    /// The look at launch always happens (the iPhone app's IPA is kept in step with the same release), but the sheet that
    /// offers a new launcher opens at most once a day: "Later" is not asked again at the next launch.
    func checkForUpdatesAtLaunch() {
        guard settings.value.checkUpdates else { return }
        let now = Date().timeIntervalSince1970
        checkForUpdates(offerSheet: now - settings.value.lastUpdateCheck >= Self.updateInterval)
    }

    public func checkForUpdates(offerSheet: Bool = true) {
        if case .checking = update { return }
        if case .downloading = update { return }
        update = .checking
        // Only an offer counts as "asked today": a silent look at launch must not push the next offer a day further.
        if offerSheet { settings.value.lastUpdateCheck = Date().timeIntervalSince1970 }
        let current = runningVersion
        Task {
            let (outcome, release) = await LauncherUpdate.latestWithRelease(current: current)
            if let release { latestRelease = release }
            defer { fetchPhoneAppIfNeeded() }
            switch outcome {
            case .upToDate(let latest):
                update = .upToDate("NXPocketApple \(current?.description ?? "?") is up to date (latest release \(latest)).")
            case .noPublicChannel:
                update = .noChannel
            case .available(let release):
                update = .available(release)
                showUpdateSheet = offerSheet
                append("update: NXPocketApple \(release.version) is available")
            case .failed(let reason):
                update = .failed(reason)
            }
        }
    }

    /// Downloads, checks and puts the release in place of this app, then quits; the swap script opens the new one.
    public func installUpdate(_ release: LauncherRelease) {
        if let refusal = updateRefusal {
            update = .failed(refusal)
            return
        }
        guard !queueHasWork else {
            update = .failed("The queue is working: update once it is done, so no build or send is cut off.")
            return
        }
        let app = Bundle.main.bundleURL
        let current = runningVersion
        update = .downloading(release, fraction: 0)
        append("update: downloading NXPocketApple \(release.version)")
        let (events, sink) = AsyncStream.makeStream(of: Double?.self)
        Task {
            let reader = Task { @MainActor in
                for await fraction in events { update = .downloading(release, fraction: fraction) }
            }
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    try LauncherUpdate.prepare(release, current: current, replacing: app) { written, expected in
                        sink.yield(expected > 0 ? Double(written) / Double(expected) : nil)
                    }
                }
            }.value
            sink.finish()
            await reader.value
            switch outcome {
            case .success(let newApp):
                do {
                    try LauncherUpdate.startSwap(app: app, newApp: newApp, version: current)
                    update = .restarting
                    append("update: NXPocketApple \(release.version) checked; the launcher quits and the new one opens")
                    NSApplication.shared.terminate(nil)
                } catch {
                    update = .failed("The update could not start: \(error.localizedDescription)")
                }
            case .failure(let error):
                let reason = (error as? NXPocketError)?.detail ?? error.localizedDescription
                update = .failed("The update was not installed: \(reason)")
                append("update: \(reason)")
            }
        }
    }

    public func openReleasePage(_ release: LauncherRelease? = nil) {
        NSWorkspace.shared.open(release?.page ?? LauncherUpdate.releasesPage)
    }
}
