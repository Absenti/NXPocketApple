import XCTest

@testable import NXPocketKit

final class SharingRulesTests: XCTestCase {
    private let titleID = "0100111000200000"

    // MARK: the plan

    func testTwoNamesThatAreOneFileOnThePhonesVolumeAreRefused() {
        XCTAssertThrowsError(try DownloadPlan.checkCollisions(["a/Readme", "a/README"]), "case")
        XCTAssertThrowsError(try DownloadPlan.checkCollisions(["caf\u{E9}", "cafe\u{301}"]), "Unicode form")
        XCTAssertThrowsError(try DownloadPlan.checkCollisions(["x", "x/y"]), "a file that is also a folder")
        XCTAssertThrowsError(try DownloadPlan.checkCollisions(["x/y", "x"]), "a folder that is also a file")
        XCTAssertNoThrow(try DownloadPlan.checkCollisions(["x/y", "x/z", "w"]))
    }

    func testThePlanOrdersTheBigFilesLast() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(addOnFiles: ["1.img": 700, "0.img": 800]).write(into: workspace)
        let data = try Data(contentsOf: root.appendingPathComponent("package.json"))
        let files = try PackageScanner.files(in: root).map { RemotePackageFile(path: $0.relativePath, size: $0.size) }

        let plan = try DownloadPlan.make(manifestData: data, listing: RemotePackageListing(revision: FileDigest.sha256(of: data), files: files),
                                         expected: TitleID(titleID)!, maximumMinimumOS: OSVersion(major: 27))

