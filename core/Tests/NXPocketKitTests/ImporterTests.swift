import XCTest

@testable import NXPocketKit

final class GameImporterTests: XCTestCase {
    private func makeImporter(_ workspace: TestWorkspace, documents: String = "Documents") throws -> GameImporter {
        let importer = GameImporter(documents: workspace.url(documents), log: nil)
        try importer.prepareDirectories()
        return importer
    }

    func testImportsAPackageIntoTheLibrary() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")

        let game = try importer.install(source, identity: identity(), signer: RecordingSigner(identifier: "dev.nxpocketapple.app"))

        XCTAssertEqual(game.titleID.description, "0100111000200000")
        XCTAssertEqual(game.title, "Fixture Game")
        XCTAssertNil(game.problem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.url("Documents/games/0100111000200000/romfs.img").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "the transfer folder is consumed by the move")
    }

    func testImportsAPackageAFinderWindowWroteInto() throws {
        // What happened on the phone: the Finder put a .DS_Store in the built framework, and the transfer was refused.
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        let framework = PackageFixture.frameworkName("0100111000200000")
        try workspace.write(".incoming/transfer/\(framework)/.DS_Store", bytes: 6148)
        try workspace.write(".incoming/transfer/.DS_Store", bytes: 6148)

        _ = try importer.install(source, identity: identity(), signer: RecordingSigner(identifier: "dev.nxpocketapple.app"))

        let installed = workspace.url("Documents/games/0100111000200000")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent("\(framework)/.DS_Store").path),
                       "the signed framework holds only what the package lists")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent(".DS_Store").path))
    }

    func testWritesASigningRecord() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        let identity = identity()

        _ = try importer.install(source, identity: identity, signer: RecordingSigner(identifier: identity.identifier, teamID: identity.teamID))

        let record = try XCTUnwrap(GameLibrary.readSigning(workspace.url("Documents/games/0100111000200000")))
        XCTAssertEqual(record.identifier, "dev.nxpocketapple.app")
        XCTAssertEqual(record.certificateSHA256, identity.certificateSHA256)
        XCTAssertEqual(record.teamID, "ABCDE12345")
    }

    func testRefusesASignatureWithAnotherIdentifier() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        XCTAssertThrowsError(try importer.install(source, identity: identity(),
                                                 signer: RecordingSigner(identifier: "dev.nxpocket.probe.Probe", teamID: "ABCDE12345"))) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .wrongSigner)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url("Documents/games/0100111000200000").path),
                       "a refused import never reaches the library")
    }

    func testRefusesAnotherTeam() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        XCTAssertThrowsError(try importer.install(source, identity: identity(),
                                                 signer: RecordingSigner(identifier: "dev.nxpocketapple.app", teamID: "ZZZZZ99999"))) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .teamMismatch)
        }
    }

    func testRefusesAnAdHocResult() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        XCTAssertThrowsError(try importer.install(source, identity: identity(),
                                                 signer: RecordingSigner(identifier: "dev.nxpocketapple.app", hasCertificate: false))) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .noCertificate)
        }
    }

    func testRefusesWhenThereIsNotEnoughSpace() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        XCTAssertThrowsError(try importer.install(source, identity: identity(),
                                                 signer: RecordingSigner(identifier: "dev.nxpocketapple.app"),
                                                 availableCapacity: 1024)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .notEnoughSpace)
        }
    }

    func testThePackageAlreadyOnTheVolumeIsNotCountedAgain() throws {
        // The transfer already takes its room: what the import needs on top is the signed executable's fresh copy.
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        let verified = try importer.verify(source, options: .default)
        let executable = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: verified.executableURL.path)[.size] as? Int64)
        XCTAssertLessThan(executable, verified.package.totalSize, "the old rule would have asked for the whole package")
        let options = ImportOptions(headroom: 0)
        let signer = RecordingSigner(identifier: "dev.nxpocketapple.app")

        XCTAssertThrowsError(try importer.install(source, identity: identity(), signer: signer, options: options,
                                                 availableCapacity: executable - 1)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .notEnoughSpace)
        }
        XCTAssertNoThrow(try importer.install(source, identity: identity(), signer: signer, options: options,
                                             availableCapacity: executable))
    }

    func testReplacingAGameNeedsNoSpaceForItsSaves() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        try workspace.write("Documents/games/0100111000200000/save/progress.dat", bytes: 3000)
        try workspace.write("Documents/games/0100111000200000/save.meta", bytes: 200)
        try workspace.write("Documents/games/0100111000200000/romfs.img", bytes: 5000)
        let source = try PackageFixture(version: "1.1.0").write(into: workspace, at: ".incoming/update")
        let verified = try importer.verify(source, options: .default)
        let executable = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: verified.executableURL.path)[.size] as? Int64)

        XCTAssertEqual(importer.spaceNeeded(for: verified, headroom: 10), executable + 10,
                       "the old game's data and its saves are moved by renames")
    }

    func testAnUpdateKeepsTheSaves() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let signer = RecordingSigner(identifier: "dev.nxpocketapple.app")
        let first = try PackageFixture(version: "1.0.0").write(into: workspace, at: ".incoming/one")
        _ = try importer.install(first, identity: identity(), signer: signer)
        let save = workspace.url("Documents/games/0100111000200000/save/progress.dat")
        try workspace.write("Documents/games/0100111000200000/save/progress.dat", "chapter 3")

        let second = try PackageFixture(version: "1.1.0").write(into: workspace, at: ".incoming/two")
        let game = try importer.install(second, identity: identity(), signer: signer)

        XCTAssertEqual(game.version, "1.1.0")
        XCTAssertEqual(try String(contentsOf: save, encoding: .utf8), "chapter 3")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.url("Documents/games").path)
        XCTAssertEqual(leftovers, ["0100111000200000"], "the replaced folder is gone")
    }

    func testASaveTheNewFolderAlreadyHasKeepsTheReplacedFolder() throws {
        // The replaced folder holds the only copy of its saves: it goes only once they are all in the new one.
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        try workspace.write("Documents/games/.replaced-x/save/progress.dat", "old")
        try workspace.write("Documents/games/.replaced-x/save.meta", "meta")
        try workspace.write("Documents/games/new/save/progress.dat", "new")

        let left = importer.carrySaves(from: workspace.url("Documents/games/.replaced-x"), to: workspace.url("Documents/games/new"))

        XCTAssertEqual(left, ["save"])
        XCTAssertEqual(try String(contentsOf: workspace.url("Documents/games/new/save/progress.dat"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: workspace.url("Documents/games/.replaced-x/save/progress.dat"), encoding: .utf8), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.url("Documents/games/new/save.meta").path))
    }

    func testAKeptReplacedFolderGivesItsSavesBackLater() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let signer = RecordingSigner(identifier: "dev.nxpocketapple.app")
        _ = try importer.install(try PackageFixture().write(into: workspace, at: ".incoming/one"), identity: identity(), signer: signer)
        _ = try PackageFixture().write(into: workspace, at: "Documents/games/.replaced-kept")
        try workspace.write("Documents/games/.replaced-kept/save/progress.dat", "chapter 4")

        XCTAssertEqual(importer.recoverReplacedSaves(), ["0100111000200000"])

        XCTAssertEqual(try String(contentsOf: workspace.url("Documents/games/0100111000200000/save/progress.dat"), encoding: .utf8),
                       "chapter 4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url("Documents/games/.replaced-kept").path))
    }

    func testAnExpiredCertificateIsRefusedBeforeSigning() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let signer = RecordingSigner(identifier: "dev.nxpocketapple.app")
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")

        XCTAssertThrowsError(try importer.install(source, identity: identity(expiresIn: -1), signer: signer)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .certificateExpired)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the transfer waits for a valid certificate")
    }

    func testAGameThatLostItsCodeOrItsRomFSIsListedAsDamaged() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let signer = RecordingSigner(identifier: "dev.nxpocketapple.app")
        _ = try importer.install(try PackageFixture().write(into: workspace, at: ".incoming/one"), identity: identity(), signer: signer)
        let folder = workspace.url("Documents/games/0100111000200000")
        XCTAssertNil(GameLibrary.entry(at: folder).problem)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("romfs.img"))
        XCTAssertEqual(GameLibrary.entry(at: folder).problem?.code, .packageMissing)

        _ = try PackageFixture(withRomfs: false).write(into: workspace, at: "Documents/games/0100111000200000")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("\(PackageFixture.frameworkName("0100111000200000"))/DmGame"))
        XCTAssertEqual(GameLibrary.entry(at: folder).problem?.code, .packageMissing)
    }

    func testDirectoriesAndIncomingFolders() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        XCTAssertTrue(importer.completedIncoming().isEmpty)
        let folder = try importer.newIncoming()
        try workspace.write("Documents/.incoming/\(folder.lastPathComponent)/\(GameLayout.completeMarker)", "")
        XCTAssertEqual(importer.completedIncoming().map(\.lastPathComponent), [folder.lastPathComponent])
    }

    func testRemovesAnIdleUnfinishedTransferButKeepsALiveOne() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        try workspace.write("Documents/.incoming/cut/partial.bin", bytes: 4096)

        XCTAssertTrue(importer.cleanStaleIncoming().isEmpty, "a transfer that is still arriving is left alone")
        let later = Date().addingTimeInterval(GameLayout.incomingIdleLimit + 60)
        XCTAssertEqual(importer.cleanStaleIncoming(now: later).map(\.lastPathComponent), ["cut"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url("Documents/.incoming/cut").path))
    }

    func testACopiedFileWithAnOldModificationDateStillCountsAsActivity() throws {
        // devicectl gives a copied file the modification time it had on the Mac: the file arrived just now, but its
        // date says yesterday, and so does the folder's once it is set back the same way.
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        let file = try workspace.write("Documents/.incoming/live/romfs.img", bytes: 4096)
        let yesterday = Date().addingTimeInterval(-86400)
        try FileManager.default.setAttributes([.modificationDate: yesterday], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: yesterday],
                                              ofItemAtPath: workspace.url("Documents/.incoming/live").path)

        XCTAssertTrue(importer.cleanStaleIncoming().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRemovesAnAbandonedTransferAtOnce() throws {
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        try workspace.write("Documents/.incoming/failed/\(GameLayout.abandonedMarker)", "abandoned\n")
        try workspace.write("Documents/.incoming/failed/romfs.img", bytes: 4096)

        XCTAssertEqual(importer.cleanStaleIncoming().map(\.lastPathComponent), ["failed"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url("Documents/.incoming/failed").path))
    }

    func testKeepsACompleteTransferHoweverOld() throws {
        // Importing is the user's move: a game sent overnight is still there in the morning.
        let workspace = try TestWorkspace()
        let importer = try makeImporter(workspace)
        try workspace.write("Documents/.incoming/done/\(GameLayout.completeMarker)", "")
        let nextWeek = Date().addingTimeInterval(7 * 86400)
        XCTAssertTrue(importer.cleanStaleIncoming(now: nextWeek).isEmpty)
        XCTAssertEqual(importer.completedIncoming().map(\.lastPathComponent), ["done"])
    }
}

