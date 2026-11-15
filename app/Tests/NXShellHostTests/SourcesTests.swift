import NXPocketKit
import NXPocketSFTP
import XCTest

@testable import NXShellHost

/// A keychain that lives in a dictionary, and can be made to refuse as some stores' do.
final class FakeKeychain: SecretKeeper {
    var items: [String: String] = [:]
    var refuses = false
    func store(_ secret: String, account: String) throws {
        if refuses { throw KeychainRefusal(status: -34018, account: account) }
        items[account] = secret
    }
    func load(account: String) -> String? { items[account] }
    func remove(account: String) { items[account] = nil }
}

/// A source that fails or stalls, for the queue's sake: the download itself is tested in the core package.
struct StubSource: PackageSource {
    enum Behaviour { case unreachable, stall, unauthorized }
    var sourceID = "mac-stubstubstubstub0"
    var behaviour: Behaviour
    var offered: [RemoteGame] = []

    func games() async throws -> [RemoteGame] { offered }
    func listing(titleID: String) async throws -> RemotePackageListing {
        switch behaviour {
        case .unreachable: throw PackageSourceError.unreachable("no route to the Mac")
        case .unauthorized: throw PackageSourceError.unauthorized
        case .stall:
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw PackageSourceError.unreachable("stalled")
        }
    }
    func read(titleID: String, revision: String, path: String, offset: UInt64) async throws -> RemoteBody { throw PackageSourceError.notFound }
    func icon(titleID: String) async throws -> Data? { nil }
}

/// A destination for copies of saves that says what it was given, or refuses.
final class SaveStub: PackageSource, SaveDestination, SaveSource, @unchecked Sendable {
    var sourceID = "mac-stubstubstubstub0"
    var refuses: PackageSourceError?
    private(set) var stored: [(titleID: String, existed: Bool)] = []
    var copies: [RemoteSaveCopy] = []
    func games() async throws -> [RemoteGame] { [] }
    func listing(titleID: String) async throws -> RemotePackageListing { throw PackageSourceError.notFound }
    func read(titleID: String, revision: String, path: String, offset: UInt64) async throws -> RemoteBody { throw PackageSourceError.notFound }
    func icon(titleID: String) async throws -> Data? { nil }
    @discardableResult
    func store(saves archive: URL, titleID: String) async throws -> String {
        if let refuses { throw refuses }
        stored.append((titleID, FileManager.default.fileExists(atPath: archive.path)))
        return SaveUpload.fileName(at: Date(timeIntervalSince1970: 1_700_000_000 + Double(stored.count)))
    }
    func saveCopies(titleID: String) async throws -> [RemoteSaveCopy] { copies }
    func fetchSaveCopy(titleID: String, name: String, to destination: URL) async throws {
        try (SaveUpload.zipMagic + Data("saves".utf8)).write(to: destination)
    }
}

/// A Mac that has a game to build, then has built it.
final class BuildStub: PackageSource, BuildRequesting, @unchecked Sendable {
    var sourceID = "mac-stubstubstubstub0"
    var built: [RemoteGame] = []
    var toBuild: [RemoteBuildable] = []
    var refuses: PackageSourceError?
    var allowed = true
    private(set) var requested: [String] = []
    func games() async throws -> [RemoteGame] { built }
    func listing(titleID: String) async throws -> RemotePackageListing { throw PackageSourceError.notFound }
    func read(titleID: String, revision: String, path: String, offset: UInt64) async throws -> RemoteBody { throw PackageSourceError.notFound }
    func icon(titleID: String) async throws -> Data? { nil }
    func buildable() async throws -> [RemoteBuildable] { toBuild }
    func buildableListing() async throws -> (games: [RemoteBuildable], allowed: Bool) { (allowed ? toBuild : [], allowed) }
    func requestBuild(titleID: String) async throws {
        if let refuses { throw refuses }
        requested.append(titleID)
    }
}