        XCTAssertEqual(plan.items.last?.path, "romfs.img")
        XCTAssertEqual(plan.items.filter { $0.path.hasPrefix("aoc/") }.map(\.path), ["aoc/0.img", "aoc/1.img"])
        XCTAssertTrue(plan.items.filter { $0.sha256 != nil }.allSatisfy { $0.path.hasPrefix("DmGame\(titleID).framework/") })
        XCTAssertEqual(plan.totalBytes, Int64(data.count) + plan.items.reduce(0) { $0 + $1.size })
    }

    func testAnUnsafeFrameworkPathInPackageJSONIsRefused() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(listedPathOverride: "../DmGame").write(into: workspace)
        let data = try Data(contentsOf: root.appendingPathComponent("package.json"))
        let listing = RemotePackageListing(revision: FileDigest.sha256(of: data), files: [])

        XCTAssertThrowsError(try DownloadPlan.make(manifestData: data, listing: listing, expected: TitleID(titleID)!)) {
            XCTAssertEqual(($0 as? NXPocketError)?.code, .unsafePath)
        }
    }

    func testANameFromAServerIsOnePathComponent() {
        for good in ["a", "Some Game", "0100111000200000.nxgame", "é", "a.b"] { XCTAssertTrue(SafePath.isSafeComponent(good), good) }
        for bad in ["", ".", "..", "a/b", "a\\b", "a\u{0}b", "a\nb", String(repeating: "x", count: 256), "/etc"] {
            XCTAssertFalse(SafePath.isSafeComponent(bad), bad.debugDescription)
        }
    }

    // MARK: what the verifier lets stand at a package's root

    func testASaveAtThePackagesRootIsRefused() throws {
        for planted in ["save", "save.meta", "Save", "SAVE0"] {
            let workspace = try TestWorkspace()
            let root = try PackageFixture().write(into: workspace)
            try workspace.write("game/\(planted)/progress.dat", "forged")

            XCTAssertThrowsError(try PackageVerifier.verify(root, options: VerifyOptions(maximumMinimumOS: OSVersion(major: 27))), planted) {
                XCTAssertEqual(($0 as? NXPocketError)?.code, .packageInconsistent)
                XCTAssertTrue(($0 as? NXPocketError)?.detail.contains("saves") ?? false, "\($0)")
            }
        }
    }

    func testAnythingElseAtTheRootIsRefusedButTheFilesOfATransferAreNot() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        for allowed in [GameLayout.completeMarker, GameLayout.downloadJournal, GameLayout.signingRecord, ".DS_Store", "._romfs.img"] {
            try workspace.write("game/\(allowed)", "x")
        }
        XCTAssertNoThrow(try PackageVerifier.verify(root, options: VerifyOptions(maximumMinimumOS: OSVersion(major: 27))))

        try workspace.write("game/notes.txt", "x")
        XCTAssertThrowsError(try PackageVerifier.verify(root, options: VerifyOptions(maximumMinimumOS: OSVersion(major: 27)))) {
            XCTAssertEqual(($0 as? NXPocketError)?.code, .packageInconsistent)
        }
    }

    // MARK: the importer's clean-up and a paused download

    func testAPausedDownloadOutlivesTheIdleLimitOfAPush() throws {
        let workspace = try TestWorkspace()
        let importer = GameImporter(documents: workspace.url("Documents"), log: nil)
        try importer.prepareDirectories()
        let paused = workspace.url("Documents/.incoming/paused")
        let pushed = workspace.url("Documents/.incoming/pushed")
        try workspace.write("Documents/.incoming/paused/romfs.img", bytes: 100)
        try DownloadJournal(sourceID: "s", titleID: titleID, revision: String(repeating: "a", count: 64)).write(in: paused)
        try workspace.write("Documents/.incoming/pushed/romfs.img", bytes: 100)

        let anHour = Date().addingTimeInterval(3600)
        XCTAssertEqual(importer.cleanStaleIncoming(now: anHour).map(\.lastPathComponent), ["pushed"],
                       "a push whose sender is gone goes after ten minutes, a pause stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pushed.path))

        let sixDays = Date().addingTimeInterval(6 * 86400)
        XCTAssertTrue(importer.cleanStaleIncoming(now: sixDays).isEmpty)
        let eightDays = Date().addingTimeInterval(8 * 86400)
        XCTAssertEqual(importer.cleanStaleIncoming(now: eightDays).map(\.lastPathComponent), ["paused"], "after a week the space goes back")
    }

    // MARK: what the list says about the library

    private func installed(_ fixture: PackageFixture, _ workspace: TestWorkspace) throws -> InstalledGame {
        GameLibrary.entry(at: try fixture.write(into: workspace, at: "Documents/games/\(titleID)"))
    }

    private func offered(_ fixture: PackageFixture, _ workspace: TestWorkspace, busy: Bool = false, packageVersion: String? = nil) throws -> RemoteGame {
        let root = try fixture.write(into: workspace, at: "offered")
        let data = try Data(contentsOf: root.appendingPathComponent("package.json"))
        var game = RemoteGame(package: try GamePackage.decode(data), revision: FileDigest.sha256(of: data), busy: busy)
        if let packageVersion { game.packageVersion = packageVersion }
        return game
    }

    func testTheStateOfAnOfferedGame() throws {
        let workspace = try TestWorkspace()
        let current = OSVersion(major: 27)
        let game = try offered(PackageFixture(), workspace)

        XCTAssertEqual(LibraryStatus.state(of: game, installed: nil, deviceOS: current), .notInstalled)
        let have = try installed(PackageFixture(), workspace)
        XCTAssertEqual(LibraryStatus.state(of: game, installed: have, deviceOS: current), .upToDate, "same package.json, same build")
        let rebuilt = try offered(PackageFixture(version: "1.0.1"), workspace)
        XCTAssertEqual(LibraryStatus.state(of: rebuilt, installed: have, deviceOS: current), .updateAvailable)
        let older = try offered(PackageFixture(version: "0.9"), workspace, packageVersion: "100")
        XCTAssertEqual(LibraryStatus.state(of: older, installed: have, deviceOS: current), .olderOnSource)
        let busy = try offered(PackageFixture(), workspace, busy: true)
        XCTAssertEqual(LibraryStatus.state(of: busy, installed: have, deviceOS: current), .rebuilding)
        let future = try offered(PackageFixture(minimumOS: "99.0"), workspace)
        XCTAssertEqual(LibraryStatus.state(of: future, installed: nil, deviceOS: current), .needsNewerOS("99.0"))
        XCTAssertFalse(OfferState.upToDate.isDownloadable)
        XCTAssertFalse(OfferState.rebuilding.isDownloadable)
        XCTAssertTrue(OfferState.updateAvailable.isDownloadable)
    }

    // MARK: bounds on what a source lists

    func testAListingIsBoundedAndCleaned() throws {
        func entry(_ id: String, name: String = "Game", revision: String = String(repeating: "a", count: 64)) -> RemoteGame {
            RemoteGame(titleID: id, name: name, version: "1", packageVersion: "1", minOS: "26.0", revision: revision,
                       codeBytes: 1, romfsBytes: 1, aocBytes: 0)
        }
        let games = [entry("0100111000200000", name: "A\u{0007}\u{001B}[31mred"), entry("0100111000200000", name: "dup"),
                     entry("0100111000200800"), entry("not-an-id"), entry("0100111000300000", revision: "short"),
                     entry("0100111000400000", name: String(repeating: "x", count: 500))]
        let data = try JSONEncoder().encode(RemoteListing(games: games))

        let decoded = try RemoteListing.decode(data)

        XCTAssertEqual(decoded.map(\.titleID), ["0100111000200000", "0100111000400000"], "an update ID, a bad ID, a bad revision and a repeat are dropped")
        XCTAssertFalse(decoded[0].name.contains("\u{0007}"))
        XCTAssertEqual(decoded[1].name.count, 120)
        XCTAssertThrowsError(try RemoteListing.decode(Data(repeating: 0x20, count: SharingLimits.metadataBytes + 1)))
        let many = try JSONEncoder().encode(RemoteListing(games: (0..<(SharingLimits.maxGames + 1)).map {
            entry(String(format: "0100%012X", $0 << 12))
        }))
        XCTAssertThrowsError(try RemoteListing.decode(many))
    }
}
