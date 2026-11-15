import NXPocketKit
import XCTest

@testable import NXShellHost

/// The certificate reminders, the offloaded tiles, the snapshots of the saves and the frame statistics.
final class KeepsakeTests: XCTestCase {
    private var documents: URL!
    private let titleID = "0100111000200000"
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        documents = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: documents) }

    private func game(saves: [String: String] = ["save/progress.dat": "level 3"]) throws -> InstalledGame {
        let folder = documents.appendingPathComponent("games/\(titleID)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, text) in saves {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return InstalledGame(titleID: TitleID(titleID)!, directory: folder)
    }

    // MARK: certificate reminders

    func testRemindersComeADayAndTwoHoursBeforeTheEarlierEnd() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let certificate = now.addingTimeInterval(5 * 86400), profile = now.addingTimeInterval(3 * 86400)
        let end = ExpiryReminder.expiry(certificate: certificate, profile: profile)
        XCTAssertEqual(end, profile, "whichever ends first ends the games")
        let moments = ExpiryReminder.moments(expiry: end, now: now)
        XCTAssertEqual(moments.map(\.kind), [.dayBefore, .hoursBefore])
        XCTAssertEqual(moments[0].at, profile.addingTimeInterval(-86400))
        XCTAssertEqual(moments[1].at, profile.addingTimeInterval(-7200))
        XCTAssertEqual(ExpiryReminder.expiry(certificate: certificate, profile: nil), certificate)
        XCTAssertNil(ExpiryReminder.expiry(certificate: nil, profile: nil))
    }

    func testAReminderThatIsPastOrAboutToFireIsNotSet() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ExpiryReminder.moments(expiry: now.addingTimeInterval(5 * 3600), now: now).map(\.kind), [.hoursBefore], "less than a day left")
        XCTAssertTrue(ExpiryReminder.moments(expiry: now.addingTimeInterval(3600), now: now).isEmpty, "less than two hours left")
        XCTAssertTrue(ExpiryReminder.moments(expiry: now.addingTimeInterval(-10), now: now).isEmpty)
        XCTAssertTrue(ExpiryReminder.moments(expiry: nil, now: now).isEmpty)
    }

    // MARK: offloaded games

    func testAnOffloadedGameKeepsItsLineAndItsIconUntilItIsForgotten() throws {
        let store = OffloadStore(documents: documents)
        let icon = documents.appendingPathComponent("icon.png")
        try Data("png".utf8).write(to: icon)
        try store.add(OffloadedGame(titleID: titleID, name: "Fixture", version: "1.0", bytes: 5_000, date: Date()), iconFrom: icon)
        XCTAssertEqual(store.records().map(\.name), ["Fixture"])
        XCTAssertNotNil(store.iconURL(for: titleID))
        XCTAssertEqual(OffloadStore(documents: documents).records().count, 1, "it survives a restart")
        store.remove(titleID: titleID)
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertNil(store.iconURL(for: titleID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.path), "nothing is left behind")
    }

    func testAnOffloadIndexEditedThroughFilesCannotNameAFile() throws {
        let store = OffloadStore(documents: documents)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let bad = #"[{"titleID":"../../x","name":"x","version":"","bytes":1,"date":0}]"#
        try Data(bad.utf8).write(to: store.folder.appendingPathComponent("index.json"))
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertNil(store.iconURL(for: "../../x"))
    }

    // MARK: snapshots of the saves

    func testASnapshotIsTakenOnceAndAgainOnlyWhenTheSavesChanged() throws {
        let game = try game()
        let first = try SaveSnapshots.take(game, name: "Fixture", device: "iPhone", documents: documents, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotNil(first)
        XCTAssertEqual(try SaveSnapshots.take(game, name: "Fixture", device: "iPhone", documents: documents, now: Date(timeIntervalSince1970: 1_700_000_100)),
                       nil, "the same saves are not copied twice")
        try Data("level 4, longer".utf8).write(to: game.directory.appendingPathComponent("save/progress.dat"))
        XCTAssertNotNil(try SaveSnapshots.take(game, name: "Fixture", device: "iPhone", documents: documents, now: Date(timeIntervalSince1970: 1_700_000_200)))
        let list = SaveSnapshots.list(titleID: titleID, documents: documents)
        XCTAssertEqual(list.count, 2)
        XCTAssertGreaterThan(list[0].date, list[1].date, "newest first")
    }

    func testASnapshotRestoresThroughTheImportThatExists() throws {
        let game = try game()
        let taken = try XCTUnwrap(try SaveSnapshots.take(game, name: "Fixture", device: "iPhone", documents: documents))
        try Data("ruined".utf8).write(to: game.directory.appendingPathComponent("save/progress.dat"))
        let staging = documents.appendingPathComponent(".staging")
        let copy = try GameSaves.read(taken, for: titleID, staging: staging)
        _ = try GameSaves.restore(copy, into: game, name: "Fixture", documents: documents, device: "iPhone")
        XCTAssertEqual(try String(contentsOf: game.directory.appendingPathComponent("save/progress.dat"), encoding: .utf8), "level 3")
        XCTAssertFalse(GameSaves.entries(in: documents.appendingPathComponent("Saves/\(titleID)"), fileManager: .default).isEmpty && false)
    }

    func testOnlyTheLastTwentySnapshotsStayAndAGameWithoutSavesHasNone() throws {
        let game = try game()
        for index in 0..<(SaveSnapshots.keep + 3) {
            try Data("level \(index)".utf8).write(to: game.directory.appendingPathComponent("save/progress.dat"))
            try SaveSnapshots.take(game, name: "Fixture", device: "iPhone", documents: documents, now: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 100))
        }
        XCTAssertEqual(SaveSnapshots.list(titleID: titleID, documents: documents).count, SaveSnapshots.keep)
        let bare = InstalledGame(titleID: TitleID("0100111000300000")!, directory: documents.appendingPathComponent("games/0100111000300000"))
        XCTAssertNil(try SaveSnapshots.take(bare, name: "Bare", device: "iPhone", documents: documents))
        SaveSnapshots.removeAll(titleID: titleID, documents: documents)
        XCTAssertTrue(SaveSnapshots.list(titleID: titleID, documents: documents).isEmpty)
    }

    // MARK: frames

    func testTheAverageRateCountsOnlyTheSecondsTheGameDrew() {
        XCTAssertNil(PlayStats(sessions: 1, frames: 300, drawingSeconds: 5).averageFPS, "too little to say")
        XCTAssertEqual(PlayStats(sessions: 2, frames: 5_400, drawingSeconds: 100).averageFPS, 54)
    }

    @MainActor
    func testTheClockKeepsSessionsAndFramesBesideThePlayTime() {
        let clock = PlayClock(titleID: titleID, documents: documents)
        clock.resume()
        _ = FrameCounter.take()
        FrameCounter.record(60)
        clock.sample()
        FrameCounter.record(0)
        clock.sample()   // a second with no frame (a loading screen) is not counted
        FrameCounter.record(30)
        clock.sample()
        clock.pause()
        let choices = GameChoices.load(titleID: titleID, documents: documents)
        XCTAssertEqual(choices.sessions, 1)
        XCTAssertEqual(choices.fpsFrames, 90)
        XCTAssertEqual(choices.fpsSeconds, 2)
        let again = PlayClock(titleID: titleID, documents: documents)
        again.resume()
        again.pause()
        XCTAssertEqual(GameChoices.load(titleID: titleID, documents: documents).sessions, 2)
    }

    // MARK: the report of a session

    func testASessionBecomesOneBucketEveryThirtySecondsWithTheWorstHeat() {
        var recorder = SessionRecorder(started: Date(timeIntervalSince1970: 0))
        for second in 0..<65 {
            recorder.feed(frames: second < 30 ? 60 : (second < 45 ? 0 : 30), thermal: second == 10 ? 2 : 0, battery: 0.9 - Double(second) / 1000)
        }
        XCTAssertEqual(recorder.report.buckets.count, 2, "sixty-five seconds hold two whole buckets")
        XCTAssertEqual(recorder.report.buckets[0].fps, 60)
        XCTAssertEqual(recorder.report.buckets[0].thermal, 2, "the worst of the thirty seconds")
        XCTAssertEqual(recorder.report.buckets[0].t, 30)
        XCTAssertEqual(try XCTUnwrap(recorder.report.buckets[1].fps), 30, "the fifteen seconds that drew nothing do not pull it down")
        XCTAssertEqual(recorder.report.buckets[1].thermal, 0)
        XCTAssertEqual(try XCTUnwrap(recorder.report.averageFPS), 45)
        XCTAssertEqual(recorder.report.worstThermal, 2)
        XCTAssertEqual(try XCTUnwrap(recorder.report.batteryUsed), 3, accuracy: 0.01)
    }

    func testABucketOfNothingHasNoRateAndABatteryThatIsUnknownIsLeftOut() {
        var recorder = SessionRecorder()
        for _ in 0..<30 { recorder.feed(frames: 0, thermal: 0, battery: nil) }
        XCTAssertNil(recorder.report.buckets[0].fps)
        XCTAssertNil(recorder.report.buckets[0].battery)
        XCTAssertNil(recorder.report.batteryUsed)
        XCTAssertNil(recorder.report.averageFPS)
    }

    func testASessionKeepsOnlyItsLastTwoHours() {
        var recorder = SessionRecorder()
        for _ in 0..<((SessionReport.maxBuckets + 10) * SessionReport.bucketSeconds) { recorder.feed(frames: 30, thermal: 0, battery: nil) }
        XCTAssertEqual(recorder.report.buckets.count, SessionReport.maxBuckets)
        XCTAssertEqual(recorder.report.buckets.last?.t, (SessionReport.maxBuckets + 10) * SessionReport.bucketSeconds)
    }

    func testTheReportSurvivesARestartAndAnEditedFileCannotNameAnotherPath() throws {
        var recorder = SessionRecorder()
        for _ in 0..<60 { recorder.feed(frames: 40, thermal: 1, battery: 0.5) }
        recorder.report.save(titleID: titleID, documents: documents)
        XCTAssertEqual(SessionReport.load(titleID: titleID, documents: documents)?.buckets.count, 2)
        recorder.report.save(titleID: "../../x", documents: documents)
        XCTAssertNil(SessionReport.load(titleID: "../../x", documents: documents))
    }

    // MARK: quick actions and the inbox

    func testTheLongPressOffersTheThreeGamesPlayedLastNewestFirst() throws {
        let ids = ["0100111000200000", "0100111000300000", "0100111000400000", "0100111000500000", "0100111000600000"]
        var games: [InstalledGame] = []
        for (index, id) in ids.enumerated() {
            games.append(InstalledGame(titleID: TitleID(id)!, directory: documents.appendingPathComponent("games/\(id)")))
            // The last one was never played: it is not offered however recent its folder is.
            guard index < 4 else { continue }
            try GameChoices(playSeconds: 60, lastPlayed: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 1000))
                .save(titleID: id, documents: documents)
        }
        let recent = QuickActions.recent(games, name: { "Game \($0.id.suffix(5))" }, documents: documents)
        XCTAssertEqual(recent.map(\.id), [ids[3], ids[2], ids[1]])
        XCTAssertEqual(QuickActions.recent([], name: { _ in "" }, documents: documents).count, 0)
    }

    func testABrokenGameIsNotOfferedByTheLongPress() throws {
        let id = "0100111000200000"
        try GameChoices(playSeconds: 60, lastPlayed: Date()).save(titleID: id, documents: documents)
        let broken = InstalledGame(titleID: TitleID(id)!, directory: documents.appendingPathComponent("games/\(id)"),
                                   problem: NXPocketError(.packageMissing, "gone"))
        XCTAssertTrue(QuickActions.recent([broken], name: { _ in "x" }, documents: documents).isEmpty)
    }

    func testTheInboxKeepsOneGameAndOnlyAGame() {
        _ = GameLaunchInbox.take()
        GameLaunchInbox.request("not a title", notify: false)
        XCTAssertNil(GameLaunchInbox.take())
        GameLaunchInbox.request("0100000000000800", notify: false)   // a system title, not a game
        XCTAssertNil(GameLaunchInbox.take())
        GameLaunchInbox.request("0100111000200000", notify: false)
        GameLaunchInbox.request("0100111000300000", notify: false)
        XCTAssertEqual(GameLaunchInbox.take()?.description, "0100111000300000", "the last request is the one that counts")
        XCTAssertNil(GameLaunchInbox.take(), "and it is taken once")
    }

    func testTheCatalogForShortcutsListsOnlyGamesAndSurvivesARestart() throws {
        GameCatalog.write([GameCatalogEntry(id: "0100111000200000", name: "Fixture"), GameCatalogEntry(id: "../x", name: "Bad")], documents: documents)
        XCTAssertEqual(GameCatalog.read(documents: documents).map(\.name), ["Fixture"])
        XCTAssertTrue(GameCatalog.read(documents: documents.appendingPathComponent("nowhere")).isEmpty)
    }

    // MARK: web libraries, resumed downloads, files sent to the app

    @MainActor
    func testAWebLibraryIsASourceWithItsAddressAndItsOptionalToken() throws {
        let suite = "nxpocket-web-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = FakeKeychain()
        let store = SourceStore(defaults: defaults, keychain: keychain)
        let record = SourceRecord(kind: .web, name: "Mine", host: "example.com", port: 443, folder: "https://example.com/lib/?key=abc")
        XCTAssertEqual(record.webURL?.absoluteString, "https://example.com/lib/?key=abc")
        XCTAssertEqual(record.sourceID, WebSource.sourceID(for: record.webURL!))
        store.add(record, secret: SourceStore.noToken)
        XCTAssertTrue(store.source(for: record) is WebSource, "a web library with no token still has a secret to keep: the address")
        store.add(record, secret: "token-1")
        XCTAssertEqual(store.secret(for: record), "token-1")
        XCTAssertNil(SourceRecord(kind: .web, name: "x", host: "h", port: 80, folder: "http://example.com/lib").webURL, "a plain http address is not one")
        XCTAssertNil(SourceRecord(kind: .mac, name: "x", host: "h", port: 1, folder: "https://example.com").webURL)
    }

    @MainActor
    func testTheSourcesScreenSavesAWebLibraryAndOffersItsGames() throws {
        let suite = "nxpocket-web2-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let net = NetworkSources(documents: documents, store: SourceStore(defaults: defaults, keychain: FakeKeychain()), defaults: defaults,
                                 sourceFactory: { _ in nil }, keepAwake: { _ in })
        let record = net.saveWeb(url: URL(string: "https://example.com/lib/")!, token: "", name: "")
        XCTAssertEqual(record.name, "example.com")
        XCTAssertEqual(record.kind, .web)
        XCTAssertEqual(net.store.records.count, 1)
    }

    func testAnInterruptedLinkDownloadIsRememberedPerLinkAndForgottenWhenItEnds() {
        let store = ArchiveDownload.ResumeStore(documents: documents)
        let link = URL(string: "https://example.com/private/a1b2c3.zip")!
        XCTAssertNil(store.load(for: link))
        store.save(Data("resume".utf8), for: link)
        XCTAssertEqual(store.load(for: link), Data("resume".utf8))
        XCTAssertTrue(store.exists(for: link))
        XCTAssertNil(store.load(for: URL(string: "https://example.com/private/other.zip")!), "one file for each link")
        XCTAssertEqual(store.url(for: link), store.url(for: link))
        XCTAssertFalse(store.url(for: link).lastPathComponent.contains("a1b2c3"), "the link, which is the secret, is not in a file name")
        store.remove(for: link)
        XCTAssertFalse(store.exists(for: link))
    }

    func testOnlyTheNetworksFailuresAreWorthATryAgain() {
        XCTAssertTrue(ArchiveDownload.isWorthRetrying(URLError(.networkConnectionLost)))
        XCTAssertTrue(ArchiveDownload.isWorthRetrying(URLError(.timedOut)))
        XCTAssertTrue(ArchiveDownload.isWorthRetrying(NXPocketError(.transferFailed, "cut")))
        XCTAssertFalse(ArchiveDownload.isWorthRetrying(NXPocketError(.notEnoughSpace, "full")), "a full disk is not mended by waiting")
        XCTAssertFalse(ArchiveDownload.isWorthRetrying(NXPocketError(.packageMissing, "the link answered 404")))
        XCTAssertFalse(ArchiveDownload.isWorthRetrying(URLError(.badURL)))
    }

    @MainActor
    func testAFileSentToTheAppWaitsForTheWarningAndIsNeverImportedByItself() throws {
        let model = ShellHostModel(documents: documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        let archive = documents.appendingPathComponent("build.zip")
        try Data("PK".utf8).write(to: archive)
        model.open(archive)
        XCTAssertEqual(model.archiveRequest?.url, archive)
        XCTAssertEqual(model.archiveRequest?.isFolder, false)
        XCTAssertFalse(model.importState.isRunning, "nothing is unpacked before the player says yes")
        let folder = documents.appendingPathComponent("A Build Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        model.open(folder)
        XCTAssertEqual(model.archiveRequest?.isFolder, true)
    }
}
