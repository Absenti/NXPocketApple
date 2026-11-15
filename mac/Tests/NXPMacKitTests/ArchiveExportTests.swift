import XCTest
import NXPocketKit

@testable import NXPMacKit

/// A built game as an archive with its hash, and that archive going into the iPhone's importer: the same code the phone runs, on what the
/// launcher made.
final class ArchiveExportTests: XCTestCase {
    private var workspace: URL!
    private var built: URL!
    private let titleID = ShareFixture.titleID

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-export-\(UUID().uuidString)", isDirectory: true)
        built = workspace.appendingPathComponent("built", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try ShareFixture.build(in: built, scratch: workspace)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: workspace) }

    private var package: URL { built.appendingPathComponent("\(titleID).nxgame") }

    func testTheArchiveHasTheHashItSaysAndTheIPhoneUnpacksItWithThatHash() async throws {
        // What a Finder or a build leaves beside a game is not sent.
        for stray in [".DS_Store", ".signing.json", ".complete"] { try Data("x".utf8).write(to: package.appendingPathComponent(stray)) }
        let archive = workspace.appendingPathComponent("out.zip")

        let result = try await ArchiveExport.export(package: package, to: archive) { _ in }

        XCTAssertEqual(result.url, archive)
        XCTAssertEqual(result.sha256, try FileDigest.sha256(ofFileAt: archive), "the hash is the file's own")
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".out.zip.partial").path), "no partial file is left")

        let documents = workspace.appendingPathComponent("Phone", isDirectory: true)
        let folder = try GameArchiveImporter(documents: documents, headroom: 0).importArchive(archive, expectedSHA256: result.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".complete").path))
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: folder.appendingPathComponent("romfs.img")),
                       try FileDigest.sha256(ofFileAt: package.appendingPathComponent("romfs.img")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".signing.json").path))
    }

    func testTheBigFilesAreStoredNotCompressedAndTheListingHasNoStrayFiles() async throws {
        try Data("x".utf8).write(to: package.appendingPathComponent(".DS_Store"))
        let archive = workspace.appendingPathComponent("out.zip")
        _ = try await ArchiveExport.export(package: package, to: archive) { _ in }
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-v", archive.path]
        let pipe = Pipe()
        listing.standardOutput = pipe
        try listing.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        listing.waitUntilExit()
        let image = text.split(separator: "\n").first { $0.contains("romfs.img") }.map(String.init) ?? ""
        XCTAssertTrue(image.contains("Stored"), image)
        XCTAssertFalse(text.contains(".DS_Store"))
    }

    func testAChangedArchiveDoesNotMatchTheHashItWasGiven() async throws {
        let archive = workspace.appendingPathComponent("out.zip")
        let result = try await ArchiveExport.export(package: package, to: archive) { _ in }
        var data = try Data(contentsOf: archive)
        data[data.count / 2] ^= 0xFF
        try data.write(to: archive)
        let documents = workspace.appendingPathComponent("Phone", isDirectory: true)
        XCTAssertThrowsError(try GameArchiveImporter(documents: documents, headroom: 0).importArchive(archive, expectedSHA256: result.sha256)) {
            XCTAssertEqual(($0 as? NXPocketError)?.code, .hashMismatch)
        }
    }

    func testOnlyABuiltGameIsExportedAndAFailureLeavesNothing() async throws {
        let other = workspace.appendingPathComponent("Not A Game.nxgame")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        do { _ = try await ArchiveExport.export(package: other, to: workspace.appendingPathComponent("x.zip")) { _ in }; XCTFail() }
        catch let error as NXPocketError { XCTAssertEqual(error.code, .packageInconsistent) }

        let broken = workspace.appendingPathComponent("zip-broken")
        try Data("#!/bin/sh\necho 'zip error: disk full' >&2\nexit 15\n".utf8).write(to: broken)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        do { _ = try await ArchiveExport.export(package: package, to: workspace.appendingPathComponent("y.zip"), zip: broken) { _ in }; XCTFail() }
        catch let error as NXPocketError { XCTAssertTrue(error.detail.contains("disk full"), error.detail) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("y.zip").path))
    }

    func testTheSuggestedNameIsSafeAndNamesTheGame() throws {
        let game = LocalGame(root: package, package: try GamePackage.decode(Data(contentsOf: package.appendingPathComponent("package.json"))))
        let name = ArchiveExport.suggestedName(for: game)
        XCTAssertTrue(name.hasSuffix("\(titleID).zip"))
        XCTAssertFalse(name.contains("/"))
    }
}
