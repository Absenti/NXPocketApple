import XCTest

@testable import NXPocketKit

final class PackageDownloaderTests: XCTestCase {
    private let titleID = "0100111000200000"
    private let fileManager = FileManager.default

    private func downloadFixture(_ workspace: TestWorkspace, source: FolderSource, downloader: PackageDownloader? = nil) async throws -> URL {
        let downloader = try downloader ?? workspace.makeDownloader()
        return try await downloader.download(.fixture(), from: source)
    }

    private func expectFailure(_ code: NXPocketError.Code, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as NXPocketError {
            XCTAssertEqual(error.code, code, "\(error)", file: file, line: line)
        } catch {
            XCTFail("expected \(code), got \(error)", file: file, line: line)
        }
    }

    // MARK: the whole path

    func testDownloadsAWholePackageAndMarksItComplete() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource(PackageFixture(addOnFiles: ["0.img": 3000, "1.img": 1500]))

        let folder = try await downloadFixture(workspace, source: source)

        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent(GameLayout.completeMarker).path))
        XCTAssertFalse(fileManager.fileExists(atPath: DownloadJournal.url(in: folder).path), "the journal goes once the folder is whole")
        XCTAssertEqual(folder.deletingLastPathComponent().lastPathComponent, ".incoming")
        let verified = try PackageVerifier.verify(folder, options: VerifyOptions(maximumMinimumOS: OSVersion(major: 27)))
        XCTAssertEqual(verified.titleID.description, titleID)
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: folder.appendingPathComponent("romfs.img")),
                       try FileDigest.sha256(ofFileAt: source.root.appendingPathComponent("romfs.img")))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("aoc/1.img")).count, 1500)
        XCTAssertEqual(source.reads.first?.path, GamePackage.fileName, "the plan is made from package.json before any other byte")
    }

    func testTheDownloadedPackageImportsLikeAPushedOne() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        let folder = try await downloadFixture(workspace, source: source)
        let importer = GameImporter(documents: workspace.url("Documents"), log: nil)

        XCTAssertEqual(importer.completedIncoming().map(\.lastPathComponent), [folder.lastPathComponent])
        let game = try importer.install(folder, identity: identity(), signer: RecordingSigner(identifier: "dev.nxpocketapple.app"))

        XCTAssertNil(game.problem)
        XCTAssertEqual(game.titleID.description, titleID)
    }

    func testSavesSurviveAnUpdateThatCameByDownload() async throws {
        let workspace = try TestWorkspace()
        let importer = GameImporter(documents: workspace.url("Documents"), log: nil)
        let signer = RecordingSigner(identifier: "dev.nxpocketapple.app")
        let first = try workspace.makeSource(PackageFixture(name: "Fixture Game"))
        _ = try importer.install(try await downloadFixture(workspace, source: first), identity: identity(), signer: signer)
        try workspace.write("Documents/games/\(titleID)/save/progress.dat", "chapter 3")
        try workspace.write("Documents/games/\(titleID)/save.meta", "meta")

        let second = try workspace.makeSource(PackageFixture(name: "Fixture Game", version: "1.1.0"), folder: "server/second")
        _ = try importer.install(try await downloadFixture(workspace, source: second), identity: identity(), signer: signer)

        XCTAssertEqual(try String(contentsOf: workspace.url("Documents/games/\(titleID)/save/progress.dat"), encoding: .utf8), "chapter 3")
        XCTAssertTrue(fileManager.fileExists(atPath: workspace.url("Documents/games/\(titleID)/save.meta").path))
        XCTAssertEqual(try PackageVerifier.loadPackage(workspace.url("Documents/games/\(titleID)")).version, "1.1.0")
    }

    func testAJournalLeftBesideTheMarkerDoesNotEnterTheLibrary() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        let folder = try await downloadFixture(workspace, source: source)
        try DownloadJournal(sourceID: "x", titleID: titleID, revision: String(repeating: "b", count: 64)).write(in: folder)
        let importer = GameImporter(documents: workspace.url("Documents"), log: nil)

        _ = try importer.install(folder, identity: identity(), signer: RecordingSigner(identifier: "dev.nxpocketapple.app"))

        XCTAssertFalse(fileManager.fileExists(atPath: workspace.url("Documents/games/\(titleID)/\(GameLayout.downloadJournal)").path))
    }

    // MARK: pause, resume, cancel

    func testResumesAfterTheConnectionIsCut() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        let total = try PackageScanner.files(in: source.root).reduce(Int64(0)) { $0 + $1.size }
        source.cutAfterBytes = total - 1500   // the cut lands inside romfs.img, the last file
        let downloader = try workspace.makeDownloader(checkpoint: 1024)

        await expectFailure(.transferFailed) { _ = try await downloader.download(.fixture(), from: source) }

        let waiting = try XCTUnwrap(workspace.incomingFolders.first)
        XCTAssertEqual(workspace.incomingFolders.count, 1, "a network failure keeps what was fetched")
        XCTAssertFalse(fileManager.fileExists(atPath: waiting.appendingPathComponent(GameLayout.completeMarker).path))
        let journal = try XCTUnwrap(DownloadJournal.read(in: waiting))
        XCTAssertEqual(journal.partialPath, "romfs.img")
        XCTAssertGreaterThan(journal.partialOffset, 0)
        XCTAssertEqual(DownloadPackageSupport.pending(workspace).map(\.titleID), [titleID])

        let servedBefore = source.bytesServed
        let folder = try await downloader.download(.fixture(), from: source)

        XCTAssertEqual(folder, waiting, "the same transfer folder carries on")
        let romfsRead = try XCTUnwrap(source.reads.last { $0.path == "romfs.img" })
        XCTAssertEqual(Int64(romfsRead.offset), journal.partialOffset, "the request starts where the journal says")
        XCTAssertLessThan(source.bytesServed - servedBefore, 4096 + 512 + 3000, "bytes already on disk are not fetched again")
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: folder.appendingPathComponent("romfs.img")),
                       try FileDigest.sha256(ofFileAt: source.root.appendingPathComponent("romfs.img")))
        XCTAssertNoThrow(try PackageVerifier.verify(folder, options: VerifyOptions(maximumMinimumOS: OSVersion(major: 27))))
    }

    func testATornTailAfterACrashIsNotTakenForData() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        let total = try PackageScanner.files(in: source.root).reduce(Int64(0)) { $0 + $1.size }
        source.cutAfterBytes = total - 1500
        let downloader = try workspace.makeDownloader(checkpoint: 1024)
        await expectFailure(.transferFailed) { _ = try await downloader.download(.fixture(), from: source) }
        let waiting = try XCTUnwrap(workspace.incomingFolders.first)
        let journal = try XCTUnwrap(DownloadJournal.read(in: waiting))
        // The app died after writing more than it journaled: whatever is past the journaled offset is garbage.
        let handle = try FileHandle(forWritingTo: waiting.appendingPathComponent("romfs.img"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xEE, count: 777))
        try handle.close()

        let folder = try await downloader.download(.fixture(), from: source)

        XCTAssertGreaterThan(journal.partialOffset, 0)
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: folder.appendingPathComponent("romfs.img")),
                       try FileDigest.sha256(ofFileAt: source.root.appendingPathComponent("romfs.img")))
    }

    func testAFileShorterThanTheJournalSaysStartsAgain() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        let total = try PackageScanner.files(in: source.root).reduce(Int64(0)) { $0 + $1.size }
        source.cutAfterBytes = total - 1500
        let downloader = try workspace.makeDownloader(checkpoint: 1024)
        await expectFailure(.transferFailed) { _ = try await downloader.download(.fixture(), from: source) }
        let waiting = try XCTUnwrap(workspace.incomingFolders.first)
        try Data().write(to: waiting.appendingPathComponent("romfs.img"))   // emptied from outside

        let folder = try await downloader.download(.fixture(), from: source)

        XCTAssertEqual(try FileDigest.sha256(ofFileAt: folder.appendingPathComponent("romfs.img")),
                       try FileDigest.sha256(ofFileAt: source.root.appendingPathComponent("romfs.img")))
    }

    func testPausingKeepsTheFolderAndDiscardingRemovesIt() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        let total = try PackageScanner.files(in: source.root).reduce(Int64(0)) { $0 + $1.size }
        source.stallAfterBytes = total - 1000
        let downloader = try workspace.makeDownloader(checkpoint: 1024)

        let task = Task { try await downloader.download(.fixture(), from: source) }
        for _ in 0..<400 where source.bytesServed < total - 1000 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(source.bytesServed, total - 1000, "the source had stalled")
        task.cancel()

        do { _ = try await task.value; XCTFail("a paused download does not finish") }
        catch let error as NXPocketError { XCTAssertEqual(error.code, .cancelled) }

        let waiting = try XCTUnwrap(workspace.incomingFolders.first)
        XCTAssertEqual(DownloadJournal.read(in: waiting)?.partialPath, "romfs.img")
        XCTAssertFalse(fileManager.fileExists(atPath: waiting.appendingPathComponent(GameLayout.completeMarker).path))

        PackageDownloader.discard(sourceID: source.sourceID, titleID: TitleID(titleID)!, documents: workspace.url("Documents"))
        XCTAssertTrue(workspace.incomingFolders.isEmpty, "cancel gives the space back")
    }

    func testAnotherBuildOfTheSameGameReplacesTheWaitingFolder() async throws {
        let workspace = try TestWorkspace()
        let old = try workspace.makeSource(PackageFixture(version: "1.0.0"), folder: "server/old")
        let total = try PackageScanner.files(in: old.root).reduce(Int64(0)) { $0 + $1.size }
        old.cutAfterBytes = total - 1500
        let downloader = try workspace.makeDownloader()
        await expectFailure(.transferFailed) { _ = try await downloader.download(.fixture(), from: old) }
        let waiting = try XCTUnwrap(workspace.incomingFolders.first)

        let new = FolderSource(root: try PackageFixture(version: "2.0.0").write(into: workspace, at: "server/new"), sourceID: old.sourceID)
        let folder = try await downloader.download(.fixture(), from: new)

        XCTAssertNotEqual(folder, waiting)
        XCTAssertEqual(workspace.incomingFolders.count, 1, "the old build's bytes are given back")
        XCTAssertEqual(try PackageVerifier.loadPackage(folder).version, "2.0.0")
    }

    func testARebuildDuringTheDownloadStartsItAgainOnce() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        source.changedOnRead = 3

        let folder = try await downloadFixture(workspace, source: source)

        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent(GameLayout.completeMarker).path))
        XCTAssertEqual(workspace.incomingFolders.count, 1)
    }

    func testAGameThatKeepsChangingIsGivenUpOn() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        source.changedEveryTime = true
        let downloader = try workspace.makeDownloader()

        await expectFailure(.transferFailed) { _ = try await downloader.download(.fixture(), from: source) }

        XCTAssertTrue(workspace.incomingFolders.isEmpty)
    }

    // MARK: a source that cannot be trusted

    func testALongerBodyThanTheFileIsRefusedAndTheFolderRemoved() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        source.contentEdit = { path, data in path == "romfs.img" ? data + Data(repeating: 1, count: 5000) : data }
        source.lengthLie = nil
        let downloader = try workspace.makeDownloader()

        await expectFailure(.sizeMismatch) { _ = try await downloader.download(.fixture(), from: source) }

        XCTAssertTrue(workspace.incomingFolders.isEmpty, "a package that is itself wrong is not kept")
    }

    func testAnEndlessBodyStopsAtTheFilesSize() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        source.contentEdit = { path, data in path == "romfs.img" ? data + Data(repeating: 1, count: 1 << 20) : data }
        source.lengthLie = 100   // announces less than it sends
        let downloader = try workspace.makeDownloader()

        await expectFailure(.sizeMismatch) { _ = try await downloader.download(.fixture(), from: source) }

        XCTAssertLessThan(source.bytesServed, 600_000, "the connection is dropped, not drained")
    }

    func testATamperedFrameworkFileIsRefusedByItsHash() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        source.contentEdit = { path, data in
            guard path.hasSuffix("/DmGame") else { return data }
            var copy = data
            copy[copy.count / 2] ^= 0xFF
            return copy
        }
        let downloader = try workspace.makeDownloader()

        await expectFailure(.hashMismatch) { _ = try await downloader.download(.fixture(), from: source) }

        XCTAssertTrue(workspace.incomingFolders.isEmpty)
        XCTAssertFalse(source.reads.contains { $0.path == "romfs.img" }, "nothing big is fetched after a bad hash")
    }

    func testABodyThatStartsAtAnotherOffsetIsRefused() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        source.offsetLie = 5
        let downloader = try workspace.makeDownloader()

        // package.json is the first read: the lie is caught before a plan exists, and nothing is written.
        await expectFailure(.transferFailed) { _ = try await downloader.download(.fixture(), from: source) }

        XCTAssertTrue(workspace.incomingFolders.isEmpty)
    }

    func testAListingThatDiffersFromThePlanIsRefusedBeforeAnyFileIsFetched() async throws {
        let cases: [(String, NXPocketError.Code, (inout RemotePackageListing) -> Void)] = [
            ("an extra file", .packageInconsistent, { $0.files.append(RemotePackageFile(path: "extra.bin", size: 4)) }),
            ("a save entry", .packageInconsistent, { $0.files.append(RemotePackageFile(path: "save/progress.dat", size: 4)) }),
            ("a missing framework file", .packageMissing, { $0.files.removeAll { $0.path.hasSuffix("/DmGame") } }),
            ("a missing romfs", .packageMissing, { $0.files.removeAll { $0.path == "romfs.img" } }),
            ("a duplicate", .packageDamaged, { $0.files.append($0.files[0]) }),
            ("a traversal", .unsafePath, { $0.files.append(RemotePackageFile(path: "../../escape", size: 1)) }),
            ("an absolute path", .unsafePath, { $0.files.append(RemotePackageFile(path: "/etc/passwd", size: 1)) }),
            ("a wrong size", .sizeMismatch, { listing in
                let index = listing.files.firstIndex { $0.path == "romfs.img" }!
                listing.files[index].size += 1 }),
            ("another revision", .hashMismatch, { $0.revision = String(repeating: "c", count: 64) }),
            ("add-ons nobody counted", .sizeMismatch, { $0.files.append(RemotePackageFile(path: "aoc/0.img", size: 10)) })
        ]
        for (label, code, edit) in cases {
            let workspace = try TestWorkspace()
            let source = try workspace.makeSource()
            source.listingEdit = edit
            let downloader = try workspace.makeDownloader()

            await expectFailure(code) { _ = try await downloader.download(.fixture(), from: source) }

            XCTAssertEqual(source.reads.map(\.path), [GamePackage.fileName], "\(label): only package.json was read")
            XCTAssertTrue(workspace.incomingFolders.isEmpty, "\(label): nothing was written")
        }
    }

    func testAPackageForAnotherGameIsRefused() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource(PackageFixture(titleID: "0100AAAA00000000"))
        let downloader = try workspace.makeDownloader()

        await expectFailure(.packageInconsistent) { _ = try await downloader.download(.fixture(), from: source) }
    }

    func testAGameNeedingANewerOSIsNotDownloaded() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource(PackageFixture(minimumOS: "99.0"))
        let downloader = try workspace.makeDownloader()

        await expectFailure(.minimumOSNewer) { _ = try await downloader.download(.fixture(), from: source) }

        XCTAssertEqual(source.reads.map(\.path), [GamePackage.fileName])
    }

    // MARK: space

    func testNotEnoughSpaceIsReportedBeforeAnythingIsWritten() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        let downloader = try workspace.makeDownloader(space: 2000)

        do {
            _ = try await downloader.download(.fixture(), from: source)
            XCTFail("expected a refusal")
        } catch let error as NXPocketError {
            XCTAssertEqual(error.code, .notEnoughSpace)
            XCTAssertTrue(error.detail.contains("needed"), error.detail)
        }

        XCTAssertTrue(workspace.incomingFolders.isEmpty)
        XCTAssertEqual(source.reads.map(\.path), [GamePackage.fileName])
    }

    func testTheSpaceNeededIsWhatIsStillToFetch() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        let total = try PackageScanner.files(in: source.root).reduce(Int64(0)) { $0 + $1.size }
        source.cutAfterBytes = total - 1500
        let downloader = try workspace.makeDownloader(checkpoint: 1024)
        await expectFailure(.transferFailed) { _ = try await downloader.download(.fixture(), from: source) }

        // Room for the 1.5 kB left plus the largest framework file, not for the whole package again.
        let tight = try workspace.makeDownloader(space: 1500 + 4096, checkpoint: 1024)
        let folder = try await tight.download(.fixture(), from: source)

        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent(GameLayout.completeMarker).path))
    }

    // MARK: the marker

    func testNoMarkerBeforeEveryFileIsWhole() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        let total = try PackageScanner.files(in: source.root).reduce(Int64(0)) { $0 + $1.size }
        source.cutAfterBytes = total - 1
        let downloader = try workspace.makeDownloader()

        await expectFailure(.transferFailed) { _ = try await downloader.download(.fixture(), from: source) }

        for folder in workspace.incomingFolders {
            XCTAssertFalse(fileManager.fileExists(atPath: folder.appendingPathComponent(GameLayout.completeMarker).path))
        }
        XCTAssertTrue(GameImporter(documents: workspace.url("Documents"), log: nil).completedIncoming().isEmpty)
    }

    // MARK: a link planted where a file goes

    func testALinkPlantedWhereAFileGoesIsNotWrittenThrough() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.makeSource()
        let total = try PackageScanner.files(in: source.root).reduce(Int64(0)) { $0 + $1.size }
        source.cutAfterBytes = total - 1500
        let downloader = try workspace.makeDownloader(checkpoint: 1024)
        await expectFailure(.transferFailed) { _ = try await downloader.download(.fixture(), from: source) }
        let waiting = try XCTUnwrap(workspace.incomingFolders.first)
        let victim = try workspace.write("Documents/victim.txt", "precious")
        try fileManager.removeItem(at: waiting.appendingPathComponent("romfs.img"))
        try fileManager.createSymbolicLink(at: waiting.appendingPathComponent("romfs.img"), withDestinationURL: victim)

        await expectFailure(.symbolicLink) { _ = try await downloader.download(.fixture(), from: source) }

        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "precious")
    }
}

/// The few places a test reads what `PackageDownloader` exposes for a screen.
enum DownloadPackageSupport {
    static func pending(_ workspace: TestWorkspace) -> [PendingDownload] {
        PackageDownloader.pending(documents: workspace.url("Documents"))
    }
}
