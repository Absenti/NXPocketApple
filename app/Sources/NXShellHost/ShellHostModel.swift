import Foundation
import NXPocketKit
import NXShellUI
import SwiftUI
import UIKit

/// Everything the shell screens talk to: the library on disk, the certificate, the importer and the one game that
/// may be running.
@MainActor
public final class ShellHostModel: ObservableObject {
    public enum ImportState: Equatable {
        case idle
        case running(stage: String, fraction: Double, detail: String)
        case finished(String)
        case failed(String)

        public var isRunning: Bool { if case .running = self { return true }; return false }
    }

    public enum LaunchState: Equatable {
        case idle
        case launching(String)
        /// The game's own view is on screen: the library never comes back in this process.
        case running(String)
        case failed(String)
    }

    public enum LoadTestState: Equatable {
        case idle
        case running(String)
        case finished(LoadTestReport)
        case failed(String)

        public var isRunning: Bool { if case .running = self { return true }; return false }
    }

    public let documents: URL

    @Published public private(set) var games: [InstalledGame] = []
    /// Whether the library was read once: until then the screen shows neither the games nor "no games yet".
    @Published public private(set) var libraryLoaded = false
    @Published public private(set) var certificate: StoredCertificate?
    /// Why the certificate the keychain holds could not be read, when it could not: it shows instead of "no certificate".
    @Published public private(set) var certificateProblem: String?
    /// Where the check of a game's data stands, and what it found (`ShellHostModel+Repair`).
    @Published public internal(set) var repairState: RepairState = .idle
    var repairScan: GameRepair.Scan?
    /// The games taken off this iPhone whose tiles stay.
    @Published public private(set) var offloaded: [OffloadedGame] = []
    /// The game whose cheats were turned off because its last start did not come back (`applyCheatsSafeMode`).
    @Published public var cheatsSafeModeFor: String?
    /// An archive or a folder asked to be imported, until the player has read the warning and said yes: from Files, or sent by AirDrop.
    @Published public var archiveRequest: ArchiveRequest?
    /// Saves from another device that a source holds, newer than these: asked before a game starts.
    @Published public var syncOffer: SyncOffer?
    var lastAutoBackup = Date.distantPast
    let offloadStore: OffloadStore
    /// Whether the app reminds the player, with a notification, that its signature is about to end.
    @Published public var certificateReminders: Bool = UserDefaults.standard.object(forKey: "certificateReminders") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(certificateReminders, forKey: "certificateReminders")
            updateExpiryReminders()
        }
    }
    @Published public var importState: ImportState = .idle
    @Published public var launch: LaunchState = .idle
    @Published public internal(set) var loadTest: LoadTestState = .idle
    @Published public private(set) var failedLaunch: LaunchMarker?
    /// The names the player gave games, by title ID (`GameChoices.name`).
    @Published public internal(set) var names: [String: String] = [:]
    @Published public private(set) var pendingTransfers: Int = 0
    /// What waits to be imported, one entry per transfer, each of which the player can delete.
    @Published public private(set) var pendingList: [PendingImport] = []
    /// The games the Mac is still sending, with how far each got.
    @Published public private(set) var receiving: [IncomingTransfer] = []
    /// Free space for an import, measured off the main thread: `volumeAvailableCapacityForImportantUsage` asks the
    /// system to estimate what it could purge, which can take a long time, and the library header showed it on every
    /// redraw. Nil until the first measurement comes back.
    @Published public private(set) var freeBytes: Int64?
    /// The touch controls' options, one set for every game (`Documents/settings/touch.json`).
    @Published public private(set) var touch: TouchControls

    public let engineHost: EngineHost
    /// The Mac and FTP sources games can be downloaded from, off until the player turns them on.
    public let sources: NetworkSources
    /// A pairing link opened from the Mac's QR code, waiting for the player to confirm it (`PairLinkSheet`).
    @Published var pairLink: PairLink?
    /// Whether a newer NXPocketApple exists (`UpdateChannel`: one request to GitHub, no personal data).
    public let updates: UpdateChecker

    let importer: ImportService
    private let signer: FrameworkSigner
    let log: ImportLog

    /// The game being started or on screen; only meaningful while `launch` says one is.
    var activeTitleID: String?
    /// A game asked for by its icon or by `.next-launch`, started once the first screen is up and the library is read.
    var pendingLaunch: String?
    var firstScreenShown = false
    /// Counts the time spent in the game on screen.
    var playClock: PlayClock?
    private var scanGeneration = 0
    private var scanTask: Task<Void, Never>?

    public init(documents: URL? = nil, engineHost: EngineHost? = nil, signer: FrameworkSigner? = nil,
                updates: UpdateChecker? = nil) {
        let documents = documents ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.documents = documents
        self.updates = updates ?? UpdateChecker()
        self.engineHost = engineHost ?? makeDefaultEngineHost()
        self.signer = signer ?? DeviceSigner()
        self.importer = ImportService(documents: documents, signer: self.signer)
        self.sources = NetworkSources(documents: documents)
        self.offloadStore = OffloadStore(documents: documents)
        self.offloaded = offloadStore.records()
        self.log = ImportLog.standard(in: documents)
        self.touch = TouchControls.load(documents: documents)
        try? importer.importer.prepareDirectories()
        BackupExclusion.excludeImportantFolders(in: documents)
        GameLogs.fileSharedLogs(documents: documents)
        GameSaves.cleanLeftovers(in: [documents, FileManager.default.temporaryDirectory])
        SigningLeftovers.clean()
        pendingLaunch = NextLaunch.take(documents: documents)?.description
        interruptedTransfer = ImportGuard.interrupted(in: documents)
        if let interruptedTransfer { log.append("the app stopped while importing \(interruptedTransfer): it is not imported again by itself") }
        loadCertificate()
        updateExpiryReminders()
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateExpiryReminders() }
        }
        sources.onDownloaded = { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(forName: GameLaunchInbox.didRequest, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let asked = GameLaunchInbox.take() { self?.request(asked) } }
        }
        NotificationCenter.default.addObserver(forName: LinkInbox.didReceive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { for url in LinkInbox.take() { self?.open(url) } }
        }
        NotificationCenter.default.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            // After the play clock has written the time of the session that just ended.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateQuickActions() } }
        }
        sources.log = { [weak self] in self?.log.append($0) }
        sources.installedGames = { [weak self] in self?.games ?? [] }
        sources.canInstall = { [weak self] in !(self?.gameIsOnScreen ?? true) }
        sources.prepareNotifications = { DownloadNotifier.requestPermission() }
        sources.onQueueStopped = { [weak self] finished, failed, remaining in
            guard let self else { return }
            var body = finished.prefix(3).joined(separator: ", ") + (finished.count > 3 ? "…" : "")
            if remaining > 0 { body += (body.isEmpty ? "" : " · ") + self.text(.notificationResume) }
            DownloadNotifier.post(title: self.text(finished.isEmpty && failed > 0 ? .notificationFailed : .notificationDownloaded), body: body)
        }
        refresh()
    }

    public func text(_ key: ShellStrings.Key) -> String { ShellStrings.text(key) }

    // MARK: - Library

    /// Runs at start, whenever the app comes back to the foreground and after every action, so a transfer that will
    /// never finish leaves the phone the next time the user looks at it.
    public func refresh() {
        for url in LinkInbox.take() { open(url) }
        if let asked = GameLaunchInbox.take() { request(asked) }
        importer.cleanUnfinishedTransfers()
        checkTransfers()
        failedLaunch = LaunchGuard.failedLaunch(in: documents)
        applyCheatsSafeMode()
        scanLibrary()
        measureFreeSpace()
        autoBackupPlayed()
    }

    /// The library is read off the main thread: every file of every game is measured, thousands for a real game, and
    /// this runs at each return to the foreground. A newer read wins over an older one still on its way.
    private func scanLibrary() {
        scanGeneration += 1
        let generation = scanGeneration
        let documents = documents
        let importer = importer
        scanTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.readLibrary(documents: documents, importer: importer)
            }.value
            guard generation == self.scanGeneration else { return }
            for note in found.notes { self.log.append(note) }
            self.games = found.games
            self.dropRestoredOffloads()
            GameCatalog.write(found.games.filter { !$0.isBroken }.map { GameCatalogEntry(id: $0.id, name: self.name(of: $0)) }, documents: self.documents)
            self.updateQuickActions()
            self.names = found.names
            self.libraryLoaded = true
            self.startPendingLaunch()
        }
    }

    /// Waits for the library read the latest `refresh()` started.
    public func libraryRead() async {
        while let task = scanTask {
            await task.value
            if task == scanTask { return }
        }
    }

    nonisolated static func readLibrary(documents: URL, importer: ImportService)
        -> (games: [InstalledGame], names: [String: String], notes: [String]) {
        // Saves an interrupted update or removal left aside go back to their game before the library is listed.
        importer.importer.recoverReplacedSaves()
        let notes = GameSaves.recoverHiddenCopies(documents: documents)
        // A game removed with its saves kept leaves them in its folder, for its next import: that is no game to list.
        let games = GameLibrary.scan(documents: documents).filter {
            !($0.problem?.code == .packageMissing && GameSaves.holdsOnlySaves($0.directory))
        }
        let names = Dictionary(uniqueKeysWithValues: games.compactMap { game in
            GameChoices.load(titleID: game.id, documents: documents).name.map { (game.id, $0) }
        })
        return (games, names, notes)
    }

    private var measuringFreeSpace = false

    private func measureFreeSpace() {
        guard !measuringFreeSpace else { return }
        measuringFreeSpace = true
        let documents = documents
        Task {
            let bytes = await Task.detached(priority: .utility) { VolumeSpace.available(documents: documents) }.value
            self.freeBytes = bytes
            self.measuringFreeSpace = false
        }
    }

    /// Called once by the first screen: the time from the process starting to something on screen, in the import
    /// log, so a slow launch on the device is a number rather than an impression.
    public func firstScreenAppeared() {
        guard !firstScreenShown else { return }
        firstScreenShown = true
        if let started = ProcessStart.date {
            log.append(String(format: "launch: first screen %.0f ms after the process started",
                              Date().timeIntervalSince(started) * 1000))
        }
        log.append(MemoryBudget.summaryLine)
        startPendingLaunch()
    }

    public var totalBytes: Int64 { games.reduce(0) { $0 + $1.byteCount } }
    public var totalText: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
    public var freeText: String { freeBytes.map { VolumeSpace.text($0) } ?? "…" }

    public var appIdentifier: String { AppSignature.currentIdentifier }

    public var certificateTeamMatchesApp: Bool {
        guard let certificate, let team = ProvisioningProfile.teamID() else { return certificate != nil }
        return certificate.teamID == team
    }

    /// Whether this app was installed with a distribution profile (ad hoc, enterprise, App Store): its signature has no
    /// `get-task-allow`. Games may then be refused by iOS whatever else is right (`SigningDiagnosis.Verdict.distributionProfile`).
    public var installIsForDistribution: Bool { SigningDiagnosis.isDistributionSigned(AppSignature.entitlements) }

    /// Whether the imported certificate is one the app's current profile allows (nil: no profile, or none imported).
    public var certificateInAppProfile: Bool? {
        certificate.flatMap { ProvisioningProfile.allows(certificateSHA256: $0.sha256) }
    }

    public var signingIdentity: SigningIdentity? {
        guard let certificate else { return nil }
        return SigningIdentity(identifier: appIdentifier, teamID: certificate.teamID,
                               certificateSHA256: certificate.sha256, subject: certificate.subject,
                               expires: certificate.expires, entitlementsTag: SigningPreference.current.tag)
    }

    public func gamesNeedingSignature() -> [InstalledGame] {
        guard let identity = signingIdentity else { return games }
        return importer.gamesNeedingSignature(games, identity: identity)
    }

    // MARK: - Certificate

    /// The certificate the keychain holds. One that is there but cannot be read says why, in the log and on screen,
    /// rather than passing for no certificate at all and sending the player to export one again for nothing.
    public func loadCertificate() {
        certificateProblem = nil
        guard let credentials = CertificateVault.credentials() else {
            certificate = nil
            return
        }
        do {
            certificate = try CertificateImporter.read(p12: credentials.p12, passphrase: credentials.passphrase).certificate
        } catch {
            certificate = nil
            let reason = (error as? NXPocketError)?.detail ?? error.localizedDescription
            certificateProblem = reason
            log.append("the certificate in the keychain could not be read: \(reason)")
        }
    }

    /// Sets, or clears, the reminders from what the app reads now: the imported certificate's end and the embedded profile's.
    public func updateExpiryReminders() {
        guard certificateReminders, let certificate else {
            ExpiryReminder.schedule([], title: "", body: { _ in "" })
            return
        }
        let end = ExpiryReminder.expiry(certificate: certificate.expires, profile: SigningFacts.current.profileExpires)
        ExpiryReminder.schedule(ExpiryReminder.moments(expiry: end), title: text(.certReminderTitle)) { kind in
            self.text(kind == .dayBefore ? .certReminderDay : .certReminderHours)
        }
    }

    public func importCertificate(p12: Data, passphrase: String) throws {
        let parsed = try CertificateImporter.read(p12: p12, passphrase: passphrase)
        if let team = ProvisioningProfile.teamID(), team != parsed.certificate.teamID {
            throw NXPocketError(.teamMismatch,
                                "this certificate is for team \(parsed.certificate.teamID); this app was installed by \(team)")
        }
        do {
            try CertificateVault.store(parsed)
        } catch let refusal as KeychainRefusal {
            // What the app was signed with is the cause, and the Mac cannot read it off the phone: the message says it.
            let message = keychainMessage(refusal)
            log.append("the keychain refused \(refusal.account) (\(refusal.status)): \(SigningFacts.current.lines.joined(separator: "; "))")
            throw NXPocketError(.signingFailed, message)
        }
        certificate = parsed.certificate
        certificateProblem = nil
        updateExpiryReminders()
        SigningPreference.forget()   // a new certificate may be accepted where the old one was refused
        triedTransfers = []   // a transfer refused for the certificate may go in now
        log.append("certificate \(parsed.certificate.subject) imported, expires \(parsed.certificate.expires)")
    }

    public func removeCertificate() {
        CertificateVault.remove()
        certificate = nil
        certificateProblem = nil
        updateExpiryReminders()
        log.append("certificate removed")
    }

    // MARK: - Import and signing

    /// The finished transfers an import has already tried. One it refused for a reason the user has to fix (no space,
    /// the certificate) stays in `.incoming`: it is not tried again on its own every two seconds, only from a button or
    /// once the certificate changes.
    private var triedTransfers: Set<String> = []
    /// The transfer the app stopped in the middle of importing (`ImportGuard`): never imported by itself, so a crash cannot repeat
    /// at every launch.
    private var interruptedTransfer: String?
    private var transferWatch: Timer?
    /// For each transfer being received, how many bytes it had and since when: a count that stays put is a transfer that stopped.
    private var receivingGrowth: [String: (bytes: Int64, since: Date)] = [:]

    /// While the app is in front, a transfer that lands is imported as soon as the Mac writes `.complete`, rather than at
    /// the next start of the app. The Mac's send takes minutes, so a look every two seconds costs nothing and is in time.
    public func watchTransfers(_ watching: Bool) {
        transferWatch?.invalidate()
        transferWatch = nil
        guard watching, !gameIsOnScreen else { return }
        checkTransfers()
        transferWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkTransfers() }
        }
    }

    /// How long a transfer may go without a byte before it is called stopped.
    nonisolated(unsafe) static var stalledAfter: TimeInterval = 20

    /// How long a game runs before its launch counts as one that did not fail.
    static let loadedAfter: TimeInterval = 20

    var gameIsOnScreen: Bool {
        switch launch {
        case .launching, .running: return true
        case .idle, .failed: return false
        }
    }

    /// What is on its way and what has arrived; a transfer that arrived and was never tried is imported at once when a
    /// certificate is there to sign it.
    func checkTransfers() {
        // A transfer the Mac cancelled and marked is removed at once, not at the next start of the app.
        importer.importer.cleanAbandonedIncoming()
        var incoming = IncomingTransfers.receiving(documents: documents)
        let now = Date()
        var seen: [String: (bytes: Int64, since: Date)] = [:]
        for index in incoming.indices {
            let id = incoming[index].id, bytes = incoming[index].received
            let since = receivingGrowth[id].flatMap { $0.bytes == bytes ? $0.since : nil } ?? now
            seen[id] = (bytes, since)
            incoming[index].stalled = now.timeIntervalSince(since) >= Self.stalledAfter
        }
        receivingGrowth = seen
        if incoming != receiving { receiving = incoming }
        let folders = importer.pending()
        let ready = folders.map(\.lastPathComponent)
        if ready.count != pendingTransfers { pendingTransfers = ready.count }
        let list = folders.map { folder -> PendingImport in
            let package = BoundedRead.dataIfPresent(at: folder.appendingPathComponent(GamePackage.fileName)).flatMap { try? GamePackage.decode($0) }
            return PendingImport(name: folder.lastPathComponent, title: package?.name, bytes: package?.totalSize ?? 0,
                                 interrupted: folder.lastPathComponent == interruptedTransfer)
        }
        if list != pendingList { pendingList = list }
        guard ready.contains(where: { !triedTransfers.contains($0) && $0 != interruptedTransfer }), signingIdentity != nil, !importState.isRunning,
              !loadTest.isRunning, !gameIsOnScreen else { return }
        log.append("import of \(ready.count) transfer(s) that arrived while the app was open")
        importTransfers(automatic: true)
    }

    /// Deletes a transfer that waits to be imported, and what it holds: the player's way out of one that cannot be imported.
    public func discardTransfer(_ name: String) {
        guard SafePath.isSafeComponent(name) else { return }
        try? FileManager.default.removeItem(at: GameLayout.incomingDirectory(in: documents).appendingPathComponent(name, isDirectory: true))
        if interruptedTransfer == name {
            interruptedTransfer = nil
            ImportGuard.end(in: documents)
        }
        log.append("deleted the transfer \(name)")
        refresh()
    }

    /// Imports what waits, because the player asked: the transfer the app stopped in is tried again too.
    public func importPendingTransfers() { importTransfers(automatic: false) }

    private func importTransfers(automatic: Bool) {
        guard !importState.isRunning else { return }
        let skipped = automatic ? interruptedTransfer.map { Set([$0]) } ?? [] : []
        if !automatic { interruptedTransfer = nil }
        guard let identity = signingIdentity else {
            importState = .failed(NXPocketError(.noCertificate, "import a certificate first").detail)
            return
        }
        importState = .running(stage: text(.importing), fraction: 0, detail: "")
        let throttle = ImportProgressLog()
        let log = self.log
        Task { [importer] in
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try importer.importEach(identity: identity, skipping: skipped) { [weak self] progress in
                        // A line every few seconds in the import log, with the memory left: if the app is stopped again, the
                        // last line says where, and whether it ran out of room.
                        if let line = throttle.line(progress) { log.append(line) }
                        Task { @MainActor in
                            self?.importState = .running(stage: progress.stage.rawValue,
                                                         fraction: progress.fraction, detail: progress.detail)
                        }
                    }
                }.value
                self.triedTransfers = Set(importer.pending().map(\.lastPathComponent))
                self.refresh()
                let imported = "\(report.imported.count) \(self.text(.imported))"
                if report.refused.isEmpty {
                    self.importState = .finished(imported)
                } else {
                    // A pass that installed some games and refused others says both.
                    let refused = report.refused.map { "\($0.transfer): \(self.message(for: $0.error))" }.joined(separator: " · ")
                    self.importState = .failed(report.imported.isEmpty ? self.labelled(.importRefused, refused)
                                                                        : "\(imported) · \(self.labelled(.importRefused, refused))")
                }
            } catch {
                self.triedTransfers = Set(importer.pending().map(\.lastPathComponent))
                self.importState = .failed(self.message(for: error))
                self.log.append("import failed: \(error)")
                self.refresh()
            }
        }
    }

    public func resignAll() {
        guard !importState.isRunning, !gameIsOnScreen, let identity = signingIdentity else { return }
        let pending = gamesNeedingSignature()
        importState = .running(stage: text(.resigning), fraction: 0, detail: "")
        Task { [importer] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    for (index, game) in pending.enumerated() {
                        _ = try importer.resign(game, identity: identity)
                        await MainActor.run {
                            self.importState = .running(stage: self.text(.resigning),
                                                        fraction: Double(index + 1) / Double(max(pending.count, 1)),
                                                        detail: game.title)
                        }
                    }
                }.value
                self.refresh()
                self.importState = .finished("\(pending.count) \(self.text(.resignDone))")
            } catch {
                self.importState = .failed(self.message(for: error))
                self.refresh()
            }
        }
    }

    /// Removes a game. `includingSaves`: everything goes, its saves, its settings, its name and its logs too; otherwise they
    /// stay for when the game is sent again.
    public func remove(_ game: InstalledGame, includingSaves: Bool) {
        do {
            try GameRemoval.remove(game, includingSaves: includingSaves)
            if includingSaves {
                SaveSnapshots.removeAll(titleID: game.id, documents: documents)
                GameChoices.remove(titleID: game.id, documents: documents)
                GameLogs.removeAll(titleID: game.id, documents: documents)
            }
            log.append("removed \(game.titleID)\(includingSaves ? " with its saves, settings and logs" : ", its saves kept")")
        } catch {
            log.append("could not remove \(game.titleID): \(error.localizedDescription)")
        }
        refresh()
    }

    func updateQuickActions() {
        QuickActions.update(games, name: { name(of: $0) }, documents: documents)
    }

    // MARK: - Offloaded games

    /// Takes a game off the phone and keeps its tile, its saves, its settings and its logs.
    public func offload(_ game: InstalledGame) {
        guard !gameIsOnScreen else { return }
        let entry = OffloadedGame(titleID: game.id, name: name(of: game), version: game.version, bytes: game.byteCount, date: Date())
        do {
            try offloadStore.add(entry, iconFrom: GameArtwork.iconURL(for: game))
            remove(game, includingSaves: false)
            offloaded = offloadStore.records()
            log.append("offloaded \(game.titleID): the tile, the saves and the settings stay")
        } catch {
            log.append("could not offload \(game.titleID): \(error.localizedDescription)")
        }
    }

    public func forgetOffloaded(_ titleID: String) {
        offloadStore.remove(titleID: titleID)
        offloaded = offloadStore.records()
    }

    /// A game that came back (downloaded, or sent by the Mac) is no longer offloaded.
    func dropRestoredOffloads() {
        let here = Set(games.map(\.id))
        let gone = offloaded.filter { here.contains($0.titleID) }
        guard !gone.isEmpty else { return }
        for entry in gone { offloadStore.remove(titleID: entry.titleID) }
        offloaded = offloadStore.records()
    }

    public func saveBytes(_ game: InstalledGame) -> Int64 { GameRemoval.saveBytes(of: game) }

    // MARK: - Settings

    /// A game's settings list, the player's choices and what an env file or the launch fixes, read from disk each time so the
    /// screen shows what the next start will apply.
    public func settings(for game: InstalledGame) -> GameSettings {
        let list = LauncherSettingsList.load(for: game)
        let keys = Set(list.map(\.env))
        var locks: [String: LockedValue] = [:]
        for preset in EngineLaunchPlan.presets(game: game, documents: documents, launchEnvironment: LaunchEnvironment.values)
            where keys.contains(preset.key) {
            locks[preset.key] = preset.value
        }
        return GameSettings(list: list, choices: GameChoices.load(titleID: game.titleID.description, documents: documents),
                            locks: locks)
    }

    /// Keeps one choice and returns the settings as they now are.
    public func choose(_ env: String, _ value: String, in settings: GameSettings, for game: InstalledGame) -> GameSettings {
        var updated = settings
        guard updated.choose(env, value) else { return settings }
        return keep(updated, for: game)
    }

    public func resetSettings(_ settings: GameSettings, for game: InstalledGame) -> GameSettings {
        var updated = settings
        updated.reset()
        return keep(updated, for: game)
    }

    /// A choice that cannot be written goes to the import log, and the screen goes back to what is on disk. Only the
    /// values are the screen's: the name and the play time in the same file are read again, not overwritten with what
    /// the screen loaded when it opened.
    private func keep(_ settings: GameSettings, for game: InstalledGame) -> GameSettings {
        do {
            var stored = GameChoices.load(titleID: game.id, documents: documents)
            stored.values = settings.choices.values
            try stored.save(titleID: game.titleID.description, documents: documents)
            return settings
        } catch {
            log.append("could not keep the settings of \(game.titleID): \(error.localizedDescription)")
            return self.settings(for: game)
        }
    }

    public func setTouch(_ touch: TouchControls) {
        do {
            try touch.save(documents: documents)
            self.touch = touch
        } catch {
            log.append("could not keep the touch controls: \(error.localizedDescription)")
        }
    }

    /// The plan `play()` and the load test start from: the game's settings and the touch controls as they are now.
    private func launchPlan(for game: InstalledGame) -> EngineLaunchPlan? {
        EngineLaunchPlan.make(game: game, documents: documents, appResources: Bundle.main.resourceURL ?? documents,
                              settings: settings(for: game), touch: touch, touchHint: text(.touchHint),
                              launchEnvironment: LaunchEnvironment.values)
    }

    // MARK: - Launch

    func launchGame(_ game: InstalledGame) {
        guard !gameIsOnScreen else { return }
        // The library's copy, not the one a screen held on to: a signature made since must count.
        let game = current(game)
        guard !game.isBroken else {
            launch = .failed(game.problem.map(message(for:)) ?? text(.broken))
            return
        }
        guard let identity = signingIdentity else {
            launch = .failed(text(.certificateNeededToPlay))
            return
        }
        guard engineHost.isAvailable else {
            launch = .failed(NXPocketError(.engineMissing, UnlinkedEngineHost.reason).detail)
            return
        }
        guard let plan = launchPlan(for: game) else {
            launch = .failed(text(.noManifest))
            return
        }
        guard game.needsResign(against: identity) else {
            start(game, plan: plan)
            return
        }
        // Signing costs about a second per MB, minutes for a large game: it runs off the main thread, like an import
        // or a renewal does, so the screen keeps drawing and says what it is doing.
        guard !importState.isRunning else {
            launch = .failed(text(.busyImporting))
            return
        }
        activeTitleID = game.id
        launch = .launching("\(text(.resigning)) \(name(of: game))")
        Task { [importer] in
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try importer.resign(game, identity: identity)
                }.value
            } catch {
                self.launch = .failed(self.message(for: error))
                self.log.append("re-signing \(game.titleID) before its launch failed: \(error)")
                self.refresh()
                return
            }
            self.start(game, plan: plan)
        }
    }

    /// Loads the framework and hands it to its own host, on the main thread: the framework's initialisers and the
    /// game's view expect it. The host's early loading then runs in the background while the game's view comes up
    /// and starts the game (`FrameworkEngineHost`).
    private func start(_ game: InstalledGame, plan: EngineLaunchPlan, retrying previous: EntitlementsChoice? = nil) {
        activeTitleID = game.id
        launch = .launching(name(of: game))
        LaunchGuard.clear(in: documents)
        noteCheatsLaunch(game)
        // The saves as they are before this session: the game is not running, so the copy cannot be torn.
        if previous == nil {
            do {
                if try SaveSnapshots.take(game, name: name(of: game), device: UIDevice.current.name, documents: documents) != nil {
                    log.append("snapshot of the saves of \(game.titleID) taken before the session")
                }
            } catch {
                log.append("no snapshot of the saves of \(game.titleID): \(error.localizedDescription)")
            }
        }
        do {
            try plan.checkExecutable()
            try LaunchGuard.willLaunch(titleID: game.titleID, in: documents)
            try plan.createFolders()
            let framework = try FrameworkLoader.load(executable: plan.frameworkExecutable)
            try FrameworkLoader.verify(framework, marker: plan.imageMarker)
            log.append("launch of \(game.titleID) started")
            if let refusal = try engineHost.start(plan) {
                throw NXPocketError(.engineFailed, refusal)
            }
            if let refusal = engineHost.present() {
                throw NXPocketError(.engineFailed, refusal)
            }
        } catch {
            LaunchGuard.clear(in: documents)
            if Self.isCodeRefusal(error) {
                if previous == nil, signWithOtherEntitlements(game, after: error, then: { self.start($0, plan: plan, retrying: $1) }) {
                    return
                }
                if let previous {
                    // Both choices were refused: the first stays the default, and nothing is signed again at each tap.
                    SigningPreference.remember(previous, exhausted: true)
                }
                launch = .failed(refusalMessage(for: game, plan: plan, error: error))
            } else {
                launch = .failed(message(for: error))
                log.append("launch of \(game.titleID) failed: \(error)")
            }
            refresh()
            return
        }
        if let previous {
            // The second choice loaded where the first was refused: every game is signed so from now on.
            log.append("the \(SigningPreference.current.tag) entitlements load on this installation; the \(previous.tag) ones were refused")
        }
        // The marker stays while the game loads, so a game that kills the app on the way in shows up as a failed launch at the
        // next start, with its log. It goes when the game has been running a while (`loadedAfter`), when the player leaves it for the
        // home screen, and when the process ends by `exit()` (the game's own Quit): only a game that dies on the way in is "a launch
        // that failed". Keeping it for the whole session reported every quit and every crash of a played game as one.
        launch = .running(name(of: game))
        LaunchGuard.clearWhenTheProcessExits(in: documents)
        let loaded = game.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadedAfter) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activeTitleID == loaded, case .running = self.launch else { return }
                LaunchGuard.clear(in: self.documents)
                self.log.append("\(loaded) has been running for \(Int(Self.loadedAfter)) s: its launch is no longer watched")
            }
        }
        watchTransfers(false)
        let clock = PlayClock(titleID: game.id, documents: documents)
        clock.followScene()
        clock.resume()
        playClock = clock
        let documents = documents
        leftGame = NotificationCenter.default.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil,
                                                          queue: .main) { _ in LaunchGuard.clear(in: documents) }
    }

    private var leftGame: NSObjectProtocol?

    // MARK: - Load test

    /// Everything `play()` does before the engine takes over, on a real game, and a report of what it measured
    /// (`LoadTestReport`). It needs no engine. The framework stays loaded for the life of the process, as any loaded
    /// image does, so a second test needs a fresh launch of the app.
    public func testLoad(_ game: InstalledGame) {
        guard !gameIsOnScreen, !loadTest.isRunning else { return }
        let game = current(game)
        guard !game.isBroken else {
            loadTest = .failed(game.problem.map(message(for:)) ?? text(.broken))
            return
        }
        guard let identity = signingIdentity else {
            loadTest = .failed(text(.certificateNeededToPlay))
            return
        }
        guard let plan = launchPlan(for: game) else {
            loadTest = .failed(text(.noManifest))
            return
        }
        guard !FrameworkLoader.isLoaded(executable: plan.frameworkExecutable) else {
            loadTest = .failed("this game is already loaded in this process, and dyld would hand back that image: "
                               + "close the app from the app switcher and open it again to test once more")
            return
        }
        let needsSigning = game.needsResign(against: identity)
        if needsSigning && importState.isRunning {
            loadTest = .failed(text(.busyImporting))
            return
        }
        log.append("load test of \(game.titleID) started")
        loadTest = .running(needsSigning ? "\(text(.resigning)) \(game.title)" : text(.testLoadRunning))
        Task { [importer] in
            var signingSeconds: Double?
            if needsSigning {
                let started = Date()
                do {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try importer.resign(game, identity: identity)
                    }.value
                } catch {
                    self.finishLoadTest(game, .failed(self.message(for: error)))
                    return
                }
                signingSeconds = Date().timeIntervalSince(started)
                self.loadTest = .running(self.text(.testLoadRunning))
            }
            // Let the "loading" line reach the screen before the main thread is busy with dyld.
            await Task.yield()
            do {
                self.finishLoadTest(game, .finished(try self.loadFramework(game, plan: plan, signingSeconds: signingSeconds)))
            } catch where Self.isCodeRefusal(error) {
                let first = SigningPreference.current
                if self.signWithOtherEntitlements(game, after: error, then: { retried, _ in
                    do {
                        self.finishLoadTest(retried, .finished(try self.loadFramework(retried, plan: plan, signingSeconds: signingSeconds)))
                        self.log.append("the \(SigningPreference.current.tag) entitlements load on this installation; the \(first.tag) ones were refused")
                    } catch {
                        SigningPreference.remember(first, exhausted: true)
                        self.finishLoadTest(retried, .failed(self.refusalMessage(for: retried, plan: plan, error: error)))
                    }
                }) { return }
                self.finishLoadTest(game, .failed(self.refusalMessage(for: game, plan: plan, error: error)))
            } catch {
                self.finishLoadTest(game, .failed(self.message(for: error)))
            }
        }
    }

    /// The load itself, on the main thread like `start()`: a game's initialisers may expect it. The launch marker is
    /// written first, so a framework that kills the app while it loads shows up as a failed launch on the next start.
    private func loadFramework(_ game: InstalledGame, plan: EngineLaunchPlan, signingSeconds: Double?) throws -> LoadTestReport {
        let executableBytes = (try? FileManager.default.attributesOfItem(atPath: plan.frameworkExecutable.path))?[.size]
            as? Int64 ?? 0
        let availableBefore = MemoryBudget.availableBytes
        try plan.checkExecutable()
        try LaunchGuard.willLaunch(titleID: game.titleID, in: documents)
        defer { LaunchGuard.clear(in: documents) }
        let started = Date()
        let framework = try FrameworkLoader.load(executable: plan.frameworkExecutable)
        let loadSeconds = Date().timeIntervalSince(started)
        let markerFound = (try? FrameworkLoader.verify(framework, marker: plan.imageMarker)) != nil
        let modules = FrameworkLoader.moduleSections(of: framework, modules: game.manifest?.modules ?? [],
                                                     nroCount: game.manifest?.nroCount ?? 0)
        return LoadTestReport(signingSeconds: signingSeconds, executableBytes: executableBytes,
                              loadSeconds: loadSeconds, markerFound: markerFound,
                              marker: plan.imageMarker, modules: modules,
                              availableBefore: availableBefore,
                              availableAfter: MemoryBudget.availableBytes)
    }

    private func finishLoadTest(_ game: InstalledGame, _ state: LoadTestState) {
        loadTest = state
        switch state {
        case .finished(let report):
            for line in report.lines { log.append("load test of \(game.titleID): \(line)") }
        case .failed(let reason):
            log.append("load test of \(game.titleID) failed: \(reason)")
        default:
            break
        }
        refresh()
    }

    public func clearLoadTest() {
        guard !loadTest.isRunning else { return }
        loadTest = .idle
    }

    public func clearFailedLaunch() {
        LaunchGuard.clear(in: documents)
        failedLaunch = nil
    }

    public func quit() {
        playClock?.pause()
        LaunchGuard.clear(in: documents)
        exit(0)
    }

    /// The log of the launch that did not come back: the newest of that game.
    public var failedLaunchLog: LogFile? {
        failedLaunch.flatMap { GameLogs.latest(titleID: $0.titleID, documents: documents) }
    }
}
