import Foundation
import NXPocketKit
import NXPocketSFTP
import UIKit

/// The network sources screen's brain: whether the feature is on, the sources, the games the open one offers, and the
/// downloads, one after another, each of which can be paused or cancelled and resumed after the app was closed.
///
/// A download is `PackageDownloader` writing into `Documents/.incoming/<uuid>/`; what this adds is the queue, the
/// progress the screen shows, and the app's own lifecycle: the screen stays awake while a download runs, and going to the
/// background pauses it (iOS would suspend the connection anyway) and coming back resumes it.
@MainActor
public final class NetworkSources: ObservableObject {
    public enum Phase: Equatable {
        case queued, running, paused
        case failed(String)
    }

    public struct Transfer: Identifiable, Equatable {
        public var id: String
        public var recordID: String
        public var game: RemoteGame
        public var phase: Phase
        public var progress: DownloadProgress?
        /// What the last seconds of this download say, restarted with each run.
        public var speed = TransferSpeed()
        public var bytesPerSecond: Double { speed.bytesPerSecond }
        /// Nil while the speed is not known.
        public var secondsLeft: TimeInterval? {
            guard let progress else { return nil }
            return speed.secondsLeft(bytesLeft: progress.bytesTotal - progress.bytesDone)
        }
    }

    /// The whole queue at a glance: how far it is, how fast the running download goes, and how long everything has left (the queue
    /// is served one game at a time, so the running speed is the one every game waits on). Nil when nothing is downloading.
    public struct Overall: Equatable {
        public var count: Int
        public var fraction: Double
        public var bytesPerSecond: Double
        public var secondsLeft: TimeInterval?
    }

    static let buildsHushedKey = "sources.buildsOffHushed"

    /// The player has read it: the notice about this Mac's switch is not shown again.
    public func hushBuildsOff(_ record: SourceRecord) {
        var hushed = Set(defaults.stringArray(forKey: Self.buildsHushedKey) ?? [])
        hushed.insert(record.id)
        defaults.set(Array(hushed), forKey: Self.buildsHushedKey)
        buildsOff.removeAll { $0.id == record.id }
    }

    public var overall: Overall? {
        let active = transfers.filter { if case .failed = $0.phase { return false }; return true }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(Int64(0)) { $0 + ($1.progress?.bytesTotal ?? $1.game.totalBytes) }
        let done = active.reduce(Int64(0)) { $0 + ($1.progress?.bytesDone ?? 0) }
        let speed = active.first { $0.phase == .running }?.bytesPerSecond ?? 0
        let left = speed > 0 ? Double(max(total - done, 0)) / speed : nil
        return Overall(count: active.count, fraction: total > 0 ? min(1, Double(done) / Double(total)) : 0, bytesPerSecond: speed, secondsLeft: left)
    }

    /// A game one of the sources has, for the library to offer as "in the cloud".
    public struct CloudEntry: Identifiable, Equatable {
        public var record: SourceRecord
        public var game: RemoteGame
        public var id: String { Self.key(record.id, game.titleID) }
        static func key(_ recordID: String, _ titleID: String) -> String { "\(recordID)|\(titleID)" }
    }