@MainActor
final class SourceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "nxpocket-sources-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func record(kind: SourceRecord.Kind = .mac) -> SourceRecord {
        kind == .mac ? SourceRecord(kind: .mac, name: "My Mac", host: "192.168.1.5", port: 49217, pin: String(repeating: "ab", count: 32))
                     : SourceRecord(kind: .sftp, name: "Seedbox", host: "box.example", port: 2222, pin: String(repeating: "cd", count: 32), user: "player",
                                    folder: "/home/player/builds")
    }

    func testTheSecretIsInTheKeychainAndNotInThePreferences() throws {
        let keychain = FakeKeychain()
        let store = SourceStore(defaults: defaults, keychain: keychain)
        let mac = record()
        store.add(mac, secret: "the-token-is-secret")

        XCTAssertEqual(keychain.items[mac.id], "the-token-is-secret")
        let saved = try XCTUnwrap(defaults.data(forKey: "networkSources"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("the-token-is-secret"))
        XCTAssertEqual(SourceStore(defaults: defaults, keychain: keychain).records, [mac], "the description comes back after a restart")
        XCTAssertEqual(SourceStore(defaults: defaults, keychain: keychain).secret(for: mac), "the-token-is-secret")
        XCTAssertFalse(store.secretsInMemoryOnly)
    }

    func testAKeychainThatRefusesKeepsTheSecretForTheRunOnly() throws {
        let keychain = FakeKeychain()
        keychain.refuses = true
        let store = SourceStore(defaults: defaults, keychain: keychain)
        let mac = record()
        store.add(mac, secret: "kept-in-memory")

        XCTAssertTrue(store.secretsInMemoryOnly, "the screen says so")
        XCTAssertEqual(store.secret(for: mac), "kept-in-memory")
        XCTAssertTrue(keychain.items.isEmpty)
        let saved = String(decoding: try XCTUnwrap(defaults.data(forKey: "networkSources")), as: UTF8.self)
        XCTAssertFalse(saved.contains("kept-in-memory"), "never a file as a fallback")
        XCTAssertNil(SourceStore(defaults: defaults, keychain: keychain).secret(for: mac), "and gone with the run")
        XCTAssertNil(SourceStore(defaults: defaults, keychain: keychain).source(for: mac), "a source without its secret is not usable")
    }

    func testForgettingASourceForgetsItsSecret() {
        let keychain = FakeKeychain()
        let store = SourceStore(defaults: defaults, keychain: keychain)
        let nas = record(kind: .sftp)
        store.add(nas, secret: SFTPCredential(password: "password").secret)
        store.remove(nas)

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(keychain.items.isEmpty)
        XCTAssertTrue(SourceStore(defaults: defaults, keychain: keychain).records.isEmpty)
    }

    func testEachKindOfSourceMakesItsOwnClient() {
        let store = SourceStore(defaults: defaults, keychain: FakeKeychain())
        let mac = record(), nas = record(kind: .sftp)
        store.add(mac, secret: String(repeating: "0", count: 64))
        store.add(nas, secret: SFTPCredential(password: "password").secret)

        XCTAssertTrue(store.source(for: mac) is PinnedHTTPSSource)
        XCTAssertTrue(store.source(for: nas) is SFTPSource)
        XCTAssertEqual(mac.sourceID, store.source(for: mac)?.sourceID)
        XCTAssertEqual(nas.sourceID, store.source(for: nas)?.sourceID)
        XCTAssertNotEqual(mac.sourceID, nas.sourceID)
    }

    func testAnSFTPSourceKeepsItsServerKeyAndFolderAndNothingSecret() throws {
        let nas = record(kind: .sftp)
        let back = try JSONDecoder().decode(SourceRecord.self, from: try JSONEncoder().encode(nas))
        XCTAssertEqual(back.sftpConfig, SFTPConfig(host: "box.example", port: 2222, user: "player", hostKey: String(repeating: "cd", count: 32),
                                                   folder: "/home/player/builds"))
        let store = SourceStore(defaults: defaults, keychain: FakeKeychain())
        store.add(nas, secret: SFTPCredential(password: "hunter2").secret)
        let saved = String(decoding: defaults.data(forKey: "networkSources") ?? Data(), as: UTF8.self)
        XCTAssertFalse(saved.contains("hunter2"), "the password is in the keychain, not in the preferences")
    }

    func testASecretThatIsNotACredentialMakesNoSFTPSource() {
        let store = SourceStore(defaults: defaults, keychain: FakeKeychain())
        let nas = record(kind: .sftp)
        store.add(nas, secret: "just a password with no wrapper")
        XCTAssertNil(store.source(for: nas))
    }
}

@MainActor
final class NetworkSourcesTests: XCTestCase {
    private var documents: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private var store: SourceStore!
    private var mac: SourceRecord!
    private var awake: [Bool] = []

