import AppKit
import Foundation
import NXPMacKit
import NXPocketKit

/// Where the IPA's copy in iCloud Drive stands.
public enum CloudCopyState: Equatable {
    case none
    case copying
    /// On this Mac, on its way to iCloud: the iPhone does not see it yet.
    case uploading
    /// In iCloud, with the date of the IPA it is a copy of.
    case inCloud(Date)
    case failed(String)
}

/// A long action of the iPhone app screen: building the IPA, or the RAM helper.
public enum TaskState: Equatable {
    case idle
    case running(fraction: Double?, detail: String)
    case finished(String)
    case failed(String)

    public var isRunning: Bool { if case .running = self { return true }; return false }
}

/// The iPhone app: its IPA (built by the repository's `tools/build_app.sh`), the ways to get it onto the phone, and
/// the one-off helper that turns on "Increased Memory Limit" for its App ID.
extension AppModel {
    public var repository: URL? { PhoneAppBuild.repository() }
    public var ipaURL: URL { settings.value.outputURL.appendingPathComponent(PhoneAppBuild.ipaName) }

    /// True when the app's sources changed after the IPA was built.
    public var ipaIsStale: Bool {
        guard let ipa = phoneIPA, let source = newestAppSource else { return false }
        return source > ipa.date
    }

    public var appBuildBlockers: [String] {
        guard let repository else {
            return ["This launcher does not run from the NXPocketApple repository (mac/.build/release/NXPocket), so it cannot build the app."]
        }
        return PhoneAppBuild.missing(in: repository, xcode: toolchain.xcode)
    }

    // MARK: - The IPA from the release

    /// Puts the IPA that came inside the launcher in the output folder when there is none there or only an older one: the
    /// iPhone app is available at once, before any release is downloaded.
    func seedPhoneAppFromBundle() {
        guard let bundled = PhoneAppDownload.bundledIPA() else { return }
        let destination = ipaURL
        Task {
            let seeded = await Task.detached(priority: .utility) { PhoneAppDownload.seed(from: bundled, to: destination) }.value
            if let seeded { append("iphone app: \(seeded.versionText) taken from this launcher") }
            refreshPhoneApp()
        }
    }

    /// Keeps the iPhone app's IPA here in step with the latest release: fetched when there is none or a newer one is out.
    /// Runs after each look at GitHub (at launch, once a day), so the app is there without being asked for.
    func fetchPhoneAppIfNeeded() {
        guard let release = latestRelease, !ipaDownload.isRunning, PhoneAppDownload.hasIPA(release) else { return }
        let ipa = ipaURL
        Task {
            // Reading the IPA's version runs `unzip`: not on the main thread.
            let have = await Task.detached(priority: .utility) { PhoneAppBuild.inspect(ipa) }.value
            if PhoneAppDownload.needsDownload(have: have, release: release) { downloadPhoneApp(release) }
        }
    }

    /// Downloads the release's IPA into the output folder, checks it, and replaces the copy kept there.
    public func downloadPhoneApp(_ release: LauncherRelease) {
        guard !ipaDownload.isRunning else { return }
        ipaDownload = .running(fraction: 0, detail: "Downloading NXPocketApple \(release.version)")
        append("iphone app: downloading \(release.version)")
        let destination = ipaURL
        let (events, sink) = AsyncStream.makeStream(of: Double?.self)
        Task {
            let reader = Task { @MainActor in
                for await fraction in events {
                    ipaDownload = .running(fraction: fraction, detail: "Downloading NXPocketApple \(release.version)")
                }
            }
            let outcome = await Task.detached(priority: .utility) { () -> Result<PhoneAppIPA, Error> in
                Result {
                    try PhoneAppDownload.fetch(release, to: destination) { written, expected in
                        sink.yield(expected > 0 ? Double(written) / Double(expected) : nil)
                    }
                }
            }.value
            sink.finish()
            await reader.value
            switch outcome {
            case .success(let found):
                phoneIPA = found
                ipaDownload = .finished("Version \(found.versionText) is here, checked against the release.")
                append("iphone app: \(found.versionText) downloaded and checked")
                refreshPhoneApp()
            case .failure(let error):
                let reason = (error as? NXPocketError)?.detail ?? error.localizedDescription
                ipaDownload = .failed("The iPhone app was not downloaded: \(reason)")
                append("iphone app: \(reason)")
            }
        }
    }

    public func refreshPhoneApp() {
        let ipa = ipaURL
        let repository = repository
        Task {
            let (found, source) = await Task.detached(priority: .utility) {
                (PhoneAppBuild.inspect(ipa), repository.flatMap(PhoneAppBuild.newestSourceChange(in:)))
            }.value
            self.phoneIPA = found
            self.newestAppSource = source
        }
    }

    // MARK: - Building the IPA

