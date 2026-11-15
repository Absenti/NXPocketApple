import XCTest

@testable import NXPocketKit

/// An update of a game this phone holds: the image is built from a clone of the one held and only the blocks that differ come from
/// the source, each checked against the list `package.json` names.
final class DifferentialTests: XCTestCase {
    private let block = 64 << 10
    private let fileManager = FileManager.default

    private func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }

    /// A package whose image is `image`, with the list of its blocks.
    private func package(_ workspace: TestWorkspace, _ folder: String, image: Data, listed: Bool = true) throws -> FolderSource {
        let root = try PackageFixture().write(into: workspace, at: folder)
        try image.write(to: root.appendingPathComponent("romfs.img"))
        var package = try GamePackage.decode(try Data(contentsOf: root.appendingPathComponent(GamePackage.fileName)))
        package.romfsSize = Int64(image.count)
        if listed {
            let list = try RomfsBlocks.digests(of: root.appendingPathComponent("romfs.img"), blockSize: block)
            try list.write(to: root.appendingPathComponent("romfs.blocks"))
            package.romfsBlocks = RomfsBlocks(blockSize: block, sha256: FileDigest.sha256(of: list))
        }
        try package.data().write(to: root.appendingPathComponent(GamePackage.fileName))
        return FolderSource(root: root)
    }

    private func downloader(_ workspace: TestWorkspace, held: URL?, space: Int64? = nil) throws -> PackageDownloader {
        try fileManager.createDirectory(at: workspace.url("Documents/.incoming"), withIntermediateDirectories: true)
        return PackageDownloader(documents: workspace.url("Documents"), availableSpace: { space }, headroom: 0,
                                 maximumMinimumOS: OSVersion(major: 27), checkpointBytes: 2048, reference: { _ in held })
    }

    private func imageReads(_ source: FolderSource) -> [UInt64] { source.reads.filter { $0.path == "romfs.img" }.map(\.offset) }

    private func held(_ workspace: TestWorkspace, _ image: Data) throws -> URL {
        let url = workspace.url("Documents/games/installed/romfs.img")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: url)
        return url
    }

    func testAnImageThatDidNotChangeCostsNoByteOfItAndIsCheckedBlockByBlock() async throws {
        let workspace = try TestWorkspace()
        let image = random(block * 9 + 1234)
        let source = try package(workspace, "server/package", image: image)
        let folder = try await downloader(workspace, held: try held(workspace, image)).download(.fixture(), from: source)
        XCTAssertEqual(imageReads(source), [], "the whole image came from the phone's own copy")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("romfs.img")), image)
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent("romfs.blocks").path))
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent(GameLayout.completeMarker).path))
    }

    func testOnlyTheBlocksThatChangedAreFetchedAndNeighboursShareARequest() async throws {
        let workspace = try TestWorkspace()
        let old = random(block * 12)
        var new = old
        for index in [2, 3, 9] { new.replaceSubrange(index * block..<(index + 1) * block, with: random(block)) }
        let source = try package(workspace, "server/package", image: new)
        let held = try held(workspace, old)

        let folder = try await downloader(workspace, held: held).download(.fixture(), from: source)

        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("romfs.img")), new)
        XCTAssertEqual(imageReads(source), [UInt64(2 * block), UInt64(9 * block)], "blocks 2 and 3 are one request, block 9 another")
        XCTAssertEqual(try Data(contentsOf: held), old, "the installed image is never touched")
    }

    func testAnImageThatGrewFetchesItsNewTailAndOneThatShrankIsCut() async throws {
        let workspace = try TestWorkspace()
        let old = random(block * 5 + 100)
        let grown = old + random(block * 3)
        let source = try package(workspace, "server/grown", image: grown)
        let folder = try await downloader(workspace, held: try held(workspace, old)).download(.fixture(), from: source)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("romfs.img")), grown)
        XCTAssertEqual(imageReads(source), [UInt64(5 * block)], "the block that was partial and the new ones, one request")

        let other = try TestWorkspace()
        let shrunk = Data(old.prefix(block * 2 + 7))
        let smaller = try package(other, "server/shrunk", image: shrunk)
        let cut = try await downloader(other, held: try held(other, old)).download(.fixture(), from: smaller)
        XCTAssertEqual(try Data(contentsOf: cut.appendingPathComponent("romfs.img")), shrunk)
        XCTAssertEqual(imageReads(smaller), [], "the image is a prefix of the old one: cutting the clone is all it takes")
    }

    func testABlockATamperedServerChangedIsRefusedAndTheFolderGoes() async throws {
        let workspace = try TestWorkspace()
        let old = random(block * 4)
        var new = old
        new.replaceSubrange(block..<2 * block, with: random(block))
        let source = try package(workspace, "server/package", image: new)
        source.contentEdit = { path, data in
            guard path == "romfs.img" else { return data }
            var edited = data
            edited[self.block + 5] ^= 0xFF
            return edited
        }
        do {
            _ = try await downloader(workspace, held: try held(workspace, old)).download(.fixture(), from: source)
            XCTFail("a block that is not the list's must be refused")
        } catch let error as NXPocketError {
            XCTAssertEqual(error.code, .hashMismatch)
        }
        XCTAssertTrue(workspace.incomingFolders.isEmpty, "a package fault leaves nothing behind")
    }

    func testAPackageWithoutAListOrAPhoneWithoutAnImageDownloadsWhole() async throws {
        let workspace = try TestWorkspace()
        let image = random(block * 3)
        let plain = try package(workspace, "server/plain", image: image, listed: false)
        _ = try await downloader(workspace, held: try held(workspace, image)).download(.fixture(), from: plain)
        XCTAssertEqual(imageReads(plain), [0], "no list: the image is read whole, from its start")

        let other = try TestWorkspace()
        let listed = try package(other, "server/listed", image: image)
        let folder = try await downloader(other, held: nil).download(.fixture(), from: listed)
        XCTAssertEqual(imageReads(listed), [0], "no image held: nothing to compare with")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("romfs.img")), image)
    }

    func testTheSpaceNeededIsWhatChangedNotTheWholeImage() async throws {
        let workspace = try TestWorkspace()
        let old = random(block * 20)
        var new = old
        new.replaceSubrange(0..<block, with: random(block))
        let source = try package(workspace, "server/package", image: new)
        // Room for one block and a little more: the whole image (20 blocks) would not fit, the change does.
        let folder = try await downloader(workspace, held: try held(workspace, old), space: Int64(block * 4)).download(.fixture(), from: source)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("romfs.img")), new)

        let other = try TestWorkspace()
        let all = try package(other, "server/all", image: random(block * 20))
        do {
            _ = try await downloader(other, held: try held(other, old), space: Int64(block * 4)).download(.fixture(), from: all)
            XCTFail("an image that changed throughout needs the room")
        } catch let error as NXPocketError {
            XCTAssertEqual(error.code, .notEnoughSpace)
        }
    }

    func testAResumeAfterACutComparesAgainAndFetchesOnlyWhatIsStillWrong() async throws {
        let workspace = try TestWorkspace()
        let old = random(block * 10)
        var new = old
        for index in [1, 4, 8] { new.replaceSubrange(index * block..<(index + 1) * block, with: random(block)) }
        let source = try package(workspace, "server/package", image: new)
        source.cutAfterBytes = Int64(block / 2)   // the connection fails inside the first block's run
        let engine = try downloader(workspace, held: try held(workspace, old))
        do { _ = try await engine.download(.fixture(), from: source); XCTFail("the cut must stop the first try") } catch {}
        let before = imageReads(source).count

        let folder = try await engine.download(.fixture(), from: source)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("romfs.img")), new)
        XCTAssertGreaterThan(imageReads(source).count, before)
    }

    func testTheListIsAsTrustedAsThePackageAndNoMore() async throws {
        let workspace = try TestWorkspace()
        let image = random(block * 4)
        let source = try package(workspace, "server/package", image: image)
        source.contentEdit = { path, data in path == "romfs.blocks" ? Data(repeating: 0, count: data.count) : data }
        do {
            _ = try await downloader(workspace, held: try held(workspace, image)).download(.fixture(), from: source)
            XCTFail("a list that is not the one package.json names must be refused")
        } catch let error as NXPocketError {
            XCTAssertEqual(error.code, .hashMismatch)
        }
    }

    func testTheVerifierAcceptsAPackageWithItsListAndTheBlocksAreCountedRight() throws {
        let blocks = RomfsBlocks(blockSize: block, sha256: String(repeating: "a", count: 64))
        XCTAssertEqual(blocks.count(forImageOf: 0), 0)
        XCTAssertEqual(blocks.count(forImageOf: Int64(block)), 1)
        XCTAssertEqual(blocks.count(forImageOf: Int64(block) + 1), 2)
        XCTAssertEqual(blocks.listBytes(forImageOf: Int64(block) * 3), 96)
        XCTAssertFalse(RomfsBlocks(blockSize: 1000, sha256: String(repeating: "a", count: 64)).isValid, "a block is a power of two")
        XCTAssertFalse(RomfsBlocks(blockSize: block, sha256: "nope").isValid)
        let workspace = try TestWorkspace()
        let source = try package(workspace, "game", image: random(block * 2))
        XCTAssertNoThrow(try PackageVerifier.checkRoot(of: source.root, package: try GamePackage.decode(Data(contentsOf: source.root.appendingPathComponent("package.json"))), fileManager: fileManager))
    }

    // MARK: checking and repairing an installed game

    private func installed(_ workspace: TestWorkspace, image: Data) throws -> (root: URL, package: GamePackage, source: FolderSource) {
        let source = try package(workspace, "server/package", image: image)
        let copy = workspace.url("Documents/games/installed")
        try fileManager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source.root, to: copy)
        return (copy, try GamePackage.decode(Data(contentsOf: copy.appendingPathComponent("package.json"))), source)
    }

    func testAnUntouchedImageScansCleanAndAWrongBlockIsFoundAndPutRight() async throws {
        let workspace = try TestWorkspace()
        let image = random(block * 8 + 99)
        let game = try installed(workspace, image: image)
        XCTAssertTrue(try GameRepair.scan(directory: game.root, package: game.package).isClean)

        let url = game.root.appendingPathComponent("romfs.img")
        var damaged = image
        damaged[block * 2 + 1] ^= 0xFF
        damaged[block * 3] ^= 0xFF
        damaged[block * 8 + 50] ^= 0xFF
        try damaged.write(to: url)
        let scan = try GameRepair.scan(directory: game.root, package: game.package)
        XCTAssertEqual(scan.badBlocks, [2, 3, 8])
        XCTAssertFalse(scan.sizeWrong)

        let fixed = try await GameRepair.repair(directory: game.root, package: game.package, scan: scan, from: game.source)
        XCTAssertEqual(fixed, 3)
        XCTAssertEqual(try Data(contentsOf: url), image)
        XCTAssertTrue(try GameRepair.scan(directory: game.root, package: game.package).isClean)
        XCTAssertEqual(game.source.reads.filter { $0.path == "romfs.img" }.map(\.offset), [UInt64(2 * block), UInt64(8 * block)],
                       "blocks 2 and 3 are one request")
    }

    func testAnImageCutShortIsSeenAndGrownBack() async throws {
        let workspace = try TestWorkspace()
        let image = random(block * 5)
        let game = try installed(workspace, image: image)
        let url = game.root.appendingPathComponent("romfs.img")
        try Data(image.prefix(block * 3 + 10)).write(to: url)
        let scan = try GameRepair.scan(directory: game.root, package: game.package)
        XCTAssertTrue(scan.sizeWrong)
        XCTAssertEqual(scan.badBlocks, [3, 4])
        _ = try await GameRepair.repair(directory: game.root, package: game.package, scan: scan, from: game.source)
        XCTAssertEqual(try Data(contentsOf: url), image)
    }

    func testASourceThatHoldsAnotherImageIsNeverMixedIn() async throws {
        let workspace = try TestWorkspace()
        let game = try installed(workspace, image: random(block * 4))
        var damaged = try Data(contentsOf: game.root.appendingPathComponent("romfs.img"))
        damaged[5] ^= 0xFF
        try damaged.write(to: game.root.appendingPathComponent("romfs.img"))
        let scan = try GameRepair.scan(directory: game.root, package: game.package)

        let other = try package(workspace, "server/other", image: random(block * 4))
        do {
            _ = try await GameRepair.repair(directory: game.root, package: game.package, scan: scan, from: other)
            XCTFail("another image must be refused")
        } catch let error as NXPocketError {
            XCTAssertEqual(error.code, .packageInconsistent)
        }
        XCTAssertEqual(try Data(contentsOf: game.root.appendingPathComponent("romfs.img")), damaged, "nothing was written")
    }

    func testATamperedBlockFromTheSourceIsRefusedAndNothingIsWrittenOverTheImage() async throws {
        let workspace = try TestWorkspace()
        let image = random(block * 4)
        let game = try installed(workspace, image: image)
        var damaged = image
        damaged[block + 3] ^= 0xFF
        try damaged.write(to: game.root.appendingPathComponent("romfs.img"))
        let scan = try GameRepair.scan(directory: game.root, package: game.package)
        game.source.contentEdit = { path, data in
            guard path == "romfs.img" else { return data }
            var edited = data
            edited[self.block + 9] ^= 0x55
            return edited
        }
        do {
            _ = try await GameRepair.repair(directory: game.root, package: game.package, scan: scan, from: game.source)
            XCTFail("a block that is not the list's must be refused")
        } catch let error as NXPocketError {
            XCTAssertEqual(error.code, .hashMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: game.root.appendingPathComponent("romfs.img")), damaged)
    }

    func testAGameInstalledWithoutAListCannotBeChecked() throws {
        let workspace = try TestWorkspace()
        let source = try package(workspace, "server/plain", image: random(block * 2), listed: false)
        let package = try GamePackage.decode(Data(contentsOf: source.root.appendingPathComponent("package.json")))
        XCTAssertThrowsError(try GameRepair.scan(directory: source.root, package: package)) { XCTAssertEqual($0 as? GameRepair.Unavailable, .noList) }
    }

    // MARK: going on with another source

    func testADownloadStartedOnOneSourceIsFinishedFromAnotherThatHasTheSameBuild() async throws {
        let workspace = try TestWorkspace()
        let image = random(block * 6)
        let first = try package(workspace, "server/mac", image: image)
        let second = FolderSource(root: workspace.url("server/nas"), sourceID: "nas-other")
        try fileManager.createDirectory(at: workspace.url("server"), withIntermediateDirectories: true)
        try fileManager.copyItem(at: first.root, to: second.root)
        let engine = try downloader(workspace, held: nil)

        first.cutAfterBytes = Int64(block * 3)   // the Mac goes to sleep inside the image
        do { _ = try await engine.download(.fixture(), from: first); XCTFail("the cut must stop the first source") } catch {}
        let kept = workspace.incomingFolders.count
        XCTAssertEqual(kept, 1)

        let folder = try await engine.download(.fixture(), from: second, alsoFrom: [first.sourceID])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("romfs.img")), image)
        XCTAssertEqual(workspace.incomingFolders.count, 1, "the same folder went on: the gigabytes are never kept twice")
        XCTAssertGreaterThan(imageReads(second).first ?? 0, 0, "the second source was asked from where the first stopped")
    }

    func testAnImageThatTwoSourcesPutTogetherIsReadAgainstTheListAndWrongBlocksArePutRight() async throws {
        let workspace = try TestWorkspace()
        let image = random(block * 6)
        let first = try package(workspace, "server/mac", image: image)
        let second = FolderSource(root: workspace.url("server/nas"), sourceID: "nas-other")
        try fileManager.createDirectory(at: workspace.url("server"), withIntermediateDirectories: true)
        try fileManager.copyItem(at: first.root, to: second.root)
        // The first source serves a wrong byte in the part it gives before the cut, and the second is right.
        first.contentEdit = { path, data in
            guard path == "romfs.img" else { return data }
            var edited = data
            edited[10] ^= 0xFF
            return edited
        }
        first.cutAfterBytes = Int64(block * 3)
        let engine = try downloader(workspace, held: nil)
        do { _ = try await engine.download(.fixture(), from: first); XCTFail("the cut must stop the first source") } catch {}

        let folder = try await engine.download(.fixture(), from: second, alsoFrom: [first.sourceID])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("romfs.img")), image, "the wrong block was found and fetched again")
    }

    func testAnotherSourcesFolderIsNotTakenWhenThePackageHasNoList() async throws {
        let workspace = try TestWorkspace()
        let image = random(block * 3)
        let first = try package(workspace, "server/mac", image: image, listed: false)
        let second = FolderSource(root: workspace.url("server/nas"), sourceID: "nas-other")
        try fileManager.createDirectory(at: workspace.url("server"), withIntermediateDirectories: true)
        try fileManager.copyItem(at: first.root, to: second.root)
        first.cutAfterBytes = Int64(block * 2)
        let engine = try downloader(workspace, held: nil)
        do { _ = try await engine.download(.fixture(), from: first); XCTFail() } catch {}
        _ = try await engine.download(.fixture(), from: second, alsoFrom: [first.sourceID])
        XCTAssertEqual(imageReads(second), [0], "nothing can check what two sources made together: the second source starts again")
    }
}
