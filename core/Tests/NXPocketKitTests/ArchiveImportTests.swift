import XCTest
import zlib

@testable import NXPocketKit

/// A build that arrives as an archive: unpacked, found, checked and handed to the importer, and every way an archive can lie about
/// itself refused with nothing left behind.
final class ArchiveImportTests: XCTestCase {
    private let block = 64 << 10
    private let fileManager = FileManager.default

    // MARK: fixtures

    private func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }

    /// A build as the launcher writes one: the fixture package with an image of several blocks and the list of them.
    private func build(_ workspace: TestWorkspace, at folder: String = "builds/0100111000200000.nxgame", corrupt: Bool = false,
                       addOns: [String: Int] = [:]) throws -> URL {
        let root = try PackageFixture(addOnFiles: addOns).write(into: workspace, at: folder)
        let image = random(block * 5 + 321)
        try image.write(to: root.appendingPathComponent("romfs.img"))
        var package = try GamePackage.decode(Data(contentsOf: root.appendingPathComponent("package.json")))
        package.romfsSize = Int64(image.count)
        let list = try RomfsBlocks.digests(of: root.appendingPathComponent("romfs.img"), blockSize: block)
        try list.write(to: root.appendingPathComponent("romfs.blocks"))
        package.romfsBlocks = RomfsBlocks(blockSize: block, sha256: FileDigest.sha256(of: list))
        try package.data().write(to: root.appendingPathComponent("package.json"))
        if corrupt {
            var damaged = image
            damaged[block * 2 + 5] ^= 0xFF
            try damaged.write(to: root.appendingPathComponent("romfs.img"))
        }
        return root
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], in directory: URL, environment: [String: String] = [:]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func importer(_ workspace: TestWorkspace, space: Int64? = nil) -> GameArchiveImporter {
        GameArchiveImporter(documents: workspace.url("Documents"), availableSpace: { space }, headroom: 0)
    }

    private func expectFailure(_ code: NXPocketError.Code, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        do { try body(); XCTFail("expected \(code)", file: file, line: line) }
        catch let error as NXPocketError { XCTAssertEqual(error.code, code, "\(error)", file: file, line: line) }
        catch { XCTFail("expected \(code), got \(error)", file: file, line: line) }
    }

    private func leftovers(_ workspace: TestWorkspace) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: workspace.url("Documents/.incoming").path)) ?? []).sorted()
    }

    private func assertImportable(_ folder: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent(".complete").path), file: file, line: line)
        let verified = try PackageVerifier.verify(folder, options: VerifyOptions(verifyRomfsIdentity: false, maximumMinimumOS: OSVersion(major: 27)))
        XCTAssertEqual(verified.titleID.description, "0100111000200000", file: file, line: line)
    }

    // MARK: the formats

    func testAZipOfTheBuildFolderIsUnpackedCheckedAndHandedOver() throws {
        let workspace = try TestWorkspace()
        _ = try build(workspace)
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "../out.zip", "0100111000200000.nxgame"], in: workspace.url("builds")), 0)

        let folder = try importer(workspace).importArchive(workspace.url("out.zip"))

        try assertImportable(folder)
        XCTAssertEqual(leftovers(workspace), [folder.lastPathComponent], "nothing is left beside the transfer")
        XCTAssertTrue(fileManager.fileExists(atPath: workspace.url("out.zip").path), "the archive is the player's: it is not touched")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("romfs.img")),
                       try Data(contentsOf: workspace.url("builds/0100111000200000.nxgame/romfs.img")))
    }

    func testStoredDeflatedAndZip64ArchivesAllUnpack() throws {
        let workspace = try TestWorkspace()
        _ = try build(workspace)
        for (name, flags) in [("stored.zip", ["-0"]), ("deflated.zip", ["-9"]), ("zip64.zip", ["-fz"])] {
            XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q"] + flags + ["../\(name)", "0100111000200000.nxgame"], in: workspace.url("builds")), 0, name)
            let folder = try importer(workspace).importArchive(workspace.url(name))
            try assertImportable(folder)
            try fileManager.removeItem(at: folder)
        }
    }

    func testTarAndTarGzAreUnpackedWithLongNames() throws {
        let workspace = try TestWorkspace()
        let long = String(repeating: "long-name-", count: 14) + ".img"
        _ = try build(workspace, addOns: [long: 1_500])
        for (name, flags) in [("a.tar", ["-cf"]), ("a.tar.gz", ["-czf"])] {
            XCTAssertEqual(try run("/usr/bin/tar", flags + ["../\(name)", "0100111000200000.nxgame"], in: workspace.url("builds"),
                                   environment: ["COPYFILE_DISABLE": "1"]), 0, name)
            let folder = try importer(workspace).importArchive(workspace.url(name))
            try assertImportable(folder)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("aoc/\(long)")).count, 1_500, "a name over a hundred bytes survives")
            try fileManager.removeItem(at: folder)
        }
    }

    func testTheBuildMayBeAtTheTopOrTwoFoldersDeep() throws {
        let workspace = try TestWorkspace()
        let root = try build(workspace)
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "../../top.zip", "."], in: root), 0)
        try assertImportable(try importer(workspace).importArchive(workspace.url("top.zip")))

        let deep = workspace.url("wrapped/My Games/Collection")
        try fileManager.createDirectory(at: deep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: root, to: deep)
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "../deep.zip", "My Games"], in: workspace.url("wrapped")), 0)
        try assertImportable(try importer(workspace).importArchive(workspace.url("deep.zip")))
    }

    func testAnArchiveWithNoBuildOrSeveralIsRefused() throws {
        let workspace = try TestWorkspace()
        try workspace.write("stuff/readme.txt", "hello")
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "none.zip", "stuff"], in: workspace.root), 0)
        expectFailure(.packageMissing) { _ = try importer(workspace).importArchive(workspace.url("none.zip")) }

        _ = try build(workspace, at: "two/a/0100111000200000.nxgame")
        _ = try build(workspace, at: "two/b/0100111000200000.nxgame")
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "../two.zip", "."], in: workspace.url("two")), 0)
        expectFailure(.packageMissing) { _ = try importer(workspace).importArchive(workspace.url("two.zip")) }
        XCTAssertEqual(leftovers(workspace), [], "a refused archive leaves nothing")
    }

    func testFormatsThatAreNotReadAreSaidSoAndNotMistakenForDamage() throws {
        let workspace = try TestWorkspace()
        for (name, magic) in [("a.7z", Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4])), ("a.rar", Data("Rar!\u{1A}\u{07}\u{01}\u{00}".utf8)),
                              ("a.xz", Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0, 0])), ("a.bin", Data("not an archive at all".utf8))] {
            try (magic + Data(count: 600)).write(to: workspace.url(name))
            let expected: NXPocketError.Code = name == "a.bin" ? .packageDamaged : .packageUnsupported
            expectFailure(expected) { _ = try importer(workspace).importArchive(workspace.url(name)) }
        }
        XCTAssertEqual(ArchiveExtractor.detect(workspace.url("a.rar")), .rar)
        XCTAssertEqual(leftovers(workspace), [])
    }

    // MARK: what the archive may not do

    func testAnArchiveCutShortOrDamagedIsRefusedAndNothingStays() throws {
        let workspace = try TestWorkspace()
        _ = try build(workspace)
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "../full.zip", "0100111000200000.nxgame"], in: workspace.url("builds")), 0)
        let data = try Data(contentsOf: workspace.url("full.zip"))
        try data.prefix(data.count / 2).write(to: workspace.url("cut.zip"))
        expectFailure(.packageDamaged) { _ = try importer(workspace).importArchive(workspace.url("cut.zip")) }

        XCTAssertEqual(try run("/usr/bin/tar", ["-czf", "../full.tgz", "0100111000200000.nxgame"], in: workspace.url("builds"), environment: ["COPYFILE_DISABLE": "1"]), 0)
        let tgz = try Data(contentsOf: workspace.url("full.tgz"))
        try tgz.prefix(tgz.count / 2).write(to: workspace.url("cut.tgz"))
        expectFailure(.packageDamaged) { _ = try importer(workspace).importArchive(workspace.url("cut.tgz")) }
        XCTAssertEqual(leftovers(workspace), [])
    }

    func testAnImageThatDoesNotMatchItsListIsFoundBeforeTheImporterSeesIt() throws {
        let workspace = try TestWorkspace()
        _ = try build(workspace, corrupt: true)
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "../bad.zip", "0100111000200000.nxgame"], in: workspace.url("builds")), 0)
        expectFailure(.hashMismatch) { _ = try importer(workspace).importArchive(workspace.url("bad.zip")) }
        XCTAssertEqual(leftovers(workspace), [])
    }

    func testAPathThatLeavesTheFolderIsRefusedBeforeAnythingIsWritten() throws {
        let workspace = try TestWorkspace()
        let archive = workspace.url("slip.zip")
        try ZipFixture.write([("../escape.txt", Data("x".utf8)), ("0100111000200000.nxgame/package.json", Data("{}".utf8))], to: archive)
        expectFailure(.unsafePath) { _ = try importer(workspace).importArchive(archive) }
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.url("Documents/escape.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.url("escape.txt").path))
        for bad in ["/etc/passwd", "a/../../b", "a\\b"] {
            try ZipFixture.write([(bad, Data("x".utf8))], to: archive)
            expectFailure(.unsafePath) { _ = try importer(workspace).importArchive(archive) }
        }
        XCTAssertEqual(leftovers(workspace), [])
    }

    func testALinkAnEncryptedEntryAndANameThatCollidesAreRefused() throws {
        let workspace = try TestWorkspace()
        let root = try build(workspace)
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("evil"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "-y", "../link.zip", "0100111000200000.nxgame"], in: workspace.url("builds")), 0)
        expectFailure(.symbolicLink) { _ = try importer(workspace).importArchive(workspace.url("link.zip")) }
        try fileManager.removeItem(at: root.appendingPathComponent("evil"))

        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "-P", "secret", "../locked.zip", "0100111000200000.nxgame"], in: workspace.url("builds")), 0)
        expectFailure(.packageUnsupported) { _ = try importer(workspace).importArchive(workspace.url("locked.zip")) }

        try ZipFixture.write([("Game/File.txt", Data("1".utf8)), ("Game/file.txt", Data("2".utf8))], to: workspace.url("case.zip"))
        expectFailure(.packageInconsistent) { _ = try importer(workspace).importArchive(workspace.url("case.zip")) }
        XCTAssertEqual(leftovers(workspace), [])
    }

    func testAFileThatDoesNotMatchItsChecksumOrItsSizeIsRefused() throws {
        let workspace = try TestWorkspace()
        let archive = workspace.url("lie.zip")
        try ZipFixture.write([("0100111000200000.nxgame/package.json", Data("{}".utf8))], to: archive, crcLie: true)
        expectFailure(.hashMismatch) { _ = try importer(workspace).importArchive(archive) }
        try ZipFixture.write([("0100111000200000.nxgame/package.json", Data("{}".utf8))], to: archive, sizeLie: true)
        // A size longer than the data reads on into what follows, and is refused by the size or by the checksum, whichever comes first.
        do { _ = try importer(workspace).importArchive(archive); XCTFail("must be refused") }
        catch let error as NXPocketError { XCTAssertTrue([.sizeMismatch, .hashMismatch, .packageDamaged].contains(error.code), "\(error)") }
        XCTAssertEqual(leftovers(workspace), [])
    }

    func testTheSpaceIsCheckedBeforeAByteIsWrittenForAZip() throws {
        let workspace = try TestWorkspace()
        _ = try build(workspace)
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "../out.zip", "0100111000200000.nxgame"], in: workspace.url("builds")), 0)
        expectFailure(.notEnoughSpace) { _ = try importer(workspace, space: 10_000).importArchive(workspace.url("out.zip")) }
        XCTAssertEqual(leftovers(workspace), [])
    }

    func testTheMarkersOfATransferInsideAnArchiveAreNotUnpacked() throws {
        let workspace = try TestWorkspace()
        let root = try build(workspace)
        try Data("x".utf8).write(to: root.appendingPathComponent(".complete"))
        try Data("{}".utf8).write(to: root.appendingPathComponent(".signing.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent(".download.json"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "../marked.zip", "0100111000200000.nxgame"], in: workspace.url("builds")), 0)
        let folder = try importer(workspace).importArchive(workspace.url("marked.zip"))
        try assertImportable(folder)
        for name in [".signing.json", ".download.json", ".DS_Store"] {
            XCTAssertFalse(fileManager.fileExists(atPath: folder.appendingPathComponent(name).path), name)
        }
    }

    // MARK: the hash of the archive

    func testAnArchiveWhoseHashIsGivenIsUnpackedOnlyIfItMatches() throws {
        let workspace = try TestWorkspace()
        _ = try build(workspace)
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "../out.zip", "0100111000200000.nxgame"], in: workspace.url("builds")), 0)
        let archive = workspace.url("out.zip")
        let hash = try FileDigest.sha256(ofFileAt: archive)

        let spaced = hash.uppercased().enumerated().map { $0.offset % 8 == 7 ? "\($0.element) " : String($0.element) }.joined()
        let folder = try importer(workspace).importArchive(archive, expectedSHA256: spaced)
        try assertImportable(folder)
        try fileManager.removeItem(at: folder)

        expectFailure(.hashMismatch) { _ = try importer(workspace).importArchive(archive, expectedSHA256: String(repeating: "0", count: 64)) }
        expectFailure(.packageDamaged) { _ = try importer(workspace).importArchive(archive, expectedSHA256: "not a hash") }
        XCTAssertEqual(leftovers(workspace), [], "a refused hash leaves nothing: nothing was unpacked")
    }

    func testTheHashIsCheckedBeforeAnythingIsUnpackedAndSaysSoInItsProgress() throws {
        let workspace = try TestWorkspace()
        _ = try build(workspace)
        XCTAssertEqual(try run("/usr/bin/zip", ["-r", "-q", "../out.zip", "0100111000200000.nxgame"], in: workspace.url("builds")), 0)
        let archive = workspace.url("out.zip")
        let stages = StageLog()
        _ = try importer(workspace).importArchive(archive, expectedSHA256: try FileDigest.sha256(ofFileAt: archive)) { stage, _ in stages.add(stage) }
        XCTAssertEqual(stages.values.first, .hashing)
        XCTAssertTrue(stages.values.contains(.unpacking))
        XCTAssertEqual(GameArchiveImporter.normalisedDigest("AB:CD " + String(repeating: "0", count: 60)), "abcd" + String(repeating: "0", count: 60))
        XCTAssertNil(GameArchiveImporter.normalisedDigest("abcd"))
    }

    // MARK: a build that is a folder

    func testAFolderIsCopiedCheckedAndHandedOverAsAnArchiveIs() throws {
        let workspace = try TestWorkspace()
        let root = try build(workspace)
        try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        let folder = try importer(workspace).importFolder(root)
        try assertImportable(folder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("romfs.img")), try Data(contentsOf: root.appendingPathComponent("romfs.img")))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("romfs.img").path), "the player's folder is untouched")
        XCTAssertFalse(fileManager.fileExists(atPath: folder.appendingPathComponent(".DS_Store").path))
    }

    func testAFolderThatHoldsTheBuildOneLevelDownIsFoundToo() throws {
        let workspace = try TestWorkspace()
        _ = try build(workspace, at: "wrapper/Games/0100111000200000.nxgame")
        try assertImportable(try importer(workspace).importFolder(workspace.url("wrapper")))
    }

    func testAFolderWithALinkADamagedImageNoBuildOrNoRoomIsRefusedAndNothingStays() throws {
        let workspace = try TestWorkspace()
        let root = try build(workspace)
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("evil"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        expectFailure(.symbolicLink) { _ = try importer(workspace).importFolder(root) }
        try fileManager.removeItem(at: root.appendingPathComponent("evil"))

        expectFailure(.notEnoughSpace) { _ = try importer(workspace, space: 10_000).importFolder(root) }

        let bad = try build(workspace, at: "bad/0100111000200000.nxgame", corrupt: true)
        expectFailure(.hashMismatch) { _ = try importer(workspace).importFolder(bad) }

        try workspace.write("empty/readme.txt", "hello")
        expectFailure(.packageMissing) { _ = try importer(workspace).importFolder(workspace.url("empty")) }
        expectFailure(.packageMissing) { _ = try importer(workspace).importFolder(workspace.url("nowhere")) }
        XCTAssertEqual(leftovers(workspace), [])
    }

    func testAnEmptyOrTinyFileIsNotAnArchive() throws {
        let workspace = try TestWorkspace()
        try Data().write(to: workspace.url("empty.zip"))
        try Data([0x50, 0x4B]).write(to: workspace.url("tiny.zip"))
        expectFailure(.packageDamaged) { _ = try importer(workspace).importArchive(workspace.url("empty.zip")) }
        expectFailure(.packageDamaged) { _ = try importer(workspace).importArchive(workspace.url("tiny.zip")) }
    }
}