    override func setUpWithError() throws {
        documents = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: documents.appendingPathComponent(".incoming"), withIntermediateDirectories: true)
        suite = "nxpocket-net-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = SourceStore(defaults: defaults, keychain: FakeKeychain())
        mac = SourceRecord(kind: .mac, name: "My Mac", host: "192.168.1.5", port: 49217, pin: String(repeating: "ab", count: 32))
        store.add(mac, secret: String(repeating: "0", count: 64))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: documents)
    }

    /// iOS gives no extra time: the grace period is over as soon as it begins.
    private static let noGrace = BackgroundTime(begin: { expired in
        Task { @MainActor in expired() }
        return UIBackgroundTaskIdentifier(rawValue: 1)
    }, end: { _ in })

    private func sources(_ behaviour: StubSource.Behaviour, offered: [RemoteGame] = [], background: BackgroundTime = noGrace,
                         isActive: @escaping () -> Bool = { true }) -> NetworkSources {
        NetworkSources(documents: documents, store: store, defaults: defaults,
                       sourceFactory: { _ in StubSource(sourceID: self.mac.sourceID ?? "", behaviour: behaviour, offered: offered) },
                       keepAwake: { [unowned self] in self.awake.append($0) }, background: background, isActive: isActive)
    }

    /// A game installed here in build 1, as `LibraryStatus` reads it: its folder holds the `package.json` whose hash is the revision.
    private func installed(_ titleID: String = "0100111000200000", withSaves: Bool = false) throws -> InstalledGame {
        let folder = documents.appendingPathComponent("games/\(titleID)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = GamePackage(titleID: TitleID(titleID)!, name: "Fixture", version: "1", packageVersion: "1", framework: "DmGame\(titleID).framework",
                                  chain: "b-3f9a2c", minOS: "26.0", romfsID: "", romfsSize: 100, aocSize: 0, files: [], createdBy: "tests")
        try package.data().write(to: folder.appendingPathComponent("package.json"))
        if withSaves {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("save"), withIntermediateDirectories: true)
            try Data("progress".utf8).write(to: folder.appendingPathComponent("save/progress.dat"))
        }
        return InstalledGame(titleID: TitleID(titleID)!, directory: folder, package: package)
    }

    private func newer(_ titleID: String = "0100111000200000") -> RemoteGame {
        RemoteGame(titleID: titleID, name: "Fixture", version: "2", packageVersion: "2", minOS: "26.0",
                   revision: String(repeating: "b", count: 64), codeBytes: 1, romfsBytes: 100, aocBytes: 0)
    }

    private func offered(_ net: NetworkSources) async throws {
        net.enabled = true
        net.refreshOffered(force: true)
        try await wait("offers read") { !net.offered.isEmpty }
    }

    private func wait(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), what)
    }

    private var game: RemoteGame { .init(titleID: "0100111000200000", name: "Fixture", version: "1", packageVersion: "1", minOS: "26.0",
                                         revision: String(repeating: "a", count: 64), codeBytes: 1, romfsBytes: 100, aocBytes: 0) }

    func testPairingAgainWithTheSameMacKeepsItsRowAndTakesTheNewAddressAndToken() throws {
        let net = sources(.unreachable)
        let again = net.remember(PairedMac(host: "mac.local", port: 50000, pin: mac.pin ?? "", token: String(repeating: "1", count: 64), name: "My Mac"),
                                 name: "My Mac")
        XCTAssertEqual(again.id, mac.id, "the row, its cloud tiles and its downloads stay")
        XCTAssertEqual(store.records.filter { $0.kind == .mac }.count, 1)
        let kept = try XCTUnwrap(store.records.first)
        XCTAssertEqual(kept.host, "mac.local")
        XCTAssertEqual(kept.port, 50000)
        XCTAssertEqual(store.secret(for: kept), String(repeating: "1", count: 64))
    }

    func testNetworkSourcesAreOffUntilTheyAreTurnedOn() {
        XCTAssertFalse(sources(.unreachable).enabled)
        XCTAssertFalse(UserDefaults(suiteName: suite)!.bool(forKey: NetworkSources.enabledKey))
        let on = sources(.unreachable)
        on.enabled = true
        XCTAssertTrue(sources(.unreachable).enabled, "the choice is remembered")
        on.enabled = false
        XCTAssertFalse(sources(.unreachable).enabled)
    }

    func testASourceThatCannotBeReachedShowsWhyAndCanBeTriedAgain() async throws {
        let net = sources(.unreachable)
        net.download([game], from: mac)

        try await wait("the download failed") { if case .failed = net.transfers.first?.phase { return true }; return false }
        guard case .failed(let reason)? = net.transfers.first?.phase else { return XCTFail("no failure") }
        XCTAssertEqual(reason, "no route to the Mac")
        net.resume(net.transfers[0].id)
        XCTAssertEqual(net.transfers.first?.phase, .queued)
    }

    func testARefusedTokenSaysToPairAgain() async throws {
        let net = sources(.unauthorized)
        net.download([game], from: mac)
        try await wait("refused") { if case .failed = net.transfers.first?.phase { return true }; return false }
        XCTAssertEqual(net.transfers.first?.phase, .failed("signedOut"))
    }

    func testPausingAStalledDownloadKeepsItAndTheScreenSleepsAgain() async throws {
        let net = sources(.stall)
        net.download([game], from: mac)
        try await wait("running") { net.transfers.first?.phase == .running }
        XCTAssertEqual(awake.last, true, "the screen stays awake while a download runs")

        net.pause(net.transfers[0].id)

        try await wait("paused") { net.transfers.first?.phase == .paused }
        try await wait("the screen may sleep") { self.awake.last == false }
    }

    func testCancellingARunningDownloadRemovesItAndItsFolder() async throws {
        let net = sources(.stall)
        net.download([game], from: mac)
        try await wait("running") { net.transfers.first?.phase == .running }
        // What an earlier checkpoint left in the transfer folder.
        let folder = documents.appendingPathComponent(".incoming/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DownloadJournal(sourceID: mac.sourceID ?? "", titleID: game.titleID, revision: game.revision).write(in: folder)

        net.cancel(net.transfers[0].id)

        XCTAssertTrue(net.transfers.isEmpty)
        try await wait("the folder is gone") { !FileManager.default.fileExists(atPath: folder.path) }
    }

    func testGoingToTheBackgroundPausesAndComingBackResumes() async throws {
        let net = sources(.stall)
        net.download([game], from: mac)
        try await wait("running") { net.transfers.first?.phase == .running }

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await wait("paused in the background") { net.transfers.first?.phase == .paused }

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await wait("running again") { net.transfers.first?.phase == .running || net.transfers.first?.phase == .queued }
        net.cancel(net.transfers[0].id)
    }

    func testForgettingASourceCancelsItsDownloads() async throws {
        let net = sources(.stall)
        net.download([game], from: mac)
        try await wait("running") { net.transfers.first?.phase == .running }

        net.forget(mac)

        XCTAssertTrue(net.transfers.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testAPausedDownloadFromAnEarlierRunIsOfferedForItsSource() throws {
        let folder = documents.appendingPathComponent(".incoming/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package: [String: Any] = ["schema": 1, "title_id": game.titleID, "name": "Fixture", "version": "1", "package_version": "1",
                                      "framework": "DmGame\(game.titleID).framework", "chain": "b-3f9a2c", "min_os": "26.0",
                                      "romfs_id": "", "romfs_size": 4000, "aoc_size": 0, "files": [], "created_by": "tests"]
        try JSONSerialization.data(withJSONObject: package).write(to: folder.appendingPathComponent("package.json"))
        try Data(count: 1000).write(to: folder.appendingPathComponent("romfs.img"))
        try DownloadJournal(sourceID: mac.sourceID ?? "", titleID: game.titleID, revision: game.revision).write(in: folder)

        let net = sources(.stall)

        XCTAssertEqual(net.waiting.map(\.titleID), [game.titleID])
        XCTAssertTrue(net.canResume(net.waiting[0]))
        XCTAssertGreaterThanOrEqual(net.waiting[0].bytesDone, 1000)
        XCTAssertTrue(IncomingTransfers.receiving(documents: documents).isEmpty, "a download is not shown as a transfer from the Mac")
        net.discard(net.waiting[0])
        XCTAssertTrue(net.waiting.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testADownloadWhoseSourceWasForgottenCannotBeResumed() throws {
        let folder = documents.appendingPathComponent(".incoming/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package: [String: Any] = ["schema": 1, "title_id": game.titleID, "name": "Fixture", "version": "1", "package_version": "1",
                                      "framework": "DmGame\(game.titleID).framework", "chain": "b-3f9a2c", "min_os": "26.0",
                                      "romfs_id": "", "romfs_size": 4000, "aoc_size": 0, "files": [], "created_by": "tests"]
        try JSONSerialization.data(withJSONObject: package).write(to: folder.appendingPathComponent("package.json"))
        try DownloadJournal(sourceID: "mac-someone-else", titleID: game.titleID, revision: game.revision).write(in: folder)

        let net = sources(.stall)

        XCTAssertEqual(net.waiting.count, 1)
        XCTAssertFalse(net.canResume(net.waiting[0]), "only the player can throw it away: its space is theirs")
    }

    // MARK: updates, queue, notifications, backups

    func testUpdateAllQueuesTheGamesThatHaveANewerBuild() async throws {
        let net = sources(.stall, offered: [newer()])
        let have = try installed()
        net.installedGames = { [have] }
        try await offered(net)
        XCTAssertEqual(net.updates.map(\.entry.game.titleID), ["0100111000200000"])
        net.updateAll()
        XCTAssertEqual(net.transfers.map(\.game.titleID), ["0100111000200000"])
        net.cancel(net.transfers[0].id)
    }

    func testAutomaticUpdatesAreOffUntilTurnedOnAndThenQueueTheNewerBuilds() async throws {
        let net = sources(.stall, offered: [newer()])
        let have = try installed()
        net.installedGames = { [have] }
        try await offered(net)
        XCTAssertFalse(net.autoUpdate)
        XCTAssertTrue(net.transfers.isEmpty, "nothing downloads by itself until the player says so")
        net.autoUpdate = true
        XCTAssertEqual(net.transfers.count, 1)
        XCTAssertTrue(sources(.stall).autoUpdate, "the choice is remembered")
        net.cancel(net.transfers[0].id)
        net.autoUpdate = false
        net.refreshOffered(force: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(net.transfers.isEmpty)
    }

    func testAnAutomaticUpdateLeavesAStoppedDownloadStoppedAndNothingIsInstalledUnderAGame() async throws {
        let net = sources(.stall, offered: [newer()])
        let have = try installed()
        net.installedGames = { [have] }
        try await offered(net)
        net.canInstall = { false }
        net.updateAll()
        XCTAssertTrue(net.transfers.isEmpty, "a game is on screen")
        net.canInstall = { true }
        net.updateAll()
        let id = try XCTUnwrap(net.transfers.first?.id)
        net.pause(id)
        try await wait("paused") { net.transfers.first?.phase == .paused }
        net.queueUpdates(includingStopped: false)
        XCTAssertEqual(net.transfers.first?.phase, .paused, "the player stopped it")
        net.cancel(id)
    }

    func testWaitingDownloadsKnowTheirPlaceInTheQueue() async throws {
        let net = sources(.stall)
        let games = ["0100111000200000", "0100111000300000", "0100111000400000"].map { id in
            RemoteGame(titleID: id, name: id, version: "1", packageVersion: "1", minOS: "26.0", revision: String(repeating: "a", count: 64),
                       codeBytes: 1, romfsBytes: 100, aocBytes: 0)
        }
        net.download(games, from: mac)
        try await wait("the first runs") { net.transfers.first?.phase == .running }
        XCTAssertNil(net.queuePosition(of: net.transfers[0].id))
        XCTAssertEqual(net.queuePosition(of: net.transfers[1].id), 1)
        XCTAssertEqual(net.queuePosition(of: net.transfers[2].id), 2)
        for transfer in net.transfers { net.cancel(transfer.id) }
    }

    func testADownloadKeepsRunningInTheBackgroundUntilIOSTakesTheTimeBack() async throws {
        var expire: (@Sendable () -> Void)?
        var ended = 0
        let grace = BackgroundTime(begin: { expired in expire = expired; return UIBackgroundTaskIdentifier(rawValue: 7) }, end: { _ in ended += 1 })
        let net = sources(.stall, background: grace)
        net.download([game], from: mac)
        try await wait("running") { net.transfers.first?.phase == .running }

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(net.transfers.first?.phase, .running, "the time iOS allows is used")

        expire?()
        try await wait("paused when the time is up") { net.transfers.first?.phase == .paused }
        XCTAssertEqual(ended, 1)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await wait("running again") { net.transfers.first?.phase == .running || net.transfers.first?.phase == .queued }
        net.cancel(net.transfers[0].id)
    }

    func testThePlayerIsToldWhenTheQueueStopsOnlyWhileTheAppIsNotInFront() async throws {
        var told: [(finished: [String], failed: Int, remaining: Int)] = []
        let away = sources(.unreachable, isActive: { false })
        away.onQueueStopped = { told.append(($0, $1, $2)) }
        away.download([game], from: mac)
        try await wait("told") { !told.isEmpty }
        XCTAssertEqual(told.first?.failed, 1)
        XCTAssertEqual(told.first?.finished, [])

        told = []
        let front = sources(.unreachable, isActive: { true })
        front.onQueueStopped = { told.append(($0, $1, $2)) }
        front.download([game], from: mac)
        try await wait("failed") { if case .failed = front.transfers.first?.phase { return true }; return false }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(told.isEmpty, "the player is looking at it")

        told = []
        let quiet = sources(.unreachable, isActive: { false })
        quiet.notifies = false
        quiet.onQueueStopped = { told.append(($0, $1, $2)) }
        quiet.download([game], from: mac)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(told.isEmpty, "switched off")
        XCTAssertFalse(sources(.unreachable).notifies, "and remembered")
    }

    func testTheSystemPermissionIsAskedWhenADownloadStartsAndNotBefore() async throws {
        var asked = 0
        let net = sources(.stall)
        net.prepareNotifications = { asked += 1 }
        XCTAssertEqual(asked, 0)
        net.download([game], from: mac)
        XCTAssertEqual(asked, 1)
        net.cancel(net.transfers[0].id)
    }

    private func zipExport(_ game: InstalledGame) async -> Result<URL, SaveProblem> {
        let folder = documents.appendingPathComponent("exports/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("copy.zip")
        try? SaveUpload.zipMagic.write(to: url)
        return .success(url)
    }

    func testBackingUpSendsEachGamesSavesAndRemovesTheFilesAfterwards() async throws {
        let destination = SaveStub()
        let net = NetworkSources(documents: documents, store: store, defaults: defaults, sourceFactory: { _ in destination },
                                 keepAwake: { _ in }, background: Self.noGrace)
        let withSaves = try installed("0100111000200000", withSaves: true)
        let without = try installed("0100111000300000")
        await net.backUpSaves([withSaves, without], to: mac, export: { await self.zipExport($0) })
        XCTAssertEqual(destination.stored.map(\.titleID), ["0100111000200000"], "a game with no save is not sent")
        XCTAssertEqual(destination.stored.first?.existed, true)
        XCTAssertEqual(net.backup, .finished(sent: 1, failed: 0, firstFailure: nil))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: documents.appendingPathComponent("exports").path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "the exported .zip is not kept on the phone")
        XCTAssertTrue(net.canKeepSaves(mac))
    }

    func testAMacThatDoesNotAcceptSavesIsAskedOnceAndSaysWhy() async throws {
        let destination = SaveStub()
        destination.refuses = .notAccepting
        let net = NetworkSources(documents: documents, store: store, defaults: defaults, sourceFactory: { _ in destination },
                                 keepAwake: { _ in }, background: Self.noGrace)
        let games = [try installed("0100111000200000", withSaves: true), try installed("0100111000300000", withSaves: true)]
        await net.backUpSaves(games, to: mac, export: { await self.zipExport($0) })
        XCTAssertEqual(net.backup, .finished(sent: 0, failed: 1, firstFailure: "savesRefused"), "it stops at the first refusal")
    }

    func testASourceThatCannotKeepSavesIsNotOffered() {
        XCTAssertFalse(sources(.unreachable).canKeepSaves(mac), "a stand-in that only reads")
    }

    // MARK: builds on the Mac

    private func buildNet(_ stub: BuildStub) -> NetworkSources {
        NetworkSources(documents: documents, store: store, defaults: defaults, sourceFactory: { _ in stub },
                       keepAwake: { _ in }, background: Self.noGrace)
    }

    func testTheGamesToBuildAreListedWithTheirState() async throws {
        let stub = BuildStub()
        stub.toBuild = [RemoteBuildable(titleID: "0100111000300000", name: "Not Built", state: .building, progress: 0.4)]
        let net = buildNet(stub)
        net.enabled = true
        net.refreshOffered(force: true)
        try await wait("listed") { !net.buildable.isEmpty }
        XCTAssertEqual(net.buildable.first?.build.state, .building)
        XCTAssertEqual(net.buildable.first?.build.progress, 0.4)
    }

    func testARequestedBuildDownloadsByItselfOnceTheGameIsBuilt() async throws {
        let stub = BuildStub()
        stub.toBuild = [RemoteBuildable(titleID: "0100111000300000", name: "Not Built", state: .idle)]
        let net = buildNet(stub)
        net.enabled = true
        net.refreshOffered(force: true)
        try await wait("listed") { !net.buildable.isEmpty }
        let entry = net.buildable[0]
        net.requestBuild(entry)
        try await wait("asked") { net.isBuildRequested(entry) }
        XCTAssertEqual(stub.requested, ["0100111000300000"])

        // The Mac built it: it is among the games now, and the request turns into a download.
        stub.toBuild = []
        stub.built = [RemoteGame(titleID: "0100111000300000", name: "Not Built", version: "1", packageVersion: "1", minOS: "26.0",
                                 revision: String(repeating: "c", count: 64), codeBytes: 1, romfsBytes: 100, aocBytes: 0)]
        net.refreshOffered(force: true)
        try await wait("downloading") { net.transfers.map(\.game.titleID) == ["0100111000300000"] }
        XCTAssertFalse(net.isBuildRequested(entry), "the request is over")
        net.cancel(net.transfers[0].id)
    }

    func testAMacThatDoesNotAllowBuildsIsSaidSoAndNothingIsRemembered() async throws {
        let stub = BuildStub()
        stub.toBuild = [RemoteBuildable(titleID: "0100111000300000", name: "Not Built", state: .idle)]
        stub.refuses = .notAccepting
        let net = buildNet(stub)
        net.enabled = true
        net.refreshOffered(force: true)
        try await wait("listed") { !net.buildable.isEmpty }
        net.requestBuild(net.buildable[0])
        try await wait("refused") { net.buildNotice != nil }
        XCTAssertEqual(net.buildNotice, "buildsRefused")
        XCTAssertFalse(net.isBuildRequested(net.buildable[0]))
    }

    func testAMacThatKeepsBuildsOffSaysSoOnceAndTheNoticeCanBeHushed() async throws {
        let stub = BuildStub()
        stub.toBuild = [RemoteBuildable(titleID: "0100111000300000", name: "Not Built", state: .idle)]
        stub.allowed = false
        let net = buildNet(stub)
        net.enabled = true
        net.refreshOffered(force: true)
        try await wait("noticed") { !net.buildsOff.isEmpty }
        XCTAssertTrue(net.buildable.isEmpty, "nothing is listed while the Mac keeps it off")
        net.hushBuildsOff(net.buildsOff[0])
        XCTAssertTrue(net.buildsOff.isEmpty)
        net.refreshOffered(force: true)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(net.buildsOff.isEmpty, "a notice that was read does not come back")
    }

    func testAFailedBuildEndsTheRequestAndShowsWhy() async throws {
        let stub = BuildStub()
        stub.toBuild = [RemoteBuildable(titleID: "0100111000300000", name: "Not Built", state: .idle)]
        let net = buildNet(stub)
        net.enabled = true
        net.refreshOffered(force: true)
        try await wait("listed") { !net.buildable.isEmpty }
        let entry = net.buildable[0]
        net.requestBuild(entry)
        try await wait("asked") { net.isBuildRequested(entry) }
        stub.toBuild = [RemoteBuildable(titleID: "0100111000300000", name: "Not Built", state: .failed, detail: "no keys")]
        net.refreshOffered(force: true)
        try await wait("failed shows") { net.buildable.first?.build.state == .failed }
        XCTAssertFalse(net.isBuildRequested(entry), "a failure ends the wait: the player decides whether to ask again")
        XCTAssertEqual(net.buildable.first?.build.detail, "no keys")
    }

    // MARK: another source

    func testADownloadThatLosesItsSourceGoesOnWithAnotherThatHasTheSameBuild() async throws {
        let nas = SourceRecord(kind: .mac, name: "NAS", host: "192.168.1.9", port: 49218, pin: String(repeating: "cd", count: 32))
        store.add(nas, secret: String(repeating: "1", count: 64))
        let both = [game]
        let net = NetworkSources(documents: documents, store: store, defaults: defaults,
                                 sourceFactory: { [unowned self] record in
                                     record.id == self.mac.id
                                         ? StubSource(sourceID: record.sourceID ?? "", behaviour: .unreachable, offered: both)
                                         : StubSource(sourceID: record.sourceID ?? "", behaviour: .stall, offered: both)
                                 },
                                 keepAwake: { _ in }, background: Self.noGrace)
        net.enabled = true
        net.refreshOffered(force: true)
        try await wait("both offer it") { net.offered.count == 2 }
        let entry = try XCTUnwrap(net.offered.first { $0.record.id == mac.id })

        net.download([entry.game], from: entry.record)

        try await wait("it went on with the other source") { net.transfers.first?.recordID == nas.id && net.transfers.first?.phase == .running }
        net.cancel(net.transfers[0].id)
    }

    func testADownloadWhoseOnlySourceFailsStaysFailed() async throws {
        let net = sources(.unreachable, offered: [game])
        net.enabled = true
        net.refreshOffered(force: true)
        try await wait("offered") { !net.offered.isEmpty }
        net.download([game], from: mac)
        try await wait("failed") { if case .failed = net.transfers.first?.phase { return true }; return false }
        XCTAssertEqual(net.transfers.first?.recordID, mac.id)
    }

    // MARK: saves that follow the player

    private func saveNet(_ stub: SaveStub) -> NetworkSources {
        NetworkSources(documents: documents, store: store, defaults: defaults, sourceFactory: { _ in stub }, keepAwake: { _ in }, background: Self.noGrace)
    }

    func testACopyThisPhoneSentIsKnownAsItsOwnAndAnotherIsNot() async throws {
        let stub = SaveStub()
        let net = saveNet(stub)
        let game = try installed("0100111000200000", withSaves: true)
        await net.backUpSaves([game], to: mac, export: { await self.zipExport($0) })
        let mine = RemoteSaveCopy(name: SaveUpload.fileName(at: Date(timeIntervalSince1970: 1_700_000_001)), size: 10, date: Date(timeIntervalSince1970: 1_700_000_001))
        let theirs = RemoteSaveCopy(name: SaveUpload.fileName(at: Date(timeIntervalSince1970: 1_800_000_000)), size: 10, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(net.isMine(mine, titleID: "0100111000200000", on: mac))
        XCTAssertFalse(net.isMine(theirs, titleID: "0100111000200000", on: mac))
        net.markSeen(theirs, titleID: "0100111000200000", on: mac)
        XCTAssertTrue(net.isMine(theirs, titleID: "0100111000200000", on: mac), "a copy the player passed on is not offered again")
    }

    func testTheCopiesOfASourceAreAskedForWithinTheTimeAndTheOnesThatAnswerAreListed() async throws {
        let stub = SaveStub()
        stub.copies = [RemoteSaveCopy(name: SaveUpload.fileName(at: Date(timeIntervalSince1970: 1_700_000_000)), size: 10, date: Date(timeIntervalSince1970: 1_700_000_000))]
        let net = saveNet(stub)
        let off = await net.remoteCopies(of: "0100111000200000")
        XCTAssertTrue(off.isEmpty, "network sources are off")
        net.enabled = true
        let found = await net.remoteCopies(of: "0100111000200000")
        XCTAssertEqual(found.first?.record.id, mac.id)
        XCTAssertEqual(found.first?.copies.count, 1)
        let file = try await net.fetchCopy(stub.copies[0], of: "0100111000200000", from: mac, temporary: documents)
        XCTAssertTrue(SaveUpload.isZip(file))
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testOnlyTheGamesWhoseSavesChangedAreSentAndEachIsSentOnce() async throws {
        let stub = SaveStub()
        let net = saveNet(stub)
        net.enabled = true
        let game = try installed("0100111000200000", withSaves: true)
        let sent = await net.backUpPlayedGames([game], to: [mac], export: { await self.zipExport($0) })
        XCTAssertEqual(sent, 1)
        let again = await net.backUpPlayedGames([game], to: [mac], export: { await self.zipExport($0) })
        XCTAssertEqual(again, 0, "nothing changed since")
        try Data("level 4, longer than before".utf8).write(to: game.directory.appendingPathComponent("save/progress.dat"))
        let changed = await net.backUpPlayedGames([game], to: [mac], export: { await self.zipExport($0) })
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(stub.stored.count, 2)
    }

    func testSavesPutBackFromACopyAreNotSentAgainAsNews() async throws {
        let net = saveNet(SaveStub())
        let game = try installed("0100111000200000", withSaves: true)
        net.markBackedUp(game.id, digest: SaveSnapshots.digest(of: game))
        let sent = await net.backUpPlayedGames([game], to: [mac], export: { await self.zipExport($0) })
        XCTAssertEqual(sent, 0)
    }

    func testAFailingSourceDoesNotMarkTheSavesAsSent() async throws {
        let stub = SaveStub()
        stub.refuses = .notAccepting
        let net = saveNet(stub)
        let game = try installed("0100111000200000", withSaves: true)
        let sent = await net.backUpPlayedGames([game], to: [mac], export: { await self.zipExport($0) })
        XCTAssertEqual(sent, 0)
        XCTAssertNil(net.lastBackedUp(game.id), "they are tried again next time")
    }

    func testTheSettingsForAutomaticBackupAndSyncAreOffUntilTurnedOn() {
        let net = saveNet(SaveStub())
        XCTAssertFalse(net.autoBackupSaves)
        XCTAssertFalse(net.syncSaves)
        net.autoBackupSaves = true
        net.syncSaves = true
        XCTAssertTrue(saveNet(SaveStub()).autoBackupSaves)
        XCTAssertTrue(saveNet(SaveStub()).syncSaves)
    }
}
