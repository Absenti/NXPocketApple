import NXPocketKit
import XCTest

@testable import NXShellHost

final class GameLogsTests: XCTestCase {
    private var fixture: LibraryFixture!
    private var documents: URL { fixture.documents }
    private let titleID = LibraryFixture.titleID

    override func setUpWithError() throws { fixture = try LibraryFixture() }
    override func tearDown() { fixture.remove() }

    private func date(_ text: String) throws -> Date { try XCTUnwrap(GameLogs.stamp.date(from: text)) }

    @discardableResult
    private func log(_ titleID: String, _ stamp: String, _ text: String = "line\n") throws -> URL {
        let url = GameLogs.newLogURL(titleID: titleID, documents: documents, now: try date(stamp))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testEachStartOfAGameGetsItsOwnLogNamedAfterItsDate() throws {
        let first = try log(titleID, "2026-11-11 153000")
        XCTAssertEqual(first.path, documents.appendingPathComponent("logs/\(titleID)/2026-11-11 153000.txt").path)
        let second = GameLogs.newLogURL(titleID: titleID, documents: documents, now: try date("2026-11-11 153000"))
        XCTAssertEqual(second.lastPathComponent, "2026-11-11 153000 2.txt", "two starts in one second do not share a file")
    }

    func testTheLaunchPlanWritesToANewLogOfItsGame() throws {
        XCTAssertNil(fixture.game.problem)
        let plan = try XCTUnwrap(EngineLaunchPlan.make(game: fixture.game, documents: documents, appResources: documents,
                                                       now: try date("2026-11-11 160000")))
        XCTAssertEqual(plan.logURL.path, documents.appendingPathComponent("logs/\(titleID)/2026-11-11 160000.txt").path)
    }

    func testBeforeAStartOnlyTheNineNewestStaySoTheNewOneMakesTen() throws {
        for minute in 0..<12 { try log(titleID, String(format: "2026-11-11 15%02d00", minute)) }
        let next = GameLogs.newLogURL(titleID: titleID, documents: documents, now: try date("2026-11-11 160000"))
        GameLogs.prepare(for: next)
        let names = try FileManager.default.contentsOfDirectory(atPath: next.deletingLastPathComponent().path).sorted()
        XCTAssertEqual(names.count, GameLogs.keep - 1)
        XCTAssertEqual(names.first, "2026-11-11 150300.txt")
    }

    func testTheGamesLogsListNewestFirstAndTheAppLogComesFirst() throws {
        try log(titleID, "2026-11-10 100000")
        try log("0100222000300000", "2026-11-11 090000")
        try log(titleID, "2026-11-11 080000")
        let logs = GameLogs.logs(documents: documents)
        XCTAssertEqual(logs.map(\.url.lastPathComponent), ["2026-11-11 090000.txt", "2026-11-11 080000.txt", "2026-11-10 100000.txt"])
        XCTAssertEqual(GameLogs.logs(titleID: titleID, documents: documents).count, 2)
    }

    @MainActor
    func testTheModelPutsTheAppLogFirstAndNamesEachLogAfterItsGame() async throws {
        try log(titleID, "2026-11-11 080000")
        let model = ShellHostModel(documents: documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        await model.libraryRead()
        let logs = model.logs()
        XCTAssertEqual(logs.first?.kind, .app)
        XCTAssertEqual(logs.dropFirst().map { model.title(of: $0) }, ["Fixture"])
        XCTAssertEqual(model.logs(for: titleID).count, 1, "one game's logs leave the app log out")
    }

    func testTheEndOfALongLogStartsOnAWholeLine() throws {
        let url = try log(titleID, "2026-11-11 080000", (0..<100).map { "line \($0)\n" }.joined())
        let shown = GameLogs.text(of: LogFile(url: url, kind: .game(titleID), date: Date(), bytes: 0), limit: 40)
        XCTAssertTrue(shown.isTail)
        XCTAssertTrue(shown.text.hasPrefix("line 9"), shown.text)
        XCTAssertTrue(shown.text.hasSuffix("line 99\n"))
        XCTAssertFalse(GameLogs.text(of: LogFile(url: url, kind: .game(titleID), date: Date(), bytes: 0)).isTail)
    }

    func testTheSharedLogOfEarlierVersionsIsFiledUnderTheGameItNames() throws {
        let shared = documents.appendingPathComponent("log.txt")
        try Data("shell: starting \(documents.path)/games/\(titleID)/DmGame\(titleID).framework/dm\nboot: DM_OPMODE=0\n".utf8)
            .write(to: shared)
        let unnamed = documents.appendingPathComponent("log.prev.txt")
        try Data("no game here\n".utf8).write(to: unnamed)
        GameLogs.fileSharedLogs(documents: documents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertEqual(GameLogs.logs(titleID: titleID, documents: documents).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unnamed.path), "a log that names no game stays where it was")
    }

    func testDeletingTheAppLogStartsItAgainEmpty() throws {
        let journal = ImportLog.standard(in: documents)
        journal.append("something")
        try GameLogs.remove(GameLogs.appLog(documents: documents))
        XCTAssertEqual(GameLogs.appLog(documents: documents).bytes, 0)
        journal.append("again")
        XCTAssertTrue(journal.read().contains("again"))
    }
}

final class GameLibraryActionsTests: XCTestCase {
    private var fixture: LibraryFixture!
    private let titleID = LibraryFixture.titleID

    override func setUpWithError() throws { fixture = try LibraryFixture() }
    override func tearDown() { fixture.remove() }

    /// A model whose library has been read: the read runs off the main thread (`ShellHostModel.refresh`).
    @MainActor
    private func model() async -> ShellHostModel {
        let model = ShellHostModel(documents: fixture.documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        await model.libraryRead()
        return model
    }

    @MainActor
    func testARenameChangesOnlyTheNameShownAndSurvivesTheSettingsAndARestart() async throws {
        let model = await model()
        let game = try XCTUnwrap(model.games.first)
        model.rename(game, to: "  My Fixture ")
        XCTAssertEqual(model.name(of: game), "My Fixture")
        XCTAssertEqual(game.title, "Fixture", "the game's own files are not touched")
        XCTAssertEqual(fixture.game.title, "Fixture")

        _ = model.choose("DM_OPMODE", "0", in: model.settings(for: game), for: game)
        XCTAssertEqual(GameChoices.load(titleID: titleID, documents: fixture.documents).name, "My Fixture",
                       "keeping a setting keeps the name beside it")
        let reopened = await self.model()
        XCTAssertEqual(reopened.name(of: game), "My Fixture")

        model.rename(game, to: "")
        XCTAssertEqual(model.name(of: game), "Fixture")
        XCTAssertFalse(model.isRenamed(game))
    }

    @MainActor
    func testRemovingAGameButKeepingItsSavesLeavesNoBrokenGameInTheLibrary() async throws {
        let model = await model()
        let game = try XCTUnwrap(model.games.first)
        model.rename(game, to: "Kept")
        model.remove(game, includingSaves: false)
        await model.libraryRead()
        XCTAssertTrue(model.games.isEmpty, "the folder holding only saves is no game to list")
        XCTAssertEqual(GameSaves.entries(in: fixture.folder), ["save", "save_meta.dat"])
        XCTAssertEqual(GameChoices.load(titleID: titleID, documents: fixture.documents).name, "Kept",
                       "the settings and the name wait for the game's return")
    }

    @MainActor
    func testDeletingEverythingTakesTheSavesSettingsAndLogsToo() async throws {
        let model = await model()
        let game = try XCTUnwrap(model.games.first)
        model.rename(game, to: "Gone")
        let log = GameLogs.newLogURL(titleID: titleID, documents: fixture.documents)
        GameLogs.prepare(for: log)
        try Data("x\n".utf8).write(to: log)
        model.remove(game, includingSaves: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
        XCTAssertNil(GameChoices.load(titleID: titleID, documents: fixture.documents).name)
        XCTAssertTrue(GameLogs.logs(titleID: titleID, documents: fixture.documents).isEmpty)
    }

    @MainActor
    func testDeletingTheSavesKeepsTheGame() async throws {
        let model = await model()
        let game = try XCTUnwrap(model.games.first)
        XCTAssertTrue(model.hasSaves(game))
        XCTAssertNil(model.deleteSaves(game))
        XCTAssertFalse(model.hasSaves(game))
        await model.libraryRead()
        XCTAssertEqual(model.games.count, 1)
    }

    @MainActor
    func testASaveOfAnotherGameIsRefusedInThePlayersWords() async throws {
        let model = await model()
        let game = try XCTUnwrap(model.games.first)
        let result = await model.importSaves(game, from: try fixture.macCopy(titleID: "0100222000300000"))
        guard case .failure(let problem) = result else { return XCTFail("imported a save of another game") }
        XCTAssertEqual(model.text(for: problem), "This save belongs to another game: Fixture (0100222000300000).")
        XCTAssertEqual(fixture.text("save/slot1.bin"), "old slot")
    }

    @MainActor
    func testAnImportedSaveTakesThePlaceOfTheOldOneWhichIsKept() async throws {
        let model = await model()
        let game = try XCTUnwrap(model.games.first)
        let result = await model.importSaves(game, from: try fixture.macCopy())
        guard case .success(let kept) = result else { return XCTFail("\(result)") }
        XCTAssertNotNil(kept)
        XCTAssertEqual(fixture.text("save/slot1.bin"), "new slot")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.documents.path).filter { $0.hasPrefix(".saves-") }
        XCTAssertEqual(leftovers, [], "the staging copy is gone")
    }
}
