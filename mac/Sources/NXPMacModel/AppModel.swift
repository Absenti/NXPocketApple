import AppKit
import Foundation
import UniformTypeIdentifiers
import NXPMacKit
import NXPocketKit

@MainActor
public final class AppModel: ObservableObject {
    public enum Screen: String, CaseIterable, Identifiable {
        case setup, library, build, devices, phoneApp, settings
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .setup: return "Setup"
            case .library: return "Library"
            case .build: return "Build"
            case .devices: return "Devices"
            case .phoneApp: return "iPhone app"
            case .settings: return "Settings"
            }
        }
        public var symbol: String {
            switch self {
            case .setup: return "checklist"
            case .library: return "square.grid.2x2"
            case .build: return "hammer"
            case .devices: return "iphone"
            case .phoneApp: return "arrow.down.app"
            case .settings: return "gearshape"
            }
        }
    }

    @Published public var screen: Screen = .library
    @Published public var settings: SettingsStore
    @Published public internal(set) var toolchain = Toolchain.empty
    @Published public internal(set) var games: [LocalGame] = []
    /// Why the last move of a package to the Trash failed, or nil.
    @Published public internal(set) var libraryProblem: String?
    @Published public internal(set) var devices: [Device] = []
    /// The last lines of the engine, the scripts and the launcher itself, each with a number that stays its own.
    @Published public internal(set) var log: [LogLine] = []
    var logCount = 0
    /// What the window's log shows, kept on disk too (`LauncherLog`): the window holds 800 lines and forgets them at quit.
    public let fileLog = LauncherLog()
    @Published public internal(set) var engineReport = "not checked"
    /// What the chosen Python lacks, in words, or nil when it has everything the engine imports.
    @Published public internal(set) var pythonProblem: String?
    /// True while `devicectl` is being asked for the connected iPhones, which can take seconds (a locked phone, a
    /// tunnel being set up) and used to freeze the whole window, Devices tab included, until it answered.
    @Published public internal(set) var searchingDevices = false
    /// Why the last search found nothing usable, or nil.
    @Published public internal(set) var deviceProblem: String?
    @Published public internal(set) var lastDeviceSearch: Date?
    /// True while the toolchain (Python, Xcode SDK, engine) is being checked, in the background.
    @Published public internal(set) var checkingToolchain = false

    // MARK: Games folder (AppModel+Folder)

    /// The games of the games folder and its subfolders (`GameFolder`).
    @Published public internal(set) var folder = GameFolderListing()
    @Published public internal(set) var scanningFolder = false
    /// Why the packages were read by their names only (no prod.keys, or it could not be read), or nil.
    @Published public internal(set) var keysProblem: String?
    /// The games ticked for the next build, by application title ID.
    @Published public internal(set) var checkedGames: Set<String> = []
    /// Each game's ticked update and DLC; a game not in it has the defaults (`GameSelection.defaults`).
    @Published public internal(set) var selections: [String: GameSelection] = [:]

    // MARK: The phone's library

    /// The games installed on the selected iPhone (`DeviceLibrary`).
    @Published public internal(set) var phoneGames: [PhoneGame] = []
    @Published public internal(set) var checkingPhone = false
    @Published public internal(set) var phoneCheckedAt: Date?
    @Published public internal(set) var phoneProblem: String?
    /// The last look at the phone's games folder: its games and every file under them, saves included.
    var phoneSnapshot: PhoneSnapshot?

    // MARK: Save backups (AppModel+Backup)

    /// The newest backup's date of each game, from `<output>/Saves`.
    @Published public internal(set) var lastBackups: [String: Date] = [:]
    /// Games whose saves are being copied now.
    @Published public internal(set) var backingUp: Set<String> = []
    /// What the last backup of a game said when it saved nothing ("no save on the iPhone") or failed.
    @Published public internal(set) var backupNotes: [String: String] = [:]
    /// Every game with copies on the Mac, for the saves card and putting a copy back.
    @Published public internal(set) var savedGames: [SavedGame] = []

    // MARK: First-run setup (AppModel+Setup)

    /// Each step's state, filled by `checkSetup` after every look at the toolchain.
    @Published public internal(set) var setupStates: [SetupStep: SetupState] = [:]
    /// Whether the setup was looked at once since launch: the window opens on it while a required step is missing.
    var setupChecked = false

    // MARK: The launcher's own updates (AppModel+Update)

    @Published public internal(set) var update: UpdateState = .idle
    /// Whether the sheet that offers a new release is open: it opens by itself when the look at launch finds one.
    @Published public var showUpdateSheet = false
    /// The latest published release, from the last look at GitHub: the launcher's update and the iPhone app's IPA.
    @Published public internal(set) var latestRelease: LauncherRelease?
    /// The IPA being downloaded from that release.
    @Published public internal(set) var ipaDownload: TaskState = .idle
    /// Where each copy sent to iCloud Drive for the iPhone stands, by backup folder path.
    @Published public internal(set) var saveExports: [String: CloudCopyState] = [:]
    /// What the phone's saves looked like at the last look, to copy the changed ones (`backUpChanged`).
    var saveWatch = SaveWatch()
    /// A queue item waiting for the user's answer (a backup failed before its send), and how to resume it.
    var pendingAnswers: [UUID: CheckedContinuation<Bool, Never>] = [:]

    // MARK: The iPhone app (AppModel+PhoneApp)

    /// The IPA in the output folder, and whether the app's sources changed after it was built.
    @Published public internal(set) var phoneIPA: PhoneAppIPA?
    @Published public internal(set) var newestAppSource: Date?
    @Published public internal(set) var appBuild: TaskState = .idle
    @Published public internal(set) var memoryHelper: TaskState = .idle
    /// How the app is installed on the selected phone, read from it, or why that could not be told. The RAM helper
    /// needs a team-signed App ID (SideStore, AltStore); any other store is a normal installation, not an error.
    @Published public internal(set) var installation: Result<MemoryLimitHelper.Installation, NXPocketError>?
    var appBuildRunner: ProcessRunner?
    /// The IPA's copy in iCloud Drive → Downloads, where SideStore's + finds it on the iPhone.
    @Published public internal(set) var cloudCopy: CloudCopyState = .none
    var cloudWatch: Task<Void, Never>?

    // MARK: Queue (AppModel+Queue)

    @Published public internal(set) var queue: [QueueItem] = []

    var queueTask: Task<Void, Never>?
    /// Items the user cancelled while they ran: a build cancelled while it packs must not go on to the send.
    var cancelledItems: Set<UUID> = []
    var runner: ProcessRunner?
    var transferControl: DeviceTransfer.Control?
    var buildProgress = BuildProgress()
    /// The engine's last red line: the reason a build stopped, which "the engine exited with 1" never said.
    var lastEngineError: String?
    /// The RomFS image the engine named in its `game files:` line.
    var reportedRomfs: URL?
    let identities = PackageIdentityCache()
    var scanGeneration = 0
    var phoneLibrary: DeviceLibrary?
    private var pollTask: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?

    /// How often the connected iPhones are looked for while the app is in front. The Devices tab used to ask every
    /// 4 seconds while it was shown, so a phone plugged in, unlocked or trusted appeared without a click; a call
    /// takes about a second of devicectl, and the app also looks when it comes to the front and before every send.
    public static let devicePollInterval: TimeInterval = 25

    public init(settings: SettingsStore? = nil) {
        self.settings = settings ?? SettingsStore()
        // A build paused when the launcher quits must not stay stopped with nobody to wake it.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.runner?.resume() }
        }
        refreshToolchain()
        refreshLibrary()
        refreshFolder()
        refreshBackups()
        // The IPA that came inside the app is put in place first, then read: two tasks would race on `phoneIPA`.
        if PhoneAppDownload.bundledIPA() != nil { seedPhoneAppFromBundle() } else { refreshPhoneApp() }
        checkForUpdatesAtLaunch()
    }

    public var selectedDevice: Device? {
        devices.first { $0.udid == settings.value.deviceUDID && $0.canReceive }
            ?? devices.first { $0.canReceive }
    }

    // MARK: - Toolchain

    /// Looks for the engine, a Python with its modules and Xcode's SDK, off the main thread: it runs a process per
    /// Python candidate and one for the SDK, and done on the main thread it held the window at launch.
    public func refreshToolchain() {
        let configured = settings.value.engineRoot.isEmpty ? nil : URL(fileURLWithPath: (settings.value.engineRoot as NSString).expandingTildeInPath)
        let xcode = settings.value.xcodeURL
        let python = settings.value.pythonURL
        checkingToolchain = true
        engineReport = "checking the engine, Python and Xcode…"
        Task {
            let (found, sdk) = await Task.detached(priority: .userInitiated) { () -> (Toolchain, String?) in
                let found = ToolchainLocator.detect(engineRoot: configured, preferredXcode: xcode, preferredPython: python)
                return (found, ToolchainLocator.sdkVersion(xcode: found.xcode))
            }.value
            self.toolchain = found
            self.phoneLibrary = DeviceLibrary(toolchain: found)
            let engine = found.engine.isUsable ? "engine ready" : "engine not synced"
            let pythonText = "python \(found.pythonVersion) (\(found.python.path))"
            let sdkText = sdk.map { "iOS SDK \($0)" } ?? "no iOS SDK"
            self.engineReport = "\(engine) · \(pythonText) · \(sdkText) · \(found.engine.root.path)"
            self.pythonProblem = found.pythonMissing.isEmpty ? nil : Self.pythonAdvice(missing: found.pythonMissing)
            self.checkingToolchain = false
            self.checkSetup()
        }
    }

    nonisolated static func pythonAdvice(missing: [String]) -> String {
        "No Python on this Mac has everything the engine needs (missing: \(missing.joined(separator: ", "))). "
            + "Install it on the Setup screen, or set a Python in Settings."
    }

    /// Whether the chosen Python can build a plan. nsz matters only for an NSZ or XCZ package.
    func pythonBlocker(compressed: Bool) -> String? {
        let missing = toolchain.pythonMissing.filter { $0 != "nsz" || compressed }
        return missing.isEmpty ? nil : Self.pythonAdvice(missing: missing)
    }

    // MARK: - Library

    public func refreshLibrary() {
        let folder = settings.value.outputURL
        games = LocalLibrary.scan(outputFolder: folder)
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Renames a built package, on the Mac at once and on the iPhone once it is sent again, and keeps the name for the
    /// next builds of the game. `nil` gives the game back its own name.
    public func renameGame(_ game: LocalGame, to newName: String?) {
        let titleID = game.titleID
        let original = settings.value.originalGameNames[titleID] ?? game.title
        let target: String
        do {
            target = try PackageRenamer.clean(newName ?? original)
        } catch {
            libraryProblem = (error as? NXPocketError)?.detail ?? error.localizedDescription
            return
        }
        let root = game.root
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<GamePackage, Error> in
                Result { try PackageRenamer.rename(root, to: target) }
            }.value
            switch outcome {
            case .success:
                if newName == nil || target == original {
                    self.settings.value.gameNames[titleID] = nil
                    self.settings.value.originalGameNames[titleID] = nil
                } else {
                    self.settings.value.originalGameNames[titleID] = original
                    self.settings.value.gameNames[titleID] = target
                }
                self.libraryProblem = nil
                self.append("renamed \(titleID) to \(target)")
            case .failure(let error):
                self.libraryProblem = "\(game.title) could not be renamed: \((error as? NXPocketError)?.detail ?? error.localizedDescription)"
            }
            self.refreshLibrary()
        }
    }

    /// The name a game goes by: the user's, else its own.
    public func displayName(titleID: String, own: String) -> String {
        settings.value.gameNames[titleID.uppercased()] ?? own
    }

    public func originalName(of game: LocalGame) -> String? {
        settings.value.originalGameNames[game.titleID]
    }

    /// Moves a built package to the Trash, after the library asked the user to confirm.
    public func moveToTrash(_ game: LocalGame) {
        // The Trash, never removeItem: a package is gigabytes and an hour of build, and a click in a context menu is
        // easy to make by mistake. A volume without a Trash refuses, and the package stays.
        do {
            try FileManager.default.trashItem(at: game.root, resultingItemURL: nil)
            libraryProblem = nil
            append("moved \(game.root.lastPathComponent) to the Trash")
        } catch {
            libraryProblem = "\(game.root.lastPathComponent) could not be moved to the Trash, and was kept: \(error.localizedDescription)"
            append(libraryProblem ?? "")
        }
        refreshLibrary()
    }

    // MARK: - Devices

    /// Starts the slow look for iPhones and the look when the app comes to the front. Called once, by the window.
    ///
    /// Every `SaveWatch.checkInterval` the phone's games are read too, for the automatic save backups: also while the
    /// launcher is in the background, since that is when the phone is played.
    public func startDeviceWatch() {
        guard pollTask == nil else { return }
        refreshDevices()
        pollTask = Task { [weak self] in
            var sinceSaveCheck: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.devicePollInterval * 1_000_000_000))
                guard let self else { return }
                sinceSaveCheck += Self.devicePollInterval
                let savesDue = self.settings.value.autoBackup && sinceSaveCheck >= SaveWatch.checkInterval
                if savesDue { sinceSaveCheck = 0 }
                guard NSApplication.shared.isActive || savesDue else { continue }
                await self.searchDevices(quiet: true, thenPhoneGames: savesDue)
            }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices(quiet: true, thenPhoneGames: true)
            }
        }
    }

    /// Asks devicectl for the connected iPhones in the background; the window keeps drawing meanwhile and shows that
    /// it is searching. `quiet` is for the periodic look: it writes nothing to the log.
    public func refreshDevices(quiet: Bool = false, thenPhoneGames: Bool = false) {
        Task { await searchDevices(quiet: quiet, thenPhoneGames: thenPhoneGames) }
    }

    /// The same, awaited: the queue looks again right before a send, so a phone that left Wi-Fi is not sent to.
    @discardableResult
    func searchDevices(quiet: Bool = true, thenPhoneGames: Bool = false) async -> [Device] {
        if searchingDevices {
            while searchingDevices { try? await Task.sleep(nanoseconds: 100_000_000) }
            return devices
        }
        searchingDevices = true
        let toolchain = toolchain
        let previous = selectedDevice?.udid
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[Device], NXPocketError> in
            do {
                return .success(try DeviceInventory.list(toolchain: toolchain).filter { !$0.isSimulator })
            } catch let error as NXPocketError {
                return .failure(error)
            } catch {
                return .failure(NXPocketError(.deviceUnavailable, error.localizedDescription))
            }
        }.value
        searchingDevices = false
        lastDeviceSearch = Date()
        switch outcome {
        case .success(let found):
            if found != devices { devices = found }
            deviceProblem = found.isEmpty ? "No iPhone found. Connect it by cable, unlock it and trust this Mac." : nil
            if found.isEmpty && !quiet { append("no iPhone is connected") }
        case .failure(let error):
            devices = []
            deviceProblem = "devicectl: \(error.detail)"
            if !quiet { append("devices: \(error.detail)") }
        }
        if selectedDevice == nil {
            phoneGames = []
        } else if thenPhoneGames || selectedDevice?.udid != previous || phoneCheckedAt == nil {
            refreshPhoneGames()
        }
        return devices
    }

    public func useDevice(_ device: Device) {
        settings.value.deviceUDID = device.udid
        phoneGames = []
        phoneCheckedAt = nil
        refreshPhoneGames()
    }

    /// Reads which games the selected iPhone has installed, for the "on the iPhone" badges, then copies the saves
    /// that changed since their newest copy on the Mac.
    public func refreshPhoneGames() {
        guard let device = selectedDevice, !checkingPhone else { return }
        Task {
            if case .success(let snapshot) = await readPhone(device) {
                await backUpChanged(snapshot, device: device)
            }
        }
    }

    /// One look at the phone's games folder, kept for the badges and the backups.
    func readPhone(_ device: Device) async -> Result<PhoneSnapshot, Error> {
        while checkingPhone { try? await Task.sleep(nanoseconds: 100_000_000) }
        let library = phoneLibrary ?? DeviceLibrary(toolchain: toolchain)
        phoneLibrary = library
        let bundleID = settings.value.bundleID.isEmpty ? LauncherSettings.defaultBundleID : settings.value.bundleID
        checkingPhone = true
        let outcome = await Task.detached(priority: .utility) { () -> Result<PhoneSnapshot, Error> in
            Result { try library.snapshot(on: device, bundleID: bundleID) }
        }.value
        checkingPhone = false
        phoneCheckedAt = Date()
        switch outcome {
        case .success(let snapshot):
            phoneSnapshot = snapshot
            phoneGames = snapshot.games
            phoneProblem = nil
        case .failure(let error):
            phoneProblem = (error as? NXPocketError)?.detail ?? error.localizedDescription
        }
        return outcome
    }

    public func phoneGame(_ titleID: String) -> PhoneGame? {
        phoneGames.first { $0.titleID == titleID.uppercased() }
    }

    // MARK: - Log

    func append(_ line: String) {
        guard !line.isEmpty else { return }
        fileLog.append(line)
        logCount += 1
        log.append(LogLine(id: logCount, text: line))
        if log.count > 800 { log.removeFirst(log.count - 800) }
    }

    public func clearLog() { log.removeAll() }

    // MARK: - Panels

    public func chooseGameFolder() {
        if let url = Panel.chooseDirectory(title: "Choose the folder that holds your games' NSP, NSZ, XCI or XCZ files (its subfolders are read too)") {
            settings.value.gameFolder = url.path
            checkedGames = []
            selections = [:]
            refreshFolder()
        }
    }

    public func choosePython() {
        if let url = Panel.chooseFile(title: "Choose the python3 to run the engine with", types: [.unixExecutable, .data]) {
            settings.value.pythonPath = url.path
            refreshToolchain()
        }
    }

    public func chooseKeysFile() {
        if let url = Panel.chooseFile(title: "Choose prod.keys", types: [.data]) {
            settings.value.keysFile = url.path
            refreshFolder()
        }
    }

    public func chooseEngineFolder() {
        if let url = Panel.chooseDirectory(title: "Choose the NX2Apple engine folder") {
            settings.value.engineRoot = url.path
            refreshToolchain()
        }
    }

    public func chooseWorkFolder() {
        if let url = Panel.chooseDirectory(title: "Choose where the engine keeps each game's build folder (gigabytes of extracted files)") {
            settings.value.workFolder = url.path
        }
    }

    public func chooseOutputFolder() {
        if let url = Panel.chooseDirectory(title: "Choose where built games are kept") {
            settings.value.outputFolder = url.path
            refreshLibrary()
        }
    }

    public func chooseXcode() {
        if let url = Panel.chooseDirectory(title: "Choose Xcode.app") {
            settings.value.xcodePath = url.path
            refreshToolchain()
        }
    }
}

enum Panel {
    static func chooseDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = title
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFile(title: String, types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = title
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// One line of the log. Its number identifies it in the list: the list once used positions, which all change when
/// the oldest lines are dropped, so every row was drawn again at each new line past 800.
public struct LogLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public let text: String
}