/// A .zip written by hand, to say what the tools would not: a path out of the folder, a wrong checksum, a wrong size.
enum ZipFixture {
    static func write(_ entries: [(String, Data)], to url: URL, crcLie: Bool = false, sizeLie: Bool = false) throws {
        var body = Data()
        var directory = Data()
        func le16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
        func le32(_ value: UInt32) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]) }
        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            var crc = UInt32(truncatingIfNeeded: data.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(data.count)) })
            if crcLie { crc ^= 0xDEAD_BEEF }
            let declared = UInt32(sizeLie ? data.count + 5 : data.count)
            let offset = UInt32(body.count)
            body += le32(0x0403_4B50) + le16(20) + le16(0x800) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(declared) + le32(declared)
            body += le16(nameBytes.count) + le16(0) + nameBytes + data
            directory += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0x800) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(declared) + le32(declared)
            directory += le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes
        }
        let end = le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(UInt32(directory.count)) + le32(UInt32(body.count)) + le16(0)
        try (body + directory + end).write(to: url)
    }
}

private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [GameArchiveImporter.Stage] = []
    func add(_ stage: GameArchiveImporter.Stage) { lock.withLock { if all.last != stage { all.append(stage) } } }
    var values: [GameArchiveImporter.Stage] { lock.withLock { all } }
}