    public enum Load: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    @Published public var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if !enabled { turnOff() }
        }
    }
    @Published public private(set) var games: [RemoteGame] = []
    @Published public private(set) var gamesLoad: Load = .idle
    @Published public private(set) var openRecord: SourceRecord?
    @Published public private(set) var transfers: [Transfer] = []
    @Published public private(set) var waiting: [PendingDownload] = []
    /// What every source offers, read in the background while network sources are on.
    @Published public private(set) var offered: [CloudEntry] = []
    /// The games the Macs have the dump of and have not built, with where each build stands.
    @Published public private(set) var buildable: [BuildEntry] = []
    /// Macs that said they do not let phones ask for builds, and that the player has not told us to stop mentioning.
    @Published public private(set) var buildsOff: [SourceRecord] = []
    /// Shown once, then cleared: why a request for a build did not go through.
    @Published public var buildNotice: String?
    private var buildPoll: Task<Void, Never>?
    private var lastOfferRefresh = Date.distantPast
    private var offerTask: Task<Void, Never>?

    public struct BuildEntry: Identifiable, Equatable {
        public var record: SourceRecord
        public var build: RemoteBuildable
        public var id: String { Self.key(record.id, build.titleID) }
        static func key(_ recordID: String, _ titleID: String) -> String { "\(recordID)|\(titleID)" }
    }

    /// Newer builds are downloaded and installed by themselves while the app is open. Off until the player says so.
    @Published public var autoUpdate: Bool {
        didSet {
            defaults.set(autoUpdate, forKey: Self.autoUpdateKey)
            if autoUpdate { queueUpdates(includingStopped: false) }
        }
    }
    /// Whether the app tells the player, in a notification, that downloads are done or waiting. On by default; the system's
    /// own permission is asked for the first time a download starts, not at launch.
    @Published public var notifies: Bool {
        didSet { defaults.set(notifies, forKey: Self.notifiesKey) }
    }
    /// What the library holds, for the updates: set by the model.
    public var installedGames: () -> [InstalledGame] = { [] }
    /// False while a game is on screen: nothing is replaced under it.
    public var canInstall: () -> Bool = { true }
    /// Called, when the app is not in front, once the queue has stopped: the names that finished, how many failed, how many are
    /// still waiting or paused. The model turns it into a notification in the player's language.
    public var onQueueStopped: (_ finished: [String], _ failed: Int, _ remaining: Int) -> Void = { _, _, _ in }
    /// Asked once, the first time a download starts.
    public var prepareNotifications: () -> Void = {}

    /// Saves are sent by themselves, after a game was played (the next time the app is in front with no game on screen), to every
    /// source that keeps copies. Off until the player says so.
    @Published public var autoBackupSaves: Bool {
        didSet { defaults.set(autoBackupSaves, forKey: Self.autoBackupKey) }
    }
    /// When a game starts, the sources are asked whether they hold saves from another of the player's devices that are newer than
    /// these. Off until the player says so.
    @Published public var syncSaves: Bool {
        didSet { defaults.set(syncSaves, forKey: Self.syncSavesKey) }
    }

    public enum BackupState: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(sent: Int, failed: Int, firstFailure: String?)
        case failed(String)
    }
    @Published public private(set) var backup: BackupState = .idle

    public let store: SourceStore
    public let discovery = MacDiscovery()
    let documents: URL
    /// Called when a download is whole and waiting to be imported.
    public var onDownloaded: () -> Void = {}

    static let enabledKey = "networkSourcesEnabled"
    static let autoUpdateKey = "networkAutoUpdate"
    static let notifiesKey = "networkNotifies"
    static let buildRequestsKey = "networkBuildRequests"
    static let autoBackupKey = "networkAutoBackupSaves"
    static let syncSavesKey = "networkSyncSaves"
    static let uploadedKey = "networkUploadedCopies"
    static let backedUpKey = "networkBackedUpDigests"
    private var icons: [String: UIImage] = [:]
    private var worker: Task<Void, Never>?
    private var running: (id: String, task: Task<Void, Never>)?
    private var pausedByBackground: Set<String> = []
    /// For each transfer, the sources it has already been tried on: a download that fails on the network goes on with another source
    /// that has the same build, once for each.
    private var triedRecords: [String: Set<String>] = [:]
    private var finishedNames: [String] = []
    private var failedCount = 0
    /// Set when iOS has taken the extra time it gave a download in the background: nothing new starts until the app is back.
    private var suspended = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let background: BackgroundTime
    private let isActive: () -> Bool
    private var observers: [NSObjectProtocol] = []
    private let sourceFactory: ((SourceRecord) -> PackageSource?)?
    private let keepAwake: (Bool) -> Void
    private let defaults: UserDefaults
    /// The system's background transfer service, which keeps the big files of a Mac or web download coming while the app is not in front.
    /// Nil in tests and wherever the system has none.
    private let transport: SegmentTransport?
    static let activeKey = "networkActiveTransfers"

    /// `sourceFactory` and `keepAwake` are for tests: a stand-in for the network, and for the screen's idle timer.
    public init(documents: URL, store: SourceStore? = nil, defaults: UserDefaults = .standard,
                sourceFactory: ((SourceRecord) -> PackageSource?)? = nil,
                keepAwake: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 },
                background: BackgroundTime = .system,
                transport: SegmentTransport? = BackgroundTransfers.shared,
                isActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.transport = transport
        self.background = background
        self.isActive = isActive
        self.documents = documents
        self.store = store ?? SourceStore()
        self.defaults = defaults
        self.sourceFactory = sourceFactory
        self.keepAwake = keepAwake
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        self.autoUpdate = defaults.bool(forKey: Self.autoUpdateKey)
        self.notifies = defaults.object(forKey: Self.notifiesKey) as? Bool ?? true
        self.autoBackupSaves = defaults.bool(forKey: Self.autoBackupKey)
        self.syncSaves = defaults.bool(forKey: Self.syncSavesKey)
        refreshWaiting()
        resumeInterrupted()
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willEnterForeground() }
        })
    }

    // MARK: what the sources offer

    /// Reads every source's games again, at most once a minute unless forced: the library shows the ones this iPhone lacks as
    /// downloadable. A source that cannot be reached offers nothing and says nothing here; its own screen explains.
    public func refreshOffered(force: Bool = false) {
        guard enabled, offerTask == nil, force || Date().timeIntervalSince(lastOfferRefresh) > 60 else { return }
        let records = store.records
        guard !records.isEmpty else { offered = []; return }
        let sources = records.compactMap { record in makeSource(record).map { (record, $0) } }
        offerTask = Task {
            let found = await withTaskGroup(of: (SourceRecord, [RemoteGame], (games: [RemoteBuildable], allowed: Bool)?).self) { group in
                for (record, source) in sources {
                    group.addTask {
                        let listing = try? await (source as? BuildRequesting)?.buildableListing()
                        return (record, (try? await source.games()) ?? [], listing)
                    }
                }
                var all: [(SourceRecord, [RemoteGame], (games: [RemoteBuildable], allowed: Bool)?)] = []
                for await item in group { all.append(item) }
                return all
            }
            let order = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($1.id, $0) })
            let sorted = found.sorted { (order[$0.0.id] ?? 0) < (order[$1.0.id] ?? 0) }
            self.offered = sorted.flatMap { record, games, _ in games.map { CloudEntry(record: record, game: $0) } }
            self.buildable = sorted.flatMap { record, _, listing in (listing?.games ?? []).map { BuildEntry(record: record, build: $0) } }
            let hushed = Set(self.defaults.stringArray(forKey: Self.buildsHushedKey) ?? [])
            self.buildsOff = sorted.compactMap { record, _, listing in listing?.allowed == false && !hushed.contains(record.id) ? record : nil }
            self.lastOfferRefresh = Date()
            self.offerTask = nil
            self.settleBuildRequests()
            if self.autoUpdate { self.queueUpdates(includingStopped: false) }
        }
    }

    // MARK: builds on the Mac

    /// A build asked for here: when its game shows up among the built ones it is downloaded without another touch. Kept across
    /// launches, since a build takes long.
    private var requestedBuilds: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.buildRequestsKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.buildRequestsKey) }
    }

    public func isBuildRequested(_ entry: BuildEntry) -> Bool { requestedBuilds.contains(entry.id) }

    /// Asks the Mac to build a game of its dump folder. The tile follows the build from there.
    public func requestBuild(_ entry: BuildEntry) {
        guard let source = makeSource(entry.record) as? BuildRequesting else { return }
        Task {
            do {
                try await source.requestBuild(titleID: entry.build.titleID)
                self.requestedBuilds.insert(entry.id)
                self.refreshOffered(force: true)
            } catch {
                self.buildNotice = Self.buildReason(error)
            }
        }
    }

    /// After each read: a requested game that is built now goes into the queue, and a request that ended in a failure (or that the
    /// Mac no longer knows) is dropped so the tile shows how it ended, or nothing. A build the Mac shows as not started stays
    /// requested: it may have been cancelled there, and the game then downloads if it is ever built.
    private func settleBuildRequests() {
        var requested = requestedBuilds
        for key in requested {
            if let entry = offered.first(where: { Self.key($0.record.id, $0.game.titleID) == key }) {
                download([entry.game], from: entry.record)
                requested.remove(key)
            } else if let build = buildable.first(where: { $0.id == key }) {
                if build.build.state == .failed { requested.remove(key) }
            } else {
                requested.remove(key)
            }
        }
        requestedBuilds = requested
        // While a build runs the Mac is asked again every ten seconds: the tile shows its progress.
        guard buildPoll == nil, buildable.contains(where: { $0.build.state == .queued || $0.build.state == .building }) else { return }
        buildPoll = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self.buildPoll = nil
            if !Task.isCancelled, self.enabled { self.refreshOffered(force: true) }
        }
    }

    static func buildReason(_ error: Error) -> String {
        switch error {
        case PackageSourceError.notAccepting: return "buildsRefused"
        case PackageSourceError.busy: return "buildBusy"
        case PackageSourceError.notFound: return "buildGone"
        default: return reason(error)
        }
    }

    // MARK: updates

    /// The games this iPhone has in an older build than a source offers.
    var updates: [CloudGames.Item] {
        CloudGames.items(sources: self, games: installedGames()).filter { $0.state == .updateAvailable }
    }

    /// Queues the update of every game that has one. `includingStopped` also restarts one that failed or was paused, which a
    /// press of "Update all" means and the automatic kind does not: a download the player stopped stays stopped.
    public func updateAll() { queueUpdates(includingStopped: true) }

    func queueUpdates(includingStopped: Bool) {
        guard enabled, canInstall() else { return }
        for item in updates {
            let id = Self.key(item.entry.record.id, item.entry.game.titleID)
            if !includingStopped, transfers.contains(where: { $0.id == id }) { continue }
            download([item.entry.game], from: item.entry.record)
        }
    }

    // MARK: sources

    public func open(_ record: SourceRecord) {
        openRecord = record
        reload()
    }

    public func close() {
        openRecord = nil
        games = []
        gamesLoad = .idle
    }

    public func reload() {
        guard let record = openRecord else { return }
        guard let source = makeSource(record) else {
            gamesLoad = .failed("signedOut")
            return
        }
        gamesLoad = .loading
        Task {
            do {
                let found = try await source.games()
                guard self.openRecord?.id == record.id else { return }
                self.games = found
                self.gamesLoad = .loaded
            } catch {
                guard self.openRecord?.id == record.id else { return }
                self.games = []
                self.gamesLoad = .failed(Self.reason(error))
            }
        }
    }

    public func forget(_ record: SourceRecord) {
        if openRecord?.id == record.id { close() }
        for transfer in transfers where transfer.recordID == record.id { cancel(transfer.id) }
        store.remove(record)
        offered.removeAll { $0.record.id == record.id }
    }

    /// Pairs with a Mac by the code on its screen and remembers it.
    public func pairMac(host: String, port: Int, code: String, deviceName: String, name: String) async throws -> SourceRecord {
        let paired = try await PinnedHTTPSSource.pair(host: host, port: port, code: code, deviceName: deviceName)
        return remember(paired, name: name)
    }

    /// Pairs from the QR code's link.
    public func pairMac(link: PairLink, deviceName: String) async throws -> SourceRecord {
        remember(try await PinnedHTTPSSource.pair(link: link, deviceName: deviceName), name: link.name)
    }

    /// Pairs once the player said the number matches and the Mac allowed it.
    public func pairMac(comparison: NumberPairing) async throws -> SourceRecord {
        remember(try await comparison.confirm(), name: comparison.macName)
    }

    func remember(_ paired: PairedMac, name: String) -> SourceRecord {
        // The same Mac again (same key) keeps its row: its address and token are replaced, not a second row added.
        var record = SourceRecord(kind: .mac, name: name.isEmpty ? paired.name : name, host: paired.host, port: paired.port, pin: paired.pin)
        if let known = store.records.first(where: { $0.kind == .mac && $0.pin == paired.pin }) {
            record = known
            record.host = paired.host
            record.port = paired.port
        }
        store.add(record, secret: paired.token)
        refreshOffered(force: true)
        return record
    }

    /// A Mac already paired (same key) at another address: the address is updated, nothing else.
    public func updateAddress(of known: SourceRecord, to mac: DiscoveredMac) {
        var record = known
        record.host = mac.host
        record.port = mac.port
        store.update(record)
    }

    public func saveSFTP(_ config: SFTPConfig, credential: SFTPCredential, name: String) -> SourceRecord {
        let record = SourceRecord(kind: .sftp, name: name.isEmpty ? config.host : name, host: config.host, port: config.port,
                                  pin: config.hostKey, user: config.user, folder: config.folder)
        store.add(record, secret: credential.secret)
        refreshOffered(force: true)
        return record
    }

    /// A web library the player checked works: remembered with its token, if it has one.
    public func saveWeb(url: URL, token: String, name: String) -> SourceRecord {
        let record = SourceRecord(kind: .web, name: name.isEmpty ? (url.host ?? "Web") : name, host: url.host ?? "", port: url.port ?? 443, folder: url.absoluteString)
        store.add(record, secret: token.isEmpty ? SourceStore.noToken : token)
        refreshOffered(force: true)
        return record
    }

    /// A game's icon from a source, a small PNG that passed the checks of `PNGHeader`; nil for a server that has none.
    public func icon(for titleID: String, in record: SourceRecord) async -> UIImage? {
        let key = Self.key(record.id, titleID)
        if let cached = icons[key] { return cached }
        guard let source = makeSource(record),
              let data = try? await source.icon(titleID: titleID), let image = UIImage(data: data) else { return nil }
        icons[key] = image
        return image
    }

    // MARK: downloads

    public func transfer(for titleID: String) -> Transfer? {
        guard let record = openRecord else { return nil }
        return transfers.first { $0.id == Self.key(record.id, titleID) }
    }

    func transfer(forEntry entry: CloudEntry) -> Transfer? { transfers.first { $0.id == entry.id } }

    public var isDownloading: Bool { transfers.contains { $0.phase == .running || $0.phase == .queued } }

    /// Where a waiting download stands in the queue, from 1; nil for one that is running, paused or not queued.
    public func queuePosition(of id: String) -> Int? {
        let queued = transfers.filter { $0.phase == .queued }
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return nil }
        return running == nil ? index : index + 1
    }

    public func download(_ games: [RemoteGame], from record: SourceRecord) {
        if !games.isEmpty, notifies { prepareNotifications() }
        for game in games {
            let id = Self.key(record.id, game.titleID)
            if let existing = transfers.firstIndex(where: { $0.id == id }) {
                switch transfers[existing].phase {
                case .queued, .running: continue
                case .paused, .failed: transfers[existing].phase = .queued
                }
            } else {
                transfers.append(Transfer(id: id, recordID: record.id, game: game, phase: .queued))
            }
        }
        rememberActive()
        startWorker()
    }

    public func pause(_ id: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        if running?.id == id { running?.task.cancel() } else { transfers[index].phase = .paused }
        rememberActive()
    }

    public func resume(_ id: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].phase = .queued
        rememberActive()
        startWorker()
    }

    /// The cancel: stops the download and gives the space back.
    public func cancel(_ id: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        let transfer = transfers[index]
        let doomed = running?.id == id ? running?.task : nil
        triedRecords[id] = nil
        transfers.remove(at: index)
        rememberActive()
        doomed?.cancel()
        let documents = documents
        let sourceID = store.records.first { $0.id == transfer.recordID }?.sourceID
        Task {
            // The folder is removed once the task has let go of it: a write after the removal would recreate files.
            await doomed?.value
            if let sourceID, let title = TitleID(transfer.game.titleID) {
                PackageDownloader.discard(sourceID: sourceID, titleID: title, documents: documents)
                // What the system's service had of it is forgotten too, so no part of a cancelled game stays on the phone.
                await BackgroundTransfers.shared?.discard(titleID: transfer.game.titleID)
            }
            self.refreshWaiting()
        }
    }

    /// The downloads left in `.incoming` by an earlier run, that no queue entry stands for.
    public func refreshWaiting() {
        let active = Set(transfers.compactMap { transfer in store.records.first { $0.id == transfer.recordID }?.sourceID.map { "\($0)|\(transfer.game.titleID)" } })
        waiting = PackageDownloader.pending(documents: documents).filter { !active.contains("\($0.sourceID)|\($0.titleID)") }
    }

    public func resume(_ pending: PendingDownload) {
        guard let record = store.records.first(where: { $0.sourceID == pending.sourceID }) else { return }
        let game = RemoteGame(titleID: pending.titleID, name: pending.name, version: "", packageVersion: "", minOS: "", revision: pending.revision,
                              codeBytes: 0, romfsBytes: pending.bytesTotal, aocBytes: 0)
        download([game], from: record)
        refreshWaiting()
    }

    public func discard(_ pending: PendingDownload) {
        try? FileManager.default.removeItem(at: pending.folder)
        refreshWaiting()
    }

    /// Whether a paused download can be resumed: its source is one of the remembered ones.
    public func canResume(_ pending: PendingDownload) -> Bool { store.records.contains { $0.sourceID == pending.sourceID } }

    // MARK: saves

    /// Whether a source can keep copies of saves: a Mac or an SFTP server, whatever the stand-in of a test says.
    public func canKeepSaves(_ record: SourceRecord) -> Bool { makeSource(record) is SaveDestination }

    /// Sends the saves of each game, one .zip each, to `record`. `export` makes the .zip (`ShellHostModel.exportSaves`) and the
    /// file is removed once it is sent. A game that fails does not stop the others; the first failure is reported.
    public func backUpSaves(_ games: [InstalledGame], to record: SourceRecord,
                            export: @escaping (InstalledGame) async -> Result<URL, SaveProblem>) async {
        guard case .idle = backup else { return }
        guard let destination = makeSource(record) as? SaveDestination else {
            backup = .failed("signedOut")
            return
        }
        let wanted = games.filter { !GameSaves.entries(in: $0.directory).isEmpty }
        guard !wanted.isEmpty else {
            backup = .finished(sent: 0, failed: 0, firstFailure: nil)
            return
        }
        var sent = 0, failed = 0
        var firstFailure: String?
        sending: for (index, game) in wanted.enumerated() {
            backup = .running(done: index, total: wanted.count)
            switch await export(game) {
            case .failure(let problem):
                failed += 1
                firstFailure = firstFailure ?? "\(problem)"
            case .success(let archive):
                defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
                do {
                    let stored = try await destination.store(saves: archive, titleID: game.titleID.description)
                    rememberUploaded(record: record, titleID: game.titleID.description, name: stored)
                    sent += 1
                } catch {
                    failed += 1
                    firstFailure = firstFailure ?? Self.reason(error)
                    // A source that refuses the first copy refuses the rest, for the same reason.
                    if case PackageSourceError.notAccepting = error { break sending }
                    if case PackageSourceError.unauthorized = error { break sending }
                }
            }
        }
        backup = .finished(sent: sent, failed: failed, firstFailure: firstFailure)
    }

    public func dismissBackup() { backup = .idle }

    // MARK: saves that follow the player

    /// The copies this phone sent: how it tells, among a source's copies, the ones that came from another device.
    private func rememberUploaded(record: SourceRecord, titleID: String, name: String) {
        guard !name.isEmpty else { return }
        var all = defaults.stringArray(forKey: Self.uploadedKey) ?? []
        all.append("\(record.id)|\(titleID)|\(name)")
        defaults.set(Array(all.suffix(300)), forKey: Self.uploadedKey)
    }

    public func isMine(_ copy: RemoteSaveCopy, titleID: String, on record: SourceRecord) -> Bool {
        (defaults.stringArray(forKey: Self.uploadedKey) ?? []).contains("\(record.id)|\(titleID)|\(copy.name)")
    }

    /// The saves a game had when they were last sent, or last put back from a copy: a game whose saves still look like that has
    /// nothing new to send. A digest of names, sizes and dates (`SaveSnapshots.digest`).
    /// A copy the player was shown and did not take: it is not offered again.
    public func markSeen(_ copy: RemoteSaveCopy, titleID: String, on record: SourceRecord) {
        rememberUploaded(record: record, titleID: titleID, name: copy.name)
    }

    func lastBackedUp(_ titleID: String) -> String? { (defaults.dictionary(forKey: Self.backedUpKey) as? [String: String])?[titleID] }

    func markBackedUp(_ titleID: String, digest: String?) {
        var all = (defaults.dictionary(forKey: Self.backedUpKey) as? [String: String]) ?? [:]
        all[titleID] = digest
        defaults.set(all, forKey: Self.backedUpKey)
    }

    /// The copies of a game's saves on the sources that give them back, a source that does not answer in `seconds` left out.
    public func remoteCopies(of titleID: String, seconds: Double = 5) async -> [(record: SourceRecord, copies: [RemoteSaveCopy])] {
        guard enabled else { return [] }
        let candidates = store.records.compactMap { record in (makeSource(record) as? SaveSource).map { (record, $0) } }
        return await withTaskGroup(of: (SourceRecord, [RemoteSaveCopy])?.self) { group in
            for (record, source) in candidates {
                group.addTask {
                    await withTaskGroup(of: [RemoteSaveCopy]?.self) { race in
                        race.addTask { try? await source.saveCopies(titleID: titleID) }
                        race.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
                        let first = await race.next() ?? nil
                        race.cancelAll()
                        return first.map { (record, $0) } ?? nil
                    }
                }
            }
            var found: [(SourceRecord, [RemoteSaveCopy])] = []
            for await item in group { if let item, !item.1.isEmpty { found.append(item) } }
            let order = Dictionary(uniqueKeysWithValues: store.records.enumerated().map { ($1.id, $0) })
            return found.sorted { (order[$0.0.id] ?? 0) < (order[$1.0.id] ?? 0) }.map { (record: $0.0, copies: $0.1) }
        }
    }

    /// Downloads one copy into a folder of its own under `temporary` and returns the file; the caller removes the folder.
    public func fetchCopy(_ copy: RemoteSaveCopy, of titleID: String, from record: SourceRecord, temporary: URL) async throws -> URL {
        guard let source = makeSource(record) as? SaveSource else { throw PackageSourceError.notFound }
        let folder = temporary.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(copy.name)
        do { try await source.fetchSaveCopy(titleID: titleID, name: copy.name, to: file) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return file
    }

    /// Sends, to every source that keeps copies, the saves of the games played since they were last sent. Quiet: nothing is shown,
    /// a failure is logged. Returns how many copies went.
    @discardableResult
    func backUpPlayedGames(_ games: [InstalledGame], to records: [SourceRecord],
                           export: @escaping (InstalledGame) async -> Result<URL, SaveProblem>) async -> Int {
        var sent = 0
        for game in games {
            guard let digest = SaveSnapshots.digest(of: game), digest != lastBackedUp(game.id) else { continue }
            guard case .success(let archive) = await export(game) else { continue }
            defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            var stored = false
            for record in records {
                guard let destination = makeSource(record) as? SaveDestination else { continue }
                do {
                    let name = try await destination.store(saves: archive, titleID: game.id)
                    rememberUploaded(record: record, titleID: game.id, name: name)
                    stored = true
                    sent += 1
                } catch {
                    log("saves of \(game.titleID) not sent to \(record.name): \(Self.reason(error))")
                }
            }
            if stored { markBackedUp(game.id, digest: digest) }
        }
        return sent
    }

    // MARK: the worker

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !self.suspended, let next = self.transfers.first(where: { $0.phase == .queued }) {
                await self.run(next.id)
            }
            self?.worker = nil
            self?.updateIdleTimer()
            self?.queueStopped()
        }
    }

    private func run(_ id: String) async {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        let transfer = transfers[index]
        guard let record = store.records.first(where: { $0.id == transfer.recordID }), let source = makeSource(record) else {
            transfers[index].phase = .failed("signedOut")
            return
        }
        transfers[index].phase = .running
        transfers[index].speed.reset()
        // Other sources that hold this very build: a transfer one of them left unfinished is taken over (`PackageDownloader`).
        let others = offered.filter { $0.game.titleID == transfer.game.titleID && $0.game.revision == transfer.game.revision && $0.record.id != record.id }
            .compactMap(\.record.sourceID)
        let documents = documents
        // An update starts from the image this phone holds: only the blocks that differ come over the network.
        let held = Dictionary(uniqueKeysWithValues: installedGames().compactMap { game -> (String, URL)? in
            FileManager.default.fileExists(atPath: game.romfsURL.path) ? (game.titleID.description, game.romfsURL) : nil
        })
        let downloader = PackageDownloader(documents: documents, availableSpace: { VolumeSpace.available(documents: documents) },
                                           reference: { held[$0.description] })
        let task = Task { [weak self] in
            do {
                _ = try await downloader.download(transfer.game, from: source, alsoFrom: others) { progress in
                    Task { @MainActor in self?.report(id, progress) }
                }
                self?.finished(id)
            } catch {
                self?.failed(id, error)
            }
        }
        running = (id, task)
        updateIdleTimer()
        await task.value
        running = nil
        updateIdleTimer()
    }

    private func report(_ id: String, _ progress: DownloadProgress) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].progress = progress
        transfers[index].speed.add(bytes: progress.bytesDone)
    }

    var log: (String) -> Void = { _ in }

    private func finished(_ id: String) {
        triedRecords[id] = nil
        if let name = transfers.first(where: { $0.id == id })?.game.name { finishedNames.append(name) }
        transfers.removeAll { $0.id == id }
        rememberActive()
        lastOfferRefresh = .distantPast
        refreshWaiting()
        onDownloaded()
    }

    private func failed(_ id: String, _ error: Error) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        if let refusal = error as? NXPocketError, refusal.code == .cancelled {
            transfers[index].phase = .paused
        } else if let alternative = alternativeSource(for: transfers[index], after: error) {
            // The source went away (a Mac that fell asleep): the same build is on another one, and the download goes on there.
            triedRecords[id, default: []].insert(transfers[index].recordID)
            log("\(transfers[index].game.name): continuing on \(alternative.record.name)")
            transfers[index].recordID = alternative.record.id
            transfers[index].game = alternative.game
            transfers[index].phase = .queued
        } else {
            transfers[index].phase = .failed(Self.reason(error))
            failedCount += 1
        }
        rememberActive()
        refreshWaiting()
    }

    /// Another source that offers the same build as `transfer`, not tried yet, when `error` is the network's and not the package's.
    private func alternativeSource(for transfer: Transfer, after error: Error) -> CloudEntry? {
        let network: Bool
        if let failure = error as? NXPocketError { network = failure.code == .transferFailed }
        else if case PackageSourceError.unreachable = error { network = true }
        else { network = false }
        return network ? alternativeEntry(for: transfer) : nil
    }

    private func alternativeEntry(for transfer: Transfer) -> CloudEntry? {
        let tried = triedRecords[transfer.id, default: []].union([transfer.recordID])
        return offered.first { $0.game.titleID == transfer.game.titleID && $0.game.revision == transfer.game.revision && !tried.contains($0.record.id) }
    }

    /// The queue has nothing left to run: the player is told if the app is not in front, and the extra time is given back.
    private func queueStopped() {
        let names = finishedNames, failures = failedCount
        finishedNames = []
        failedCount = 0
        endBackgroundTask()
        guard notifies, !names.isEmpty || failures > 0, !isActive() else { return }
        let remaining = transfers.filter { $0.phase == .queued || $0.phase == .paused }.count
        onQueueStopped(names, failures, remaining)
    }

    // MARK: lifecycle

    /// iOS suspends the app, and its connection, a moment after it leaves the front. The download asks for the time iOS allows
    /// (about thirty seconds): a small one finishes and the player is told, a large one is paused when the time is up.
    private func enteredBackground() {
        guard running != nil || transfers.contains(where: { $0.phase == .queued }), backgroundTask == .invalid else { return }
        backgroundTask = background.begin { [weak self] in
            MainActor.assumeIsolated { self?.backgroundTimeEnded() }
        }
    }

    func backgroundTimeEnded() {
        // A download whose files are with the system's service does not need the app: it is left running, and the app is woken when the
        // service has something to hand over.
        if let current = running, let transfer = transfers.first(where: { $0.id == current.id }), goesOnInBackground(transfer.recordID) {
            endBackgroundTask()
            return
        }
        suspended = true
        if let current = running {
            pausedByBackground.insert(current.id)
            current.task.cancel()
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        background.end(backgroundTask)
        backgroundTask = .invalid
    }

    private func willEnterForeground() {
        suspended = false
        endBackgroundTask()
        let ids = pausedByBackground
        pausedByBackground = []
        for id in ids { resume(id) }
        startWorker()
        refreshWaiting()
        refreshOffered()
    }

    private func turnOff() {
        discovery.stop()
        buildPoll?.cancel()
        buildPoll = nil
        running?.task.cancel()
        for transfer in transfers where transfer.phase == .queued { pause(transfer.id) }
    }

    private func updateIdleTimer() { keepAwake(running != nil) }

    /// The client for a source, for the screens that read from it themselves (a repair).
    func source(for record: SourceRecord) -> PackageSource? { makeSource(record) }

    private func makeSource(_ record: SourceRecord) -> PackageSource? {
        guard let source = sourceFactory?(record) ?? store.source(for: record) else { return nil }
        // A Mac and a web server speak plain HTTPS: their big files are handed to the system's transfer service. An SFTP connection
        // does not survive the app being suspended, so it stays as it was.
        if let transport, let readable = source as? BackgroundReadable { return SegmentedSource(inner: readable, transport: transport) }
        return source
    }

    /// Whether this source's downloads go on while the app is away.
    private func goesOnInBackground(_ recordID: String) -> Bool {
        // A stand-in source (a test's) is never one that goes through the service.
        guard transport != nil, sourceFactory == nil, let kind = store.records.first(where: { $0.id == recordID })?.kind else { return false }
        return kind == .mac || kind == .web
    }

    /// The downloads that were asked for and not finished, for the next start to go on with if the system stopped the app meanwhile
    /// (`resumeInterrupted`). Only those whose files come over the system's service: the others stop with the app.
    private func rememberActive() {
        let ids = transfers.filter { ($0.phase == .queued || $0.phase == .running) && goesOnInBackground($0.recordID) }.map(\.id)
        defaults.set(ids, forKey: Self.activeKey)
    }

    /// The system started the app again because its service has something for it, or the player opened it after the system stopped it
    /// in the middle of a download: the downloads that were running go on, from the segments that finished meanwhile.
    public func resumeInterrupted() {
        guard enabled, let service = BackgroundTransfers.shared, transport != nil else { return }
        let ids = Set(defaults.stringArray(forKey: Self.activeKey) ?? [])
        guard !ids.isEmpty else { return }
        Task {
            guard await service.hasWork() else { return }
            for pending in self.waiting {
                guard let record = self.store.records.first(where: { $0.sourceID == pending.sourceID }),
                      ids.contains(Self.key(record.id, pending.titleID)) else { continue }
                self.resume(pending)
            }
        }
    }

    static func key(_ recordID: String, _ titleID: String) -> String { "\(recordID)|\(titleID)" }

    /// A short code the screen turns into the player's words: what went wrong with a source, not how.
    static func reason(_ error: Error) -> String {
        switch error {
        case PackageSourceError.unauthorized: return "signedOut"
        case PackageSourceError.untrusted: return "keyChanged"
        case PackageSourceError.unreachable(let detail), PackageSourceError.malformed(let detail): return detail
        case PackageSourceError.notAccepting: return "savesRefused"
        case PackageSourceError.noRoom: return "noRoom"
        case PackageSourceError.busy: return "rebuilding"
        case PackageSourceError.notFound: return "notFound"
        case PackageSourceError.changed: return "changed"
        case let refusal as NXPocketError: return refusal.detail
        default: return error.localizedDescription
        }
    }
}

/// The time iOS gives an app that has just left the front. A stand-in for tests, which cannot ask UIKit for it.
public struct BackgroundTime {
    /// Starts the grace period; the closure runs when it is over.
    public var begin: (@escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    public var end: (UIBackgroundTaskIdentifier) -> Void

    public init(begin: @escaping (@escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier, end: @escaping (UIBackgroundTaskIdentifier) -> Void) {
        self.begin = begin
        self.end = end
    }

    @MainActor
    public static let system = BackgroundTime(
        begin: { expired in UIApplication.shared.beginBackgroundTask(withName: "downloads", expirationHandler: expired) },
        end: { UIApplication.shared.endBackgroundTask($0) })
}
