import NXPocketKit
import XCTest

@testable import NXShellHost

final class SigningFactsTests: XCTestCase {
    private let profile: [String: Any] = [
        "Name": "SideStore dev.nxpocketapple.app", "TeamIdentifier": ["ABCDE12345"],
        "ExpirationDate": Date(timeIntervalSince1970: 1_800_000_000),
        "Entitlements": ["application-identifier": "ABCDE12345.dev.nxpocketapple.app",
                         "keychain-access-groups": ["ABCDE12345.*"]],
    ]

    func testTheFactsSayWhatTheProfileAndTheSignatureGrantWithoutAnySecret() {
        let facts = SigningFacts.make(bundleID: "dev.nxpocketapple.app", signatureIdentifier: "dev.nxpocketapple.app",
                                      signatureTeam: "ABCDE12345", profile: profile,
                                      signed: ["application-identifier": "ABCDE12345.dev.nxpocketapple.app"])
        let text = facts.lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("bundle ID: dev.nxpocketapple.app"))
        XCTAssertTrue(text.contains("profile application-identifier: ABCDE12345.dev.nxpocketapple.app"))
        XCTAssertTrue(text.contains("profile keychain-access-groups: ABCDE12345.*"))
        XCTAssertTrue(text.contains("signed keychain-access-groups: none"), "the signature granting no group is the -34018 cause")
        XCTAssertTrue(text.contains("team ABCDE12345"))
    }

    func testAnAppWithNoProfileAndNoEntitlementsSaysSo() {
        let facts = SigningFacts.make(bundleID: "dev.nxpocketapple.app", signatureIdentifier: nil, signatureTeam: nil,
                                      profile: nil, signed: nil)
        XCTAssertEqual(facts.lines, ["bundle ID: dev.nxpocketapple.app", "signature: none",
                                     "profile: no embedded.mobileprovision", "signed entitlements: none"])
    }

    @MainActor
    func testAKeychainRefusalSaysItsStatusAndWhatTheAppWasSignedWith() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: documents) }
        let model = ShellHostModel(documents: documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        let facts = SigningFacts.make(bundleID: "dev.nxpocketapple.app", signatureIdentifier: "dev.nxpocketapple.app", signatureTeam: nil,
                                      profile: profile, signed: [:])
        let message = model.keychainMessage(KeychainRefusal(status: -34018, account: Keychain.identityAccount), facts: facts)
        XCTAssertTrue(message.hasPrefix("The keychain refused the certificate: the signature"), message)
        XCTAssertTrue(message.contains("(-34018)"))
        XCTAssertTrue(message.contains("profile keychain-access-groups: ABCDE12345.*"))
        XCTAssertTrue(message.contains("signed keychain-access-groups: none"))
    }
}

final class ErrorReportTests: XCTestCase {
    private var fixture: LibraryFixture!

    override func setUpWithError() throws { fixture = try LibraryFixture() }
    override func tearDown() { fixture.remove() }

    @MainActor
    func testTheReportHoldsTheErrorTheGameTheAppTheSigningAndTheLogsLastLines() async throws {
        let log = GameLogs.newLogURL(titleID: LibraryFixture.titleID, documents: fixture.documents)
        GameLogs.prepare(for: log)
        try Data((0..<500).map { "line \($0)\n" }.joined().utf8).write(to: log)
        let model = ShellHostModel(documents: fixture.documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        await model.libraryRead()
        let report = model.report(error: "dlopen refused DmGame", titleID: LibraryFixture.titleID)
        XCTAssertTrue(report.contains("error: dlopen refused DmGame"))
        XCTAssertTrue(report.contains("game: Fixture (\(LibraryFixture.titleID))"))
        XCTAssertTrue(report.contains("app: NXPocketApple "))
        XCTAssertTrue(report.contains("iOS \(UIDevice.current.systemVersion), "))
        XCTAssertTrue(report.contains("certificate: none"))
        XCTAssertTrue(report.contains("bundle ID: "))
        let logPart = try XCTUnwrap(report.components(separatedBy: "last 200 lines:\n").last)
        let lines = logPart.split(separator: "\n")
        XCTAssertEqual(lines.count, ShellHostModel.reportLogLines)
        XCTAssertEqual(lines.first, "line 300")
        XCTAssertEqual(lines.last, "line 499")
        XCTAssertFalse(report.lowercased().contains("passphrase"))
    }

    @MainActor
    func testAnImportReportCarriesTheAppsLog() async throws {
        let model = ShellHostModel(documents: fixture.documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        ImportLog.standard(in: fixture.documents).append("import of x refused: hash mismatch")
        let report = model.report(error: "Refused", appLog: true)
        XCTAssertTrue(report.contains("log import-log.txt"))
        XCTAssertTrue(report.contains("import of x refused: hash mismatch"))
    }
}

final class PlayTimeTests: XCTestCase {
    private var fixture: LibraryFixture!

    override func setUpWithError() throws { fixture = try LibraryFixture() }
    override func tearDown() { fixture.remove() }

    @MainActor
    func testTheClockAddsEachStretchToTheGamesFileAndKeepsItsNameAndSettings() throws {
        let id = LibraryFixture.titleID
        try GameChoices(values: ["DM_OPMODE": "0"], name: "South Park").save(titleID: id, documents: fixture.documents)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PlayClock(titleID: id, documents: fixture.documents)
        clock.resume(now: start)
        clock.checkpoint(now: start.addingTimeInterval(60))
        XCTAssertEqual(GameChoices.load(titleID: id, documents: fixture.documents).playSeconds, 60, "a kill now loses nothing before this")
        clock.pause(now: start.addingTimeInterval(90))
        clock.pause(now: start.addingTimeInterval(500))
        clock.resume(now: start.addingTimeInterval(1000))
        clock.pause(now: start.addingTimeInterval(1030))
        let choices = GameChoices.load(titleID: id, documents: fixture.documents)
        XCTAssertEqual(choices.playSeconds, 120, "the background is not play time")
        XCTAssertEqual(choices.lastPlayed, start.addingTimeInterval(1030))
        XCTAssertEqual(choices.name, "South Park")
        XCTAssertEqual(choices.values, ["DM_OPMODE": "0"])
    }

    @MainActor
    func testTheSheetShowsTheTotalAndTheLastDayAndASettingKeepsThem() async throws {
        let model = ShellHostModel(documents: fixture.documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        await model.libraryRead()
        let game = try XCTUnwrap(model.games.first)
        XCTAssertNil(model.playTime(of: game))
        let opened = model.settings(for: game)
        try GameChoices(name: "Renamed", playSeconds: 3 * 3600 + 12 * 60, lastPlayed: Date())
            .save(titleID: game.id, documents: fixture.documents)
        _ = model.choose("DM_OPMODE", "0", in: opened, for: game)
        let after = GameChoices.load(titleID: game.id, documents: fixture.documents)
        XCTAssertEqual(after.playSeconds, 3 * 3600 + 12 * 60, "a screen opened earlier does not write its old copy back")
        XCTAssertEqual(after.name, "Renamed")
        let time = try XCTUnwrap(model.playTime(of: game))
        XCTAssertTrue(time.total.contains("3") && time.total.contains("12"), time.total)
    }
}