final class GameLibraryTests: XCTestCase {
    func testListsAGameThatWasImported() throws {
        let workspace = try TestWorkspace()
        let importer = GameImporter(documents: workspace.url("Documents"), log: nil)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        _ = try importer.install(source, identity: identity(), signer: RecordingSigner(identifier: "dev.nxpocketapple.app"))

        let games = GameLibrary.scan(documents: workspace.url("Documents"))
        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games.first?.title, "Fixture Game")
        XCTAssertEqual(games.first?.version, "1.0.0")
        XCTAssertGreaterThan(games.first?.byteCount ?? 0, 0)
    }

    func testReportsADamagedFolderWithoutThrowing() throws {
        let workspace = try TestWorkspace()
        try workspace.write("Documents/games/0100111000200000/package.json", "{ not json }")
        let games = GameLibrary.scan(documents: workspace.url("Documents"))
        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games.first?.title, "Unknown game")
        XCTAssertEqual(games.first?.problem?.code, .packageDamaged)
    }

    func testIgnoresHiddenFoldersAndFiles() throws {
        let workspace = try TestWorkspace()
        try workspace.write("Documents/games/.replaced-abc/package.json", "{}")
        try workspace.write("Documents/games/readme.txt", "x")
        XCTAssertTrue(GameLibrary.scan(documents: workspace.url("Documents")).isEmpty)
    }

    func testDecidesWhenAGameNeedsSigningAgain() throws {
        let workspace = try TestWorkspace()
        let importer = GameImporter(documents: workspace.url("Documents"), log: nil)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        let certificate = identity()
        let game = try importer.install(source, identity: certificate,
                                        signer: RecordingSigner(identifier: certificate.identifier, teamID: certificate.teamID))

        XCTAssertFalse(game.needsResign(against: certificate))
        XCTAssertTrue(game.isSigned(by: certificate))
        XCTAssertTrue(game.needsResign(against: identity(identifier: "dev.nxpocket.other")))
        XCTAssertTrue(game.needsResign(against: certificate, now: Date().addingTimeInterval(5 * 86400)))
    }
}