    /// Runs `tools/build_app.sh --device-unsigned`, which writes `NXPocketApple.ipa` into the output folder.
    public func buildPhoneApp() {
        guard !appBuild.isRunning else { return }
        guard let repository else {
            appBuild = .failed(appBuildBlockers.first ?? "The NXPocketApple repository was not found.")
            return
        }
        let missing = PhoneAppBuild.missing(in: repository, xcode: toolchain.xcode)
        guard missing.isEmpty else {
            appBuild = .failed("Missing: \(missing.joined(separator: ", ")).")
            return
        }
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/bash"),
                                   arguments: [repository.appendingPathComponent("tools/build_app.sh").path, "--device-unsigned"],
                                   currentDirectory: repository,
                                   environment: PhoneAppBuild.environment(output: settings.value.outputURL, xcode: toolchain.xcode))
        // One ordered stream, as for the engine: the script's FAIL line is seen before its exit is.
        let (lines, sink) = AsyncStream.makeStream(of: String.self)
        runner.onLine = { sink.yield($0) }
        runner.onExit = { _ in sink.finish() }
        appBuild = .running(fraction: 0, detail: "starting")
        append("app: building the iPhone app's IPA")
        do {
            try runner.start()
        } catch {
            sink.finish()
            appBuild = .failed((error as? NXPocketError)?.detail ?? error.localizedDescription)
            return
        }
        appBuildRunner = runner
        Task { @MainActor [model = self] in
            var failure: String?
            for await line in lines {
                model.append("app: \(line)")
                if let reason = PhoneAppBuild.failure(in: line) { failure = reason }
                if let step = PhoneAppBuild.progress(after: line) { model.appBuild = .running(fraction: step.fraction, detail: step.stage) }
            }
            let result = await Task.detached { runner.waitUntilExit() }.value
            model.appBuildRunner = nil
            if result.isCancelled {
                model.appBuild = .failed("cancelled")
            } else if result.status == 0 {
                model.appBuild = .finished("IPA built")
            } else {
                let last = result.lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                model.appBuild = .failed(failure ?? last ?? "the script exited with \(result.status)")
            }
            model.refreshPhoneApp()
        }
    }

    public func cancelPhoneAppBuild() {
        appBuildRunner?.cancel()
    }

    // MARK: - Getting it onto the phone

    public func saveIPACopy() {
        guard let ipa = phoneIPA else { return }
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = "NXPocketApple-\(ipa.version ?? "app")\(ipa.build.map { "-\($0)" } ?? "").ipa"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: ipa.url, to: destination)
            revealInFinder(destination)
        } catch {
            append("app: the copy failed: \(error.localizedDescription)")
        }
    }

    // MARK: - iCloud Drive

    /// `~/Library/Mobile Documents/com~apple~CloudDocs`: iCloud Drive's own folder, nil when iCloud Drive is off.
    public var iCloudDrive: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: drive.path, isDirectory: &isDirectory) && isDirectory.boolValue ? drive : nil
    }

    public var cloudIPA: URL? {
        iCloudDrive?.appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(PhoneAppBuild.ipaName)
    }

    /// Puts the IPA in iCloud Drive → Downloads, replacing an earlier copy at once (never a half-written file there:
    /// the copy is made beside it and swapped in), then follows its upload.
    public func copyIPAToiCloud() {
        guard let ipa = phoneIPA, let destination = cloudIPA else {
            cloudCopy = .failed("iCloud Drive is off on this Mac: turn it on in System Settings → Apple Account → iCloud.")
            return
        }
        cloudCopy = .copying
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                Result {
                    let manager = FileManager.default
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: destination, create: true)
                    defer { try? manager.removeItem(at: scratch) }
                    let fresh = scratch.appendingPathComponent(PhoneAppBuild.ipaName)
                    try manager.copyItem(at: ipa.url, to: fresh)
                    if manager.fileExists(atPath: destination.path) {
                        _ = try manager.replaceItemAt(destination, withItemAt: fresh)
                    } else {
                        try manager.moveItem(at: fresh, to: destination)
                    }
                }
            }.value
            if case .failure(let error) = outcome {
                self.cloudCopy = .failed("The copy to iCloud Drive failed: \(error.localizedDescription)")
                return
            }
            self.append("app: NXPocketApple.ipa copied to iCloud Drive → Downloads")
            self.watchCloudCopy()
        }
    }

    /// Reads the copy's upload state now, and every 2 seconds while it is uploading.
    public func watchCloudCopy() {
        cloudWatch?.cancel()
        guard let destination = cloudIPA else { cloudCopy = .none; return }
        cloudWatch = Task { [weak self] in
            while !Task.isCancelled {
                let state = await Task.detached(priority: .utility) { Self.cloudState(of: destination) }.value
                guard let self else { return }
                self.cloudCopy = state
                guard state == .uploading || state == .copying else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    nonisolated static func cloudState(of url: URL) -> CloudCopyState {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard FileManager.default.fileExists(atPath: fresh.path) else { return .none }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
                                         .ubiquitousItemUploadingErrorKey, .contentModificationDateKey]
        guard let values = try? fresh.resourceValues(forKeys: keys) else { return .failed("its iCloud state cannot be read") }
        if let error = values.ubiquitousItemUploadingError { return .failed("iCloud did not take it: \(error.localizedDescription)") }
        if values.isUbiquitousItem != true { return .failed("the folder is not synced with iCloud Drive") }
        if values.ubiquitousItemIsUploaded == true { return .inCloud(values.contentModificationDate ?? Date()) }
        return .uploading
    }

    // MARK: - Increased Memory Limit

    /// Reads the bundle ID NXPocketApple is installed under on the selected iPhone. A team after it (SideStore,
    /// AltStore) is the user's own App ID, which the RAM helper can change; the plain ID (FlareStore, Sideloadly,
    /// Xcode, TrollStore...) is an installation like any other, only the helper does not apply to it.
    public func findInstallation() {
        guard let device = selectedDevice else {
            installation = .failure(NXPocketError(.deviceUnavailable, "Connect the iPhone: the app is looked for on it."))
            return
        }
        let toolchain = toolchain
        let base = settings.value.bundleID.isEmpty ? LauncherSettings.defaultBundleID : settings.value.bundleID
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> Result<MemoryLimitHelper.Installation, NXPocketError> in
                do {
                    let installed = try DeviceTransfer(toolchain: toolchain).installedBundleID(on: device, matching: base)
                    return .success(MemoryLimitHelper.installation(installed: installed, base: base))
                } catch let error as NXPocketError {
                    return .failure(error)
                } catch {
                    return .failure(NXPocketError(.deviceUnavailable, error.localizedDescription))
                }
            }.value
            self.installation = found
        }
    }

    /// Whether Xcode is signed in with the team SideStore uses (Xcode → Settings → Accounts).
    public func xcodeHasTeam(_ team: String) -> Bool { MemoryLimitHelper.xcodeTeams().contains(team) }

    /// Generates the helper in a temporary folder and builds it once for any iOS device with
    /// `-allowProvisioningUpdates`. The screen asked the user to confirm first: this changes their App ID at Apple.
    public func enableMemoryLimit(_ target: MemoryLimitHelper.Target) {
        guard !memoryHelper.isRunning else { return }
        guard let xcodegen = PhoneAppBuild.xcodegen() else {
            memoryHelper = .failed("XcodeGen is missing: install it on the Setup screen")
            return
        }
        guard let xcode = toolchain.xcode else {
            memoryHelper = .failed("Xcode was not found: set it in Settings.")
            return
        }
        memoryHelper = .running(fraction: nil, detail: "making the helper project")
        append("memory: helper for \(target.bundleID) (team \(target.team))")
        Task { [model = self] in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-memory-\(UUID().uuidString)", isDirectory: true)
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(Int32, [String]), NXPocketError> in
                defer { try? FileManager.default.removeItem(at: folder) }
                do {
                    let project = try MemoryLimitHelper.generate(target, in: folder, xcodegen: xcodegen)
                    var environment = ProcessInfo.processInfo.environment
                    environment["DEVELOPER_DIR"] = xcode.appendingPathComponent("Contents/Developer").path
                    let runner = ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                                               arguments: MemoryLimitHelper.buildArguments(project: project,
                                                                                         derivedData: folder.appendingPathComponent("dd")),
                                               currentDirectory: folder, environment: environment)
                    runner.onLine = { line in
                        Task { @MainActor in
                            if line.contains("error:") || line.contains("warning:") || line.hasPrefix("**") { model.append("memory: \(line)") }
                            if line.contains("Signing Identity") || line.contains("Provisioning Profile") || line.hasPrefix("CodeSign ") {
                                model.memoryHelper = .running(fraction: nil, detail: "signing (Xcode updates the App ID)")
                            }
                        }
                    }
                    try runner.start()
                    let result = runner.waitUntilExit()
                    return .success((result.status, result.lines))
                } catch let error as NXPocketError {
                    return .failure(error)
                } catch {
                    return .failure(NXPocketError(.engineFailed, error.localizedDescription))
                }
            }.value
            switch outcome {
            case .failure(let error):
                model.memoryHelper = .failed(error.detail)
            case .success(let (status, lines)):
                switch MemoryLimitHelper.interpret(status: status, lines: lines) {
                case .enabled:
                    model.append("memory: Xcode signed the helper with the entitlement")
                    model.memoryHelper = .finished("Xcode signed the helper with Increased Memory Limit: the App ID \(target.bundleID) has it.")
                case .needsAccount(let line):
                    model.memoryHelper = .failed("Xcode has no account for team \(target.team). Sign in with the Apple ID SideStore uses in Xcode → Settings → Accounts, then try again.\n\(line)")
                case .failed(let reason):
                    model.memoryHelper = .failed(reason)
                }
            }
        }
    }
}