final class LaunchMarkerTests: XCTestCase {
    func testWritesReadsAndClears() throws {
        let workspace = try TestWorkspace()
        let documents = workspace.url("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        XCTAssertNil(LaunchMarker.read(in: documents))

        try LaunchMarker.write(LaunchMarker(titleID: TitleID("0100111000200000")!), in: documents)
        let marker = try XCTUnwrap(LaunchMarker.read(in: documents))
        XCTAssertEqual(marker.titleID, "0100111000200000")

        LaunchMarker.clear(in: documents)
        XCTAssertNil(LaunchMarker.read(in: documents))
    }

    func testRewritesOverAnExistingMarker() throws {
        let workspace = try TestWorkspace()
        let documents = workspace.url("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try LaunchMarker.write(LaunchMarker(titleID: TitleID("0100111000200000")!), in: documents)
        try LaunchMarker.write(LaunchMarker(titleID: TitleID("0100999999990000")!), in: documents)
        XCTAssertEqual(LaunchMarker.read(in: documents)?.titleID, "0100999999990000")
    }
}

final class ImportLogTests: XCTestCase {
    func testAppendsInOrder() throws {
        let workspace = try TestWorkspace()
        let log = ImportLog(url: workspace.url("import-log.txt"))
        log.append("first")
        log.append("second")
        let text = log.read()
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"))
        XCTAssertLessThan(text.range(of: "first")!.lowerBound, text.range(of: "second")!.lowerBound)
    }

    func testRotatesInsteadOfGrowingForever() throws {
        let workspace = try TestWorkspace()
        let log = ImportLog(url: workspace.url("import-log.txt"), limits: 512)
        for index in 0..<200 { log.append("line \(index) padding padding padding") }
        let size = try FileManager.default.attributesOfItem(atPath: workspace.url("import-log.txt").path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, 1024)
        XCTAssertTrue(log.read().contains("log rotated"))
    }

    func testTwoLogsOnOneFileWritingAtOnceKeepEveryLineWhole() throws {
        // The importer and the app each hold an ImportLog on import-log.txt and write from different threads.
        let workspace = try TestWorkspace()
        let url = workspace.url("import-log.txt")
        let logs = [ImportLog(url: url), ImportLog(url: url)]
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            logs[index % 2].append("writer \(index % 2) line \(index) end")
        }
        let lines = ImportLog(url: url).read().split(separator: "\n")
        XCTAssertEqual(lines.count, 400)
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix(" end") && $0.hasPrefix("[") }, "a line was cut by another writer")
    }
}
